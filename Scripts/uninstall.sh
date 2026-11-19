#!/usr/bin/env bash
set -euo pipefail

APP_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--app /path/to/CodexBar.app]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$APP_PATH" ]]; then
  if [[ -d "$HOME/Applications/CodexBar.app" ]]; then
    APP_PATH="$HOME/Applications/CodexBar.app"
  elif [[ -d "/Applications/CodexBar.app" ]]; then
    APP_PATH="/Applications/CodexBar.app"
  else
    echo "Error: CodexBar.app not found." >&2
    exit 1
  fi
fi

EXEC_PATH="$APP_PATH/Contents/MacOS/CodexBar"
BACKUP_BIN="$APP_PATH/Contents/MacOS/CodexBar.orbitbar-backup"
DYLIB_PATH="$APP_PATH/Contents/Frameworks/OrbitBar.dylib"

pkill -x CodexBar 2>/dev/null || true
sleep 0.4

if [[ -f "$BACKUP_BIN" ]]; then
  mv -f "$BACKUP_BIN" "$EXEC_PATH"
  echo "Restored original executable from backup."
fi

if [[ -f "$DYLIB_PATH" ]]; then
  rm -f "$DYLIB_PATH"
  echo "Removed OrbitBar.dylib."
fi

codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

UID_NUM="$(id -u)"
LABEL="local.quota.codexbar.menubar"
if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/${UID_NUM}/${LABEL}"
else
  open -a "$APP_PATH"
fi

echo "OrbitBar uninstalled and original host app restored."
