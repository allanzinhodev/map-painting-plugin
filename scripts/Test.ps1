param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$Aseprite = 'C:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe',
  [string]$ItemsOtb = 'C:\Users\Allan\backlands-workflow\server\data\items\items.otb'
)
$ErrorActionPreference = 'Stop'
$output = Join-Path $ProjectRoot 'test-output'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$nexa = Join-Path $ProjectRoot 'build\nexamap\bin\NexaMap Editor.exe'
if (-not (Test-Path -LiteralPath $nexa)) { throw 'Build NexaMap before running full tests.' }
function Native-Test([string[]]$Arguments, [string]$Report) {
  # Start-Process does not quote arguments containing spaces automatically.
  $quoted = $Arguments | ForEach-Object { '"' + $_ + '"' }
  $process = Start-Process -FilePath $nexa -ArgumentList $quoted -WindowStyle Hidden -Wait -PassThru
  # wxApp exits 255 in these intentional headless modes. The report is authoritative.
  $result = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
  if (-not $result.success) { throw "Native test failed: $($result.error)" }
  return $result
}
$nativeReport = Join-Path $output 'native-report.json'
if (Test-Path -LiteralPath $nativeReport) { Remove-Item -LiteralPath $nativeReport }
$native = Native-Test @('--aseprite-bridge-selftest',$ItemsOtb,$nativeReport) $nativeReport
Copy-Item -LiteralPath $nativeReport -Destination (Join-Path $ProjectRoot 'tests\native-result.json') -Force
foreach ($name in @('codec','models','integration','publish','cross-language','installed')) {
  $script = Join-Path $ProjectRoot "tests\$name.lua"
  $report = Join-Path $ProjectRoot "tests\$name-result.txt"
  if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report }
  & $Aseprite --batch --script-param "root=$ProjectRoot" --script $script | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Aseprite test failed: $name" }
  $result = Get-Content -LiteralPath $report -Raw
  if ($result -notmatch '(?m)^PASS' -or $result -match '(?m)^FAIL') { throw "Test did not pass: $name" }
  Write-Output "$name : PASS"
}
$packet = Join-Path $output 'aseprite-roundtrip-scene.json'
$returnReport = Join-Path $output 'native-return-report.json'
if (Test-Path -LiteralPath $returnReport) { Remove-Item -LiteralPath $returnReport }
$returned = Native-Test @('--aseprite-bridge-validate',$ItemsOtb,$packet,$returnReport) $returnReport
Write-Output "Native scene return: PASS ($($returned.itemCount) items, $($returned.tileCount) tiles)"
# Check byte preservation and position/stack preservation after the complete round trip.
$sent = Get-Content -LiteralPath $packet -Raw | ConvertFrom-Json
foreach ($tile in $sent.tiles) {
  $restored = @($returned.tiles | Where-Object { $_.x -eq $tile.x -and $_.y -eq $tile.y -and $_.z -eq $tile.z })
  if ($restored.Count -ne 1) { throw 'Returned tile position changed.' }
  if ($restored[0].items.Count -ne $tile.items.Count -or $restored[0].flags -ne $tile.flags -or $restored[0].houseId -ne $tile.houseId) { throw 'Returned tile data changed.' }
  for ($index=0; $index -lt $tile.items.Count; $index++) {
    $a=$tile.items[$index]; $b=$restored[0].items[$index]
    if ($a.serverId -ne $b.serverId -or $a.clientId -ne $b.clientId -or $a.otbmHex -cne $b.otbmHex) { throw 'Returned native item bytes or stack changed.' }
  }
}
Write-Output 'ALL TESTS PASSED'
