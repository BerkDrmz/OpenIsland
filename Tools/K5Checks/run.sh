#!/bin/bash
# K5 başlık satırı eşdeğerlik denetimleri (gerçek IslandCore kaynaklarıyla derlenir; uygulama başlatılmaz).
#   ./Tools/K5Checks/run.sh            → yerleşim (180 yapılandırma) + ara kare (yeniden hedeflemeli yay) denetimi
#   HEADER_EQ_NEGATIVE=1 / HEADER_EQ_NO_SKELETON=1 / NEGATIVE=1 → negatif kontroller (FAIL beklenir)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT/layout" "$OUT/anim"
cp Tools/K5Checks/HeaderShiftEquivalence.swift "$OUT/layout/main.swift"
cp Tools/K5Checks/AnimatedHeaderEquivalence.swift "$OUT/anim/main.swift"
swiftc -O -module-name HeaderEq Sources/IslandCore/*.swift "$OUT/layout/main.swift" -o "$OUT/header-eq"
swiftc -O -module-name AnimEq Sources/IslandCore/*.swift "$OUT/anim/main.swift" -o "$OUT/anim-eq"
"$OUT/header-eq" | tail -2
"$OUT/anim-eq" | tail -2
