param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$source = Join-Path $ProjectRoot 'extension'
$manifest = Get-Content -LiteralPath (Join-Path $source 'package.json') -Raw | ConvertFrom-Json
$dist = Join-Path $ProjectRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$target = Join-Path $dist ($manifest.name + '-' + $manifest.version + '.aseprite-extension')
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
[System.IO.Compression.ZipFile]::CreateFromDirectory($source, $target)
Write-Output $target
