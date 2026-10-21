#!/usr/bin/env bash
# OpenIsland AppKit deneyi: arayüz AppKit/Core Animation ile (Deney/Sources), servisler ve durum makinesi ana
# uygulamayla ortak (Sources/IslandCore, Sources/OpenIsland). Ayrı paket kimliği ve veri klasörü kullanır.
#
#   ./Deney/build.sh            → Deney/build/OpenIsland Deney.app
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/Deney/.build"
APP="$ROOT/Deney/build/OpenIsland Deney.app"
mkdir -p "$OUT"
FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUT/cache" -O -D OPENISLAND_DENEY)

# Ana uygulamanın yerini AppKit sürümleri alan dosyalar.
EXCLUDE=(
  "Sources/OpenIsland/App/OpenIslandApp.swift"
  "Sources/OpenIsland/Window/NotchWindowController.swift"
)
SOURCES=()
while IFS= read -r file; do
  skip=0; for e in "${EXCLUDE[@]}"; do [[ "$file" == "$e" ]] && skip=1; done
  [[ $skip == 0 ]] && SOURCES+=("$file")
done < <(find Sources/OpenIsland -name '*.swift' | sort)
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Deney/Sources -name '*.swift' | sort)

echo "▸ IslandCore"
swiftc "${FLAGS[@]}" -parse-as-library -emit-library -static -emit-module -module-name IslandCore \
  Sources/IslandCore/*.swift -o "$OUT/libIslandCore.a" -emit-module-path "$OUT/IslandCore.swiftmodule"

echo "▸ OpenIsland Deney (${#SOURCES[@]} dosya)"
swiftc "${FLAGS[@]}" -parse-as-library -module-name OpenIslandDeney -I "$OUT" -L "$OUT" -lIslandCore \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Support/Info.plist" \
  "${SOURCES[@]}" -o "$OUT/OpenIslandDeney"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/OpenIslandDeney" "$APP/Contents/MacOS/OpenIslandDeney"
cp Support/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.openisland.deney "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string OpenIslandDeney "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "OpenIsland Deney" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "OpenIsland Deney" "$APP/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
fi
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"OpenIsland Local Signing"'; then
  IDENTITY="OpenIsland Local Signing"
fi
codesign --force --options runtime --timestamp=none --entitlements Support/OpenIsland.entitlements \
  --sign "${IDENTITY:--}" "$APP"
echo "✅ $APP"
