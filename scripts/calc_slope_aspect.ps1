# 지표 ⑥ 경사·향 적합면적 비율 — 대시보드 여섯째 칸 (6주차 슬라이드 25~28·38)
# 정의: 대상지 중 경사·향·표고 조건을 모두 충족하는 90m 셀(0.81ha)의 면적 비율(%).
# 저장: 값 1개만 두면 임계값 가정이 사라지므로 기준안 15% · 하한 10% · 상한 25% 세 값을
#       DEM 출처 · 해상도 · 조회일과 함께 한 행으로 저장한다.
#
# 판정: 셀마다 Horn 방식(3x3)으로 경사도(%)와 향을 구하고, 세 조건을 모두 충족해야 '참 셀', 하나라도 어기면 거짓.
#   경사 <= 임계값(%)          기준안 15 · 하한 10 · 상한 25 (교재 범위 안의 가정. 이 값만 바꿔 세 번 계산)
#   향 135~225도(남향 ±45도)   평지는 향이 정의되지 않아 거짓으로 둔다
#   표고 <= 기반시설 표고 + 50m  기반시설 표고는 자료에 값이 없어 -InfraElevM 으로 받고, 없으면 중심점 표고로 '가정'한다
# 면적: 적합면적 = 참 셀 수 x 0.81ha, 비율 = 적합면적 / 대상지 면적(셀 수 x 0.81ha)
# 경계 셀: 셀 중심이 반경 안이면 대상지에 넣는다. 90m보다 작은 급경사는 반영되지 않는다.
#
# DEM 출처: 기본은 Open-Meteo Elevation API(Copernicus DEM GLO-90, 키 불필요, 정수 m 단위).
#   슬라이드가 지정한 국토지리정보원 DEM 90m 이 아니므로 출처 열에 그대로 적는다.
#   국토지리정보원 DEM 을 직접 받았다면 r,c,elev 열의 CSV 로 만들어 -ElevCsv 로 넘기고 -DemName 을 고친다.
#   (r=북쪽에서 아래로, c=서쪽에서 오른쪽으로 0부터. 격자 크기는 중심을 가운데 둔 홀수 정방형)
#
# 출력: out/dem/slope_aspect_suitability.csv   한 행(세 임계값 + 출처 + 해상도 + 조회일)
#       out/dem/raw/elev_*.csv                 받은 고도 격자(-FromCache 로 재계산)
# 사용: .\scripts\calc_slope_aspect.ps1
#       .\scripts\calc_slope_aspect.ps1 -RadiusM 2000
#       .\scripts\calc_slope_aspect.ps1 -FromCache
param(
  [double]$Lat = 37.5735,
  [double]$Lon = 126.9788,
  [int]$RadiusM = 1000,
  [int]$CellM = 90,
  [double[]]$Thresholds = @(10, 15, 25),
  [double]$AspectMin = 135,
  [double]$AspectMax = 225,
  [double]$InfraElevM = [double]::NaN,
  [double]$ElevMarginM = 50,
  [string]$VworldLayer = 'LT_C_ADSIDO_INFO (행정경계 확인용, 셀 판정에는 미사용)',
  [string]$ElevCsv,
  [string]$DemName = 'Copernicus DEM GLO-90 (Open-Meteo Elevation API, 정수 m)',
  [string]$OutDir,
  [switch]$FromCache,
  [int]$DelayMs = 300
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$inv = [Globalization.CultureInfo]::InvariantCulture

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out\dem' }
$rawDir = Join-Path $OutDir 'raw'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

# 격자: 반경 안 셀 + 경사 계산용 바깥 한 칸
$half = [int][Math]::Floor($RadiusM / $CellM) + 1
$size = 2 * $half + 1
$mPerDegLat = 111320.0
$mPerDegLon = 111320.0 * [Math]::Cos($Lat * [Math]::PI / 180.0)

$z = New-Object 'double[,]' $size, $size
$조회일 = Get-Date -Format 'yyyy-MM-dd'

$cachePath = Join-Path $rawDir ('elev_' + $Lat.ToString('0.####', $inv) + '_' + $Lon.ToString('0.####', $inv) + '_' + $RadiusM + 'm_' + $CellM + 'm.csv')
$readPath = $null
if ($ElevCsv) { $readPath = $ElevCsv } elseif ($FromCache) { $readPath = $cachePath }

if ($readPath) {
  if (-not (Test-Path $readPath)) { throw ('고도 격자 파일이 없습니다: ' + $readPath + '  (-FromCache 없이 한 번 실행하면 받아온다)') }
  $rows = Import-Csv -Path $readPath
  if ($rows.Count -ne $size * $size) { throw ('격자 크기가 맞지 않습니다: ' + $rows.Count + '행, 필요 ' + ($size * $size) + '행(' + $size + 'x' + $size + ')') }
  foreach ($row in $rows) { $z[[int]$row.r, [int]$row.c] = [double]::Parse($row.elev, $inv) }
  $조회일 = (Get-Item $readPath).LastWriteTime.ToString('yyyy-MM-dd')
  Write-Host ('[고도] 저장된 격자 사용: ' + $readPath) -ForegroundColor Cyan
}
else {
  Write-Host ('[고도] ' + $size + 'x' + $size + ' = ' + ($size * $size) + '점 요청 (셀 ' + $CellM + 'm)') -ForegroundColor Cyan
  $pts = New-Object System.Collections.ArrayList
  for ($r = 0; $r -lt $size; $r++) {
    for ($c = 0; $c -lt $size; $c++) {
      $north = ($half - $r) * $CellM
      $east = ($c - $half) * $CellM
      [void]$pts.Add([pscustomobject]@{ r = $r; c = $c; lat = $Lat + $north / $mPerDegLat; lon = $Lon + $east / $mPerDegLon })
    }
  }
  $out = New-Object System.Collections.ArrayList
  for ($s = 0; $s -lt $pts.Count; $s += 100) {
    $batch = $pts.GetRange($s, [Math]::Min(100, $pts.Count - $s))
    $la = ($batch | ForEach-Object { $_.lat.ToString('0.00000', $inv) }) -join ','
    $lo = ($batch | ForEach-Object { $_.lon.ToString('0.00000', $inv) }) -join ','
    $url = 'https://api.open-meteo.com/v1/elevation?latitude=' + $la + '&longitude=' + $lo
    try { $res = Invoke-RestMethod -Uri $url -TimeoutSec 30 }
    catch { throw ('고도 API 호출 실패: ' + $_.Exception.Message + '  (요청이 몰렸다면 잠시 뒤 다시 실행)') }
    $el = @($res.elevation)
    if ($el.Count -ne $batch.Count) { throw ('응답 개수가 요청과 다릅니다: ' + $el.Count + '/' + $batch.Count) }
    for ($k = 0; $k -lt $batch.Count; $k++) {
      $z[$batch[$k].r, $batch[$k].c] = [double]$el[$k]
      [void]$out.Add([pscustomobject]@{ r = $batch[$k].r; c = $batch[$k].c; lat = $batch[$k].lat.ToString('0.00000', $inv); lon = $batch[$k].lon.ToString('0.00000', $inv); elev = ([double]$el[$k]).ToString($inv) })
    }
    Start-Sleep -Milliseconds $DelayMs
  }
  $out | Export-Csv -Path $cachePath -NoTypeInformation -Encoding UTF8
  Write-Host ('  고도 격자 저장 -> ' + $cachePath)
}

# 기반시설 표고: 자료에 값이 없으므로 지정이 없으면 중심점(종로구청) 표고로 가정한다
$infraAssumed = [double]::IsNaN($InfraElevM)
$infra = $InfraElevM
if ($infraAssumed) { $infra = $z[$half, $half] }

# 셀마다 경사도(%)와 향(도, 북=0 시계방향) — Horn 3x3
$facingElevOk = 0
$total = 0
$slopeOk = @{}; $bothOk = @{}
foreach ($t in $Thresholds) { $slopeOk[$t] = 0; $bothOk[$t] = 0 }
$slopeSum = 0.0; $flat = 0

for ($r = 1; $r -lt $size - 1; $r++) {
  for ($c = 1; $c -lt $size - 1; $c++) {
    $dy = ($r - $half) * $CellM; $dx = ($c - $half) * $CellM
    if ([Math]::Sqrt($dx * $dx + $dy * $dy) -gt $RadiusM) { continue }

    $za = $z[($r - 1), ($c - 1)]; $zb = $z[($r - 1), $c]; $zc = $z[($r - 1), ($c + 1)]
    $zd = $z[$r, ($c - 1)];                               $zf = $z[$r, ($c + 1)]
    $zg = $z[($r + 1), ($c - 1)]; $zh = $z[($r + 1), $c]; $zi = $z[($r + 1), ($c + 1)]
    $dzdx = (($zc + 2 * $zf + $zi) - ($za + 2 * $zd + $zg)) / (8.0 * $CellM)
    $dzdy = (($zg + 2 * $zh + $zi) - ($za + 2 * $zb + $zc)) / (8.0 * $CellM)
    $slope = 100.0 * [Math]::Sqrt($dzdx * $dzdx + $dzdy * $dzdy)

    $facing = $false
    if ($dzdx -eq 0 -and $dzdy -eq 0) { $flat++ }
    else {
      $deg = [Math]::Atan2($dzdy, -$dzdx) * 180.0 / [Math]::PI
      if ($deg -lt 0) { $aspect = 90.0 - $deg } elseif ($deg -gt 90) { $aspect = 360.0 - $deg + 90.0 } else { $aspect = 90.0 - $deg }
      $facing = ($aspect -ge $AspectMin -and $aspect -le $AspectMax)
    }

    $elevOk = ($z[$r, $c] -le ($infra + $ElevMarginM))
    $total++
    $slopeSum += $slope
    if ($facing -and $elevOk) { $facingElevOk++ }
    foreach ($t in $Thresholds) {
      if ($slope -le $t) { $slopeOk[$t]++; if ($facing -and $elevOk) { $bothOk[$t]++ } }
    }
  }
}
if ($total -eq 0) { throw '대상지 안에 계산할 셀이 없습니다. -RadiusM 을 키우세요.' }

function Pct([int]$n) { return [Math]::Round(100.0 * $n / $total, 1) }

$row = [ordered]@{
  '지표'              = '⑥ 경사·향 적합면적 비율'
  '값(%)_기준안'      = ''
  '값(%)_하한'        = ''
  '값(%)_상한'        = ''
}
# 임계값 순서는 입력 순서(기본 10·15·25)이고, 기준안은 가운데 값으로 본다
$sorted = $Thresholds | Sort-Object
$lo = $sorted[0]; $hi = $sorted[$sorted.Count - 1]
$mid = $sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]
if ($sorted.Count -ge 3) { $mid = $sorted[1] }
$row['값(%)_기준안'] = Pct $bothOk[$mid]
$row['값(%)_하한'] = Pct $bothOk[$lo]
$row['값(%)_상한'] = Pct $bothOk[$hi]
$row['임계값(경사%)'] = ($lo.ToString($inv) + ' · ' + $mid.ToString($inv) + ' · ' + $hi.ToString($inv))
$cellHa = $CellM * $CellM / 10000.0
$row['적합면적(ha)_기준안'] = [Math]::Round($bothOk[$mid] * $cellHa, 2)
$row['적합면적(ha)_하한'] = [Math]::Round($bothOk[$lo] * $cellHa, 2)
$row['적합면적(ha)_상한'] = [Math]::Round($bothOk[$hi] * $cellHa, 2)
$row['대상지 면적(ha)'] = [Math]::Round($total * $cellHa, 2)
$row['셀 수'] = $total
$row['셀 크기(ha)'] = $cellHa
$row['경사만_기준안(%)'] = Pct $slopeOk[$mid]
$row['경사만_하한(%)'] = Pct $slopeOk[$lo]
$row['경사만_상한(%)'] = Pct $slopeOk[$hi]
$row['향·표고만 충족(%)'] = Pct $facingElevOk
$row['판정 조건'] = ('경사 ≤ 임계값 AND 향 ' + $AspectMin + '~' + $AspectMax + '도 AND 표고 ≤ 기반시설 +' + $ElevMarginM + 'm (3개 모두 충족 = 참)')
$row['기반시설 표고(m)'] = $infra
$row['평균경사(%)'] = [Math]::Round($slopeSum / $total, 1)
$row['평지 셀(향 없음 → 거짓)'] = $flat
$row['해상도'] = ($CellM.ToString() + 'm 격자')
$row['대상지'] = ('중심 ' + $Lat + ',' + $Lon + ' 반경 ' + $RadiusM + 'm')
$row['경계 셀 규칙'] = '셀 중심이 반경 안이면 포함'
$row['DEM 출처'] = $DemName
$row['브이월드 레이어'] = $VworldLayer
$row['조회일'] = $조회일
$가정 = @('임계값 10·15·25%는 교재 범위 안의 가정(기준안 15, 하한 10, 상한 25)')
if ($infraAssumed) { $가정 += ('기반시설 표고는 자료에 값이 없어 중심점 표고 ' + $infra + 'm 로 가정') }
$가정 += 'DEM 은 지표면 모델이라 건물·수목 높이가 섞임'
$가정 += '90m보다 작은 급경사는 반영되지 않음'
$row['가정·한계'] = ($가정 -join ' / ')

$csv = Join-Path $OutDir 'slope_aspect_suitability.csv'
[pscustomobject]$row | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host ('대상지 셀 ' + $total + '개 (' + $CellM + 'm, ' + $row['대상지 면적(ha)'] + 'ha), 평균경사 ' + $row['평균경사(%)'] + '%, 기반시설 표고 ' + $infra + 'm' + $(if ($infraAssumed) { ' (가정)' } else { '' }))
Write-Host ('  경사 ≤ ' + $lo + '%  & 향 & 표고 : ' + $row['값(%)_하한'] + '%  ' + $row['적합면적(ha)_하한'] + 'ha   (경사만 ' + $row['경사만_하한(%)'] + '%)')
Write-Host ('  경사 ≤ ' + $mid + '% & 향 & 표고 : ' + $row['값(%)_기준안'] + '%  ' + $row['적합면적(ha)_기준안'] + 'ha   (경사만 ' + $row['경사만_기준안(%)'] + '%)  <- 기준안')
Write-Host ('  경사 ≤ ' + $hi + '% & 향 & 표고 : ' + $row['값(%)_상한'] + '%  ' + $row['적합면적(ha)_상한'] + 'ha   (경사만 ' + $row['경사만_상한(%)'] + '%)')
Write-Host ('  향·표고만 충족 : ' + $row['향·표고만 충족(%)'] + '%   평지 셀(향 없음→거짓) ' + $flat + '개')
Write-Host ('저장 -> ' + $csv)
