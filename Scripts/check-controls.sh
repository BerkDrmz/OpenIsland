#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openisland-controls-check.XXXXXX")"
cleanup() {
  # Abort edilen bir test de yalnızca kendi test pencerelerini normal quit ile bırakır.
  swift -e 'import AppKit; for app in NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.openisland.CloseTest") { app.terminate() }' >/dev/null 2>&1 || true
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT
FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$CHECK_DIR/cache")
swiftc "${FLAGS[@]}" -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift \
  -o "$CHECK_DIR/libIslandCore.dylib" -emit-module-path "$CHECK_DIR/IslandCore.swiftmodule"
swiftc "${FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/UI/IslandDesign.swift Sources/OpenIsland/System/CoreAudioDevice.swift \
  Sources/OpenIsland/Features/Media/ScriptRunner.swift \
  Sources/OpenIsland/Features/Controls/*.swift Tools/ControlChecks/Main.swift -o "$CHECK_DIR/control-check"
mkdir -p "$CHECK_DIR/CloseTest.app/Contents/MacOS"
cat > "$CHECK_DIR/CloseTest.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.github.openisland.CloseTest</string><key>CFBundleExecutable</key><string>CloseTest</string><key>CFBundleName</key><string>OpenIsland Close Test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc "${FLAGS[@]}" -parse-as-library Tools/ControlChecks/CloseTest.swift -o "$CHECK_DIR/CloseTest.app/Contents/MacOS/CloseTest"
"$CHECK_DIR/control-check" "$CHECK_DIR/CloseTest.app"
