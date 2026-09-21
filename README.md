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

배포 주소: https://claude.ai/artifact/SNoAMHQqKJ6WUXsvpXjr8b

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
