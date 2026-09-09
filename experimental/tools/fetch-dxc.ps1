# ---------------------------------------------------------------------------
# Experimental v2 tooling - not part of the published npm package.
#
# PowerShell port of fetch-dxc.sh, for running directly on native Windows
# (where dxc.exe actually runs, unlike this repo's Linux/WSL dev sandbox -
# see ../README.md for why the bash version can only get partway there
# there).
#
# Downloads the right Microsoft.Direct3D.DXC build from nuget.org and
# extracts win-x64 dxc.exe + dxcompiler.dll (+ dxil.dll, when the package
# ships one) into experimental/tools/dxc/<version>/x64/.
#
# Version selection: if any *.hlsl/*.hlsli file under the given path(s)
# contains the raw text `NodeLaunch("mesh")`, pin to
# 1.8.2404.55-mesh-nodes-preview (the only dxc build able to compile a
# mesh-launch node so far). Otherwise fetch whatever nuget.org currently
# reports as the latest stable (non-prerelease) release. This is a plain
# text scan, deliberately not preprocessor-aware - see ../README.md.
#
# Usage: .\fetch-dxc.ps1 [-HlslPath <path...>]
#   -HlslPath defaults to experimental/hlsl (this repo's fixtures).
#
# Writes the resulting dxc directory path to stdout, so it composes as:
#   $dxcDir = .\fetch-dxc.ps1
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string[]]$HlslPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is much faster without the progress UI

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExperimentalDir = Split-Path -Parent $ScriptDir
$CacheRoot = Join-Path $ExperimentalDir 'tools\dxc'

$PackageIdLower = 'microsoft.direct3d.dxc'
$MeshPreviewVersion = '1.8.2404.55-mesh-nodes-preview'

if (-not $HlslPath -or $HlslPath.Count -eq 0) {
    $HlslPath = @(Join-Path $ExperimentalDir 'hlsl')
}

Write-Host "Scanning for mesh-launch nodes under: $($HlslPath -join ', ')"
$meshFiles = Get-ChildItem -Path $HlslPath -Recurse -Include '*.hlsl', '*.hlsli' -File -ErrorAction SilentlyContinue |
    Select-String -Pattern 'NodeLaunch\s*\(\s*"mesh"' -List

if ($meshFiles) {
    $meshFiles | ForEach-Object { Write-Host $_.Path }
    Write-Host "-> found a mesh-launch node, pinning to $MeshPreviewVersion"
    $version = $MeshPreviewVersion
} else {
    Write-Host '-> no mesh-launch node found, resolving latest stable release from nuget.org'
    $searchUrl = 'https://azuresearch-usnc.nuget.org/query?q=packageid:Microsoft.Direct3D.DXC&prerelease=false'
    $result = Invoke-RestMethod -Uri $searchUrl
    $version = $result.data[0].version
    Write-Host "-> latest stable release is $version"
}

$outDir = Join-Path $CacheRoot "$version\x64"
$dxcExe = Join-Path $outDir 'dxc.exe'

if (Test-Path $dxcExe) {
    Write-Host "already fetched: $outDir"
    Write-Output $outDir
    return
}

$nupkgUrl = "https://api.nuget.org/v3-flatcontainer/$PackageIdLower/$version/$PackageIdLower.$version.nupkg"
$versionDir = Join-Path $CacheRoot $version
New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
$nupkgPath = Join-Path $versionDir "$PackageIdLower.$version.nupkg"
# Expand-Archive requires a .zip extension regardless of actual content.
$zipPath = Join-Path $versionDir "$PackageIdLower.$version.zip"

Write-Host "downloading $nupkgUrl"
Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgPath

Write-Host 'extracting win-x64 binaries'
Copy-Item $nupkgPath $zipPath -Force
$extractDir = Join-Path $versionDir 'extracted'
Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$binDir = Join-Path $extractDir 'build\native\bin\x64'
Copy-Item (Join-Path $binDir 'dxc.exe') $outDir -Force
Copy-Item (Join-Path $binDir 'dxcompiler.dll') $outDir -Force

$dxilSrc = Join-Path $binDir 'dxil.dll'
if (Test-Path $dxilSrc) {
    Copy-Item $dxilSrc $outDir -Force
    Write-Host 'extracted dxil.dll (validator available)'
} else {
    Write-Host 'no dxil.dll in this package (fine - run-dxc.ps1 will pass -Vd)'
}

Remove-Item $nupkgPath, $zipPath -Force
Remove-Item $extractDir -Recurse -Force

Write-Host "fetched: $outDir"
Write-Output $outDir
