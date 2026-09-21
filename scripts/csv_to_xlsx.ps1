# 표 원본 CSV를 엑셀(.xlsx)로 변환
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'

$jobs = @(
  @{ csv = 'ring_density_1km.csv';     xlsx = '2주차_과제2_링별밀도표_임성아.xlsx';     sheet = '1km 링별 밀도표' },
  @{ csv = 'smart_park_priority.csv';  xlsx = '2주차_과제3_우선순위표_임성아.xlsx';  sheet = '스마트공원 우선순위표' }
)

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false

try {
  foreach ($job in $jobs) {
    $rows = Import-Csv (Join-Path $outDir $job.csv) -Encoding UTF8
    $cols = $rows[0].psobject.Properties.Name
    $nRow = $rows.Count + 1
    $nCol = $cols.Count

    $grid = New-Object 'object[,]' $nRow, $nCol
    for ($c = 0; $c -lt $nCol; $c++) { $grid[0, $c] = $cols[$c] }
    for ($r = 0; $r -lt $rows.Count; $r++) {
      for ($c = 0; $c -lt $nCol; $c++) {
        $v = $rows[$r].($cols[$c])
        $num = 0.0
        # 숫자로 읽히는 값은 숫자로 저장해 엑셀에서 계산·정렬이 되게 한다
        if ([double]::TryParse($v, [ref]$num)) { $grid[($r + 1), $c] = $num }
        else { $grid[($r + 1), $c] = $v }
      }
    }

    $wb = $excel.Workbooks.Add()
    $ws = $wb.Worksheets.Item(1)
    $ws.Name = $job.sheet
    $ws.Range($ws.Cells(1, 1), $ws.Cells($nRow, $nCol)).Value2 = $grid

    $header = $ws.Range($ws.Cells(1, 1), $ws.Cells(1, $nCol))
    $header.Font.Bold = $true
    $header.Interior.Color = 15982074      # 연한 파랑
    $header.HorizontalAlignment = -4108    # 가운데

    $used = $ws.Range($ws.Cells(1, 1), $ws.Cells($nRow, $nCol))
    $used.Borders.LineStyle = 1
    $used.Borders.Color = 12566463
    [void]$used.EntireColumn.AutoFit()

    $ws.Application.ActiveWindow.SplitRow = 1
    $ws.Application.ActiveWindow.FreezePanes = $true

    $path = Join-Path $outDir $job.xlsx
    if (Test-Path $path) { Remove-Item $path -Force }
    $wb.SaveAs($path, 51)   # 51 = xlsx
    $wb.Close($false)
    Write-Host "저장: $($job.xlsx)  ($nRow행 x $nCol열)"
  }
}
finally {
  $excel.Quit()
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
}
