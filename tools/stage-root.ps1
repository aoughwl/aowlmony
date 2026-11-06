# Stage the aowlmony compiler root: the layout the compiler driver expects
# beside itself, assembled from the aowlmony repos and a seed root.
#
#   <Root>\bin\aowlmony.exe      the driver (c / check / --app:lib / -p: / -d: ...)
#   <Root>\bin\nimsem.exe ...    the per-module tools it starts (parser, sem,
#                                build executor, C emitter, linker driver, ...)
#   <Root>\bin\hexer.exe         OUR lowering pass (aowlhexer), under the name
#                                the driver looks up
#   <Root>\bin\nifmake.exe       the build executor, OURS: src\nifmake\nifmake.aowl
#                                compiled by the staged aowlmony itself (it starts
#                                every step with CreateProcess, never cmd.exe, so
#                                a step's command line may reach 32,767 chars)
#   <Root>\lib                   standard library   (from rt\lib)
#   <Root>\vendor\mimalloc       allocator sources  (from rt\vendor)
#   <Root>\src                   compiler-internal library modules that std/macros
#                                and the Jester native host import (from the seed)
#   <Root>\nimcache_static       written by the driver at build time
#
# INPUTS
#   -Seed      a root that already holds the per-module compiler tools (bin\*.exe
#              other than hexer/nifmake) and the compiler-internal src tree.
#              Default: -Root itself, i.e. restaging in place keeps those tools.
#   -Hexer     the lowering pass, built from the aowlhexer repo
#              (aowlhexer\tools\selfbuild.sh), default aowlhexer\bin\aowlhexer.exe.
#   -CcBin     the C compiler directory (mingw-w64 ucrt) used to build nifmake.
#   The standard library and allocator come from this repo's rt\.
#
# Nothing here is a junction or symlink: every file is copied, so a cleanup of
# the root can never delete through into a checkout. Keep a backup of the old
# root outside it before restaging.
#
# USE
#   powershell -NoProfile -File tools\stage-root.ps1
#   powershell -NoProfile -File tools\stage-root.ps1 -Seed <old root> -Root <new root>

param(
  [string]$Root = (Join-Path (Split-Path $PSScriptRoot -Parent) 'root'),
  [string]$Seed = '',
  [string]$Hexer = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'aowlhexer\bin\aowlhexer.exe'),
  [string]$CcBin = 'C:\msys64\ucrt64\bin'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if ($Seed -eq '') { $Seed = $Root }
New-Item -ItemType Directory -Force $Root | Out-Null
$inPlace = ((Resolve-Path $Seed).Path.TrimEnd('\') -ieq (Resolve-Path $Root).Path.TrimEnd('\'))

# per-module tools carried from the seed
$seedTools = 'aowlmony', 'nimsem', 'nifler', 'lengc', 'shoggoth', 'niflink', 'nj', 'vl', 'validator', 'dagon', 'pnak'

foreach ($d in @($Seed, $CcBin)) { if (-not (Test-Path $d)) { throw "missing: $d" } }
if (-not (Test-Path $Hexer)) { throw "no aowlhexer at $Hexer" }
foreach ($t in $seedTools) { if (-not (Test-Path (Join-Path $Seed "bin\$t.exe"))) { throw "seed has no bin\$t.exe" } }
if (-not (Test-Path (Join-Path $Seed 'src'))) { throw "seed has no src" }
$bin = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$cache = Join-Path $env:TEMP 'aowlmony-stage-root'
$env:PATH = "$CcBin;" + $env:PATH

function Mirror($from, $to, [string[]]$excludeFiles = @(), [string[]]$excludeDirs = @()) {
  $a = @($from, $to, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XJ')
  if ($excludeFiles.Count) { $a += '/XF'; $a += $excludeFiles }
  if ($excludeDirs.Count) { $a += '/XD'; $a += $excludeDirs }
  & robocopy @a | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy $from -> $to failed ($LASTEXITCODE)" }
}

if (-not $inPlace) {
  foreach ($t in $seedTools) { Copy-Item (Join-Path $Seed "bin\$t.exe") (Join-Path $bin "$t.exe") -Force }
  if (Test-Path (Join-Path $Seed 'bin\nifmake.exe')) { Copy-Item (Join-Path $Seed 'bin\nifmake.exe') (Join-Path $bin 'nifmake.exe') -Force }
  Mirror (Join-Path $Seed 'src') (Join-Path $Root 'src') @('*.exe', '*.o', '*.obj') @('nimcache', '.git')
}

Copy-Item $Hexer (Join-Path $bin 'hexer.exe') -Force
Mirror (Join-Path $repo 'rt\lib') (Join-Path $Root 'lib')
Mirror (Join-Path $repo 'rt\vendor') (Join-Path $Root 'vendor')
$global:LASTEXITCODE = 0

# nifmake: compiled from OUR source by the staged aowlmony driver. The new
# binary goes in under a temporary name and is renamed into place: other
# builds may be running the old one.
$nm = Join-Path $bin 'nifmake.exe'
if (-not (Test-Path $nm)) { throw "no bin\nifmake.exe in the seed to start the first build with" }
Write-Output "building nifmake (aowlmony)"
$nmCache = Join-Path $cache 'nifmake-aowl'
if (Test-Path $nmCache) { Remove-Item -Recurse -Force $nmCache }   # a reused cache hands back a stale exe
& (Join-Path $bin 'aowlmony.exe') c -d:virtualParRi "-p:$(Join-Path $Root 'src')" "--nimcache:$nmCache" "-o:$nm.new" (Join-Path $repo 'src\nifmake\nifmake.aowl')
if ($LASTEXITCODE -ne 0) { throw "aowlmony build of nifmake failed ($LASTEXITCODE)" }
$prev = 'nifmake.prev.exe'
try { if (Test-Path (Join-Path $bin $prev)) { Remove-Item -Force (Join-Path $bin $prev) } }
catch { $prev = 'nifmake.prev-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.exe' }   # still running
Rename-Item $nm $prev
Rename-Item "$nm.new" 'nifmake.exe'
$global:LASTEXITCODE = 0

$hexerRev = (& git -C (Split-Path (Split-Path $Hexer -Parent) -Parent) rev-parse --short HEAD)
$repoRev = (& git -C $repo rev-parse --short HEAD)
@(
  "seed: $Seed (per-module tools and compiler-internal src)"
  "lowering: $Hexer (aowlhexer repo @ $hexerRev)"
  "lowering sha256: " + (Get-FileHash $Hexer -Algorithm SHA256).Hash.ToLower()
  "library: $(Join-Path $repo 'rt') @ $repoRev"
  "build executor: $(Join-Path $repo 'src\nifmake\nifmake.aowl') @ $repoRev (built by the staged aowlmony)"
  "staged: " + (Get-Date -Format o)
) | Set-Content -Encoding utf8 (Join-Path $Root 'STAGED.txt')
Write-Output "aowlmony root at $Root"
