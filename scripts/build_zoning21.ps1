# 용도지역 21종 건폐율·용적률 표를 조문 원문에서 직접 만든다
# 입력: out/law/law_articles.csv  (fetch_law_articles.ps1 -TargetsPath scripts\law_targets_jongno.json 의 산출물)
#       영 제84조 = 건폐율 상한, 영 제85조 = 용적률 범위, 조례 제44조·제48조 = 서울시 적용값
# 출력: data/seoul_zoning21.csv
# 값을 손으로 옮겨 적지 않는다. 호 번호로 조문 원문에서 뽑고, 21종이 다 차지 않으면 경고한다.
param(
  [string]$ArticlesPath,
  [string]$OutPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ArticlesPath) { $ArticlesPath = Join-Path $root 'out\law\law_articles.csv' }
if (-not $OutPath)      { $OutPath      = Join-Path $root 'data\seoul_zoning21.csv' }
if (-not (Test-Path $ArticlesPath)) {
  throw ('조문 CSV가 없습니다: ' + $ArticlesPath + [Environment]::NewLine +
         '  먼저 실행: .\scripts\fetch_law_articles.ps1 -OC <본인OC> -TargetsPath scripts\law_targets_jongno.json')
}

$rows = Import-Csv -Path $ArticlesPath -Encoding UTF8

# 21종의 법정 순서. 영 제84조·제85조의 호 번호와 같다
$ZONES = @(
  @{ n=1;  g='도시지역-주거'; z='제1종전용주거지역' }, @{ n=2;  g='도시지역-주거'; z='제2종전용주거지역' }
  @{ n=3;  g='도시지역-주거'; z='제1종일반주거지역' }, @{ n=4;  g='도시지역-주거'; z='제2종일반주거지역' }
  @{ n=5;  g='도시지역-주거'; z='제3종일반주거지역' }, @{ n=6;  g='도시지역-주거'; z='준주거지역' }
  @{ n=7;  g='도시지역-상업'; z='중심상업지역' },       @{ n=8;  g='도시지역-상업'; z='일반상업지역' }
  @{ n=9;  g='도시지역-상업'; z='근린상업지역' },       @{ n=10; g='도시지역-상업'; z='유통상업지역' }
  @{ n=11; g='도시지역-공업'; z='전용공업지역' },       @{ n=12; g='도시지역-공업'; z='일반공업지역' }
  @{ n=13; g='도시지역-공업'; z='준공업지역' },         @{ n=14; g='도시지역-녹지'; z='보전녹지지역' }
  @{ n=15; g='도시지역-녹지'; z='생산녹지지역' },       @{ n=16; g='도시지역-녹지'; z='자연녹지지역' }
  @{ n=17; g='관리지역';     z='보전관리지역' },       @{ n=18; g='관리지역';     z='생산관리지역' }
  @{ n=19; g='관리지역';     z='계획관리지역' },       @{ n=20; g='농림지역';     z='농림지역' }
  @{ n=21; g='자연환경보전'; z='자연환경보전지역' }
)

function Get-ArticleRow([string]$lawLike, [string]$jo) {
  $hit = $rows | Where-Object { $_.법령명 -like $lawLike -and $_.조 -eq $jo } | Select-Object -First 1
  if ($null -eq $hit) { throw ('조문을 찾지 못했습니다: ' + $lawLike + ' ' + $jo) }
  return $hit
}

# '5. 제3종일반주거지역 : 100퍼센트 이상 300퍼센트 이하' 같은 호를 번호로 집어낸다
function Get-HoText($row, [int]$no, [string]$zone) {
  $t = $row.내용
  $m = [regex]::Match($t, ('(?<!\d)' + $no + '\.\s*' + [regex]::Escape($zone) + '\s*[:：]\s*([^0-9]*?[0-9][^0-9]*?(?:이하|이상[^0-9]*이하|퍼센트[^0-9]*))(?=\s*(?:\d+\.\s|$))'))
  if (-not $m.Success) {
    # 단서가 붙은 조례 호(예: '8. 일반상업지역: 800퍼센트(단, 서울도심: 600퍼센트)')
    $m = [regex]::Match($t, ('(?<!\d)' + $no + '\.\s*' + [regex]::Escape($zone) + '\s*[:：]\s*(.+?)(?=\s*\d+\.\s|$)'))
  }
  if (-not $m.Success) { return $null }
  return ($m.Groups[1].Value.Trim() -replace '\s+', ' ')
}

function Get-Pct([string]$s, [switch]$Last) {
  if (-not $s) { return '' }
  $ms = [regex]::Matches($s, '([\d,]+)\s*(천)?\s*([\d,]*)\s*퍼센트')
  if ($ms.Count -eq 0) { return '' }
  $m = if ($Last) { $ms[$ms.Count - 1] } else { $ms[0] }
  # '1천500퍼센트' -> 1500
  $a = [int](($m.Groups[1].Value) -replace ',', '')
  if ($m.Groups[2].Value -eq '천') {
    $b = 0
    if ($m.Groups[3].Value) { $b = [int](($m.Groups[3].Value) -replace ',', '') }
    return [string](($a * 1000) + $b)
  }
  return [string]$a
}

$령84 = Get-ArticleRow '*시행령' '제84조'
$령85 = Get-ArticleRow '*시행령' '제85조'
$례44 = Get-ArticleRow '서울특별시 도시계획 조례' '제44조'
$례48 = Get-ArticleRow '서울특별시 도시계획 조례' '제48조'

$조회일 = $령84.조회일
$out = @()
$missing = @()

foreach ($z in $ZONES) {
  $t84 = Get-HoText $령84 $z.n $z.z
  $t85 = Get-HoText $령85 $z.n $z.z
  $t44 = Get-HoText $례44 $z.n $z.z
  $t48 = Get-HoText $례48 $z.n $z.z

  if (-not $t84 -or -not $t85) { $missing += ('영 ' + $z.z) }

  $영건폐 = Get-Pct $t84
  $영용하 = Get-Pct $t85
  $영용상 = Get-Pct $t85 -Last
  $조건폐 = Get-Pct $t44
  $조용적 = Get-Pct $t48
  $도심   = ''
  if ($t48 -and $t48 -match '서울도심') { $도심 = Get-Pct $t48 -Last; if ($도심 -eq $조용적) { $도심 = '' } }

  $비고 = @()
  if ($조건폐 -and $영건폐 -and [int]$조건폐 -lt [int]$영건폐) {
    $비고 += ('조례가 건폐율을 상한보다 ' + ([int]$영건폐 - [int]$조건폐) + '%p 강화')
  }
  if (-not $t44 -and -not $t48) { $비고 += '서울시 조례 미규정(도시지역 외) — 영 기준 적용' }

  $out += [pscustomobject]@{
    '연번'              = $z.n
    '구분'              = $z.g
    '용도지역'          = $z.z
    '영_건폐율상한_pct' = $영건폐
    '영_용적률하한_pct' = $영용하
    '영_용적률상한_pct' = $영용상
    '조례_건폐율_pct'   = $조건폐
    '조례_용적률_pct'   = $조용적
    '조례_서울도심_용적률_pct' = $도심
    '근거_영'           = ('제84조제1항제' + $z.n + '호 / 제85조제1항제' + $z.n + '호')
    '근거_조례'         = $(if ($t44) { '제44조제' + $z.n + '호 / 제48조제' + $z.n + '호' } else { '' })
    '영_시행일'         = $령84.시행일
    '조례_시행일'       = $례44.시행일
    '조회일'            = $조회일
    '비고'              = ($비고 -join ' · ')
  }
}

if ($missing.Count -gt 0) { throw ('조문에서 값을 뽑지 못한 항목이 있습니다: ' + ($missing -join ', ')) }

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$out | Export-Csv -Path $OutPath -NoTypeInformation -Encoding UTF8

$out | Select-Object 연번,용도지역,영_건폐율상한_pct,조례_건폐율_pct,영_용적률상한_pct,조례_용적률_pct,조례_서울도심_용적률_pct | Format-Table -AutoSize
Write-Host ''
Write-Host ($out.Count.ToString() + '종 저장: ' + $OutPath)
Write-Host ('출처: 영 시행 ' + $령84.시행일 + ' / 조례 시행 ' + $례44.시행일 + ' / 조회일 ' + $조회일)
