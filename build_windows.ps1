# Builds Slang from src/slang into the per-platform directory a Jai module
# expects.  The Windows counterpart of build_linux.sh; see that script for the
# reasoning behind the CMake options, which are the same.
#
#   windows/x64/          slang-compiler.lib and slang-guard.lib (static), the
#                           matching DLLs for #run, and the DLLs Slang loads
#   include/              the public headers, for the binding generator
#
#   .\build_windows.ps1           # build
#   .\build_windows.ps1 clean
#
# Run it from a Visual Studio Developer PowerShell, so cl, lib, link and the
# Windows SDK are on PATH.  cmake and ninja are also required.
#
# The paths below are translated from the Linux script rather than observed, so
# expect to correct a couple of them.

param([string]$Command = "all")

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$Src   = "src\slang"
$Build = "build"
$Out   = "windows\x64"

# libslang-glslang carries glslang and SPIRV-Tools.  Without it SPIR-V output
# only works at SLANG_OPTIMIZATION_LEVEL_NONE, because anything above runs
# spirv-opt through it.
$WithGlslang = if ($env:WITH_GLSLANG) { $env:WITH_GLSLANG -ne "0" } else { $true }

# SLANG_ENABLE_SLANG_PROXY=OFF skips the legacy slang.dll, which exists only to
# forward every export to slang-compiler.dll.  Nothing here loads it.
$Common = @(
    "-DCMAKE_BUILD_TYPE=Release"
    "-DSLANG_SLANG_LLVM_FLAVOR=DISABLE"
    "-DSLANG_ENABLE_SLANG_PROXY=OFF"
    "-DSLANG_ENABLE_GFX=OFF"
    "-DSLANG_ENABLE_SLANG_RHI=OFF"
    "-DSLANG_ENABLE_TESTS=OFF"
    "-DSLANG_ENABLE_EXAMPLES=OFF"
    "-DSLANG_ENABLE_SLANGD=OFF"
    "-DSLANG_ENABLE_SLANGI=OFF"
    "-DSLANG_ENABLE_REPLAYER=OFF"
    "-DSLANG_ENABLE_CUDA=OFF"
    "-DSLANG_ENABLE_OPTIX=OFF"
    "-DSLANG_ENABLE_AFTERMATH=OFF"
    "-DSLANG_ENABLE_NVAPI=OFF"
    "-DSLANG_ENABLE_DXIL=OFF"
    "-DSLANG_ENABLE_RELEASE_DEBUG_INFO=OFF"
    "-DSLANG_ENABLE_SPLIT_DEBUG_INFO=OFF"
    "-DSLANG_ENABLE_SLANGRT=OFF"
    "-DSLANG_STANDARD_MODULE_DEVELOP_BUILD=OFF"
    "-DSLANG_ENABLE_SLANG_GLSLANG=$(if ($WithGlslang) { 'ON' } else { 'OFF' })"
)

function Invoke-Checked {
    $exe  = $args[0]
    $rest = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }
    & $exe @rest
    if ($LASTEXITCODE -ne 0) { throw "$exe failed with exit code $LASTEXITCODE" }
}

# CMake scatters its outputs, and the exact subdirectory differs per dependency,
# so search rather than hard-code.  Exactly one match or it is an error worth
# seeing immediately.
function Find-One {
    param([string]$Root, [string]$Name)
    $hits = @(Get-ChildItem -Path $Root -Recurse -Filter $Name -File -ErrorAction SilentlyContinue)
    if ($hits.Count -ne 1) {
        throw "expected exactly one $Name under $Root, found $($hits.Count)$(if ($hits) { ': ' + ($hits.FullName -join ', ') })"
    }
    return $hits[0].FullName
}

if ($Command -eq "clean") {
    Remove-Item -Recurse -Force $Build, $Out -ErrorAction SilentlyContinue
    Write-Host "cleaned"
    exit 0
}

foreach ($tool in "cmake", "ninja", "cl", "lib", "link") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not on PATH - run this from a Visual Studio Developer PowerShell"
    }
}

# ---------------------------------------------------------------- slang

foreach ($type in "SHARED", "STATIC") {
    $dir = "$Build\windows-$($type.ToLower())"
    $runtime = @()
    if ($type -eq "STATIC") {
        # Jai's link line uses the static CRT (libcmt/vcruntime/ucrt). CMake's
        # default is the DLL CRT (/MD), which would leave this static Slang
        # expecting msvcprt.dll and fail the final link with unresolved
        # __imp_ symbols. The shared build keeps the default; its DLL carries
        # its own CRT.
        $runtime = @("-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded")
    }
    Invoke-Checked cmake -S $Src -B $dir -G Ninja @Common @runtime "-DSLANG_LIB_TYPE=$type"
    Invoke-Checked cmake --build $dir --target all slang-glsl-module
}

$shared = "$Build\windows-shared"
$static = "$Build\windows-static"

$runtimeDlls = @("slang-glsl-module.dll")
if ($WithGlslang) { $runtimeDlls += "slang-glslang.dll" }

# Both flavours share the directory: the .lib files go into the executable,
# the DLLs are what the Jai compiler loads for #run. No import library is kept
# next to the static archive, so a plain #library can only mean the static one.
Copy-Item (Find-One $shared "slang-compiler.dll") "$Out\"
foreach ($dll in $runtimeDlls) { Copy-Item (Find-One $shared $dll) "$Out\" }

# CMake does not bundle transitive static dependencies, so the static Slang is
# several libraries that have to be merged into one.
$parts = @("slang-compiler", "compiler-core", "core", "miniz", "lz4", "cmark-gfm") |
    ForEach-Object { Find-One $static "$_.lib" }
Invoke-Checked lib /nologo "/OUT:$Out\slang-compiler.lib" @parts

# ---------------------------------------------------------------- guard

# slang-guard.cpp is the catch(...) barrier between Slang and Jai, and the only
# thing here compiled with exceptions on purpose.  Built in both flavours for
# the same reason Slang is: the .lib goes into the executable, the DLL is what
# the Jai compiler loads for #run.
$guardStatic = "$Build\slang-guard.obj"
$guardShared = "$Build\slang-guard-dll.obj"

# /MT to match the static Slang lib and Jai's own static-CRT link line (see
# the CMAKE_MSVC_RUNTIME_LIBRARY note above); the DLL build below stays /MD.
Invoke-Checked cl /nologo /std:c++17 /O2 /EHsc /MT /I include /c slang-guard.cpp "/Fo$guardStatic"
Invoke-Checked lib /nologo "/OUT:$Out\slang-guard.lib" $guardStatic

# The guard DLL links against the shared build's import library straight out of
# the build tree; the import library itself is not shipped. Its /IMPLIB goes to
# the build directory so it cannot collide with the static slang-guard.lib.
Invoke-Checked cl /nologo /std:c++17 /O2 /EHsc /MD /DSLANG_GUARD_EXPORTS /I include /c slang-guard.cpp "/Fo$guardShared"
Invoke-Checked link /nologo /DLL "/OUT:$Out\slang-guard.dll" "/IMPLIB:$Build\slang-guard-dll.lib" `
    $guardShared (Find-One $shared "slang-compiler.lib")

# ---------------------------------------------------------------- headers

Remove-Item -Recurse -Force include -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path include | Out-Null
Copy-Item "$Src\include\*.h" include\
# Not Find-One: the build tree also holds the generator's own source-tree copy
# (source\slang\slang-version-header\slang-tag-version.h), so a recursive search
# is ambiguous. The Release output path is as fixed as the rest of this layout.
Copy-Item "$shared\Release\include\slang-tag-version.h" include\

Write-Host ""
Write-Host "built into $Out"
Get-ChildItem $Out -File | ForEach-Object { "  {0,-28} {1,10:N0}" -f $_.Name, $_.Length }
