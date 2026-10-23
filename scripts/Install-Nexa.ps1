param(
  [string]$NexaRoot = 'C:\Users\Allan\backlands-workflow\mapeditor',
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$binary = Join-Path $ProjectRoot 'build\nexamap\bin\NexaMap Editor.exe'
if (-not (Test-Path -LiteralPath $binary)) { throw 'Build NexaMap first.' }
if (Get-Process -Name 'NexaMap Editor' -ErrorAction SilentlyContinue) { throw 'Close NexaMap before installing the bridge.' }
$menu = Join-Path $NexaRoot 'data\menubar.xml'
$originalMenu = Join-Path $ProjectRoot 'bridge\original\data\menubar.xml'
if ((Get-FileHash -LiteralPath $menu).Hash -ne (Get-FileHash -LiteralPath $originalMenu).Hash) {
  $installedMenu = Join-Path $ProjectRoot 'bridge\nexamap\data\menubar.xml'
  if ((Get-FileHash -LiteralPath $menu).Hash -ne (Get-FileHash -LiteralPath $installedMenu).Hash) {
    throw 'NexaMap menu changed since preparation. Review and merge before installing.'
  }
}
$backup = Join-Path $ProjectRoot ('backups\nexamap-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($name in @('NexaMap Editor.exe','NexaMap Editor.pdb')) {
  $path = Join-Path $NexaRoot $name
  if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup }
}
Copy-Item -LiteralPath $menu -Destination (Join-Path $backup 'menubar.xml')
# Staging next to the destination keeps binary replacement within one volume.
$target = Join-Path $NexaRoot 'NexaMap Editor.exe'
$stage = Join-Path $NexaRoot 'NexaMap Editor.exe.tibia-new'
Copy-Item -LiteralPath $binary -Destination $stage -Force
try {
  Copy-Item -LiteralPath (Join-Path $ProjectRoot 'bridge\nexamap\data\menubar.xml') -Destination $menu -Force
  Move-Item -LiteralPath $stage -Destination $target -Force
  Copy-Item -LiteralPath (Join-Path $ProjectRoot 'build\nexamap\bin\NexaMap Editor.pdb') -Destination $NexaRoot -Force
} catch {
  Copy-Item -LiteralPath (Join-Path $backup 'menubar.xml') -Destination $menu -Force
  Copy-Item -LiteralPath (Join-Path $backup 'NexaMap Editor.exe') -Destination $target -Force
  throw
}
Write-Output "Installed NexaMap bridge: $target"
Write-Output "Backup: $backup"
