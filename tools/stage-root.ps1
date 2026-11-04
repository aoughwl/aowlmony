# Stage the aowlmony compiler root: the layout the compiler driver expects
# beside itself, built from source into a fresh directory.
#
#   <Root>\bin\aowlmony.exe      the driver (c / check / --app:lib / -p: / -d: ...)
#   <Root>\bin\nimsem.exe ...    the per-module tools it starts (parser, sem,
#                                build executor, C emitter, linker driver, ...)
#   <Root>\bin\hexer.exe         OUR lowering pass (aowlhexer), under the name
#                                the driver looks up
#   <Root>\lib                   standard library   (from rt\lib)
#   <Root>\vendor\mimalloc       allocator sources  (from rt\vendor)
#   <Root>\src                   compiler-internal library modules that std/macros
#                                and the Jester native host import (from -CompilerSrc)
#   <Root>\nimcache_static       written by the driver at build time
#
# Nothing here is a junction or symlink: every file is copied, so a cleanup of
# the root can never delete through into a checkout.
#
# USE
#   powershell -NoProfile -File tools\stage-root.ps1               # build everything
#   powershell -NoProfile -File tools\stage-root.ps1 -Tools aowlmony,nimsem
#
# The compiler sources are the toolchain fork checkout (-CompilerSrc, default the
# sibling `nimony` directory); they are compiled with the bootstrap compiler
# found under ~\.choosenim (-NimBin). Builds are debug builds, matching the
# binaries the Jester tools have been using, unless -Release is passed.

param(
  [string]$Root = (Join-Path (Split-Path $PSScriptRoot -Parent) 'root'),
  [string]$CompilerSrc = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'nimony'),
  [string]$Hexer = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'aowlhexer\bin\aowlhexer.exe'),
  [string]$NimBin = (Join-Path $env:USERPROFILE '.choosenim\toolchains\nim-2.2.2\bin'),
  [string]$CcBin = 'C:\msys64\ucrt64\bin',
  [string[]]$Tools = @(),
  [switch]$Release
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

# name in <Root>\bin  ->  source module (relative to -CompilerSrc)
$all = [ordered]@{
  'aowlmony'  = 'src\nimony\nimony.nim'
  'nimsem'    = 'src\nimony\nimsem.nim'
  'nifler'    = 'src\nifler\nifler.nim'
  'nifmake'   = 'src\nifmake\nifmake.nim'
  'lengc'     = 'src\lengc\lengc.nim'
  'shoggoth'  = 'src\lengc\shoggoth\shoggoth.nim'
  'niflink'   = 'src\niflink\niflink.nim'
  'nj'        = 'src\njvl\nj.nim'
  'vl'        = 'src\njvl\vl.nim'
  'validator' = 'src\validator\validator.nim'
  'dagon'     = 'src\dagon\dagon.nim'
  'pnak'      = 'src\pnak\pnak.nim'
}
if ($Tools.Count -eq 0) { $Tools = @($all.Keys) }

foreach ($d in @($CompilerSrc, $NimBin, $CcBin)) { if (-not (Test-Path $d)) { throw "missing: $d" } }
if (-not (Test-Path $Hexer)) { throw "no aowlhexer at $Hexer" }
$bin = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$cache = Join-Path $env:TEMP 'aowlmony-stage-root'
$env:PATH = "$CcBin;$NimBin;" + $env:PATH

Push-Location $CompilerSrc
try {
  foreach ($t in $Tools) {
    if (-not $all.Contains($t)) { throw "unknown tool: $t" }
    $out = Join-Path $bin "$t.exe"
    $nimArgs = @('c')
    if ($Release) { $nimArgs += '-d:release' }
    $nimArgs += @('--warningAsError:ProveInit:off', '--warningAsError:Uninit:off', '--hints:off', '--warnings:off',
               "--nimcache:$cache\$t", "-o:$out", $all[$t])
    Write-Output "building $t"
    & nim @nimArgs
    if ($LASTEXITCODE -ne 0) { throw "build of $t failed ($LASTEXITCODE)" }
  }
} finally { Pop-Location }

Copy-Item $Hexer (Join-Path $bin 'hexer.exe') -Force

function Mirror($from, $to, [string[]]$excludeFiles = @(), [string[]]$excludeDirs = @()) {
  $a = @($from, $to, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XJ')
  if ($excludeFiles.Count) { $a += '/XF'; $a += $excludeFiles }
  if ($excludeDirs.Count) { $a += '/XD'; $a += $excludeDirs }
  & robocopy @a | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy $from -> $to failed ($LASTEXITCODE)" }
}
Mirror (Join-Path $repo 'rt\lib') (Join-Path $Root 'lib')
Mirror (Join-Path $repo 'rt\vendor') (Join-Path $Root 'vendor')
Mirror (Join-Path $CompilerSrc 'src') (Join-Path $Root 'src') @('*.exe', '*.o', '*.obj') @('nimcache', '.git')
$global:LASTEXITCODE = 0

$rev = (& git -C $CompilerSrc rev-parse --short HEAD)
$dirty = if (& git -C $CompilerSrc status --porcelain --untracked-files=no -- src) { '+dirty' } else { '' }
@(
  "compiler source: $CompilerSrc @ $rev$dirty"
  "lowering: $Hexer"
  "lowering sha256: " + (Get-FileHash $Hexer -Algorithm SHA256).Hash.ToLower()
  "staged: " + (Get-Date -Format o)
) | Set-Content -Encoding utf8 (Join-Path $Root 'STAGED.txt')
Write-Output "aowlmony root at $Root"
