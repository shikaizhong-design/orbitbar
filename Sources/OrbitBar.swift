import AppKit
import CoreGraphics
import Foundation
import ObjectiveC.runtime

// MARK: - Quota Data Model
// Reads dual-window quota percentages from:
//   1. Upstream CodexBar widget-snapshot.json (App Group or Application Support)
//   2. Optional codexbar-summary.json (for membership-summary forks)
//   3. Built-in fallback from CodexBar's own switcher quota indicator bar

struct ProviderRingData: Equatable {
    let weeklyPct: Double?      // Outer ring: weekly / 30d remaining % (0...100)
    let shortPct: Double?       // Inner ring: 5h / daily remaining % (0...100), nil if single-window
    let weeklyLabel: String
    let shortLabel: String?
    let detailTooltip: String
    let hasData: Bool
}

enum MenuBarIconStyle: String {
    case color      // Default: vibrant teal outer + warm amber inner
    case monochrome // Native macOS template monochrome dual rings
    case native     // Leave CodexBar's original menu bar icon untouched

    static func current() -> MenuBarIconStyle {
        if let raw = UserDefaults.standard.string(forKey: "OrbitBarMenuBarStyle")?.lowercased(),
           let style = MenuBarIconStyle(rawValue: raw)
        {
            return style
        }
        return .color
    }
}

private enum OrbitLocale {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    static var outerLegend: String { isChinese ? "外圈 周额度" : "Outer Weekly" }
    static var innerLegend: String { isChinese ? "内圈 5小时" : "Inner 5h" }
    static var overviewTip: String { isChinese ? "全部账号总览 · 外圈周额度 / 内圈5小时" : "Overview · Outer Weekly / Inner 5h" }
    static var noShortLimit: String { isChinese ? "无 5h 限" : "Single window" }
    static var defaultWeekly: String { isChinese ? "周" : "Weekly" }
    static var defaultShort: String { isChinese ? "5 小时" : "5h" }
}

final class QuotaSnapshotStore: @unchecked Sendable {
    static let shared = QuotaSnapshotStore()

    private struct SourceFile {
        let url: URL
        let kind: Kind
        enum Kind { case widgetSnapshot, membershipSummary }
    }

    private var sources: [SourceFile] = []
    private var lastMTimes: [URL: Date] = [:]
    private var cache: [String: ProviderRingData] = [:]
    private var topRecommendedKey: String?
    private var dirWatchers: [DispatchSourceFileSystemObject] = []
    var onChange: (() -> Void)?

    private init() {
        self.sources = Self.discoverSources()
        self.reloadIfNeeded(force: true)
        self.startWatchingDirectories()
    }

    private static func discoverSources() -> [SourceFile] {
        var found: [SourceFile] = []
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)

        // 1. Optional membership summary JSON (if present)
        let summaryURL = appSupport
            .appendingPathComponent("会员额度看板", isDirectory: true)
            .appendingPathComponent("codexbar-summary.json")
        found.append(SourceFile(url: summaryURL, kind: .membershipSummary))

        // 2. Upstream CodexBar App Group widget-snapshot.json
        let groupRoot = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        let knownGroups = [
            "Y5PE65HELJ.com.steipete.codexbar",
            "group.com.steipete.codexbar",
            "Y5PE65HELJ.com.steipete.codexbar.debug",
            "group.com.steipete.codexbar.debug",
        ]
        var seenDirs = Set<URL>()
        for g in knownGroups {
            let dir = groupRoot.appendingPathComponent(g, isDirectory: true)
            seenDirs.insert(dir)
            found.append(SourceFile(url: dir.appendingPathComponent("widget-snapshot.json"), kind: .widgetSnapshot))
        }
        if let entries = try? fm.contentsOfDirectory(at: groupRoot, includingPropertiesForKeys: nil) {
            for dir in entries where dir.lastPathComponent.lowercased().contains("codexbar") && !seenDirs.contains(dir) {
                found.append(SourceFile(url: dir.appendingPathComponent("widget-snapshot.json"), kind: .widgetSnapshot))
            }
        }

        // 3. Upstream CodexBar Application Support fallback
        let appSupportSnapshot = appSupport
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
        found.append(SourceFile(url: appSupportSnapshot, kind: .widgetSnapshot))

        return found
    }

    private func startWatchingDirectories() {
        var watchedDirs = Set<String>()
        for src in self.sources {
            let dirPath = src.url.deletingLastPathComponent().path
            guard !watchedDirs.contains(dirPath) else { continue }
            let fd = open(dirPath, O_EVTONLY)
            guard fd >= 0 else { continue }
            watchedDirs.insert(dirPath)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename],
                queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if self.reloadIfNeeded(force: false) {
                    DispatchQueue.main.async {
                        self.onChange?()
                    }
                }
            }
            source.setCancelHandler { [fd] in
                close(fd)
            }
            source.resume()
            self.dirWatchers.append(source)
        }
    }

    @discardableResult
    func reloadIfNeeded(force: Bool = false) -> Bool {
        let fm = FileManager.default
        var anyChanged = force
        var latestMTimes: [URL: Date] = [:]

        for src in self.sources {
            if let attrs = try? fm.attributesOfItem(atPath: src.url.path),
               let mtime = attrs[.modificationDate] as? Date
            {
                latestMTimes[src.url] = mtime
                if self.lastMTimes[src.url] != mtime {
                    anyChanged = true
                }
            }
        }
        guard anyChanged else { return false }

        var merged: [String: ProviderRingData] = [:]
        var recKey: String?

        // Load widget snapshots first (broad coverage across all upstream providers)
        for src in self.sources where src.kind == .widgetSnapshot {
            guard latestMTimes[src.url] != nil,
                  let raw = try? Data(contentsOf: src.url),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
            else { continue }
            let parsed = Self.parseWidgetSnapshot(obj)
            for (k, v) in parsed {
                merged[k] = v
            }
        }

        // Overlay membership summary if present (includes explicit recommendation ordering)
        for src in self.sources where src.kind == .membershipSummary {
            guard latestMTimes[src.url] != nil,
                  let raw = try? Data(contentsOf: src.url),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let accounts = obj["accounts"] as? [String: [String: Any]]
            else { continue }
            let parsed = Self.parseMembershipAccounts(accounts)
            for (k, v) in parsed {
                merged[k] = v
            }
            if let rows = obj["rows"] as? [[String: Any]],
               let first = rows.first(where: { ($0["rank"] as? Int) == 1 }),
               let title = first["title"] as? String
            {
                recKey = Self.canonicalKey(forTitle: title)
            } else if let rec = obj["recommendation"] as? String, !rec.isEmpty {
                recKey = Self.canonicalKey(forTitle: rec)
            }
        }

        self.lastMTimes = latestMTimes
        if !merged.isEmpty {
            self.cache = merged
        }
        self.topRecommendedKey = recKey
        return true
    }

    func ringData(forTitle title: String) -> ProviderRingData? {
        return self.cache[Self.canonicalKey(forTitle: title)]
    }

    func statusBarRingData(selectedTitle: String?) -> ProviderRingData? {
        if let title = selectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let lower = title.lowercased()
            if lower != "overview" && lower != "总览",
               let hit = self.cache[Self.canonicalKey(forTitle: title)]
            {
                return hit
            }
        } else {
            let wasOverview = UserDefaults.standard.bool(forKey: "mergedMenuLastSelectedWasOverview")
            if !wasOverview,
               let saved = UserDefaults.standard.string(forKey: "selectedMenuProvider"),
               let hit = self.cache[Self.canonicalKey(forTitle: saved)]
            {
                return hit
            }
        }
        if let top = self.topRecommendedKey, let hit = self.cache[top] {
            return hit
        }
        return self.cache["claude"] ?? self.cache["antigravity"] ?? self.cache["codex"] ?? self.cache.values.first
    }

    static func canonicalKey(forTitle title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("claude") { return "claude" }
        if t.contains("antigravity") || t.contains("gemini") { return "antigravity" }
        if t.contains("codex") || t.contains("openai") { return "codex" }
        if t.contains("kimi") || t.contains("moonshot") { return "kimi" }
        if t.contains("glm") || t.contains("z.ai") || t.contains("zai") || t.contains("智谱") { return "glm" }
        if t.contains("grok") || t.contains("xai") { return "grok" }
        if t.contains("devin") { return "devin" }
        if t.contains("cursor") { return "cursor" }
        if t.contains("copilot") { return "copilot" }
        if t.contains("amp") { return "amp" }
        if t.contains("augment") { return "augment" }
        if t.contains("minimax") { return "minimax" }
        if t.contains("deepseek") { return "deepseek" }
        if t.contains("qwen") { return "qwen" }
        return t
    }

    // MARK: Upstream CodexBar widget-snapshot.json parser

    private static func parseWidgetSnapshot(_ obj: [String: Any]) -> [String: ProviderRingData] {
        guard let entries = obj["entries"] as? [[String: Any]] else { return [:] }
        var result: [String: ProviderRingData] = [:]

        for entry in entries {
            let providerRaw: String
            if let s = entry["provider"] as? String {
                providerRaw = s
            } else if let dict = entry["provider"] as? [String: Any], let raw = dict["rawValue"] as? String {
                providerRaw = raw
            } else {
                continue
            }
            let key = Self.canonicalKey(forTitle: providerRaw)

            var windows: [(remaining: Double, minutes: Int?, title: String?)] = []
            for field in ["primary", "secondary", "tertiary"] {
                guard let w = entry[field] as? [String: Any] else { continue }
                if (w["isSyntheticPlaceholder"] as? Bool) == true { continue }
                let used: Double
                if let d = w["usedPercent"] as? Double { used = d }
                else if let n = w["usedPercent"] as? NSNumber { used = n.doubleValue }
                else { continue }
                let rem = max(0, min(100, 100.0 - used))
                let mins = (w["windowMinutes"] as? Int) ?? (w["windowMinutes"] as? NSNumber)?.intValue
                let title = w["title"] as? String
                windows.append((rem, mins, title))
            }
            guard !windows.isEmpty else { continue }

            var weeklyPct: Double?
            var weeklyLabel = OrbitLocale.defaultWeekly
            var shortPct: Double?
            var shortLabel: String?

            for w in windows {
                let mins = w.minutes
                let lowerTitle = (w.title ?? "").lowercased()
                let isShort: Bool
                if let m = mins {
                    isShort = m <= 1440 // <= 24h (5h = 300m, daily = 1440m)
                } else {
                    isShort = lowerTitle.contains("5h") || lowerTitle.contains("session")
                        || lowerTitle.contains("hour") || lowerTitle.contains("daily")
                }

                if isShort {
                    if shortPct == nil || w.remaining < shortPct! {
                        shortPct = w.remaining
                        shortLabel = (mins == 1440) ? (OrbitLocale.isChinese ? "日" : "Daily") : OrbitLocale.defaultShort
                    }
                } else {
                    if weeklyPct == nil || w.remaining < weeklyPct! {
                        weeklyPct = w.remaining
                        if let m = mins, m >= 40000 {
                            weeklyLabel = OrbitLocale.isChinese ? "30 天" : "30d"
                        } else {
                            weeklyLabel = OrbitLocale.defaultWeekly
                        }
                    }
                }
            }

            // If only a single short window existed (rare), map it cleanly so the ring still renders
            if weeklyPct == nil, let onlyShort = shortPct {
                weeklyPct = onlyShort
                weeklyLabel = shortLabel ?? OrbitLocale.defaultShort
                shortPct = nil
                shortLabel = nil
            }

            let wStr = weeklyPct.map { "\(weeklyLabel) \(Int($0.rounded()))%" } ?? ""
            let sStr = shortPct.map { "\(shortLabel ?? OrbitLocale.defaultShort) \(Int($0.rounded()))%" } ?? OrbitLocale.noShortLimit
            let tip = "\(providerRaw)\n" + [wStr, sStr].filter { !$0.isEmpty }.joined(separator: " · ")

            result[key] = ProviderRingData(
                weeklyPct: weeklyPct,
                shortPct: shortPct,
                weeklyLabel: weeklyLabel,
                shortLabel: shortLabel,
                detailTooltip: tip,
                hasData: true)
        }
        return result
    }

    // MARK: Membership summary codexbar-summary.json parser

    private static func serviceKey(accountKey: String, account: [String: Any]) -> String {
        if let svc = account["service"] as? String { return Self.canonicalKey(forTitle: svc) }
        if let name = account["displayName"] as? String { return Self.canonicalKey(forTitle: name) }
        if accountKey.hasPrefix("a") { return "antigravity" }
        if accountKey.hasPrefix("c") && accountKey != "cl" { return "codex" }
        if accountKey == "cl" { return "claude" }
        if accountKey == "ki" { return "kimi" }
        if accountKey == "gl" { return "glm" }
        if accountKey == "gr" { return "grok" }
        if accountKey == "dv" { return "devin" }
        return accountKey.lowercased()
    }

    private struct PoolSample {
        let name: String
        let weeklyPct: Double?
        let weeklyLabel: String
        let shortPct: Double?
        let shortLabel: String?
    }

    private static func parseMembershipAccounts(_ accounts: [String: [String: Any]]) -> [String: ProviderRingData] {
        var grouped: [String: [PoolSample]] = [:]
        var displayNames: [String: String] = [:]

        for (accKey, acc) in accounts {
            let svc = Self.serviceKey(accountKey: accKey, account: acc)
            if let dn = acc["displayName"] as? String, displayNames[svc] == nil {
                displayNames[svc] = dn
            }
            guard let pools = acc["p"] as? [[String: Any]], !pools.isEmpty else { continue }
            for pool in pools {
                let poolName = (pool["name"] as? String) ?? ""
                guard let windows = pool["w"] as? [[Any]], !windows.isEmpty else { continue }
                var wkPct: Double?
                var wkLabel = OrbitLocale.defaultWeekly
                var shPct: Double?
                var shLabel: String?

                for w in windows {
                    guard w.count >= 2, let label = w[0] as? String else { continue }
                    let val: Double
                    if let d = w[1] as? Double { val = d }
                    else if let i = w[1] as? Int { val = Double(i) }
                    else if let n = w[1] as? NSNumber { val = n.doubleValue }
                    else { continue }

                    let clamped = max(0, min(100, val))
                    let lower = label.lowercased()
                    if lower.contains("5") || lower.contains("小时") || lower.contains("hour") || lower.contains("session") {
                        shPct = clamped
                        shLabel = label
                    } else if lower.contains("日") || lower.contains("day") {
                        if shPct == nil {
                            shPct = clamped
                            shLabel = label
                        }
                    } else {
                        if wkPct == nil || lower.contains("周") || lower.contains("week") {
                            wkPct = clamped
                            wkLabel = label
                        }
                    }
                }
                if wkPct != nil || shPct != nil {
                    grouped[svc, default: []].append(PoolSample(
                        name: poolName,
                        weeklyPct: wkPct,
                        weeklyLabel: wkLabel,
                        shortPct: shPct,
                        shortLabel: shLabel))
                }
            }
        }

        var result: [String: ProviderRingData] = [:]
        for (svc, samples) in grouped {
            let chosen = samples.min { lhs, rhs in
                let lw = lhs.weeklyPct ?? 101
                let rw = rhs.weeklyPct ?? 101
                if abs(lw - rw) > 0.05 { return lw < rw }
                return (lhs.shortPct ?? 101) < (rhs.shortPct ?? 101)
            } ?? samples[0]

            let title = displayNames[svc] ?? svc
            let tipLines: [String] = samples.map { s in
                let prefix = samples.count > 1 && !s.name.isEmpty ? "\(s.name): " : ""
                let wStr = s.weeklyPct.map { "\(s.weeklyLabel) \(Int($0.rounded()))%" } ?? ""
                let sStr = s.shortPct.map { "\(s.shortLabel ?? OrbitLocale.defaultShort) \(Int($0.rounded()))%" } ?? OrbitLocale.noShortLimit
                return [prefix + wStr, sStr].filter { !$0.isEmpty }.joined(separator: " · ")
            }

            result[svc] = ProviderRingData(
                weeklyPct: chosen.weeklyPct,
                shortPct: chosen.shortPct,
                weeklyLabel: chosen.weeklyLabel,
                shortLabel: chosen.shortLabel,
                detailTooltip: "\(title)\n" + tipLines.joined(separator: "\n"),
                hasData: true)
        }
        return result
    }
}

// MARK: - CoreGraphics Dual-Ring Retina Renderer

enum OrbitRingRenderer {
    static let dialSize: CGFloat = 36.0

    static func renderOverviewMedallion(
        glyph: NSImage?,
        isSelected: Bool,
        isDark: Bool
    ) -> NSImage {
        let size = NSSize(width: dialSize, height: dialSize)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 15.2

            let fillColor: NSColor
            let strokeColor: NSColor
            let glyphTint: NSColor

            if isSelected {
                fillColor = NSColor.white.withAlphaComponent(0.18)
                strokeColor = NSColor.white.withAlphaComponent(0.55)
                glyphTint = NSColor.white
            } else if isDark {
                fillColor = NSColor.white.withAlphaComponent(0.08)
                strokeColor = NSColor.white.withAlphaComponent(0.20)
                glyphTint = NSColor.white.withAlphaComponent(0.88)
            } else {
                fillColor = NSColor.black.withAlphaComponent(0.045)
                strokeColor = NSColor.black.withAlphaComponent(0.14)
                glyphTint = NSColor.black.withAlphaComponent(0.76)
            }

            let circleRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2)
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(1.15)
            ctx.strokeEllipse(in: circleRect.insetBy(dx: 0.6, dy: 0.6))

            if let glyph {
                Self.drawTintedGlyph(glyph, in: ctx, center: center, boxSize: 15.0, tint: glyphTint)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    static func renderProviderDualRing(
        glyph: NSImage?,
        data: ProviderRingData?,
        fallbackWeeklyPct: Double?,
        isSelected: Bool,
        isDark: Bool
    ) -> NSImage {
        let size = NSSize(width: dialSize, height: dialSize)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerR: CGFloat = 15.6
            let outerW: CGFloat = 2.9
            let innerR: CGFloat = 11.1
            let innerW: CGFloat = 2.15

            let weeklyPct = data?.weeklyPct ?? fallbackWeeklyPct
            let shortPct = data?.shortPct
            let hasAnyData = (weeklyPct != nil || shortPct != nil)

            let outerTrack: NSColor
            let innerTrack: NSColor
            let outerStroke: NSColor
            let innerStroke: NSColor
            let glyphTint: NSColor

            if isSelected {
                outerTrack = NSColor.white.withAlphaComponent(0.24)
                innerTrack = NSColor.white.withAlphaComponent(0.18)
                outerStroke = (weeklyPct ?? 100) < 20
                    ? NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.42, alpha: 1.0)
                    : NSColor.white
                innerStroke = (shortPct ?? 100) < 20
                    ? NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.62, alpha: 1.0)
                    : NSColor(calibratedRed: 1.0, green: 0.87, blue: 0.36, alpha: 1.0)
                glyphTint = NSColor.white.withAlphaComponent(hasAnyData ? 1.0 : 0.78)
            } else if isDark {
                outerTrack = NSColor.white.withAlphaComponent(hasAnyData ? 0.14 : 0.09)
                innerTrack = NSColor.white.withAlphaComponent(hasAnyData ? 0.10 : 0.06)
                outerStroke = (weeklyPct ?? 100) < 20
                    ? NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.24, alpha: 1.0)
                    : NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.76, alpha: 1.0)
                innerStroke = (shortPct ?? 100) < 20
                    ? NSColor(calibratedRed: 0.99, green: 0.44, blue: 0.44, alpha: 1.0)
                    : NSColor(calibratedRed: 0.99, green: 0.60, blue: 0.24, alpha: 1.0)
                glyphTint = NSColor.white.withAlphaComponent(hasAnyData ? 0.90 : 0.45)
            } else {
                outerTrack = NSColor.black.withAlphaComponent(hasAnyData ? 0.11 : 0.075)
                innerTrack = NSColor.black.withAlphaComponent(hasAnyData ? 0.08 : 0.05)
                outerStroke = (weeklyPct ?? 100) < 20
                    ? NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.04, alpha: 1.0)
                    : NSColor(calibratedRed: 0.05, green: 0.58, blue: 0.53, alpha: 1.0)
                innerStroke = (shortPct ?? 100) < 20
                    ? NSColor(calibratedRed: 0.86, green: 0.19, blue: 0.19, alpha: 1.0)
                    : NSColor(calibratedRed: 0.92, green: 0.41, blue: 0.06, alpha: 1.0)
                glyphTint = NSColor.black.withAlphaComponent(hasAnyData ? 0.82 : 0.44)
            }

            Self.strokeCircle(in: ctx, center: center, radius: outerR, width: outerW, color: outerTrack, dash: nil)
            if let wp = weeklyPct, wp > 0.5 {
                Self.strokeArc(
                    in: ctx,
                    center: center,
                    radius: outerR,
                    width: outerW,
                    fraction: CGFloat(wp / 100.0),
                    color: outerStroke)
            }

            if hasAnyData {
                if let sp = shortPct {
                    if sp <= 0.5 {
                        let warnColor = isSelected
                            ? NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.62, alpha: 0.95)
                            : NSColor(calibratedRed: 0.92, green: 0.24, blue: 0.24, alpha: 0.92)
                        Self.strokeCircle(in: ctx, center: center, radius: innerR, width: innerW, color: warnColor, dash: [2.6, 2.4])
                    } else {
                        Self.strokeCircle(in: ctx, center: center, radius: innerR, width: innerW, color: innerTrack, dash: nil)
                        Self.strokeArc(
                            in: ctx,
                            center: center,
                            radius: innerR,
                            width: innerW,
                            fraction: CGFloat(sp / 100.0),
                            color: innerStroke)
                    }
                } else {
                    let singleColor = isSelected
                        ? NSColor.white.withAlphaComponent(0.28)
                        : (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14))
                    Self.strokeCircle(in: ctx, center: center, radius: innerR, width: 1.35, color: singleColor, dash: [2.0, 2.6])
                }
            } else {
                Self.strokeCircle(in: ctx, center: center, radius: innerR, width: 1.6, color: innerTrack, dash: nil)
            }

            if let glyph {
                Self.drawTintedGlyph(glyph, in: ctx, center: center, boxSize: 12.2, tint: glyphTint)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    static func renderStatusBarDualRing(
        data: ProviderRingData?,
        isLightMenuBar: Bool,
        style: MenuBarIconStyle
    ) -> NSImage {
        let size = NSSize(width: 18.0, height: 18.0)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerR: CGFloat = 7.4
            let outerW: CGFloat = 2.15
            let innerR: CGFloat = 4.2
            let innerW: CGFloat = 1.75

            let track = isLightMenuBar
                ? NSColor.black.withAlphaComponent(0.18)
                : NSColor.white.withAlphaComponent(0.28)

            let outerFill: NSColor
            let innerFill: NSColor
            let warnAmber: NSColor
            let dangerRed: NSColor

            if style == .monochrome {
                let fg = isLightMenuBar ? NSColor.black.withAlphaComponent(0.88) : NSColor.white
                outerFill = fg
                innerFill = fg.withAlphaComponent(0.80)
                warnAmber = fg
                dangerRed = fg
            } else {
                outerFill = isLightMenuBar
                    ? NSColor(calibratedRed: 0.04, green: 0.56, blue: 0.51, alpha: 1.0)
                    : NSColor(calibratedRed: 0.28, green: 0.93, blue: 0.84, alpha: 1.0)
                innerFill = isLightMenuBar
                    ? NSColor(calibratedRed: 0.92, green: 0.42, blue: 0.05, alpha: 1.0)
                    : NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.28, alpha: 1.0)
                warnAmber = isLightMenuBar
                    ? NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.04, alpha: 1.0)
                    : NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.24, alpha: 1.0)
                dangerRed = isLightMenuBar
                    ? NSColor(calibratedRed: 0.86, green: 0.16, blue: 0.16, alpha: 1.0)
                    : NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.36, alpha: 1.0)
            }

            let weeklyPct = data?.weeklyPct
            let shortPct = data?.shortPct

            Self.strokeCircle(in: ctx, center: center, radius: outerR, width: outerW, color: track, dash: nil)
            if let wp = weeklyPct, wp > 0.5 {
                Self.strokeArc(
                    in: ctx,
                    center: center,
                    radius: outerR,
                    width: outerW,
                    fraction: CGFloat(wp / 100.0),
                    color: wp < 20 ? warnAmber : outerFill)
            } else if data == nil {
                Self.strokeArc(in: ctx, center: center, radius: outerR, width: outerW, fraction: 0.75, color: outerFill)
            }

            if let sp = shortPct {
                if sp <= 0.5 {
                    Self.strokeCircle(in: ctx, center: center, radius: innerR, width: innerW, color: dangerRed, dash: [1.8, 1.8])
                } else {
                    Self.strokeCircle(in: ctx, center: center, radius: innerR, width: innerW, color: track, dash: nil)
                    Self.strokeArc(
                        in: ctx,
                        center: center,
                        radius: innerR,
                        width: innerW,
                        fraction: CGFloat(sp / 100.0),
                        color: sp < 20 ? dangerRed : innerFill)
                }
            } else if data != nil {
                Self.strokeCircle(in: ctx, center: center, radius: innerR, width: 1.2, color: track, dash: [1.6, 2.0])
            } else {
                Self.strokeCircle(in: ctx, center: center, radius: innerR, width: innerW, color: track, dash: nil)
                Self.strokeArc(in: ctx, center: center, radius: innerR, width: innerW, fraction: 0.5, color: innerFill)
            }

            return true
        }
        img.isTemplate = false
        return img
    }

    private static func strokeCircle(
        in ctx: CGContext,
        center: CGPoint,
        radius: CGFloat,
        width: CGFloat,
        color: NSColor,
        dash: [CGFloat]?
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func strokeArc(
        in ctx: CGContext,
        center: CGPoint,
        radius: CGFloat,
        width: CGFloat,
        fraction: CGFloat,
        color: NSColor
    ) {
        let clamped = max(0.015, min(1.0, fraction))
        let startAngle = CGFloat.pi / 2.0
        let endAngle = startAngle - clamped * CGFloat.pi * 2.0

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawTintedGlyph(
        _ glyph: NSImage,
        in ctx: CGContext,
        center: CGPoint,
        boxSize: CGFloat,
        tint: NSColor
    ) {
        var proposed = CGRect(x: center.x - boxSize / 2, y: center.y - boxSize / 2, width: boxSize, height: boxSize)
        guard let cg = glyph.cgImage(forProposedRect: &proposed, context: NSGraphicsContext.current, hints: nil) else {
            return
        }
        let aspect = cg.height > 0 ? CGFloat(cg.width) / CGFloat(cg.height) : 1.0
        let drawW: CGFloat = aspect >= 1 ? boxSize : boxSize * aspect
        let drawH: CGFloat = aspect >= 1 ? boxSize / aspect : boxSize
        let drawRect = CGRect(x: center.x - drawW / 2, y: center.y - drawH / 2, width: drawW, height: drawH)

        ctx.saveGState()
        ctx.clip(to: drawRect, mask: cg)
        ctx.setFillColor(tint.cgColor)
        ctx.fill(drawRect)
        ctx.restoreGState()
    }
}

#if !PREVIEW_PNG

// MARK: - Non-Invasive Runtime Integration

private nonisolated(unsafe) var kOriginalIconKey: UInt8 = 0
private nonisolated(unsafe) var kDidUpgradeSwitcherKey: UInt8 = 0
private nonisolated(unsafe) var kUpgradedHeightKey: UInt8 = 0
private nonisolated(unsafe) var kLegendViewKey: UInt8 = 0

private final class OrbitLegendView: NSView {
    private let outerDot = NSView()
    private let outerLabel = NSTextField(labelWithString: OrbitLocale.outerLegend)
    private let innerDot = NSView()
    private let innerLabel = NSTextField(labelWithString: OrbitLocale.innerLegend)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.wantsLayer = true

        for dot in [outerDot, innerDot] {
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.0
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6.0),
                dot.heightAnchor.constraint(equalToConstant: 6.0),
            ])
        }

        let font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        for lbl in [outerLabel, innerLabel] {
            lbl.font = font
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.lineBreakMode = .byClipping
        }

        let stack = NSStackView(views: [outerDot, outerLabel, innerDot, innerLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4.0
        stack.setCustomSpacing(12.0, after: outerLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
        self.updateColors(isDark: false)
    }

    required init?(coder: NSCoder) { nil }

    func updateColors(isDark: Bool) {
        self.outerDot.layer?.backgroundColor = (isDark
            ? NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.76, alpha: 1.0)
            : NSColor(calibratedRed: 0.05, green: 0.58, blue: 0.53, alpha: 1.0)).cgColor
        self.innerDot.layer?.backgroundColor = (isDark
            ? NSColor(calibratedRed: 0.99, green: 0.60, blue: 0.24, alpha: 1.0)
            : NSColor(calibratedRed: 0.92, green: 0.41, blue: 0.06, alpha: 1.0)).cgColor
        let textColor = isDark
            ? NSColor.white.withAlphaComponent(0.48)
            : NSColor.black.withAlphaComponent(0.45)
        self.outerLabel.textColor = textColor
        self.innerLabel.textColor = textColor
    }
}

@MainActor
final class OrbitBarController {
    static let shared = OrbitBarController()

    private let trackedSwitchers = NSHashTable<NSView>.weakObjects()
    private let trackedStatusButtons = NSHashTable<NSButton>.weakObjects()
    private var activeSelectedTitle: String?

    private static let upgradedRowHeight: CGFloat = 58.0
    private static let upgradedRowSpacing: CGFloat = 5.0
    private static let legendHeight: CGFloat = 15.0
    private static let legendTopGap: CGFloat = 3.0

    private init() {
        QuotaSnapshotStore.shared.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshAll(reloadJSON: false)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAll(reloadJSON: true)
            }
        }
    }

    nonisolated static func isSwitcherView(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return NSStringFromClass(type(of: view)).contains("ProviderSwitcherView")
    }

    nonisolated static func isStackedButton(_ view: NSView) -> Bool {
        return NSStringFromClass(type(of: view)).contains("StackedToggleButton")
    }

    func registerAndUpgrade(_ switcher: NSView) {
        self.trackedSwitchers.add(switcher)
        QuotaSnapshotStore.shared.reloadIfNeeded(force: false)
        self.upgradeLayoutIfNeeded(switcher)
        self.refreshRings(in: switcher)
    }

    func refreshAll(reloadJSON: Bool) {
        if reloadJSON {
            QuotaSnapshotStore.shared.reloadIfNeeded(force: false)
        }
        for switcher in self.trackedSwitchers.allObjects {
            self.upgradeLayoutIfNeeded(switcher)
            self.refreshRings(in: switcher)
        }
        self.refreshAllStatusButtons()
    }

    func registerAndRenderStatusButton(_ button: NSButton) -> NSImage? {
        guard MenuBarIconStyle.current() != .native else { return nil }
        self.trackedStatusButtons.add(button)
        QuotaSnapshotStore.shared.reloadIfNeeded(force: false)
        return self.makeStatusBarImage(for: button)
    }

    func refreshAllStatusButtons() {
        guard MenuBarIconStyle.current() != .native else { return }
        for btn in self.trackedStatusButtons.allObjects {
            self.applyStatusBarImage(to: btn)
        }
    }

    func refreshStatusButton(_ button: NSButton) {
        guard MenuBarIconStyle.current() != .native else { return }
        self.trackedStatusButtons.add(button)
        self.applyStatusBarImage(to: button)
    }

    private func applyStatusBarImage(to button: NSButton) {
        guard let origSet = gOrigStatusButtonSetImage, button.image != nil else { return }
        let img = self.makeStatusBarImage(for: button)
        origSet(button, #selector(setter: NSButton.image), img)
    }

    private func makeStatusBarImage(for button: NSButton) -> NSImage {
        let match = button.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        let isLightBar = (match == .aqua || match == .vibrantLight)
        let data = QuotaSnapshotStore.shared.statusBarRingData(selectedTitle: self.activeSelectedTitle)
        return OrbitRingRenderer.renderStatusBarDualRing(
            data: data,
            isLightMenuBar: isLightBar,
            style: MenuBarIconStyle.current())
    }

    func refreshSingleButton(_ button: NSButton) {
        guard let switcher = button.superview,
              Self.isSwitcherView(switcher),
              (objc_getAssociatedObject(switcher, &kDidUpgradeSwitcherKey) as? Bool) == true
        else { return }
        let isDark = Self.isDarkAppearance(switcher)
        self.renderButton(button, isDark: isDark)
        if button.state == .on {
            self.refreshAllStatusButtons()
        }
    }

    private static func isDarkAppearance(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func stackedButtons(in switcher: NSView) -> [NSButton] {
        switcher.subviews.compactMap { v -> NSButton? in
            guard let btn = v as? NSButton, Self.isStackedButton(btn) else { return nil }
            return btn
        }
    }

    private func extractStackParts(from button: NSButton) -> (NSStackView, NSImageView, NSTextField)? {
        guard let stack = button.subviews.first(where: { $0 is NSStackView }) as? NSStackView,
              let iconView = stack.arrangedSubviews.first(where: { $0 is NSImageView }) as? NSImageView,
              let titleField = stack.arrangedSubviews.first(where: { $0 is NSTextField }) as? NSTextField
        else { return nil }
        return (stack, iconView, titleField)
    }

    private func hideOldIndicators(in button: NSButton) {
        for sub in button.subviews where !(sub is NSStackView) {
            sub.alphaValue = 0
            sub.layer?.opacity = 0
        }
    }

    private func fallbackWeeklyPercent(fromHiddenIndicatorIn button: NSButton) -> Double? {
        for sub in button.subviews where !(sub is NSStackView) {
            if let fill = sub.subviews.first, sub.frame.width > 4 {
                let ratio = Double(fill.frame.width / sub.frame.width)
                if ratio >= 0 && ratio <= 1.05 {
                    return max(0, min(100, ratio * 100.0))
                }
            }
        }
        return nil
    }

    private func upgradeLayoutIfNeeded(_ switcher: NSView) {
        let buttons = self.stackedButtons(in: switcher)
        guard !buttons.isEmpty else { return }

        if (objc_getAssociatedObject(switcher, &kDidUpgradeSwitcherKey) as? Bool) == true {
            return
        }
        objc_setAssociatedObject(switcher, &kDidUpgradeSwitcherKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        for button in buttons {
            button.wantsLayer = true
            button.layer?.cornerRadius = 10.0
            self.hideOldIndicators(in: button)

            for c in button.constraints where c.firstAttribute == .height && c.secondItem == nil {
                if c.constant < Self.upgradedRowHeight {
                    c.constant = Self.upgradedRowHeight
                }
            }

            if let (stack, iconView, titleField) = self.extractStackParts(from: button) {
                if objc_getAssociatedObject(button, &kOriginalIconKey) == nil, let orig = iconView.image {
                    objc_setAssociatedObject(button, &kOriginalIconKey, orig, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }

                stack.spacing = 2.0
                titleField.font = NSFont.systemFont(ofSize: 10.0, weight: .medium)

                for c in iconView.constraints where (c.firstAttribute == .width || c.firstAttribute == .height) && c.secondItem == nil {
                    c.constant = OrbitRingRenderer.dialSize
                }
                iconView.imageScaling = .scaleProportionallyDown

                for c in button.constraints where (c.firstItem as? NSView) === stack {
                    if c.firstAttribute == .top { c.constant = 3.0 }
                    else if c.firstAttribute == .bottom { c.constant = -2.0 }
                    else if c.firstAttribute == .leading { c.constant = 3.0 }
                    else if c.firstAttribute == .trailing { c.constant = -3.0 }
                }
            }
        }

        let containers = switcher.subviews.filter { !($0 is NSButton) && !($0 is OrbitLegendView) }
        var detectedRows = 1
        if let gridContainer = containers.first {
            let rowViews = gridContainer.subviews
            if !rowViews.isEmpty {
                detectedRows = rowViews.count
                for row in rowViews {
                    for c in row.constraints where c.firstAttribute == .height && c.secondItem == nil {
                        if c.constant < Self.upgradedRowHeight {
                            c.constant = Self.upgradedRowHeight
                        }
                    }
                }
                for c in gridContainer.constraints where c.firstAttribute == .top && c.secondAttribute == .bottom {
                    c.constant = Self.upgradedRowSpacing
                }
            }

            for c in switcher.constraints where c.firstAttribute == .bottom && c.secondAttribute == .bottom {
                if (c.firstItem as? NSView) === gridContainer && (c.secondItem as? NSView) === switcher {
                    c.constant = -(Self.legendHeight + Self.legendTopGap)
                } else if (c.secondItem as? NSView) === gridContainer && (c.firstItem as? NSView) === switcher {
                    c.constant = (Self.legendHeight + Self.legendTopGap)
                }
            }
        }

        let legend = OrbitLegendView(frame: .zero)
        switcher.addSubview(legend)
        NSLayoutConstraint.activate([
            legend.leadingAnchor.constraint(equalTo: switcher.leadingAnchor, constant: 10),
            legend.trailingAnchor.constraint(equalTo: switcher.trailingAnchor, constant: -10),
            legend.bottomAnchor.constraint(equalTo: switcher.bottomAnchor, constant: -1),
            legend.heightAnchor.constraint(equalToConstant: Self.legendHeight),
        ])
        objc_setAssociatedObject(switcher, &kLegendViewKey, legend, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let totalHeight = CGFloat(detectedRows) * Self.upgradedRowHeight
            + CGFloat(max(0, detectedRows - 1)) * Self.upgradedRowSpacing
            + Self.legendHeight + Self.legendTopGap
        objc_setAssociatedObject(switcher, &kUpgradedHeightKey, NSNumber(value: Double(totalHeight)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        var frame = switcher.frame
        if abs(frame.size.height - totalHeight) > 0.5 {
            frame.size.height = totalHeight
            switcher.frame = frame
        }
        switcher.invalidateIntrinsicContentSize()
        switcher.needsLayout = true
    }

    func upgradedHeight(for switcher: NSView) -> CGFloat? {
        guard let num = objc_getAssociatedObject(switcher, &kUpgradedHeightKey) as? NSNumber else {
            return nil
        }
        return CGFloat(num.doubleValue)
    }

    func refreshRings(in switcher: NSView) {
        let isDark = Self.isDarkAppearance(switcher)
        if let legend = objc_getAssociatedObject(switcher, &kLegendViewKey) as? OrbitLegendView {
            legend.updateColors(isDark: isDark)
        }
        for button in self.stackedButtons(in: switcher) {
            self.hideOldIndicators(in: button)
            self.renderButton(button, isDark: isDark)
        }
    }

    private func renderButton(_ button: NSButton, isDark: Bool) {
        guard let (_, iconView, titleField) = self.extractStackParts(from: button) else { return }
        if objc_getAssociatedObject(button, &kOriginalIconKey) == nil, let orig = iconView.image {
            objc_setAssociatedObject(button, &kOriginalIconKey, orig, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let originalGlyph = objc_getAssociatedObject(button, &kOriginalIconKey) as? NSImage
        let title = titleField.stringValue
        let isSelected = (button.state == .on)
        if isSelected {
            self.activeSelectedTitle = title
        }

        let lowerTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerTitle == "overview" || lowerTitle == "总览" {
            iconView.image = OrbitRingRenderer.renderOverviewMedallion(
                glyph: originalGlyph,
                isSelected: isSelected,
                isDark: isDark)
            button.toolTip = OrbitLocale.overviewTip
        } else {
            let data = QuotaSnapshotStore.shared.ringData(forTitle: title)
            let fallbackWk = data == nil ? self.fallbackWeeklyPercent(fromHiddenIndicatorIn: button) : nil
            iconView.image = OrbitRingRenderer.renderProviderDualRing(
                glyph: originalGlyph,
                data: data,
                fallbackWeeklyPct: fallbackWk,
                isSelected: isSelected,
                isDark: isDark)
            button.toolTip = data?.detailTooltip
        }
    }
}

// MARK: - Objective-C Runtime Hooks (public AppKit selectors only)

private nonisolated(unsafe) var gOrigStatusButtonSetImage: (@convention(c) (NSButton, Selector, NSImage?) -> Void)?

private enum OrbitSwizzler {
    static func install() {
        Self.swizzleStatusBarButton()
        Self.swizzleMenuItemSetView()
        Self.swizzleProviderSwitcherView()
        Self.swizzleStackedToggleButton()
    }

    private static func swizzleStatusBarButton() {
        guard let cls: AnyClass = NSClassFromString("NSStatusBarButton") else { return }

        let imgSel = #selector(setter: NSButton.image)
        if let m = class_getInstanceMethod(cls, imgSel) {
            let origIMP = method_getImplementation(m)
            typealias ImgFn = @convention(c) (NSButton, Selector, NSImage?) -> Void
            let orig = unsafeBitCast(origIMP, to: ImgFn.self)
            gOrigStatusButtonSetImage = orig

            let block: @convention(block) (NSButton, NSImage?) -> Void = { btn, incoming in
                guard incoming != nil else {
                    orig(btn, imgSel, nil)
                    return
                }
                let custom = MainActor.assumeIsolated {
                    OrbitBarController.shared.registerAndRenderStatusButton(btn)
                }
                orig(btn, imgSel, custom ?? incoming)
            }
            let newIMP = imp_implementationWithBlock(block)
            let superIMP = class_getSuperclass(cls).flatMap { class_getInstanceMethod($0, imgSel) }.map { method_getImplementation($0) }
            if superIMP == origIMP {
                class_addMethod(cls, imgSel, newIMP, method_getTypeEncoding(m))
            } else {
                method_setImplementation(m, newIMP)
            }
        }

        for sel in [#selector(NSView.viewDidChangeEffectiveAppearance), #selector(NSView.viewDidMoveToWindow)] {
            if let m = class_getInstanceMethod(cls, sel) {
                let origIMP = method_getImplementation(m)
                typealias ViewFn = @convention(c) (NSButton, Selector) -> Void
                let orig = unsafeBitCast(origIMP, to: ViewFn.self)
                let block: @convention(block) (NSButton) -> Void = { btn in
                    orig(btn, sel)
                    MainActor.assumeIsolated {
                        OrbitBarController.shared.refreshStatusButton(btn)
                    }
                }
                let newIMP = imp_implementationWithBlock(block)
                let superIMP = class_getSuperclass(cls).flatMap { class_getInstanceMethod($0, sel) }.map { method_getImplementation($0) }
                if superIMP == origIMP {
                    class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))
                } else {
                    method_setImplementation(m, newIMP)
                }
            }
        }
    }

    private static func swizzleMenuItemSetView() {
        let cls: AnyClass = NSMenuItem.self
        let sel = #selector(setter: NSMenuItem.view)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let origIMP = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector, NSView?) -> Void
        let orig = unsafeBitCast(origIMP, to: Fn.self)

        let block: @convention(block) (AnyObject, NSView?) -> Void = { obj, view in
            if let view, OrbitBarController.isSwitcherView(view) {
                MainActor.assumeIsolated {
                    OrbitBarController.shared.registerAndUpgrade(view)
                }
            }
            orig(obj, sel, view)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleProviderSwitcherView() {
        guard let cls: AnyClass = NSClassFromString("_TtC8CodexBar20ProviderSwitcherView") else { return }

        let moveSel = #selector(NSView.viewDidMoveToWindow)
        if let m = class_getInstanceMethod(cls, moveSel) {
            let origIMP = method_getImplementation(m)
            typealias Fn = @convention(c) (NSView, Selector) -> Void
            let orig = unsafeBitCast(origIMP, to: Fn.self)
            let block: @convention(block) (NSView) -> Void = { view in
                orig(view, moveSel)
                MainActor.assumeIsolated {
                    if view.window != nil {
                        OrbitBarController.shared.registerAndUpgrade(view)
                    }
                }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }

        let appSel = #selector(NSView.viewDidChangeEffectiveAppearance)
        if let m = class_getInstanceMethod(cls, appSel) {
            let origIMP = method_getImplementation(m)
            typealias Fn = @convention(c) (NSView, Selector) -> Void
            let orig = unsafeBitCast(origIMP, to: Fn.self)
            let block: @convention(block) (NSView) -> Void = { view in
                orig(view, appSel)
                MainActor.assumeIsolated {
                    OrbitBarController.shared.refreshRings(in: view)
                }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }

        let sizeSel = #selector(getter: NSView.intrinsicContentSize)
        if let m = class_getInstanceMethod(cls, sizeSel) {
            let origIMP = method_getImplementation(m)
            typealias Fn = @convention(c) (NSView, Selector) -> NSSize
            let orig = unsafeBitCast(origIMP, to: Fn.self)
            let block: @convention(block) (NSView) -> NSSize = { view in
                var size = orig(view, sizeSel)
                MainActor.assumeIsolated {
                    if let h = OrbitBarController.shared.upgradedHeight(for: view) {
                        size.height = h
                    }
                }
                return size
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    private static func swizzleStackedToggleButton() {
        guard let cls: AnyClass = NSClassFromString("_TtC8CodexBar19StackedToggleButton") else { return }

        let stateSel = #selector(setter: NSButton.state)
        if let m = class_getInstanceMethod(cls, stateSel) {
            let origIMP = method_getImplementation(m)
            typealias StateFn = @convention(c) (NSButton, Selector, NSControl.StateValue) -> Void
            let orig = unsafeBitCast(origIMP, to: StateFn.self)
            let block: @convention(block) (NSButton, NSControl.StateValue) -> Void = { btn, newState in
                orig(btn, stateSel, newState)
                MainActor.assumeIsolated {
                    OrbitBarController.shared.refreshSingleButton(btn)
                }
            }
            let newIMP = imp_implementationWithBlock(block)
            let superIMP = class_getSuperclass(cls).flatMap { class_getInstanceMethod($0, stateSel) }.map { method_getImplementation($0) }
            if superIMP == origIMP {
                class_addMethod(cls, stateSel, newIMP, method_getTypeEncoding(m))
            } else {
                method_setImplementation(m, newIMP)
            }
        }

        let addSel = #selector(NSView.addSubview(_:))
        if let m = class_getInstanceMethod(cls, addSel) {
            let origAddIMP = method_getImplementation(m)
            typealias AddFn = @convention(c) (NSView, Selector, NSView) -> Void
            let origAdd = unsafeBitCast(origAddIMP, to: AddFn.self)
            let addBlock: @convention(block) (NSView, NSView) -> Void = { parent, subview in
                origAdd(parent, addSel, subview)
                if !(subview is NSStackView) {
                    subview.alphaValue = 0
                    subview.layer?.opacity = 0
                }
            }
            let newAddIMP = imp_implementationWithBlock(addBlock)
            let superAddIMP = class_getSuperclass(cls).flatMap { class_getInstanceMethod($0, addSel) }.map { method_getImplementation($0) }
            if superAddIMP == origAddIMP {
                class_addMethod(cls, addSel, newAddIMP, method_getTypeEncoding(m))
            } else {
                method_setImplementation(m, newAddIMP)
            }
        }
    }
}

private nonisolated(unsafe) var gDidInstallOrbit = false

@_cdecl("OrbitBarBootstrap")
public func OrbitBarBootstrap() {
    let tryInstall: @Sendable () -> Void = {
        guard !gDidInstallOrbit else { return }
        if NSClassFromString("_TtC8CodexBar20ProviderSwitcherView") != nil {
            gDidInstallOrbit = true
            OrbitSwizzler.install()
        }
    }
    tryInstall()
    DispatchQueue.main.async {
        _ = QuotaSnapshotStore.shared
        _ = OrbitBarController.shared
        tryInstall()
    }
}

#endif
