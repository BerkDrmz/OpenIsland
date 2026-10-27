#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$1"
ENTRY="${2:-OffscreenUIContract.swift}"
case "$ENTRY" in OffscreenUIContract.swift|MotionLifecycleCheck.swift) ;; *) echo "Unsupported UI contract entry: $ENTRY" >&2; exit 64;; esac
mkdir -p "$OUT"
cd "$ROOT"
cp Support/Info.plist "$OUT/TestInfo.plist"
plutil -replace CFBundleIdentifier -string io.github.openisland.validation.contract "$OUT/TestInfo.plist"
FLAGS=(-swift-version 6 -O -whole-module-optimization -target "$(uname -m)-apple-macosx14.0" -D OPENISLAND_DENEY -module-cache-path "$OUT/cache")
swiftc "${FLAGS[@]}" -parse-as-library -emit-library -static -emit-module -module-name IslandCore Sources/IslandCore/*.swift -o "$OUT/libIslandCore.a" -emit-module-path "$OUT/IslandCore.swiftmodule"
FILES=()
while IFS= read -r f; do
 case "$f" in Sources/OpenIsland/App/OpenIslandApp.swift|Sources/OpenIsland/Window/NotchWindowController.swift|Deney/Sources/App/DeneyApp.swift) continue;; esac
 FILES+=("$f")
done < <(find Sources/OpenIsland Deney/Sources -name '*.swift' | sort)
# Keep the real menu/helper declarations in the entry file; only its @main
# attribute is removed so the test executable supplies its own entry point.
sed '/^@main$/d' Deney/Sources/App/DeneyApp.swift > "$OUT/DeneyAppWithoutEntry.swift"
FILES+=("$OUT/DeneyAppWithoutEntry.swift")
swiftc "${FLAGS[@]}" -parse-as-library -module-name MotionUIContract -I "$OUT" -L "$OUT" -lIslandCore -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$OUT/TestInfo.plist" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 14.0 "${FILES[@]}" "Deney/Tests/$ENTRY" -o "$OUT/ui-contract"
