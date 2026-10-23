param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$AssetsDirectory = 'C:\Users\Allan\backlands-workflow\client\data\things\860',
  [string]$AsepriteProfile = (Join-Path $env:APPDATA 'Aseprite')
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $ProjectRoot 'extension'
$manifest = Get-Content -LiteralPath (Join-Path $source 'package.json') -Raw | ConvertFrom-Json
if ($manifest.name -ne 'tibia-workbench') { throw 'Unexpected extension name.' }
foreach ($name in @('Tibia.dat','Tibia.spr','Tibia.otfi')) {
  if (-not (Test-Path -LiteralPath (Join-Path $AssetsDirectory $name))) { throw "Missing asset: $name" }
}
$runtime = Join-Path $ProjectRoot 'runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$defaults = @{ assetsDirectory = $AssetsDirectory; bridgeDirectory = $runtime } | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $source 'defaults.json'), $defaults, (New-Object Text.UTF8Encoding($false)))
$destination = Join-Path $AsepriteProfile 'extensions\tibia-workbench'
if (Test-Path -LiteralPath $destination) {
  $backupRoot = Join-Path $ProjectRoot 'backups'
  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
  Copy-Item -LiteralPath $destination -Destination (Join-Path $backupRoot ('extension-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Recurse
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Get-ChildItem -LiteralPath $source | Copy-Item -Destination $destination -Recurse -Force
& (Join-Path $PSScriptRoot 'Package.ps1') -ProjectRoot $ProjectRoot
Write-Output "Installed: $destination"
