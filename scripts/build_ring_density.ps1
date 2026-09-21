# 대상지 중심에서 1km 간격 링(권역)별 건물밀도 집계
# 입력: dashboard/buildings.json (Overpass API 수집 -> build_dataset.ps1 산출)
# 출력: out/ring_density_1km.csv
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'dashboard\buildings.json'
$outDir = Join-Path $root 'out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$CENTER_LAT = 37.5735   # 서울 종로구청
$CENTER_LON = 126.9788
$SCALE = 100000
$M_PER_DEG_LAT = 111320.0
$M_PER_DEG_LON = 111320.0 * [math]::Cos($CENTER_LAT * [math]::PI / 180)

$text = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)

# [위도x1e5, 경도x1e5, 카테고리, "이름"?] 형태를 그대로 뽑는다
$matches = [regex]::Matches($text, '\[(-?\d+),(-?\d+),(\d)')

$RING_COUNT = 3
$total    = New-Object 'int[]' $RING_COUNT   # 링별 전체 건물수
$classified = New-Object 'int[]' $RING_COUNT # 링별 용도 태그가 있는 건물수
$commercial = New-Object 'int[]' $RING_COUNT # 링별 상업·업무
$residential = New-Object 'int[]' $RING_COUNT
$outside = 0

foreach ($m in $matches) {
  $lat = [double]$m.Groups[1].Value / $SCALE
  $lon = [double]$m.Groups[2].Value / $SCALE
  $cat = [int]$m.Groups[3].Value

  $dx = ($lon - $CENTER_LON) * $M_PER_DEG_LON
  $dy = ($lat - $CENTER_LAT) * $M_PER_DEG_LAT
  $dist = [math]::Sqrt($dx * $dx + $dy * $dy)

  $ring = [math]::Floor($dist / 1000)
  if ($ring -ge $RING_COUNT) { $outside++; continue }

  $total[$ring]++
  if ($cat -ne 5) { $classified[$ring]++ }   # 5 = 미분류
  if ($cat -eq 0) { $commercial[$ring]++ }   # 0 = 상업·업무
  if ($cat -eq 1) { $residential[$ring]++ }  # 1 = 주거
}

$rows = @()
$sumTotal = 0; $sumClass = 0; $sumComm = 0; $sumResi = 0
for ($i = 0; $i -lt $RING_COUNT; $i++) {
  $inner = $i; $outer = $i + 1
  $area = [math]::PI * ($outer * $outer - $inner * $inner)   # km^2
  $rows += [pscustomobject]@{
    '링'            = "R$($i+1)"
    '거리구간_km'   = "$inner-$outer"
    '건물수_동'     = $total[$i]
    '링면적_km2'    = [math]::Round($area, 3)
    '건물밀도_동perkm2' = [math]::Round($total[$i] / $area, 1)
    '분류건물수_동' = $classified[$i]
    '분류건물밀도_동perkm2' = [math]::Round($classified[$i] / $area, 1)
    '기재율_pct'    = [math]::Round(100.0 * $classified[$i] / $total[$i], 1)
    '상업업무_동'   = $commercial[$i]
    '주거_동'       = $residential[$i]
  }
  $sumTotal += $total[$i]; $sumClass += $classified[$i]
  $sumComm += $commercial[$i]; $sumResi += $residential[$i]
}

$areaAll = [math]::PI * 9
$rows += [pscustomobject]@{
  '링'            = '전체'
  '거리구간_km'   = '0-3'
  '건물수_동'     = $sumTotal
  '링면적_km2'    = [math]::Round($areaAll, 3)
  '건물밀도_동perkm2' = [math]::Round($sumTotal / $areaAll, 1)
  '분류건물수_동' = $sumClass
  '분류건물밀도_동perkm2' = [math]::Round($sumClass / $areaAll, 1)
  '기재율_pct'    = [math]::Round(100.0 * $sumClass / $sumTotal, 1)
  '상업업무_동'   = $sumComm
  '주거_동'       = $sumResi
}

$csvPath = Join-Path $outDir 'ring_density_1km.csv'
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$rows | Format-Table -AutoSize
Write-Host ""
Write-Host "3km 밖(경계 오차로 제외): $outside 동"
Write-Host "저장: $csvPath"
