#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openisland-performance-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
SWIFT_FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$CHECK_DIR/cache")
swiftc "${SWIFT_FLAGS[@]}" -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift \
  -o "$CHECK_DIR/libIslandCore.dylib" -emit-module-path "$CHECK_DIR/IslandCore.swiftmodule"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/Features/Events/{TransferMonitor,NetworkMonitor}.swift \
  Sources/OpenIsland/Island/IslandViewModel.swift Tools/PerformanceChecks/Main.swift -o "$CHECK_DIR/performance-check"
swiftc "${SWIFT_FLAGS[@]}" Tools/PerformanceChecks/ProgressPublisher.swift -o "$CHECK_DIR/progress-publisher"
"$CHECK_DIR/performance-check" "$CHECK_DIR/progress-publisher"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/UI/IslandDesign.swift Sources/OpenIsland/Island/IslandViewModel.swift \
  Tools/PerformanceChecks/HapticsCheck.swift -o "$CHECK_DIR/haptics-check"
"$CHECK_DIR/haptics-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/UI/IslandDesign.swift Sources/OpenIsland/Island/IslandViewModel.swift \
  Sources/OpenIsland/System/Preferences.swift \
  Sources/OpenIsland/Window/NotchPanel.swift Tools/PerformanceChecks/HoverExitCheck.swift \
  -o "$CHECK_DIR/hover-exit-check"
"$CHECK_DIR/hover-exit-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
  Sources/OpenIsland/Features/Media/{NowPlaying,MediaRemoteAdapterSource}.swift \
  Tools/PerformanceChecks/AdapterCheck.swift -o "$CHECK_DIR/adapter-check"
"$CHECK_DIR/adapter-check"
sed '/^import IOBluetooth$/d; /^import CoreBluetooth$/d' \
  Sources/OpenIsland/Features/Events/BluetoothConnectionMonitor.swift > "$CHECK_DIR/BluetoothConnectionMonitor.swift"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  "$CHECK_DIR/BluetoothConnectionMonitor.swift" Tools/PerformanceChecks/BluetoothCheck.swift \
  -o "$CHECK_DIR/bluetooth-check"
"$CHECK_DIR/bluetooth-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/UI/{IslandDesign,WaveformView}.swift Tools/PerformanceChecks/WaveformCheck.swift \
  -o "$CHECK_DIR/waveform-check"
"$CHECK_DIR/waveform-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
  Sources/OpenIsland/UI/TimeProgressView.swift Tools/PerformanceChecks/TimeProgressCheck.swift \
  -o "$CHECK_DIR/time-progress-check"
"$CHECK_DIR/time-progress-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/UI/{IslandDesign,IslandShape}.swift Tools/PerformanceChecks/CanvasCheck.swift \
  -o "$CHECK_DIR/canvas-check"
"$CHECK_DIR/canvas-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
  Sources/OpenIsland/Features/Focus/{EventStoreProvider,RemindersService}.swift \
  Tools/PerformanceChecks/RemindersCheck.swift -o "$CHECK_DIR/reminders-check"
"$CHECK_DIR/reminders-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
  Sources/OpenIsland/System/PermissionsCenter.swift Tools/PerformanceChecks/PermissionsCheck.swift \
  -o "$CHECK_DIR/permissions-check"
"$CHECK_DIR/permissions-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
  Sources/OpenIsland/Features/Clipboard/ClipboardHistory.swift Tools/PerformanceChecks/ClipboardCheck.swift \
  -o "$CHECK_DIR/clipboard-check"
"$CHECK_DIR/clipboard-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/Features/Media/{NowPlaying,MediaController}.swift \
  Tools/PerformanceChecks/MediaArtworkCheck.swift -o "$CHECK_DIR/media-artwork-check"
"$CHECK_DIR/media-artwork-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
  Sources/OpenIsland/Features/Focus/{EventStoreProvider,CalendarService}.swift \
  Tools/PerformanceChecks/CalendarCheck.swift -o "$CHECK_DIR/calendar-check"
"$CHECK_DIR/calendar-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/UI/IslandDesign.swift Sources/OpenIsland/Features/Mirror/CameraMirror.swift \
  Tools/PerformanceChecks/CameraCheck.swift -o "$CHECK_DIR/camera-check"
"$CHECK_DIR/camera-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/System/Preferences.swift Tools/PerformanceChecks/PreferencesCheck.swift -o "$CHECK_DIR/preferences-check"
"$CHECK_DIR/preferences-check"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lIslandCore \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Sources/OpenIsland/Features/Media/{NowPlaying,ScriptedPlayerSource}.swift \
  Tools/PerformanceChecks/ScriptedPlayerCheck.swift -o "$CHECK_DIR/scripted-player-check"
"$CHECK_DIR/scripted-player-check"
