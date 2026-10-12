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

배포 주소(production): https://gee6285-star.github.io/seonga-04/dashboard/ — GitHub Pages가 `main` 브랜치를 그대로 배포한다.
저장소: https://github.com/gee6285-star/seonga-04

(이전에 쓰던 Artifact 주소는 2026-10-12에 읽기가 되지 않아 쓰지 않는다.)

- **팀 지표 카드**: 한 칸 = 값 · 단위 · 출처 · 조회일. 네 칸이 다 차지 않은 값은 올리지 않고 `조회 대기`로 비워 둔다.
  1주차 기온, 2주차 건물밀도, 3주차 조례 용적률(「서울특별시 도시계획 조례」 제48조제5호, 시행 2026-07-13) 순이다.
- **건물 용도**: 건물 한 동 = 점 하나. 미분류를 끄면 지도가 비는 것으로 기재율을 체감한다.
- **격자 기재율 / 격자 건물밀도**: 250m·500m·1km 격자로 집계. 기재율이 지역마다 다른 것이 보인다.
- 지도 하단 막대는 **화면에 보이는 범위**의 용도 구성비라 이동·확대하면 같이 바뀐다.
- SGIS 오픈API(토큰 4시간) 절차를 함께 정리해 두었다. 같은 격자 크기로 인구·가구·주택 통계를 붙이면
  "건물 용도 × 인구" 비교로 확장할 수 있다.

## 법령 조문 수집

```
scripts/law_targets_jongno.json  종로(수업 대상지)용 수집 목록 — 국토계획법·시행령·서울시 조례·규칙
scripts/law_targets.json         시흥 포동(공모전)용 수집 목록
scripts/fetch_law_articles.ps1   국가법령정보 OPEN API 호출  -> out/law/
```

사전에 [open.law.go.kr](https://open.law.go.kr) > OPEN API 신청에서 **목록 조회와 본문 조회를
함께** 신청해 승인(1~2일)받고, 호출할 PC의 공인 IP를 등록해야 한다. `OC`는 가입 이메일의 `@` 앞부분.

```bash
powershell -ExecutionPolicy Bypass -File scripts/fetch_law_articles.ps1 -OC <본인OC> -TargetsPath scripts/law_targets_jongno.json
```

수집 목록의 `type`으로 대상을 고른다. `law`는 법령(법률·시행령·시행규칙), `ordin`은 자치법규(조례·규칙)다.
자치법규는 25개 자치구가 같은 제명을 쓰므로 제명이 완전히 일치하는 건만 고른다.
`tables`에 별표 번호를 적으면 그 별표도 함께 받는다. 도면처럼 본문 텍스트가 없는 별표는
값을 지어내지 않고 **첨부파일 주소만** 남긴다.

`out/law/law_articles.csv`는 조·항 단위 표에 **법령ID·MST·시행일·조회일**과 인용용 출처표기를 함께 남기고,
`out/law/law_versions.csv`는 법령별 식별자·시점 대장을 남긴다.
법령ID는 개정돼도 고정이지만 MST는 시행일 버전마다 바뀌므로, 나중에 같은 조문을 다시 찾으려면 이 네 값이 필요하다.
API 원본 XML은 `out/law/raw/`에 남아 `-FromCache`로 호출 없이 다시 파싱할 수 있다.

같은 날 조회해도 시행일은 법령마다 다르다. 2026-09-21 조회 기준으로 종로 대상지에 걸리는 네 건은
법률 2026-07-01 · 시행령 2026-09-18 · 서울시 조례 2026-07-13 · 같은 조례 시행규칙 2024-10-14로
모두 달랐다. 실행 기록은 `submit/비교과_MCP_조문조회_임성아.html`에 정리했다.

## 기상청 자연환경 데이터 수집

강의자료 4주차(슬라이드 34) "자연환경 세부항목"의 '기후' 칸은 기상청에서 본다고 돼 있다.
`scripts/fetch_kma_weather.ps1`가 이 칸을 두 갈래로 채운다.

```
scripts/fetch_kma_weather.ps1   기상청 공공데이터(data.go.kr) 호출  -> out/kma/
  -Mode forecast   단기예보(오늘 최고기온·최저기온·강수확률·풍속·습도) — 1주차 카드가
                   Open-Meteo로 임시로 채웠던 자리를 기상청 공식 값으로 대체하는 용도
  -Mode obs        ASOS 일자료 최근 N년 집계(폭염일수·한파일수·호우일수·기간 최대풍속) —
                   자연환경 세부항목의 '풍수해·지진기록'을 뒷받침하는 자료
  -Mode both       (기본값) 위 둘을 한 번에
```

사전에 [data.go.kr](https://www.data.go.kr) 회원가입 후 **기상청_단기예보 조회서비스**와
**기상청_지상(종관,ASOS) 일자료 조회서비스** 두 API를 각각 활용신청한다(보통 즉시~수 시간 승인).
마이페이지의 "일반 인증키(Decoding)" 값 하나로 둘 다 호출할 수 있다. 키는 코드에 적지 않고
환경변수 `KMA_KEY`에만 둔다(법령 API의 `LAW_OC`와 같은 원칙).

```bash
powershell -ExecutionPolicy Bypass -File scripts/fetch_kma_weather.ps1 -ServiceKey <본인키>
powershell -ExecutionPolicy Bypass -File scripts/fetch_kma_weather.ps1 -Mode obs -Years 10
powershell -ExecutionPolicy Bypass -File scripts/fetch_kma_weather.ps1 -FromCache   # 호출 없이 저장된 원본만 다시 집계
```

기본 좌표는 37.5735/126.9788(종로구청, 수업 대상지)이고 위경도를
기상청 격자(nx, ny)로 자동 변환한다. ASOS 지점번호는 기본 108(서울)이며 `-StnId`로 바꿀 수 있다.

`out/kma/vilage_fcst_summary.csv`와 `out/kma/climate_extremes_summary.csv`는 팀 지표 카드 규칙과
같은 **값·단위·출처(구체 API명)·조회일** 네 칸 형식으로 저장돼 대시보드 카드에 바로 옮겨 쓸 수 있다.
API 원본 JSON은 `out/kma/raw/`에 남아 `-FromCache`로 호출 없이 다시 집계할 수 있다.

## 지표 ⑥ 경사·향 적합면적 비율

6주차 슬라이드 25~28·38의 대시보드 여섯째 칸. `scripts/calc_slope_aspect.ps1`가 대상지(중심점+반경)를 90m 셀(0.81ha)로 나눠
고도를 받고, 셀마다 Horn 방식으로 경사도(%)와 향을 구한다. **세 조건을 모두 충족한 셀만 '참'**이다.

- 경사 ≤ 임계값: **기준안 15% · 하한 10% · 상한 25%** 세 값으로 각각 계산한다(교재 범위 안의 가정)
- 향 135~225°(남향 ±45°), 평지는 향이 정의되지 않아 거짓
- 표고 ≤ 기반시설 표고 + 50m

적합면적 = 참 셀 수 × 0.81ha, 비율 = 적합면적 ÷ 대상지 면적. 세 값을 DEM 출처 · 해상도 · 조회일과 함께
한 행(`out/dem/slope_aspect_suitability.csv`)으로 저장한다.

```bash
powershell -ExecutionPolicy Bypass -File scripts/calc_slope_aspect.ps1 -RadiusM 1000
```

- **기반시설 표고는 자료에 값이 없다.** 지정이 없으면 중심점(종로구청) 표고로 가정하고 `가정·한계` 열에 적는다. `-InfraElevM`으로 바꾼다.
- DEM 출처는 기본값이 Open-Meteo(Copernicus GLO-90, 키 불필요, 정수 m)이며 **자료가 지정한 국토지리정보원 DEM 90m가 아니다**. 출처 열에 그대로 적힌다.
  국토지리정보원 DEM(국토정보플랫폼에서 내려받기)을 받았다면 `r,c,elev` CSV로 만들어 `-ElevCsv`로 넘기고 `-DemName`을 고친다.
- 경계 셀은 셀 중심이 반경 안이면 포함하고, 90m보다 작은 급경사는 반영되지 않는다.
- 계산식은 남향·북향·평지 합성 지형으로 검증했다(경사 12%인 면에서 임계값 10%는 0%, 15%·25%는 100%). DEM은 지표면 모델이라 건물·수목 높이가 섞인다.

## 브이월드 레이어 수집

강의자료 슬라이드 30(브이월드 2D 데이터 API 2.0, 요청 네 단계)을 코드로 옮긴 `scripts/fetch_vworld_data.ps1`.

```
1 키와 서비스 URL   인증키는 환경변수 VWORLD_KEY, 등록 도메인은 VWORLD_DOMAIN (코드·문서·화면에 노출 금지)
2 서비스 ID 확정    -Data <레이어ID> (슬라이드 예: LT_C_ADSIDO_INFO)
3 요청 조립         api.vworld.kr/req/data · GetFeature · geomFilter=BOX(반경) · crs=EPSG:4326 · size<=1000 · page
4 응답 읽기         status 먼저 확인 → result 저장, 1000건 초과면 page를 올려 이어 받음
```

```bash
powershell -ExecutionPolicy Bypass -File scripts/fetch_vworld_data.ps1 -Data LT_C_ADSIDO_INFO
powershell -ExecutionPolicy Bypass -File scripts/fetch_vworld_data.ps1 -Data <ID> -RadiusM 500 -FromCache
```

기본 범위는 종로구청 반경 1,000m. `out/vworld/`에 레이어별 `.geojson`(지오메트리+속성)과 `_properties.csv`,
그리고 **요청 URL(키 제외)·환경변수 이름·domain 전송 여부·status·건수·조회일·비고(오류 본문 한 줄)** 를 남기는 `request_log.csv`가 생긴다.
오류로 멈춰도 기록은 남고, 원인을 판별하기 전에는 같은 요청을 반복하지 않는다(일일 한도만 소모).
레이어 ID는 슬라이드 예시 하나만 확인된 값이라, 다른 레이어는 API 레퍼런스의 서비스 목록에서 ID를 확인한 뒤 쓴다.
