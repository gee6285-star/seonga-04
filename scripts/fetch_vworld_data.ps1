# 브이월드 2D 데이터 API 2.0 -> 대상지 반경 안 레이어(용도지역·건물·도시계획 등) 수집
# 강의자료 슬라이드 30 "요청 네 단계"를 그대로 코드로 옮긴 것.
#   1) 키와 서비스 URL : 키는 환경변수 VWORLD_KEY 에만 둔다(코드·문서·화면에 노출 금지)
#   2) 서비스 ID 확정  : -Data 에 레이어 ID를 적는다(예: LT_C_ADSIDO_INFO). 158개 목록은 API 레퍼런스에서 확인
#   3) 요청 조립       : api.vworld.kr/req/data + GetFeature·data·key·geomFilter·crs(EPSG:4326)·size(<=1000)·page
#                        브라우저 밖에서 호출하므로 등록한 도메인을 domain 으로 함께 보낸다
#   4) 응답 읽기       : status 부터 확인하고 result 를 저장. 1000건을 넘으면 page 를 올려 이어 받는다
#
# 사전준비: vworld.kr 오픈API 인증키 개별 발급(발급 시 등록한 서비스 URL 이 domain 이 된다)
#   $env:VWORLD_KEY = '<본인키>' ; $env:VWORLD_DOMAIN = '<등록한 도메인>'
#
# 입력: -Data (레이어 ID, 여러 개 가능)  -Lat/-Lon (기본 종로구청 37.5735/126.9788)  -RadiusM (기본 1000)
# 출력: out/vworld/<ID>.geojson           지오메트리 + 속성
#       out/vworld/<ID>_properties.csv    속성 표(지오메트리 제외)
#       out/vworld/request_log.csv        요청 URL(키 제외)·status·건수·조회일 기록
#       out/vworld/raw/*.json             API 원본 응답(-FromCache 로 재처리)
#
# 주의: 레이어 ID 는 슬라이드 예시(LT_C_ADSIDO_INFO)만 확인된 값이다. 다른 레이어는 API 레퍼런스의
#       서비스 목록에서 ID 를 확인한 뒤 쓴다. BOX 는 (경도,위도) 순으로 보냈는데, 첫 호출이 NOT_FOUND 면
#       request_log.csv 의 요청 URL 로 축 순서와 반경부터 의심한다.
# 사용: .\scripts\fetch_vworld_data.ps1 -Data LT_C_ADSIDO_INFO
#       .\scripts\fetch_vworld_data.ps1 -Data <ID1>,<ID2> -RadiusM 500
#       .\scripts\fetch_vworld_data.ps1 -Data <ID> -FromCache
param(
  [string]$Key = $env:VWORLD_KEY,
  [string]$Domain = $env:VWORLD_DOMAIN,
  [string[]]$Data = @('LT_C_ADSIDO_INFO'),
  [double]$Lat = 37.5735,
  [double]$Lon = 126.9788,
  [int]$RadiusM = 1000,
  [ValidateRange(1, 1000)]
  [int]$Size = 1000,
  [int]$MaxPages = 20,
  [string]$OutDir,
  [switch]$FromCache,
  [int]$DelayMs = 300
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web.Extensions

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out\vworld' }
$rawDir = Join-Path $OutDir 'raw'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

if (-not $FromCache -and -not $Key) {
  throw 'VWORLD_KEY 가 필요합니다. $env:VWORLD_KEY 에 인증키를 설정하세요(코드에 적지 않는다).'
}
if (-not $FromCache -and -not $Domain) {
  Write-Warning 'VWORLD_DOMAIN 이 비어 있습니다. 브라우저 밖 호출은 등록한 도메인을 domain 으로 보내야 거부되지 않습니다.'
}

$API = 'https://api.vworld.kr/req/data'
$inv = [Globalization.CultureInfo]::InvariantCulture

# 지오메트리가 커서 ConvertFrom-Json(2MB 제한)을 쓸 수 없다. 한도를 푼 JavaScriptSerializer 로 읽는다
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue

function Get-Val($node, [string[]]$path) {
  $cur = $node
  foreach ($p in $path) {
    if ($null -eq $cur -or -not ($cur -is [System.Collections.IDictionary]) -or -not ([System.Collections.IDictionary]$cur).Contains($p)) { return $null }
    $cur = $cur[$p]
  }
  return $cur
}

function Hide-Key([string]$u) { return ($u -replace '([?&]key=)[^&]*', '$1***') }

# 중심점과 반경(m) -> 위경도 BOX
function Get-BoxFilter {
  $dLat = $RadiusM / 111320.0
  $dLon = $RadiusM / (111320.0 * [Math]::Cos($Lat * [Math]::PI / 180.0))
  $v = @(($Lon - $dLon), ($Lat - $dLat), ($Lon + $dLon), ($Lat + $dLat)) | ForEach-Object { $_.ToString('0.######', $inv) }
  return 'BOX(' + ($v -join ',') + ')'
}

function Get-VworldPage([string]$dataId, [int]$page, [string]$box) {
  $cache = Join-Path $rawDir ($dataId + '_' + $RadiusM + 'm_p' + $page + '.json')
  $url = $API + '?service=data&version=2.0&request=GetFeature&format=json&errorformat=json' +
    '&data=' + $dataId + '&key=' + [uri]::EscapeDataString($Key) +
    '&geomFilter=' + $box + '&crs=EPSG:4326&size=' + $Size + '&page=' + $page
  if ($Domain) { $url += '&domain=' + [uri]::EscapeDataString($Domain) }

  if ($FromCache) {
    if (-not (Test-Path $cache)) {
      Write-Warning ('저장된 원본이 없어 건너뜁니다: ' + (Split-Path -Leaf $cache) + '  (-FromCache 없이 한 번 실행하면 받아온다)')
      return $null
    }
    $text = [IO.File]::ReadAllText($cache, [Text.Encoding]::UTF8)
    $조회일 = (Get-Item $cache).LastWriteTime.ToString('yyyy-MM-dd')
  }
  else {
    try {
      $res = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
    }
    catch {
      $script:log += [pscustomobject]@{
        '조회일' = (Get-Date -Format 'yyyy-MM-dd'); '서비스ID' = $dataId; 'page' = $page; 'status' = 'HTTP 오류'
        '전체건수' = ''; '전체page' = ''; '수신건수' = 0
        '요청URL(키제외)' = (Hide-Key $url); '환경변수' = 'VWORLD_KEY'; 'domain 전송' = $(if ($Domain) { 'O' } else { 'X(domain 미전송)' }); '비고' = $_.Exception.Message
      }
      Save-Log
      throw ('브이월드 호출 실패: ' + $_.Exception.Message + [Environment]::NewLine + '  요청 URL: ' + (Hide-Key $url))
    }
    $text = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray())
    [IO.File]::WriteAllText($cache, $text, (New-Object Text.UTF8Encoding($false)))
    $조회일 = Get-Date -Format 'yyyy-MM-dd'
    Start-Sleep -Milliseconds $DelayMs
  }

  try { $obj = $ser.DeserializeObject($text) }
  catch { throw ('JSON 이 아닌 응답입니다. 응답 앞부분: ' + $text.Substring(0, [Math]::Min(200, $text.Length))) }

  return [pscustomobject]@{ obj = $obj; url = (Hide-Key $url); 조회일 = $조회일 }
}

$box = Get-BoxFilter
Write-Host ('[범위] ' + $box + '  (중심 ' + $Lat + ',' + $Lon + ' 반경 ' + $RadiusM + 'm)') -ForegroundColor Cyan

$log = @()
$logPath = Join-Path $OutDir 'request_log.csv'
$domainSent = $(if ($Domain) { 'O' } else { 'X(domain 미전송)' })

# 오류로 멈추기 전에도 기록은 남긴다 — 원인 판별 근거가 오류 본문 한 줄이다
function Save-Log { if ($script:log.Count -gt 0) { $script:log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 } }

foreach ($dataId in $Data) {
  Write-Host ('[조회] ' + $dataId) -ForegroundColor Cyan
  $features = New-Object System.Collections.ArrayList
  $page = 1

  while ($true) {
    $r = Get-VworldPage -dataId $dataId -page $page -box $box
    if ($null -eq $r) { break }

    # 4단계: status 를 먼저 본다
    $status = [string](Get-Val $r.obj @('response', 'status'))
    $total = [int](Get-Val $r.obj @('response', 'record', 'total'))
    $pages = [int](Get-Val $r.obj @('response', 'page', 'total'))
    $feats = @(Get-Val $r.obj @('response', 'result', 'featureCollection', 'features'))
    $got = 0
    if ($status -eq 'OK') { $got = $feats.Count }

    $code = Get-Val $r.obj @('response', 'error', 'code')
    $txt = Get-Val $r.obj @('response', 'error', 'text')
    $비고 = ''
    if ($status -ne 'OK') { $비고 = ('status ' + $status + $(if ($code -or $txt) { ' / ' + $code + ' ' + $txt } else { '' })) }

    $log += [pscustomobject]@{
      '조회일' = $r.조회일; '서비스ID' = $dataId; 'page' = $page; 'status' = $status
      '전체건수' = $total; '전체page' = $pages; '수신건수' = $got
      '요청URL(키제외)' = $r.url; '환경변수' = 'VWORLD_KEY'; 'domain 전송' = $domainSent; '비고' = $비고
    }

    if ($status -eq 'NOT_FOUND') { Save-Log; Write-Warning ('  결과 없음(NOT_FOUND): ' + $dataId + ' — 반경·레이어 ID 를 확인하세요'); break }
    if ($status -ne 'OK') {
      Save-Log
      throw ('브이월드가 요청을 거부했습니다 (status ' + $status + ' / ' + $code + '): ' + $txt + [Environment]::NewLine +
        '  키 미승인·도메인 불일치·서비스 ID 오타를 확인하세요. 요청 URL: ' + $r.url)
    }

    foreach ($f in $feats) { [void]$features.Add($f) }
    Write-Host ('  page ' + $page + '/' + $pages + '  ' + $got + '건 (전체 ' + $total + ')')
    if ($page -ge $pages) { break }
    if ($page -ge $MaxPages) { Write-Warning ('  -MaxPages ' + $MaxPages + ' 에서 멈춤. 나머지는 반경을 줄이거나 -MaxPages 를 올리세요'); break }
    $page++
  }

  if ($features.Count -eq 0) { continue }

  $gj = '{"type":"FeatureCollection","features":[' + (($features | ForEach-Object { $ser.Serialize($_) }) -join ',') + ']}'
  $gjPath = Join-Path $OutDir ($dataId + '.geojson')
  [IO.File]::WriteAllText($gjPath, $gj, (New-Object Text.UTF8Encoding($false)))

  # 속성 표: 레이어마다 필드가 달라 전체 키의 합집합으로 열을 만든다
  $cols = New-Object System.Collections.Generic.List[string]
  foreach ($f in $features) {
    $props = Get-Val $f @('properties')
    if ($props -is [System.Collections.IDictionary]) { foreach ($k in $props.Keys) { if (-not $cols.Contains($k)) { $cols.Add($k) } } }
  }
  $rows = foreach ($f in $features) {
    $props = Get-Val $f @('properties')
    $row = [ordered]@{ '서비스ID' = $dataId; 'id' = [string](Get-Val $f @('id')); 'geometry' = [string](Get-Val $f @('geometry', 'type')) }
    foreach ($c in $cols) {
      $v = $null
      if ($props -is [System.Collections.IDictionary] -and ([System.Collections.IDictionary]$props).Contains($c)) { $v = $props[$c] }
      if ($v -is [System.Collections.IDictionary] -or ($v -is [System.Collections.IEnumerable] -and $v -isnot [string])) { $v = $ser.Serialize($v) }
      $row[$c] = $v
    }
    [pscustomobject]$row
  }
  $csvPath = Join-Path $OutDir ($dataId + '_properties.csv')
  $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  Write-Host ('  ' + $features.Count + '건 -> ' + $gjPath)
  Write-Host ('  속성 표 -> ' + $csvPath)
}

if ($log.Count -gt 0) {
  $logPath = Join-Path $OutDir 'request_log.csv'
  $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
  Write-Host ('요청 기록(키 제외) -> ' + $logPath)
}
