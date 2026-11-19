#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH=""
SKIP_RESTART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --no-restart)
      SKIP_RESTART=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--app /path/to/CodexBar.app] [--no-restart]"
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
    echo "Error: CodexBar.app not found in ~/Applications or /Applications." >&2
    echo "Pass --app /path/to/CodexBar.app explicitly." >&2
    exit 1
  fi
fi

EXEC_PATH="$APP_PATH/Contents/MacOS/CodexBar"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
BACKUP_BIN="$APP_PATH/Contents/MacOS/CodexBar.orbitbar-backup"
DYLIB_NAME="OrbitBar.dylib"
DYLIB_INSTALL_NAME="@rpath/$DYLIB_NAME"

if [[ ! -x "$EXEC_PATH" ]]; then
  echo "Error: executable not found at $EXEC_PATH" >&2
  exit 1
fi

ARCHS="$(lipo -archs "$EXEC_PATH")"
BUILD_DIR="$ROOT_DIR/.build"
mkdir -p "$BUILD_DIR"

build_arch() {
  local arch="$1"
  local out="$BUILD_DIR/${DYLIB_NAME}.${arch}"
  local obj="$BUILD_DIR/orbitbar_init.${arch}.o"
  clang -arch "$arch" -mmacosx-version-min=14.0 -O2 -c "$ROOT_DIR/Sources/orbitbar_init.c" -o "$obj"
  swiftc -emit-library -O \
    -target "${arch}-apple-macosx14.0" \
    -Xlinker -install_name -Xlinker "$DYLIB_INSTALL_NAME" \
    "$ROOT_DIR/Sources/OrbitBar.swift" "$obj" \
    -o "$out"
  rm -f "$obj"
}

echo "1/4 Building $DYLIB_NAME for architecture(s): $ARCHS ..."
BUILT_SLICES=()
for arch in $ARCHS; do
  build_arch "$arch"
  BUILT_SLICES+=("$BUILD_DIR/${DYLIB_NAME}.${arch}")
done

DYLIB_OUT="$BUILD_DIR/$DYLIB_NAME"
if [[ "${#BUILT_SLICES[@]}" -gt 1 ]]; then
  lipo -create "${BUILT_SLICES[@]}" -output "$DYLIB_OUT"
  rm -f "${BUILT_SLICES[@]}"
else
  mv "${BUILT_SLICES[0]}" "$DYLIB_OUT"
fi

echo "2/4 Installing $DYLIB_NAME into $APP_PATH ..."
if [[ "$SKIP_RESTART" -eq 0 ]]; then
  pkill -x CodexBar 2>/dev/null || true
  sleep 0.4
fi

mkdir -p "$FRAMEWORKS_DIR"
if [[ ! -f "$BACKUP_BIN" ]]; then
  cp -p "$EXEC_PATH" "$BACKUP_BIN"
fi

cp -f "$DYLIB_OUT" "$FRAMEWORKS_DIR/$DYLIB_NAME"
chmod 755 "$FRAMEWORKS_DIR/$DYLIB_NAME"
codesign --force --sign - "$FRAMEWORKS_DIR/$DYLIB_NAME"

echo "3/4 Linking weak dylib & re-signing app bundle (ad-hoc) ..."
/usr/bin/python3 "$ROOT_DIR/Scripts/patch_macho.py" "$EXEC_PATH" "$DYLIB_INSTALL_NAME"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "4/4 Done!"
if [[ "$SKIP_RESTART" -eq 0 ]]; then
  UID_NUM="$(id -u)"
  LABEL="local.quota.codexbar.menubar"
  if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/${UID_NUM}/${LABEL}"
  else
    open -a "$APP_PATH"
  fi
  echo "OrbitBar is now active in your macOS menu bar."
fi
