#!/usr/bin/env bash
# 서울 종로구 중심 반경 3km 건물(building=*)의 중심점과 태그를 Overpass API(OSM)에서 수집한다.
# 반경 전체를 한 번에 요청하면 서버가 거부(too busy)하므로 4개 구역으로 나눠 받는다.
# 구역 경계에 걸친 건물은 양쪽에 중복 등장하므로 way id로 중복 제거한다(build_dataset.ps1에서 처리).
set -euo pipefail

CENTER_LAT=37.5735
CENTER_LON=126.9788
RADIUS_M=3000
API="https://overpass-api.de/api/interpreter"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/data/centers"

mkdir -p "$OUT_DIR"

fetch_quadrant () {
  local name=$1 south=$2 west=$3 north=$4 east=$5
  for attempt in 1 2 3 4 5; do
    curl -s -m 280 -X POST "$API" \
      --data-urlencode "data=[out:json][timeout:270];way($south,$west,$north,$east)(around:${RADIUS_M},${CENTER_LAT},${CENTER_LON})[building];out center;" \
      -o "$OUT_DIR/$name.json"
    if [ "$(wc -c < "$OUT_DIR/$name.json")" -gt 50000 ]; then
      echo "$name 완료 ($(grep -c '"type": "way"' "$OUT_DIR/$name.json")동)"
      return 0
    fi
    echo "$name 재시도 $attempt (서버 혼잡)"
    sleep 20
  done
  echo "$name 실패" >&2
  return 1
}

fetch_quadrant sw 37.5460 126.9443 37.5735 126.9788
fetch_quadrant se 37.5460 126.9788 37.5735 127.0133
fetch_quadrant nw 37.5735 126.9443 37.6010 126.9788
fetch_quadrant ne 37.5735 126.9788 37.6010 127.0133

echo ""
echo "다음: powershell -ExecutionPolicy Bypass -File scripts/build_dataset.ps1"
