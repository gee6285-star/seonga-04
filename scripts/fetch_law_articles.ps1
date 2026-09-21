# 국가법령정보 OPEN API -> 대상지 관련 법령·자치법규 조문 수집
# 사전준비: open.law.go.kr > OPEN API 신청에서 '현행법령(시행일) 목록 조회'와 '본문 조회'를
#           함께 신청해 승인받고, 이 PC의 공인 IP를 등록해 두어야 한다.
#           자치법규(조례·규칙)를 받으려면 '자치법규 목록/본문 조회'도 함께 신청해야 한다.
# 입력: scripts/law_targets.json (수집 대상 법령·조문 목록. type 에 law 또는 ordin)
# 출력: out/law/law_articles.csv  (조·항 단위 표 + 인용용 출처표기)
#       out/law/law_versions.csv  (법령별 식별자·시점 대장: ID·MST·공포·시행일·조회일)
#       out/law/text/*.txt        (법령별 조문 전문, 보고서에 붙여쓰기용)
#       out/law/raw/*.xml         (API 원본 응답. 나중에 재파싱·검증용)
# 사용: .\scripts\fetch_law_articles.ps1 -OC <본인OC>
#       .\scripts\fetch_law_articles.ps1 -OC <본인OC> -TargetsPath scripts\law_targets_jongno.json
#       .\scripts\fetch_law_articles.ps1 -FromCache     # 호출 없이 저장된 원본만 다시 파싱
param(
  [string]$OC = $env:LAW_OC,
  [string]$TargetsPath,
  [string]$OutDir,
  [switch]$FromCache,
  [int]$DelayMs = 400
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $PSScriptRoot
if (-not $TargetsPath) { $TargetsPath = Join-Path $PSScriptRoot 'law_targets.json' }
if (-not $OutDir)      { $OutDir      = Join-Path $root 'out\law' }
$rawDir  = Join-Path $OutDir 'raw'
$textDir = Join-Path $OutDir 'text'
New-Item -ItemType Directory -Force -Path $rawDir, $textDir | Out-Null

if (-not $FromCache -and -not $OC) {
  throw 'OC(신청자 이메일 ID)가 필요합니다. -OC 로 넘기거나 $env:LAW_OC 에 설정하세요. 예) -OC hong (가입 이메일이 hong@…이면 hong)'
}

$BASE = 'https://www.law.go.kr/DRF'
$조회일 = Get-Date -Format 'yyyy-MM-dd'

function Get-SafeName([string]$s) {
  return ($s -replace '[\\/:*?"<>|\s]', '_')
}

function ConvertTo-OneLine([string]$s) {
  if (-not $s) { return '' }
  return ((($s -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' ').Trim())
}

function Remove-Space([string]$s) {
  if (-not $s) { return '' }
  return ($s -replace '\s', '')
}

function Format-KDate([string]$ymd) {
  if ($ymd -match '^(\d{4})(\d{2})(\d{2})$') {
    return ('{0}. {1}. {2}.' -f $matches[1], [int]$matches[2], [int]$matches[3])
  }
  return $ymd
}

# 항번호는 ①②③ 같은 원문자로 온다. 숫자로 바꿔야 '제1항'을 만들 수 있다
function Get-HangNo([string]$s) {
  if (-not $s) { return '' }
  $t = $s.Trim()
  if ($t -match '(\d+)') { return $matches[1] }
  if ($t.Length -eq 0) { return '' }
  $c = [int][char]$t[0]
  if ($c -ge 0x2460 -and $c -le 0x2473) { return [string]($c - 0x2460 + 1) }    # ① ~ ⑳
  if ($c -ge 0x3251 -and $c -le 0x325F) { return [string]($c - 0x3251 + 21) }   # ㉑ ~ ㉟
  if ($c -ge 0x32B1 -and $c -le 0x32BF) { return [string]($c - 0x32B1 + 36) }   # ㊱ ~ ㊿
  return ''
}

function Get-NodeText($node, [string]$xpath) {
  if ($null -eq $node) { return '' }
  $n = $node.SelectSingleNode($xpath)
  if ($null -eq $n) { return '' }
  return $n.InnerText.Trim()
}

# API 거부 응답을 XML 파싱 실패 대신 원인별 안내로 바꿔준다
function Assert-ApiOk([string]$text, [string]$url) {
  $looksXml = $text -match '^\s*<\?xml' -or $text -match '^\s*<[가-힣A-Za-z]'
  $rejected = $text -match '검증\s*실패' -or $text -match '사용자\s*정보' -or $text -match 'INVALID'
  if ($looksXml -and -not $rejected) { return }
  $head = $text.Substring(0, [Math]::Min(200, $text.Length))
  $msg = @(
    '법령 API가 요청을 거부했습니다. 아래 순서로 확인하세요.',
    '  1) open.law.go.kr 활용신청이 "승인" 상태인가 (신청 후 1~2일 소요)',
    '  2) 신청 항목에 "현행법령(시행일) 본문 조회"가 포함됐는가 (목록만 신청하면 본문이 막힌다)',
    '  3) 신청서에 등록한 IP와 지금 호출하는 PC의 공인 IP가 같은가',
    '  4) OC 값이 가입 이메일의 @ 앞부분과 같은가',
    ('요청 URL : ' + $url),
    ('응답 앞부분: ' + $head)
  ) -join [Environment]::NewLine
  throw $msg
}

function Invoke-LawXml {
  param([string]$Url, [string]$CachePath)

  if ($FromCache) {
    if (-not (Test-Path $CachePath)) {
      Write-Warning ('저장된 원본이 없어 건너뜁니다: ' + (Split-Path -Leaf $CachePath) + '  (-FromCache 없이 한 번 실행하면 받아온다)')
      return $null
    }
    $text = [IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8)
    Assert-ApiOk -text $text -url $CachePath
  }
  else {
    $res = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -UserAgent ([Microsoft.PowerShell.Commands.PSUserAgent]::Chrome)
    $text = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray())
    Assert-ApiOk -text $text -url $Url
    [IO.File]::WriteAllText($CachePath, $text, (New-Object Text.UTF8Encoding($false)))
    Start-Sleep -Milliseconds $DelayMs
  }

  $xml = New-Object System.Xml.XmlDocument
  $xml.LoadXml($text)
  return $xml
}

# 약칭이나 글자수 비슷한 다른 법령에 걸리지 않도록 제명이 정확히 일치하는 현행 법령을 고른다
function Resolve-Law([string]$name) {
  $cache = Join-Path $rawDir ('search_' + (Get-SafeName $name) + '.xml')
  $url = $BASE + '/lawSearch.do?OC=' + $OC + '&target=law&type=XML&display=100&search=1&query=' + [uri]::EscapeDataString($name)
  $xml = Invoke-LawXml -Url $url -CachePath $cache
  if ($null -eq $xml) { return $null }

  $hits = $xml.SelectNodes('//law')
  if ($hits.Count -eq 0) {
    Write-Warning ('검색 결과가 없습니다: ' + $name)
    return $null
  }

  $wanted = Remove-Space $name
  $best = $null
  foreach ($h in $hits) {
    if ((Remove-Space (Get-NodeText $h '법령명한글')) -ne $wanted) { continue }
    if ($null -eq $best) { $best = $h }
    if ((Get-NodeText $h '현행연혁코드') -eq '현행') { $best = $h; break }
  }

  if ($null -eq $best) {
    $cand = @()
    foreach ($h in $hits) { $cand += (Get-NodeText $h '법령명한글') }
    Write-Warning ('제명이 정확히 일치하는 법령이 없습니다: ' + $name)
    Write-Warning ('  검색 결과 후보: ' + (($cand | Select-Object -First 5) -join ' / '))
    return $null
  }

  return [pscustomobject]@{
    법령명   = Get-NodeText $best '법령명한글'
    법령ID   = Get-NodeText $best '법령ID'
    MST      = Get-NodeText $best '법령일련번호'
    법종구분 = Get-NodeText $best '법령구분명'
    소관부처 = Get-NodeText $best '소관부처명'
    공포일자 = Get-NodeText $best '공포일자'
    공포번호 = Get-NodeText $best '공포번호'
    시행일자 = Get-NodeText $best '시행일자'
    공포표기 = Get-NodeText $best '법령구분명'
    링크종류 = '법령'
  }
}

# 자치법규(조례·규칙)는 target=ordin 이고 필드명이 법령과 다르다.
# 자치단체마다 같은 제명을 쓰므로(예: 25개 자치구 도시계획 조례) 제명 완전일치로 고른다.
function Resolve-Ordin([string]$name) {
  $cache = Join-Path $rawDir ('search_ordin_' + (Get-SafeName $name) + '.xml')
  $url = $BASE + '/lawSearch.do?OC=' + $OC + '&target=ordin&type=XML&display=100&search=1&query=' + [uri]::EscapeDataString($name)
  $xml = Invoke-LawXml -Url $url -CachePath $cache
  if ($null -eq $xml) { return $null }

  $hits = $xml.SelectNodes('//law')
  if ($hits.Count -eq 0) {
    Write-Warning ('검색 결과가 없습니다: ' + $name)
    return $null
  }

  $wanted = Remove-Space $name
  $best = $null
  foreach ($h in $hits) {
    if ((Remove-Space (Get-NodeText $h '자치법규명')) -eq $wanted) { $best = $h; break }
  }

  if ($null -eq $best) {
    $cand = @()
    foreach ($h in $hits) { $cand += (Get-NodeText $h '자치법규명') }
    Write-Warning ('제명이 정확히 일치하는 자치법규가 없습니다: ' + $name)
    Write-Warning ('  검색 결과 후보: ' + (($cand | Select-Object -First 5) -join ' / '))
    return $null
  }

  $기관 = Get-NodeText $best '지자체기관명'
  $종류 = Get-NodeText $best '자치법규종류'
  return [pscustomobject]@{
    법령명   = Get-NodeText $best '자치법규명'
    법령ID   = Get-NodeText $best '자치법규ID'
    MST      = Get-NodeText $best '자치법규일련번호'
    법종구분 = $종류
    소관부처 = $기관
    공포일자 = Get-NodeText $best '공포일자'
    공포번호 = Get-NodeText $best '공포번호'
    시행일자 = Get-NodeText $best '시행일자'
    공포표기 = ($기관 + $종류)          # 인용 관례: 서울특별시조례 제10139호
    링크종류 = '자치법규'
  }
}

# "58", "제58조", "58의2", "58-2" 를 모두 받는다
function Get-ArticleSpec([string]$spec) {
  $s = (Remove-Space $spec) -replace '[제조]', ''
  if ($s -match '^(\d+)(?:의|-)(\d+)$') {
    return [pscustomobject]@{ 번호 = [int]$matches[1]; 가지 = [int]$matches[2] }
  }
  if ($s -match '^(\d+)$') {
    return [pscustomobject]@{ 번호 = [int]$matches[1]; 가지 = 0 }
  }
  throw ('조문 지정 형식 오류: ' + $spec + '  (예: 58, 58의2)')
}

function New-Row($meta, $조표기, $항표기, $제목, $본문, $조문시행일) {
  $인용 = '「' + $meta.법령명 + '」 ' + $조표기 + $항표기 + ' (' + $meta.공포표기 + ' 제' + $meta.공포번호 + '호, ' + (Format-KDate $meta.시행일자) + ' 시행), 국가법령정보센터, ' + $조회일 + ' 조회'
  return [pscustomobject]@{
    '법령명'     = $meta.법령명
    '법령ID'     = $meta.법령ID
    'MST'        = $meta.MST
    '법종구분'   = $meta.법종구분
    '소관부처'   = $meta.소관부처
    '조'         = $조표기
    '항'         = $항표기
    '조문제목'   = $제목
    '내용'       = $본문
    '조문시행일' = $조문시행일
    '시행일'     = $meta.시행일자
    '조회일'     = $조회일
    '출처표기'   = $인용
    '원문URL'    = 'https://www.law.go.kr/' + $meta.링크종류 + '/' + [uri]::EscapeDataString($meta.법령명)
  }
}

$cfg = [IO.File]::ReadAllText($TargetsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

$rows = @()
$summary = @()

foreach ($law in $cfg.laws) {
  $종류 = 'law'
  if ($law.type) { $종류 = ([string]$law.type).Trim().ToLower() }
  if ($종류 -ne 'law' -and $종류 -ne 'ordin') { throw ('type 은 law 또는 ordin 이어야 합니다: ' + $law.type) }
  Write-Host ('[조회] ' + $law.name) -ForegroundColor Cyan

  if ($종류 -eq 'ordin') { $meta = Resolve-Ordin $law.name } else { $meta = Resolve-Law $law.name }
  if ($null -eq $meta) { continue }

  $specs = @()
  if ($law.articles) { foreach ($a in $law.articles) { $specs += (Get-ArticleSpec ([string]$a)) } }
  $keys = @()
  if ($law.keywords) { foreach ($k in $law.keywords) { $keys += (Remove-Space $k) } }

  $bodyCache = Join-Path $rawDir ($종류 + '_' + $meta.법령ID + '_' + $meta.MST + '.xml')
  $bodyUrl = $BASE + '/lawService.do?OC=' + $OC + '&target=' + $종류 + '&type=XML&MST=' + $meta.MST
  $body = Invoke-LawXml -Url $bodyUrl -CachePath $bodyCache
  if ($null -eq $body) { continue }

  # 목록과 본문이 다를 수 있으므로 본문 기준값으로 덮어쓴다
  $기본정보 = '//기본정보'
  if ($종류 -eq 'ordin') { $기본정보 = '//자치법규기본정보' }
  $v = Get-NodeText $body ($기본정보 + '/시행일자')
  if ($v) { $meta.시행일자 = $v }
  $v = Get-NodeText $body ($기본정보 + '/공포번호')
  if ($v) { $meta.공포번호 = $v }

  $ID라벨 = '법령ID'
  if ($종류 -eq 'ordin') { $ID라벨 = '자치법규ID' }
  $lines = @()
  $lines += ('법령명 : ' + $meta.법령명 + '  (' + $meta.공포표기 + ' 제' + $meta.공포번호 + '호)')
  $lines += ($ID라벨 + ' : ' + $meta.법령ID + '   (개정돼도 바뀌지 않는 식별자)')
  $lines += ('MST    : ' + $meta.MST + '   (시행일 버전 식별자. 개정되면 바뀜)')
  $lines += ('시행일 : ' + (Format-KDate $meta.시행일자))
  $lines += ('조회일 : ' + $조회일)
  $lines += ('출처   : 국가법령정보센터 https://www.law.go.kr')
  $lines += ('-' * 70)

  $hitCount = 0

  # ---- 자치법규: 조문이 <조> 하나에 항·호까지 통째로 들어 있어 조 단위로만 쪼갠다 ----
  if ($종류 -eq 'ordin') {
    foreach ($u in $body.SelectNodes('//조')) {
      if ((Get-NodeText $u '조문여부') -ne 'Y') { continue }   # 장·절 제목 행 제외

      # 조문번호는 '004802' 처럼 온다. 앞자리가 조번호, 뒤 두 자리가 가지번호다
      $noTxt = Get-NodeText $u '조문번호'
      if ($noTxt -notmatch '^\d{3,8}$') { continue }
      $no  = [int]$noTxt.Substring(0, $noTxt.Length - 2)
      $sub = [int]$noTxt.Substring($noTxt.Length - 2, 2)

      $제목 = Get-NodeText $u '조제목'
      $조내용 = Get-NodeText $u '조내용'

      $take = $false
      if ($specs.Count -gt 0) {
        foreach ($s in $specs) { if ($s.번호 -eq $no -and $s.가지 -eq $sub) { $take = $true; break } }
      }
      elseif ($keys.Count -gt 0) {
        $hay = Remove-Space ($제목 + ' ' + $조내용)
        foreach ($k in $keys) { if ($hay -like ('*' + $k + '*')) { $take = $true; break } }
      }
      else { $take = $true }
      if (-not $take) { continue }
      $hitCount++

      $조표기 = '제' + $no + '조'
      if ($sub -gt 0) { $조표기 = $조표기 + '의' + $sub }

      # 조내용 앞에 '제3절 건폐율 및 용적률' 같은 절 제목이 함께 붙어 오므로 조문 시작부터 자른다
      $idx = $조내용.IndexOf($조표기 + '(')
      if ($idx -lt 0) { $idx = $조내용.IndexOf($조표기) }
      if ($idx -gt 0) { $조내용 = $조내용.Substring($idx) }

      $lines += ''
      $lines += $조내용
      $rows += (New-Row $meta $조표기 '' $제목 (ConvertTo-OneLine $조내용) $meta.시행일자)
    }

    # 별표는 조문이 위임한 기준표·도면이다. 도면은 첨부파일에만 있고 본문 텍스트가 비어 있다
    $tableSpecs = @()
    if ($law.tables) { foreach ($t in $law.tables) { $tableSpecs += (Get-ArticleSpec ([string]$t)) } }
    if ($tableSpecs.Count -gt 0) {
      foreach ($b in $body.SelectNodes('//별표단위')) {
        if ((Get-NodeText $b '별표구분') -ne '별표') { continue }
        $bn = Get-NodeText $b '별표번호'
        $bs = Get-NodeText $b '별표가지번호'
        if ($bn -notmatch '^\d+$') { continue }
        $bno = [int]$bn
        $bsub = 0
        if ($bs -match '^\d+$') { $bsub = [int]$bs }

        $take = $false
        foreach ($s in $tableSpecs) { if ($s.번호 -eq $bno -and $s.가지 -eq $bsub) { $take = $true; break } }
        if (-not $take) { continue }
        $hitCount++

        $별표표기 = '별표 ' + $bno
        if ($bsub -gt 0) { $별표표기 = $별표표기 + '의' + $bsub }
        $별표제목 = Get-NodeText $b '별표제목'
        $별표내용 = ConvertTo-OneLine (Get-NodeText $b '별표내용')
        $첨부 = Get-NodeText $b '별표첨부파일명'
        if ($별표내용.Length -lt 40) {
          # 도면·서식처럼 본문이 비어 있으면 임의로 채우지 않고 첨부파일 위치만 남긴다
          $별표내용 = '(본문 텍스트 없음 — 첨부파일로만 제공) ' + $첨부
        }

        $lines += ''
        $lines += ('[' + $별표표기 + '] ' + $별표제목)
        $lines += $별표내용
        $rows += (New-Row $meta $별표표기 '' $별표제목 $별표내용 $meta.시행일자)
      }
    }
  }
  else {

  foreach ($u in $body.SelectNodes('//조문단위')) {
    $kind = Get-NodeText $u '조문여부'
    if ($kind -and $kind -ne '조문') { continue }   # 편·장·절 제목 행 제외

    $noTxt = Get-NodeText $u '조문번호'
    if ($noTxt -notmatch '^\d+$') { continue }
    $no = [int]$noTxt
    $subTxt = Get-NodeText $u '조문가지번호'
    $sub = 0
    if ($subTxt -match '^\d+$') { $sub = [int]$subTxt }

    $제목 = Get-NodeText $u '조문제목'
    $조문내용 = Get-NodeText $u '조문내용'

    $take = $false
    if ($specs.Count -gt 0) {
      foreach ($s in $specs) { if ($s.번호 -eq $no -and $s.가지 -eq $sub) { $take = $true; break } }
    }
    elseif ($keys.Count -gt 0) {
      $hay = Remove-Space ($제목 + ' ' + $u.InnerText)
      foreach ($k in $keys) { if ($hay -like ('*' + $k + '*')) { $take = $true; break } }
    }
    else { $take = $true }
    if (-not $take) { continue }
    $hitCount++

    $조표기 = '제' + $no + '조'
    if ($sub -gt 0) { $조표기 = $조표기 + '의' + $sub }
    $조문시행일 = Get-NodeText $u '조문시행일자'
    if (-not $조문시행일) { $조문시행일 = $meta.시행일자 }

    # 조문내용은 보통 '제58조(제목)'으로 시작한다. 없을 때만 머리글을 따로 만든다
    $lines += ''
    if ($조문내용) {
      $lines += $조문내용
    }
    else {
      $머리 = $조표기
      if ($제목) { $머리 = $머리 + '(' + $제목 + ')' }
      $lines += $머리
    }

    $hangs = $u.SelectNodes('항')
    if ($hangs.Count -gt 0) {
      foreach ($h in $hangs) {
        $항번호 = Get-NodeText $h '항번호'
        $항내용 = Get-NodeText $h '항내용'
        # 호 노드의 InnerText를 쓰면 호번호가 호내용 앞에 한 번 더 붙어 '1.1.'이 된다
        $호텍스트 = @()
        foreach ($ho in $h.SelectNodes('호')) {
          $호내용 = Get-NodeText $ho '호내용'
          if (-not $호내용) { $호내용 = ConvertTo-OneLine $ho.InnerText }
          $목텍스트 = @()
          foreach ($mok in $ho.SelectNodes('목')) {
            $목내용 = Get-NodeText $mok '목내용'
            if (-not $목내용) { $목내용 = $mok.InnerText }
            $목텍스트 += (ConvertTo-OneLine $목내용)
          }
          $호텍스트 += (ConvertTo-OneLine ($호내용 + ' ' + ($목텍스트 -join ' ')))
        }

        # 항 본문이 조문내용에 이미 들어있으면 중복 출력하지 않는다
        if ($항내용 -and (Remove-Space $조문내용) -notlike ('*' + (Remove-Space $항내용) + '*')) {
          $lines += $항내용
        }
        foreach ($t in $호텍스트) { $lines += ('    ' + $t) }

        $본문 = ConvertTo-OneLine ($항내용 + ' ' + ($호텍스트 -join ' '))
        $항표기 = ''
        $항숫자 = Get-HangNo $항번호
        if ($항숫자) { $항표기 = '제' + $항숫자 + '항' }
        $rows += (New-Row $meta $조표기 $항표기 $제목 $본문 $조문시행일)
      }
    }
    else {
      $rows += (New-Row $meta $조표기 '' $제목 (ConvertTo-OneLine $조문내용) $조문시행일)
    }
  }

  }   # /법령

  if ($hitCount -eq 0) {
    Write-Warning ('  조건에 맞는 조문이 없습니다. articles/keywords를 확인하세요: ' + $law.name)
  }

  $txtPath = Join-Path $textDir ((Get-SafeName $meta.법령명) + '.txt')
  [IO.File]::WriteAllLines($txtPath, $lines, (New-Object Text.UTF8Encoding($true)))

  $summary += [pscustomobject]@{
    '구분'       = $meta.법종구분
    '법령명'     = $meta.법령명
    '법령ID'     = $meta.법령ID
    'MST'        = $meta.MST
    '소관'       = $meta.소관부처
    '공포일자'   = $meta.공포일자
    '공포번호'   = $meta.공포번호
    '시행일'     = $meta.시행일자
    '조회일'     = $조회일
    '수집조문'   = $hitCount
    '본문API'    = $BASE + '/lawService.do?target=' + $종류 + '&type=XML&MST=' + $meta.MST
    '원문URL'    = 'https://www.law.go.kr/' + $meta.링크종류 + '/' + [uri]::EscapeDataString($meta.법령명)
  }
}

if ($rows.Count -eq 0) { throw '수집된 조문이 없습니다. scripts/law_targets.json 을 확인하세요.' }

$csvPath = Join-Path $OutDir 'law_articles.csv'
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$verPath = Join-Path $OutDir 'law_versions.csv'
$summary | Export-Csv -Path $verPath -NoTypeInformation -Encoding UTF8

$summary | Select-Object 구분,법령명,법령ID,MST,시행일,수집조문 | Format-Table -AutoSize
Write-Host ''
Write-Host ('조·항 ' + $rows.Count + '행 저장: ' + $csvPath)
Write-Host ('식별자 대장: ' + $verPath)
Write-Host ('조문 전문: ' + $textDir)
Write-Host ('API 원본: ' + $rawDir + '   (-FromCache 로 다시 파싱 가능)')
