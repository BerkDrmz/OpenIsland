#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openisland-dock-check.XXXXXX")"
cleanup() {
  swift -e 'import AppKit; for app in NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.openisland.DockPreviewFixture") { app.terminate() }' >/dev/null 2>&1 || true
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT
FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$CHECK_DIR/cache")
swiftc "${FLAGS[@]}" -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift \
  -o "$CHECK_DIR/libIslandCore.dylib" -emit-module-path "$CHECK_DIR/IslandCore.swiftmodule"
swiftc "${FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/Features/DockPreview/*.swift Tools/DockPreviewChecks/Main.swift -o "$CHECK_DIR/dock-check"
if [[ "${1:-}" == "--live" ]]; then
  mkdir -p "$CHECK_DIR/DockPreviewFixture.app/Contents/MacOS"
  cat > "$CHECK_DIR/DockPreviewFixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.github.openisland.DockPreviewFixture</string><key>CFBundleExecutable</key><string>DockPreviewFixture</string><key>CFBundleName</key><string>Dock Preview Fixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
  swiftc "${FLAGS[@]}" -parse-as-library Tools/DockPreviewChecks/Fixture.swift -o "$CHECK_DIR/DockPreviewFixture.app/Contents/MacOS/DockPreviewFixture"
  "$CHECK_DIR/dock-check" "$CHECK_DIR/DockPreviewFixture.app"
else
  "$CHECK_DIR/dock-check"
fi
