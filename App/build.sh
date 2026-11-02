#!/usr/bin/env bash
# OpenIsland AppKit deneyi: arayüz AppKit/Core Animation ile (App/Sources), servisler ve durum makinesi ana
# uygulamayla ortak (Sources/IslandCore, Sources/OpenIsland). Ayrı paket kimliği ve veri klasörü kullanır.
#
#   ./App/build.sh            → App/build/OpenIsland.app
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
INFO="${OPENISLAND_BUILD_INFO_PLIST:-$ROOT/Support/Info.plist}"
OUT="$ROOT/App/.build"
APP="$ROOT/App/build/OpenIsland.app"
mkdir -p "$OUT"
FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUT/cache" -O -D OPENISLAND_APPKIT)

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
while IFS= read -r file; do SOURCES+=("$file"); done < <(find App/Sources -name '*.swift' | sort)

echo "▸ IslandCore"
swiftc "${FLAGS[@]}" -parse-as-library -emit-library -static -emit-module -module-name IslandCore \
  Sources/IslandCore/*.swift -o "$OUT/libIslandCore.a" -emit-module-path "$OUT/IslandCore.swiftmodule"

echo "▸ OpenIsland (${#SOURCES[@]} dosya)"
# Üretim SwiftUI ikilisi (`swift build`) LC_BUILD_VERSION'da "sdk 14.0" taşır; AppKit/SwiftUI denetimleri bu yüzden
# Sonoma görünümüyle çizilir (yuvarlak kaydırıcı düğmesi vb.). Görsel eşdeğerlik için aynı platform sürümü yazılır.
swiftc "${FLAGS[@]}" -parse-as-library -module-name OpenIslandApp -I "$OUT" -L "$OUT" -lIslandCore \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO" \
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 14.0 \
  "${SOURCES[@]}" -o "$OUT/OpenIsland"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/OpenIsland" "$APP/Contents/MacOS/OpenIsland"
cp "$INFO" "$APP/Contents/Info.plist"
if [[ -z "${OPENISLAND_BUILD_INFO_PLIST:-}" ]]; then
  plutil -replace CFBundleIdentifier -string io.github.openisland.OpenIsland "$APP/Contents/Info.plist"
fi
plutil -replace CFBundleExecutable -string OpenIsland "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "OpenIsland" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "OpenIsland" "$APP/Contents/Info.plist"
# Simge `App/Assets/make-app-icon.swift` ile üretilir.
cp "$ROOT/App/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"

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
