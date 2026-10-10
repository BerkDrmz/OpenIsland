#!/usr/bin/env bash
# OpenIsland.app paketini üretir ve imzalar.
#
#   ./Scripts/build-app.sh                         # arm64, ad-hoc imza
#   CODESIGN_IDENTITY="Developer ID Application: …" ./Scripts/build-app.sh
#   ARCHS="arm64 x86_64" ./Scripts/build-app.sh    # Universal 2
#
# Not: Ad-hoc imzada her derlemede cdhash değişir ve TCC izinleri (Erişilebilirlik, Kamera)
# sıfırlanır. CODESIGN_IDENTITY verilmezse sırasıyla anahtar zincirindeki ilk "Apple Development"
# kimliği, yoksa Scripts/create-dev-identity.sh ile oluşturulan "OpenIsland Local Signing" kimliği
# kendiliğinden seçilir (TCC, imza kimliğine bağlı "designated requirement" ile eşleşir ve
# yeniden derlemede izinler korunur). Kimlik yoksa ad-hoc imzaya düşülür ve uyarı verilir.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-arm64}"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
fi
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  # Kendinden imzalı olduğu için "geçerli kimlikler" (-v) listesinde görünmez; adıyla aranır.
  if security find-identity -p codesigning 2>/dev/null | grep -q '"OpenIsland Local Signing"'; then
    CODESIGN_IDENTITY="OpenIsland Local Signing"
  fi
fi
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  echo "⚠️  İmza kimliği bulunamadı; ad-hoc imzalanıyor. Her derlemede Erişilebilirlik/Kamera izinleri sıfırlanabilir."
  echo "   Kalıcı çözüm (bir kez): ./Scripts/create-dev-identity.sh"
else
  echo "🔏 İmza kimliği: $IDENTITY"
fi
APP="build/OpenIsland.app"

ARCH_FLAGS=()
if [[ -n "${SWIFT_SCRATCH_PATH:-}" ]]; then ARCH_FLAGS+=(--scratch-path "$SWIFT_SCRATCH_PATH"); fi
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

# Yalnızca Command Line Tools varsa: macOS 27 SDK'sında SwiftUI `@State` bir makrodur ve
# eklentisi (SwiftUIMacros) yalnızca Xcode ile gelir. Kaynakların bir kopyasında `@State`,
# aynı property wrapper'a işaret eden bir typealias ile değiştirilip o kopya derlenir.
PACKAGE_PATH="$PWD"
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  echo "ℹ️  Xcode bulunamadı; Command Line Tools uyumluluk kopyası derleniyor."
  PACKAGE_PATH="$PWD/.build/clt-compat"
  mkdir -p "$PACKAGE_PATH"
  rsync -a --delete --exclude .build --exclude build --exclude Vendor ./ "$PACKAGE_PATH/"
  find "$PACKAGE_PATH/Sources/OpenIsland" -name '*.swift' -exec sed -i '' 's/@State /@CLTState /g' {} +
  printf 'import SwiftUI\n\ntypealias CLTState = SwiftUI.State\n' > "$PACKAGE_PATH/Sources/OpenIsland/_CLTCompat.swift"
fi

swift build --package-path "$PACKAGE_PATH" -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build --package-path "$PACKAGE_PATH" -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OpenIsland" "$APP/Contents/MacOS/OpenIsland"
cp Support/Info.plist "$APP/Contents/Info.plist"

# İsteğe bağlı: macOS 15.4+ için web oynatıcı desteği (bkz. README → MediaRemote).
if [[ -d Vendor/MediaRemoteAdapter ]]; then
  cp -R Vendor/MediaRemoteAdapter "$APP/Contents/Resources/MediaRemoteAdapter"
  codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
fi

# Notarizasyon güvenli zaman damgası ister (Developer ID); geliştirme imzasında ağ çağrısı yapılmaz.
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" == "Developer ID Application:"* ]] && TIMESTAMP="--timestamp"

codesign --force --options runtime "$TIMESTAMP" \
  --entitlements Support/OpenIsland.entitlements \
  --sign "$IDENTITY" "$APP"

echo "✅ $APP hazır → open $APP"
