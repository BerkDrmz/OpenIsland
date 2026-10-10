#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openisland-system-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$CHECK_DIR/cache")
swiftc "${FLAGS[@]}" -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift \
  -o "$CHECK_DIR/libIslandCore.dylib" -emit-module-path "$CHECK_DIR/IslandCore.swiftmodule"
swiftc "${FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/Features/System/{PrivateAPIGuard,SystemSensors,PrivateControls,StorageVolumes,SystemMonitor}.swift \
  Tools/SystemChecks/SystemMonitorCheck.swift -o "$CHECK_DIR/system-check"
"$CHECK_DIR/system-check"
