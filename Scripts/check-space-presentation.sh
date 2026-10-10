#!/usr/bin/env bash
# Gerçek pencere yaşam döngüsü kaynaklarını kontrollü sağlayıcılarla sınar.
# Ekranları/Space'leri değiştirmez, görünür test penceresi açmaz, sistem izni istemez.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openisland-space-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
CHECK_ARCH="$(uname -m)"
SWIFT_FLAGS=(-target "${CHECK_ARCH}-apple-macosx14.0" -module-cache-path "$CHECK_DIR/cache")
swiftc "${SWIFT_FLAGS[@]}" -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift \
  -o "$CHECK_DIR/libIslandCore.dylib" -emit-module-path "$CHECK_DIR/IslandCore.swiftmodule"
LINK_FLAGS=(-parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore -Xlinker -rpath -Xlinker "$CHECK_DIR")
swiftc "${SWIFT_FLAGS[@]}" "${LINK_FLAGS[@]}" \
  Sources/OpenIsland/Window/SpacePresentation/{SpaceProviders,PrivateSpaceProvider,SpacePresentationController}.swift \
  Tools/SpacePresentationChecks/ControllerCheck.swift -o "$CHECK_DIR/controller-check"
"$CHECK_DIR/controller-check"
swiftc "${SWIFT_FLAGS[@]}" "${LINK_FLAGS[@]}" \
  Sources/OpenIsland/Features/Events/FullscreenMonitor.swift \
  Tools/SpacePresentationChecks/FullscreenCheck.swift -o "$CHECK_DIR/fullscreen-check"
"$CHECK_DIR/fullscreen-check"
swiftc "${SWIFT_FLAGS[@]}" "${LINK_FLAGS[@]}" \
  Sources/OpenIsland/Window/ScreenManager.swift \
  Tools/SpacePresentationChecks/ScreenGeometryCheck.swift -o "$CHECK_DIR/screen-geometry-check"
"$CHECK_DIR/screen-geometry-check"
