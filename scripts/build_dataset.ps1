# Overpass 원본(4개 구역, out center) -> 대시보드용 압축 데이터셋
# 분류 규칙의 단일 출처(single source of truth). 결과: dashboard/buildings.json
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'data\centers'
$outPath = Join-Path $root 'dashboard\buildings.json'

$RESIDENTIAL_B = @('house','residential','apartments','detached','semidetached_house','terrace','dormitory','bungalow','static_caravan','cabin','houseboat')
$COMMERCIAL_B  = @('commercial','office','retail','supermarket','kiosk','hotel')
$PUBLIC_B      = @('school','university','hospital','government','public','civic','kindergarten','college','train_station')
$RELIGIOUS_B   = @('church','cathedral','chapel','mosque','temple','shrine','museum','theatre')
$INDUSTRIAL_B  = @('industrial','warehouse','factory','manufacture')

$COMMERCIAL_A  = @('bank','restaurant','cafe','fast_food','pharmacy','marketplace','fuel','car_rental','pub','bar')
$PUBLIC_A      = @('school','university','hospital','kindergarten','townhall','library','police','fire_station','clinic','college','courthouse','post_office')
$RELIGIOUS_A   = @('place_of_worship','theatre','arts_centre','community_centre')

# 카테고리 인덱스: 0 상업·업무 / 1 주거 / 2 공공·교육 / 3 종교·문화 / 4 공업 / 5 미분류
function Get-Category($building, $shop, $office, $amenity, $tourism, $landuse, $manMade) {
  if ($building) {
    if ($RESIDENTIAL_B -contains $building) { return 1 }
    if ($COMMERCIAL_B  -contains $building) { return 0 }
    if ($PUBLIC_B      -contains $building) { return 2 }
    if ($RELIGIOUS_B   -contains $building) { return 3 }
    if ($INDUSTRIAL_B  -contains $building) { return 4 }
  }
  if ($shop -or $office) { if ($office -eq 'government') { return 2 } else { return 0 } }
  if ($amenity) {
    if ($COMMERCIAL_A -contains $amenity) { return 0 }
    if ($PUBLIC_A     -contains $amenity) { return 2 }
    if ($RELIGIOUS_A  -contains $amenity) { return 3 }
  }
  if ($tourism) {
    if (@('hotel','guest_house','hostel','motel') -contains $tourism) { return 0 }
    if ($tourism -eq 'museum') { return 3 }
  }
  if ($landuse -eq 'industrial' -or $manMade -eq 'works') { return 4 }
  return 5
}

function Get-Tag($block, $key) {
  $pattern = '"' + [regex]::Escape($key) + '":\s*"((?:[^"\\]|\\.)*)"'
  if ($block -match $pattern) { return $matches[1] }
  return $null
}

$sb = New-Object System.Text.StringBuilder
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$counts = New-Object 'int[]' 6
$timestamp = $null
$first = $true
$total = 0

foreach ($q in @('sw','se','nw','ne')) {
  $path = Join-Path $srcDir "$q.json"
  $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)

  if (-not $timestamp -and $text -match '"timestamp_osm_base":\s*"([^"]+)"') { $timestamp = $matches[1] }

  $blocks = [regex]::Split($text, '(?=\{\s*"type":\s*"way")')
  foreach ($block in $blocks) {
    if ($block -notmatch '"type":\s*"way"') { continue }
    if ($block -notmatch '"id":\s*(\d+)') { continue }
    $id = $matches[1]
    if (-not $seen.Add($id)) { continue }
    if ($block -notmatch '"center":\s*\{\s*"lat":\s*(-?[\d.]+),\s*"lon":\s*(-?[\d.]+)') { continue }
    $lat = [double]$matches[1]
    $lon = [double]$matches[2]

    $cat = Get-Category (Get-Tag $block 'building') (Get-Tag $block 'shop') (Get-Tag $block 'office') `
                        (Get-Tag $block 'amenity') (Get-Tag $block 'tourism') (Get-Tag $block 'landuse') `
                        (Get-Tag $block 'man_made')

    $name = Get-Tag $block 'name:ko'
    if (-not $name) { $name = Get-Tag $block 'name' }

    $latE5 = [int][math]::Round($lat * 100000)
    $lonE5 = [int][math]::Round($lon * 100000)

    if (-not $first) { [void]$sb.Append(',') }
    $first = $false
    if ($name) { [void]$sb.Append("[$latE5,$lonE5,$cat,`"$name`"]") }
    else       { [void]$sb.Append("[$latE5,$lonE5,$cat]") }

    $counts[$cat]++
    $total++
  }
  Write-Host "$q 처리 완료 (누적 $total 동)"
}

$cats = '[{"key":"commercial","name":"상업·업무"},{"key":"residential","name":"주거"},{"key":"public_edu","name":"공공·교육"},{"key":"religious_cultural","name":"종교·문화"},{"key":"industrial","name":"공업"},{"key":"unclassified","name":"미분류"}]'
$meta = "{`"center`":[37.5735,126.9788],`"radius_m`":3000,`"timestamp`":`"$timestamp`",`"total`":$total,`"coord_scale`":100000}"
$json = "{`"meta`":$meta,`"categories`":$cats,`"buildings`":[" + $sb.ToString() + "]}"

[IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "총 $total 동 -> $outPath ($([math]::Round((Get-Item $outPath).Length / 1MB, 2)) MB)"
for ($i = 0; $i -lt 6; $i++) { Write-Host ("  [{0}] {1,6} 동" -f $i, $counts[$i]) }
