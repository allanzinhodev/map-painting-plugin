param(
  [string]$NexaRoot = 'C:\Users\Allan\backlands-workflow\mapeditor',
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -property installationPath
$msbuild = Join-Path $vsRoot 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild)) { throw 'MSBuild not found.' }
$stage = Join-Path $ProjectRoot 'build\nexamap'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($folder in @('source','icons','brushes')) {
  Copy-Item -LiteralPath (Join-Path $NexaRoot $folder) -Destination $stage -Recurse -Force
}
$projectDir = Join-Path $stage 'vcproj\Project'
New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $NexaRoot 'vcproj\Project') -File | Copy-Item -Destination $projectDir -Force
Copy-Item -LiteralPath (Join-Path $NexaRoot 'vcpkg.json') -Destination $stage -Force
$overlay = Join-Path $ProjectRoot 'bridge\nexamap'
foreach ($file in Get-ChildItem -LiteralPath $overlay -File -Recurse) {
  $relative = $file.FullName.Substring($overlay.Length + 1)
  if ($relative -like 'data\*') { continue }
  $destination = Join-Path $stage $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
}
$installed = Join-Path $NexaRoot 'vcpkg_installed\x64-windows\x64-windows\'
if (-not (Test-Path -LiteralPath (Join-Path $installed 'include\wx'))) { throw "Dependencies not found: $installed" }
$log = Join-Path $ProjectRoot 'build\nexamap-build.log'
& $msbuild (Join-Path $projectDir 'Editor.vcxproj') -m:2 -nologo -verbosity:minimal `
  -p:Configuration=Release -p:Platform=x64 -p:VcpkgManifestInstall=false `
  "-p:_ZVcpkgCurrentInstalledDir=$installed" `
  "-p:OutDir=$stage\bin\" "-p:SolutionDir=$stage\vcproj\" `
  "-fileLoggerParameters:LogFile=$log;Verbosity=normal"
if ($LASTEXITCODE -ne 0) { throw "NexaMap build failed; see $log" }
Write-Output (Join-Path $stage 'bin\NexaMap Editor.exe')
