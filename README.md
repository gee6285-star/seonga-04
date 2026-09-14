# seonga-04 — 스마트도시계획 캡스톤디자인

서울 종로구 중심 반경 3km 건물 데이터(Overpass API / OpenStreetMap)를 수집해
**지도 위에서 기재율을 확인하는** 대시보드. 강의 자료의 문제의식 — "구성비를 보기 전에
기재율(용도 태그 보유율)부터 확인해야 한다" — 를 실제 데이터로 재현하고,
SGIS 격자 통계와 같은 방식의 격자 집계 지도를 함께 제공한다.

## 파이프라인

```
scripts/fetch_overpass_data.sh   Overpass API에서 4개 구역으로 나눠 수집  -> data/centers/*.json
scripts/build_dataset.ps1        용도 분류 + 중복 제거 + 압축             -> dashboard/buildings.json
dashboard/index.html             지도 대시보드 (Artifact로도 게시)
```

재현 순서:

```bash
bash scripts/fetch_overpass_data.sh
powershell -ExecutionPolicy Bypass -File scripts/build_dataset.ps1
```

## 데이터

- 출처: Overpass API (OpenStreetMap), ODbL
- 범위: 중심 37.5735, 126.9788 / 반경 3,000m / `building=*` way
- 결과: **19,193동** (구역 경계 중복은 way id로 제거)
- 형상(폴리곤) 대신 중심점을 쓴다. 전체 폴리곤은 16MB를 넘고, 격자 집계에는 중심점이면 충분하다.

## 용도 분류

`build_dataset.ps1`의 `Get-Category`가 분류의 단일 출처다. `building` 값으로 1차 판정하고,
`building=yes`처럼 일반값이면 `shop` / `office` / `amenity` / `tourism` / `landuse` / `man_made`로 2차 판정한다.
어디에도 걸리지 않으면 미분류로 남는다.

| 카테고리 | 동수 | 비중 |
|---|---:|---:|
| 상업·업무 | 2,607 | 13.6% |
| 주거 | 1,638 | 8.5% |
| 공공·교육 | 460 | 2.4% |
| 종교·문화 | 167 | 0.9% |
| 공업 | 16 | 0.1% |
| **미분류** | **14,305** | **74.5%** |

기재율 25.5%. 즉 열 동 중 일곱 동 이상은 용도를 알 수 없고, 미분류를 포함한 구성비는
"태그가 달린 건물만 센 결과"에 가깝다.

## 대시보드

- **건물 용도**: 건물 한 동 = 점 하나. 미분류를 끄면 지도가 비는 것으로 기재율을 체감한다.
- **격자 기재율 / 격자 건물밀도**: 250m·500m·1km 격자로 집계. 기재율이 지역마다 다른 것이 보인다.
- 지도 하단 막대는 **화면에 보이는 범위**의 용도 구성비라 이동·확대하면 같이 바뀐다.
- SGIS 오픈API(토큰 4시간) 절차를 함께 정리해 두었다. 같은 격자 크기로 인구·가구·주택 통계를 붙이면
  "건물 용도 × 인구" 비교로 확장할 수 있다.
