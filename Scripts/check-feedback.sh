#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openisland-feedback-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
SWIFT_FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$CHECK_DIR/cache")
swiftc "${SWIFT_FLAGS[@]}" -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift \
  -o "$CHECK_DIR/libIslandCore.dylib" -emit-module-path "$CHECK_DIR/IslandCore.swiftmodule"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/Features/Shelf/{ShelfStore,ShelfFileOperations}.swift \
  Sources/OpenIsland/Features/Events/SystemLifecycleMonitor.swift \
  Tools/FeedbackChecks/Main.swift -o "$CHECK_DIR/feedback-check"
"$CHECK_DIR/feedback-check"
