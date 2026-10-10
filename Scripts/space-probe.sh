#!/usr/bin/env bash
# OpenIsland'in Space/tam ekran geçişlerinde yatay kayıp kaymadığını ölçer (geliştirici aracı, salt okuma).
#
#   ./Scripts/space-probe.sh        # 60 sn
#   ./Scripts/space-probe.sh 120    # 120 sn
#
# Çalışırken dört parmakla kaydırın, tam ekrana girip çıkın vb.; sonunda her ada penceresi için en büyük
# yatay sapma ve "SABİT ✅ / KAYDI ❌" yazılır. Ekran kaydı izni gerekmez.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=.build/space-probe
if [[ ! -x "$BIN" || Tools/SpaceProbe/main.swift -nt "$BIN" ]]; then
  mkdir -p .build
  swiftc -O Tools/SpaceProbe/main.swift -o "$BIN" 2>&1 | grep -v "search path" || true
fi
exec "$BIN" "${1:-60}"
