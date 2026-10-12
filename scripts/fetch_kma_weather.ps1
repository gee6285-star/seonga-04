# 기상청 공공데이터(data.go.kr) -> 대상지 자연환경 세부항목(기후) 수집
# 슬라이드 34번 "자연환경 세부항목"의 '기후' 칸은 기상청에서 본다고 돼 있다.
# 이 스크립트는 그 기후 칸을 두 갈래로 채운다.
#   forecast : 단기예보(오늘·내일 기온·강수확률·풍속) - 1주차 카드가 Open-Meteo로 임시로 채웠던 자리를
#              기상청 공식 API 값으로 대체하는 용도
#   obs      : ASOS 일자료(최근 N년) - 폭염일수·한파일수·호우일수 같은 극값을 집계.
#              자연환경 세부항목의 '풍수해·지진기록'을 뒷받침하는 자료
#
# 사전준비: data.go.kr 회원가입 후 아래 두 API를 각각 "활용신청"(보통 즉시~수 시간 승인).
#   - 기상청_단기예보 조회서비스(VilageFcstInfoService_2.0)
#   - 기상청_지상(종관,ASOS) 일자료 조회서비스(AsosDalyInfoService)
#   같은 마이페이지의 "일반 인증키(Decoding)" 값을 하나 그대로 쓰면 둘 다 통과한다.
#   키는 코드에 적지 말고 환경변수 KMA_KEY 에만 둔다(LAW_OC와 같은 원칙).
#
# 입력: -Lat/-Lon (기본 37.5735/126.9788, 종로구청 — site-jongno-class 메모의 수업 대상지 좌표)
#       -StnId (ASOS 지점번호, 기본 108 = 서울)
# 출력: out/kma/vilage_fcst_today.csv     단기예보 원자료(항목별 시간대 값)
#       out/kma/vilage_fcst_summary.csv   단기예보 요약(값·단위·출처·조회일 네 칸 형식)
#       out/kma/asos_daily.csv            ASOS 일자료 원자료
#       out/kma/climate_extremes_summary.csv  극값 요약(폭염일수 등)
#       out/kma/raw/*.json                API 원본 응답(재파싱·검증용)
#
# 사용: .\scripts\fetch_kma_weather.ps1 -Mode both -ServiceKey <본인키>
#       .\scripts\fetch_kma_weather.ps1 -Mode forecast
#       .\scripts\fetch_kma_weather.ps1 -Mode obs -Years 5
#       .\scripts\fetch_kma_weather.ps1 -Mode obs -FromCache      # 호출 없이 저장된 원본만 다시 집계
param(
  [string]$ServiceKey = $env:KMA_KEY,
  [ValidateSet('forecast', 'obs', 'both')]
  [string]$Mode = 'both',
  [double]$Lat = 37.5735,
  [double]$Lon = 126.9788,
  [string]$StnId = '108',
  [int]$Years = 5,
  [string]$StartDt,
  [string]$EndDt,
  [string]$OutDir,
  [switch]$FromCache,
  [int]$DelayMs = 300
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out\kma' }
$rawDir = Join-Path $OutDir 'raw'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

if (-not $FromCache -and -not $ServiceKey) {
  throw 'ServiceKey가 필요합니다. -ServiceKey 로 넘기거나 $env:KMA_KEY 에 설정하세요. (data.go.kr 마이페이지의 일반 인증키)'
}

$BASE = 'http://apis.data.go.kr/1360000'
$조회일 = Get-Date -Format 'yyyy-MM-dd'

# --- 위경도 -> 기상청 격자(nx, ny) 변환 (기상청이 공개한 람베르트 정각원추도법 계산식) ---
function ConvertTo-KmaGrid([double]$lat, [double]$lon) {
  $RE = 6371.00877; $GRID = 5.0
  $SLAT1 = 30.0; $SLAT2 = 60.0
  $OLON = 126.0; $OLAT = 38.0
  $XO = 43.0; $YO = 136.0
  $DEGRAD = [Math]::PI / 180.0

  $re = $RE / $GRID
  $slat1 = $SLAT1 * $DEGRAD
  $slat2 = $SLAT2 * $DEGRAD
  $olon = $OLON * $DEGRAD
  $olat = $OLAT * $DEGRAD

  $sn = [Math]::Tan([Math]::PI * 0.25 + $slat2 * 0.5) / [Math]::Tan([Math]::PI * 0.25 + $slat1 * 0.5)
  $sn = [Math]::Log([Math]::Cos($slat1) / [Math]::Cos($slat2)) / [Math]::Log($sn)
  $sf = [Math]::Tan([Math]::PI * 0.25 + $slat1 * 0.5)
  $sf = ([Math]::Pow($sf, $sn) * [Math]::Cos($slat1)) / $sn
  $ro = [Math]::Tan([Math]::PI * 0.25 + $olat * 0.5)
  $ro = ($re * $sf) / [Math]::Pow($ro, $sn)

  $ra = [Math]::Tan([Math]::PI * 0.25 + ($lat * $DEGRAD) * 0.5)
  $ra = ($re * $sf) / [Math]::Pow($ra, $sn)
  $theta = ($lon * $DEGRAD) - $olon
  if ($theta -gt [Math]::PI) { $theta -= 2.0 * [Math]::PI }
  if ($theta -lt -[Math]::PI) { $theta += 2.0 * [Math]::PI }
  $theta *= $sn

  $x = [Math]::Floor($ra * [Math]::Sin($theta) + $XO + 0.5)
  $y = [Math]::Floor($ro - $ra * [Math]::Cos($theta) + $YO + 0.5)
  return [pscustomobject]@{ nx = [int]$x; ny = [int]$y }
}

# 단기예보는 3시간 간격 정시(02,05,08,11,14,17,20,23)에 발표되고, 발표 후 약 10분 뒤 공개된다.
# 여유 15분을 두고 "지금 시각에 이미 나와 있을" 가장 최근 발표 시각을 고른다.
function Get-LatestBaseDateTime {
  $slots = @(2300, 2000, 1700, 1400, 1100, 800, 500, 200)
  $now = Get-Date
  foreach ($t in $slots) {
    $h = [int]([math]::Floor($t / 100)); $m = $t % 100
    $cand = Get-Date -Hour $h -Minute $m -Second 0
    if ($now -ge $cand.AddMinutes(15)) {
      return [pscustomobject]@{ date = $cand.ToString('yyyyMMdd'); time = ('{0:D4}' -f $t) }
    }
  }
  $y = $now.AddDays(-1)
  return [pscustomobject]@{ date = $y.ToString('yyyyMMdd'); time = '2300' }
}

# data.go.kr 공통 오류(서비스키 미승인, 일일 트래픽 초과 등)를 원인별 안내로 바꿔준다
function Assert-ApiOk($json, [string]$url) {
  $code = $json.response.header.resultCode
  if ($code -eq '00') { return }
  $msg = $json.response.header.resultMsg
  $hint = switch ($code) {
    '30' { 'SERVICE_KEY_IS_NOT_REGISTERED_ERROR — data.go.kr 활용신청이 아직 "승인" 상태가 아니거나 키가 틀림' }
    '22' { 'LIMITED_NUMBER_OF_SERVICE_REQUESTS_EXCEEDS_ERROR — 일일 트래픽 한도 초과' }
    '03' { 'NODATA_ERROR — 요청 기간/지점에 자료가 없음(관측소 번호나 날짜 범위를 확인)' }
    default { '알 수 없는 오류 코드' }
  }
  throw ('기상청 API가 요청을 거부했습니다 (코드 ' + $code + ': ' + $msg + ').' + [Environment]::NewLine +
    '  ' + $hint + [Environment]::NewLine + '  요청 URL: ' + $url)
}

function Invoke-KmaJson {
  param([string]$Url, [string]$CachePath)

  if ($FromCache) {
    if (-not (Test-Path $CachePath)) {
      Write-Warning ('저장된 원본이 없어 건너뜁니다: ' + (Split-Path -Leaf $CachePath) + '  (-FromCache 없이 한 번 실행하면 받아온다)')
      return $null
    }
    $text = [IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8)
  }
  else {
    $res = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
    $text = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray())
    if ($text -match '^\s*<') {
      throw ('기상청 API가 XML 오류 응답을 반환했습니다(서비스키 오류 가능성). 응답 앞부분: ' + $text.Substring(0, [Math]::Min(300, $text.Length)))
    }
    [IO.File]::WriteAllText($CachePath, $text, (New-Object Text.UTF8Encoding($false)))
    Start-Sleep -Milliseconds $DelayMs
  }

  $json = $text | ConvertFrom-Json
  Assert-ApiOk -json $json -url $CachePath
  return $json
}

$KOR = @{
  TMP = '1시간 기온'; TMN = '일 최저기온'; TMX = '일 최고기온'; POP = '강수확률'
  PCP = '1시간 강수량'; REH = '습도'; WSD = '풍속'; SKY = '하늘상태'; PTY = '강수형태'
}
$UNIT = @{
  TMP = '°C'; TMN = '°C'; TMX = '°C'; POP = '%'; PCP = 'mm'; REH = '%'; WSD = 'm/s'; SKY = '코드'; PTY = '코드'
}

# ---------------- 단기예보 ----------------
function Get-VilageForecast {
  $grid = ConvertTo-KmaGrid -lat $Lat -lon $Lon
  $baseInfo = Get-LatestBaseDateTime
  Write-Host ('[단기예보] 격자 nx=' + $grid.nx + ' ny=' + $grid.ny + '  기준 ' + $baseInfo.date + ' ' + $baseInfo.time) -ForegroundColor Cyan

  $cache = Join-Path $rawDir ('vilage_fcst_' + $baseInfo.date + '_' + $baseInfo.time + '.json')
  $key = [uri]::EscapeDataString($ServiceKey)
  $url = $BASE + '/VilageFcstInfoService_2.0/getVilageFcst?serviceKey=' + $key +
    '&pageNo=1&numOfRows=1000&dataType=JSON&base_date=' + $baseInfo.date + '&base_time=' + $baseInfo.time +
    '&nx=' + $grid.nx + '&ny=' + $grid.ny
  $json = Invoke-KmaJson -Url $url -CachePath $cache
  if ($null -eq $json) { return }

  $items = $json.response.body.items.item
  if (-not $items) { throw '단기예보 응답에 항목이 없습니다.' }

  $rows = foreach ($it in $items) {
    [pscustomobject]@{
      '기준일시' = $it.baseDate + ' ' + $it.baseTime
      '예보일'   = $it.fcstDate
      '예보시각' = $it.fcstTime
      '항목코드' = $it.category
      '항목명'   = $(if ($KOR.ContainsKey($it.category)) { $KOR[$it.category] } else { $it.category })
      '값'       = $it.fcstValue
      '단위'     = $(if ($UNIT.ContainsKey($it.category)) { $UNIT[$it.category] } else { '' })
    }
  }
  $rawCsv = Join-Path $OutDir 'vilage_fcst_today.csv'
  $rows | Export-Csv -Path $rawCsv -NoTypeInformation -Encoding UTF8

  # 팀 지표 카드(값·단위·출처·조회일)에 바로 쓸 수 있게 예보 첫날 기준으로 항목별 대표값을 뽑는다
  $firstDate = ($rows | Sort-Object 예보일, 예보시각 | Select-Object -First 1).예보일
  $today = $rows | Where-Object { $_.예보일 -eq $firstDate }
  $summary = @()
  foreach ($code in 'TMX', 'TMN', 'POP', 'WSD', 'REH') {
    $vals = $today | Where-Object { $_.항목코드 -eq $code }
    if (-not $vals) { continue }
    $rep = $(if ($code -eq 'POP' -or $code -eq 'WSD') {
        ($vals | Measure-Object -Property 값 -Maximum).Maximum
      }
      else { $vals[0].값 })
    $summary += [pscustomobject]@{
      '구분'   = '자연환경 · 기후(단기예보)'
      '항목'   = $KOR[$code]
      '값'     = $rep
      '단위'   = $UNIT[$code]
      '기준'   = $firstDate + ' 예보 (발표 ' + $baseInfo.date + ' ' + $baseInfo.time + ')'
      '출처'   = '기상청 단기예보 조회서비스(data.go.kr) getVilageFcst · 격자 nx=' + $grid.nx + '/ny=' + $grid.ny
      '조회일' = $조회일
    }
  }
  $sumCsv = Join-Path $OutDir 'vilage_fcst_summary.csv'
  $summary | Export-Csv -Path $sumCsv -NoTypeInformation -Encoding UTF8

  Write-Host ('  원자료 ' + $rows.Count + '행 -> ' + $rawCsv)
  Write-Host ('  카드용 요약 ' + $summary.Count + '행 -> ' + $sumCsv)
}

# ---------------- ASOS 일자료(극값) ----------------
function Get-AsosExtremes {
  if (-not $StartDt) { $StartDt = (Get-Date).AddYears(-$Years).ToString('yyyyMMdd') }
  if (-not $EndDt) { $EndDt = (Get-Date).AddDays(-1).ToString('yyyyMMdd') }
  Write-Host ('[ASOS 일자료] 지점 ' + $StnId + '  기간 ' + $StartDt + ' ~ ' + $EndDt) -ForegroundColor Cyan

  $key = [uri]::EscapeDataString($ServiceKey)
  $all = @()
  $pageNo = 1
  $numOfRows = 999
  while ($true) {
    $cache = Join-Path $rawDir ('asos_' + $StnId + '_' + $StartDt + '_' + $EndDt + '_p' + $pageNo + '.json')
    $url = $BASE + '/AsosDalyInfoService/getWthrDataList?serviceKey=' + $key +
      '&pageNo=' + $pageNo + '&numOfRows=' + $numOfRows + '&dataType=JSON&dataCd=ASOS&dateCd=DAY' +
      '&startDt=' + $StartDt + '&endDt=' + $EndDt + '&stnIds=' + $StnId
    $json = Invoke-KmaJson -Url $url -CachePath $cache
    if ($null -eq $json) { return }

    $items = @($json.response.body.items.item)
    if ($items.Count -eq 0) { break }
    $all += $items
    $totalCount = [int]$json.response.body.totalCount
    if ($all.Count -ge $totalCount) { break }
    $pageNo++
  }
  if ($all.Count -eq 0) { throw 'ASOS 응답에 항목이 없습니다. 지점번호/기간을 확인하세요.' }

  $rows = foreach ($it in $all) {
    [pscustomobject]@{
      '일시'       = $it.tm
      '평균기온'   = $it.avgTa
      '최고기온'   = $it.maxTa
      '최저기온'   = $it.minTa
      '일강수량'   = $it.sumRn
      '평균풍속'   = $it.avgWs
      '최대풍속'   = $it.maxWs
      '최심적설'   = $it.ddMefs
    }
  }
  $rawCsv = Join-Path $OutDir 'asos_daily.csv'
  $rows | Export-Csv -Path $rawCsv -NoTypeInformation -Encoding UTF8

  # 자연환경 세부항목 '풍수해·지진기록' 판단에 바로 쓸 수 있는 극값만 추린다.
  # 결측(공백)은 숫자 계산에서 빼고 세지 않는다.
  function ToNum($v) { if ($v -eq $null -or $v -eq '') { return $null }; return [double]$v }
  $maxTaVals = $rows | ForEach-Object { ToNum $_.최고기온 } | Where-Object { $_ -ne $null }
  $minTaVals = $rows | ForEach-Object { ToNum $_.최저기온 } | Where-Object { $_ -ne $null }
  $avgTaVals = $rows | ForEach-Object { ToNum $_.평균기온 } | Where-Object { $_ -ne $null }
  $rnVals    = $rows | ForEach-Object { ToNum $_.일강수량 } | Where-Object { $_ -ne $null }
  $wsVals    = $rows | ForEach-Object { ToNum $_.최대풍속 } | Where-Object { $_ -ne $null }

  $기간표기 = $StartDt.Substring(0, 4) + '-' + $StartDt.Substring(4, 2) + '-' + $StartDt.Substring(6, 2) + ' ~ ' +
              $EndDt.Substring(0, 4) + '-' + $EndDt.Substring(4, 2) + '-' + $EndDt.Substring(6, 2)
  $출처 = '기상청 지상(종관,ASOS) 일자료 조회서비스(data.go.kr) getWthrDataList · 지점 ' + $StnId

  $summary = @(
    [pscustomobject]@{ '구분' = '자연환경 · 기후(연평균)'; '항목' = '연평균기온';        '값' = [math]::Round(($avgTaVals | Measure-Object -Average).Average, 1); '단위' = '°C';  '기준' = $기간표기; '출처' = $출처; '조회일' = $조회일 }
    [pscustomobject]@{ '구분' = '자연환경 · 풍수해(폭염)';   '항목' = '폭염일수(일최고기온≥33℃)'; '값' = ($maxTaVals | Where-Object { $_ -ge 33 }).Count; '단위' = '일/기간'; '기준' = $기간표기; '출처' = $출처; '조회일' = $조회일 }
    [pscustomobject]@{ '구분' = '자연환경 · 풍수해(한파)';   '항목' = '한파일수(일최저기온≤-12℃)'; '값' = ($minTaVals | Where-Object { $_ -le -12 }).Count; '단위' = '일/기간'; '기준' = $기간표기; '출처' = $출처; '조회일' = $조회일 }
    [pscustomobject]@{ '구분' = '자연환경 · 풍수해(호우)';   '항목' = '호우일수(일강수량≥80mm)';   '값' = ($rnVals | Where-Object { $_ -ge 80 }).Count; '단위' = '일/기간'; '기준' = $기간표기; '출처' = $출처; '조회일' = $조회일 }
    [pscustomobject]@{ '구분' = '자연환경 · 풍수해(강수)';   '항목' = '기간 중 최대 일강수량';      '값' = ($rnVals | Measure-Object -Maximum).Maximum; '단위' = 'mm'; '기준' = $기간표기; '출처' = $출처; '조회일' = $조회일 }
    [pscustomobject]@{ '구분' = '자연환경 · 풍수해(바람)';   '항목' = '기간 중 최대풍속';           '값' = ($wsVals | Measure-Object -Maximum).Maximum; '단위' = 'm/s'; '기준' = $기간표기; '출처' = $출처; '조회일' = $조회일 }
  )
  $sumCsv = Join-Path $OutDir 'climate_extremes_summary.csv'
  $summary | Export-Csv -Path $sumCsv -NoTypeInformation -Encoding UTF8

  Write-Host ('  원자료 ' + $rows.Count + '행 -> ' + $rawCsv)
  Write-Host ('  극값 요약 -> ' + $sumCsv)
  $summary | Format-Table -AutoSize
}

if ($Mode -eq 'forecast' -or $Mode -eq 'both') { Get-VilageForecast }
if ($Mode -eq 'obs' -or $Mode -eq 'both') { Get-AsosExtremes }
