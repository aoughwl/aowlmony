# Stage the aowlmony compiler root: the layout the compiler driver expects
# beside itself, built from source into a fresh directory.
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
  'lengc'     = 'src\lengc\lengc.nim'
  'shoggoth'  = 'src\lengc\shoggoth\shoggoth.nim'
  'niflink'   = 'src\niflink\niflink.nim'
  'nj'        = 'src\njvl\nj.nim'
  'vl'        = 'src\njvl\vl.nim'
  'validator' = 'src\validator\validator.nim'
  'dagon'     = 'src\dagon\dagon.nim'
  'pnak'      = 'src\pnak\pnak.nim'
}
if ($Tools.Count -eq 0) { $Tools = @($all.Keys) + 'nifmake' }

foreach ($d in @($CompilerSrc, $NimBin, $CcBin)) { if (-not (Test-Path $d)) { throw "missing: $d" } }
if (-not (Test-Path $Hexer)) { throw "no aowlhexer at $Hexer" }
$bin = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$cache = Join-Path $env:TEMP 'aowlmony-stage-root'
$env:PATH = "$CcBin;$NimBin;" + $env:PATH

Push-Location $CompilerSrc
try {
  foreach ($t in $Tools) {
    if ($t -eq 'nifmake') { continue }   # built by aowlmony below
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

# nifmake: compiled from OUR source by the staged aowlmony driver. The driver
# itself runs a nifmake, so a root without one (a first stage) is bootstrapped
# with the inherited executor from -CompilerSrc, which the aowlmony one replaces
# right away. The new binary goes in under a temporary name and is renamed into
# place: other builds may be running the old one.
if ($Tools -contains 'nifmake') {
  $nm = Join-Path $bin 'nifmake.exe'
  if (-not (Test-Path $nm)) {
    Write-Output "bootstrapping nifmake"
    Push-Location $CompilerSrc
    try {
      & nim c --hints:off --warnings:off "--nimcache:$cache\nifmake-boot" "-o:$nm" 'src\nifmake\nifmake.nim'
      if ($LASTEXITCODE -ne 0) { throw "bootstrap nifmake failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
  }
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
}

$rev = (& git -C $CompilerSrc rev-parse --short HEAD)
$dirty = if (& git -C $CompilerSrc status --porcelain --untracked-files=no -- src) { '+dirty' } else { '' }
@(
  "compiler source: $CompilerSrc @ $rev$dirty"
  "lowering: $Hexer"
  "build executor: $(Join-Path $repo 'src\nifmake\nifmake.aowl') @ $(& git -C $repo rev-parse --short HEAD) (built by the staged aowlmony)"
  "lowering sha256: " + (Get-FileHash $Hexer -Algorithm SHA256).Hash.ToLower()
  "staged: " + (Get-Date -Format o)
) | Set-Content -Encoding utf8 (Join-Path $Root 'STAGED.txt')
Write-Output "aowlmony root at $Root"
