# Building the engine of the live demo into WebAssembly: nshwasm.wasm out of the
# REAL nsh_surface.pas and the real formula parser.
#
# A wasm32-wasip1 cross compiler (ppcrosswasm32) is needed. FPC gained one in
# 3.3.1, while the library itself is built with 3.2.2 - and that difference is
# stated plainly on the page rather than hidden.
$ErrorActionPreference = 'Stop'

# The custom sections come off before the module goes out. The compiler leaves
# a "name" section behind - half a megabyte of debugger names, and inside it the
# full path the module was built at, which anyone who downloads the module can
# read. It takes no part in execution. Stripping it here rather than by hand
# means the next build cannot put the path back.
function Remove-WasmCustomSections([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 8 -or $b[0] -ne 0 -or $b[1] -ne 0x61 -or $b[2] -ne 0x73 -or $b[3] -ne 0x6D) {
        throw "$Path is not a WebAssembly module"
    }
    $ms = New-Object System.IO.MemoryStream
    $ms.Write($b, 0, 8)
    $i = 8
    $dropped = 0
    while ($i -lt $b.Length) {
        $start = $i
        $id = $b[$i]; $i++
        $size = 0; $shift = 0
        while ($true) {
            $x = $b[$i]; $i++
            $size = $size -bor (($x -band 0x7F) -shl $shift)
            $shift += 7
            if (($x -band 0x80) -eq 0) { break }
        }
        $end = $i + $size
        if ($id -ne 0) { $ms.Write($b, $start, $end - $start) } else { $dropped += $size }
        $i = $end
    }
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $ms.Dispose()
    return $dropped
}


$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Live = Split-Path -Parent $Here

# Where to take the sources from. Both directories are given explicitly: a guess
# about where the subject of a build lies once cost a false conclusion on the
# gates of the parser - a neighbour was being built while the report spoke about
# the published tree.
$Core = if ($env:NASHIRA3D_SRC) { $env:NASHIRA3D_SRC } else { Join-Path $Live '..\nashira3d' }
if (-not (Test-Path (Join-Path $Core 'core\nsh_surface.pas'))) {
    throw "core/nsh_surface.pas was not found in $Core - set NASHIRA3D_SRC"
}
$Core = (Resolve-Path $Core).Path
$Parser = Join-Path $Core 'thirdparty\pascal-mathparser'
if (-not (Test-Path (Join-Path $Parser 'src'))) {
    throw "the parser was not found: $Parser"
}

$Fpc = if ($env:FPC_WASM) { $env:FPC_WASM } else { 'fpc.exe' }
$Out = Join-Path $Here 'out'
$Www = Join-Path $Live 'demo'
New-Item -ItemType Directory -Force $Out, $Www | Out-Null
Remove-Item "$Out/*" -Recurse -Force -ErrorAction SilentlyContinue

# The finished module is removed BEFORE the build. Otherwise the check at the
# end passes over somebody else's file: the compiler fell over, the module from
# last time is still in place, and the script says "ready". The same order as in
# the build of the core.
$Wasm = Join-Path $Www 'nshwasm.wasm'
if (Test-Path $Wasm) { Remove-Item $Wasm -Force }

# The decoder of the jit is on the path, and nothing else from that directory
# is meant to arrive with it. It generates no machine code: it takes the byte
# code the parser produces and reads it back as plain steps, which nsh_fasteval
# turns into a short program over a stack of doubles - the part machine code
# plays where there is no machine code to be had.
# Keeping the whole directory off the path used to be the guard, and it was a
# guard by hope: nothing arrived while nobody referred to it. The check after
# the build replaces it with a fact.
# NOFORMS/NOGRAPHICS are the same headless definitions the Linux build uses:
# without them Thread.pas drags in Forms, which wasm has not got and does not
# need. NSH_NO_JIT switches nsh_surface over to the interpreter: there is no
# machine code in WebAssembly, and ParseJit does not build for it by design. The
# jit directory is absent from the path ON PURPOSE - so that it cannot be pulled
# in silently through somebody else's reference, and a refusal arrives at once
# and on the merits.
& $Fpc -Pwasm32 -Twasip1 -Mdelphi -O2 -Sh -Xs -vw- `
    -dNOFORMS -dNOGRAPHICS -dNSH_NO_JIT `
    ("-Fu$Here") ("-Fu$Core/core") `
    ("-Fu$Parser/src") ("-Fu$Parser/src/compat") ("-Fu$Parser/jit") `
    ("-Fi$Parser/src") `
    ("-FU$Out") ("-FE$Out") `
    (Join-Path $Here 'nshwasm.pas')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# WHAT CAME IN FROM THE JIT, checked rather than assumed. Only the decoder is
# wanted; the emitter of machine code, its executable memory and its parser have
# no business in a module for a browser, and a reference added by accident would
# bring them in without a word. The compiler leaves a unit file for everything it
# built, so the answer is on disk.
$Forbidden = @('parsejit.memory', 'parsejit.codegen', 'parsejit.executor',
               'parsejit.parser')
$Built = Get-ChildItem $Out -File -ErrorAction SilentlyContinue |
         ForEach-Object { $_.BaseName.ToLower() }
$Sneaked = $Built | Where-Object { $Forbidden -contains $_ } | Sort-Object -Unique
if ($Sneaked) {
    throw ("the machine code side of the jit reached the browser build: " +
           ($Sneaked -join ', '))
}
if (-not ($Built -contains 'parsejit.decoder')) {
    throw "the decoder did not build - nsh_fasteval cannot have been compiled"
}

# The name of the finished module depends on the version of the compiler: some
# put it out without an extension, others already with .wasm. Guessing will not
# do - whichever exists is taken, and if neither does the refusal arrives at
# once and by name.
$Built = @((Join-Path $Out 'nshwasm.wasm'), (Join-Path $Out 'nshwasm')) |
         Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Built) { throw "the build said nothing, but there is no module in $Out" }
Copy-Item $Built $Wasm -Force
$Dropped = Remove-WasmCustomSections $Wasm
$Size = [math]::Round((Get-Item $Wasm).Length / 1KB)
Write-Output "nshwasm.wasm is ready, $Size KB (custom sections stripped: $Dropped bytes)"
