# ---------------------------------------------------------------------------
# Experimental v2 tooling - not part of the published npm package.
#
# PowerShell port of run-dxc.sh, for running directly on native Windows
# (dxc.exe is a native PE binary - this is the platform it actually runs on;
# see ../README.md for why the bash/wine version can only get partway there
# on this repo's Linux dev sandbox).
#
# Fetches (via fetch-dxc.ps1, cached) and runs dxc against a fixture in
# experimental/hlsl, to see what dxc itself can tell us about a work graph's
# structure - a candidate replacement for this tool's current
# regex/paren-balance scan, especially around #define/#ifdef resolution and
# dead-code elimination the regex scanner can't do at all.
#
# Usage:
#   .\run-dxc.ps1 [-SourceFile <path>] [-Entry <name>...] [-TargetProfile <p>]
#                  [-Define <KEY=VAL>...] [-Mode preprocess|compile|both]
#                  [-OutDir <path>] [-- <extra dxc args...>]
#
# -Entry: for a lib_* profile, restricts the compiled library to these
#   exports only (dxc `-exports NAME[,NAME...]`); for a non-lib profile,
#   only the first value is used as the single entry point (`-E NAME`).
# -Define: preprocessor define(s), passed as `-D KEY=VAL`. Pass
#   `-Define ENABLE_MESH_PATH=1` to pull the mesh-launch fixture node in.
# -Mode:
#   preprocess: `dxc -P` - dumps the fully macro-/#if-resolved source, no
#     compilation. Shows exactly what dxc's preprocessor did with
#     -Define/#ifdef, nothing a regex scanner sees.
#   compile: full `-T <profile>` compile, emitting the compiled container
#     (-Fo) and its disassembly (-Fc) - the disassembly's metadata blocks
#     (!dx.entryPoints etc.) describe every compiled node's launch
#     mode/records/dispatch grid as dxc actually resolved them.
#   both (default): both of the above.
# -EmbedDebug: adds `-Zi -Qembed_debug` to the compile step, embedding the
#   original per-file pre-preprocessor source (comments, un-expanded macro
#   names, #if-0-dead code) into the compiled container, addressable via
#   !DISubprogram's (file, line) - see ../README.md. Only affects `compile`/
#   `both` mode; ignored for `preprocess`. Named -EmbedDebug rather than
#   -Debug because [CmdletBinding()] already reserves -Debug as a common
#   parameter. Output files get a `.debug.` infix when set, so debug and
#   non-debug compiles of the same source don't clobber each other.
#
# SourceFile defaults to experimental/hlsl/WorkGraph.hlsl.
# Anything after a literal `--` is passed through to dxc verbatim.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$SourceFile,
    [string[]]$Entry = @(),
    [string]$TargetProfile = 'lib_6_8',
    [string[]]$Define = @(),
    [ValidateSet('preprocess', 'compile', 'both')]
    [string]$Mode = 'both',
    [switch]$EmbedDebug,
    [string]$OutDir,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExperimentalDir = Split-Path -Parent $ScriptDir

if (-not $SourceFile) {
    $SourceFile = Join-Path $ExperimentalDir 'hlsl\WorkGraph.hlsl'
}
$SourceFile = (Resolve-Path $SourceFile).Path

if (-not $OutDir) {
    $OutDir = Join-Path $ExperimentalDir 'out'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# `--` (a literal double-dash) marks the start of dxc passthrough args;
# ValueFromRemainingArguments also captures it, so strip a leading one.
if ($ExtraArgs -and $ExtraArgs[0] -eq '--') {
    $ExtraArgs = $ExtraArgs[1..($ExtraArgs.Count - 1)]
}

$dxcDir = & (Join-Path $ScriptDir 'fetch-dxc.ps1') -HlslPath (Split-Path -Parent $SourceFile)
$dxcExe = Join-Path $dxcDir 'dxc.exe'
if (-not (Test-Path $dxcExe)) {
    throw "expected dxc.exe at $dxcExe after fetch-dxc.ps1 - see its output above"
}

$stem = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)

$defineArgs = @()
foreach ($d in $Define) { $defineArgs += @('-D', $d) }

$entryArgs = @()
if ($Entry.Count -gt 0) {
    if ($TargetProfile -like 'lib_*') {
        $entryArgs = @('-exports', ($Entry -join ','))
    } else {
        $entryArgs = @('-E', $Entry[0])
    }
}

$validatorArgs = @()
if (-not (Test-Path (Join-Path $dxcDir 'dxil.dll'))) {
    $validatorArgs = @('-Vd')
}

function Invoke-Dxc {
    param([string[]]$DxcArgs)
    Write-Host "+ dxc $($DxcArgs -join ' ')"
    & $dxcExe @DxcArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dxc exited with code $LASTEXITCODE"
    }
}

if ($Mode -eq 'preprocess' -or $Mode -eq 'both') {
    $preOut = Join-Path $OutDir "$stem.i.hlsl"
    Invoke-Dxc -DxcArgs (@('-P', '-Fi', $preOut) + $defineArgs + @($SourceFile) + $ExtraArgs)
    Write-Host "preprocessed source: $preOut"
}

if ($Mode -eq 'compile' -or $Mode -eq 'both') {
    $compileStem = if ($EmbedDebug) { "$stem.debug" } else { $stem }
    $debugArgs = @()
    if ($EmbedDebug) { $debugArgs = @('-Zi', '-Qembed_debug') }
    $dxilOut = Join-Path $OutDir "$compileStem.dxil"
    $asmOut = Join-Path $OutDir "$compileStem.dis.ll"
    Invoke-Dxc -DxcArgs (@('-T', $TargetProfile) + $entryArgs + $defineArgs + $debugArgs + $validatorArgs +
        @('-Fo', $dxilOut, '-Fc', $asmOut, $SourceFile) + $ExtraArgs)
    Write-Host "compiled container: $dxilOut"
    Write-Host "disassembly:        $asmOut"
}
