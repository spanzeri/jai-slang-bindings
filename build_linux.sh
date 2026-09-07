#!/bin/sh
# Builds Slang from src/slang into the per-platform directories a Jai module
# expects.  Each of them gets both flavours, because the compiler needs both:
# the .so is dlopened for #run / compile-time execution, the .a is what goes
# into the final executable so it stays a single file.
#
#   linux/            libslang-compiler.{so,a}, libslang-guard.{so,a}, and the
#                     two libraries Slang loads at runtime. Both flavours share
#                     the directory: Jai loads the .so to run Slang during #run
#                     and links the .a into the executable.
#   android/x64/      the same, for x86_64 and arm64-v8a
#   android/arm64/
#   include/          the public headers, for the binding generator
#
# Android is built as well whenever the NDK is found (ANDROID_NDK_HOME, or a
# versioned directory under $ANDROID_SDK_ROOT/ndk).
#
#   ./build_linux.sh                 # everything available
#   ./build_linux.sh linux           # host only
#   ./build_linux.sh android         # Android only (needs a host build first)
#   ./build_linux.sh clean

set -eu
cd "$(dirname "$0")"

SRC=src/slang
BUILD=build
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
ANDROID_API=${ANDROID_API:-31}

# libslang-glslang carries glslang and SPIRV-Tools.  It is the only part of the
# build with any mass left to cut: dropping it takes the build from 1:31 to
# 1:07 on 32 cores and 11MB off each platform directory.  The cost is that
# SPIR-V output then only works at SLANG_OPTIMIZATION_LEVEL_NONE, because
# anything above that runs spirv-opt through it.  GLSL output and `import glsl`
# are unaffected; Slang emits those itself.
WITH_GLSLANG=${WITH_GLSLANG:-1}

# Slang defaults to building a whole IDE's worth of things.  This cuts it to
# the compiler plus the two modules it loads at runtime.
#
#   SLANG_SLANG_LLVM_FLAVOR=DISABLE   otherwise CMake downloads a ~150MB
#       slang-llvm, which is only used to run shaders on the host CPU.
#   SLANG_ENABLE_DXIL=OFF             needs DXC, Windows-only.
#   SLANG_ENABLE_SLANGRT=OFF          libslang-rt is only pulled in by
#       slang-test, which is already off, and we do not ship it.
#   SLANG_STANDARD_MODULE_DEVELOP_BUILD=OFF  what Slang's own release build
#       does; drops the UNIT_TEST macro from the standard modules.
#   CMAKE_PLATFORM_NO_VERSIONED_SONAME  drops the .so.0.<version> suffix, so
#       there is one real file with a matching SONAME instead of a file plus
#       two symlinks.
COMMON="
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON
    -DSLANG_SLANG_LLVM_FLAVOR=DISABLE
    -DSLANG_ENABLE_GFX=OFF
    -DSLANG_ENABLE_SLANG_RHI=OFF
    -DSLANG_ENABLE_TESTS=OFF
    -DSLANG_ENABLE_EXAMPLES=OFF
    -DSLANG_ENABLE_SLANGD=OFF
    -DSLANG_ENABLE_SLANGI=OFF
    -DSLANG_ENABLE_REPLAYER=OFF
    -DSLANG_ENABLE_CUDA=OFF
    -DSLANG_ENABLE_OPTIX=OFF
    -DSLANG_ENABLE_AFTERMATH=OFF
    -DSLANG_ENABLE_NVAPI=OFF
    -DSLANG_ENABLE_DXIL=OFF
    -DSLANG_ENABLE_RELEASE_DEBUG_INFO=OFF
    -DSLANG_ENABLE_SPLIT_DEBUG_INFO=OFF
    -DSLANG_ENABLE_SLANGRT=OFF
    -DSLANG_STANDARD_MODULE_DEVELOP_BUILD=OFF
    -DSLANG_ENABLE_XLIB=OFF
"

if [ "$WITH_GLSLANG" = 1 ]; then
    COMMON="$COMMON -DSLANG_ENABLE_SLANG_GLSLANG=ON"
else
    COMMON="$COMMON -DSLANG_ENABLE_SLANG_GLSLANG=OFF"
fi

find_ndk() {
    if [ -n "${ANDROID_NDK_HOME-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
        echo "$ANDROID_NDK_HOME"; return
    fi
    if [ -n "${ANDROID_NDK_ROOT-}" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
        echo "$ANDROID_NDK_ROOT"; return
    fi
    for sdk in "${ANDROID_SDK_ROOT-}" "${ANDROID_HOME-}" "$HOME/Android/Sdk"; do
        [ -n "$sdk" ] || continue
        # Highest version wins.
        ndk=$(ls -d "$sdk"/ndk/*/ 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$ndk" ]; then echo "${ndk%/}"; return; fi
    done
    return 0
}

case "${1-all}" in
    clean)   rm -rf "$BUILD" linux android include; echo cleaned; exit 0 ;;
    linux)   DO_HOST=1; DO_ANDROID=0 ;;
    android) DO_HOST=0; DO_ANDROID=1 ;;
    all)     DO_HOST=1; DO_ANDROID=1 ;;
    *)       echo "usage: $0 [all|linux|android|clean]" >&2; exit 2 ;;
esac

[ -f "$SRC/CMakeLists.txt" ] || { echo "error: no Slang source in $SRC" >&2; exit 1; }
[ -f "$SRC/external/spirv-tools/CMakeLists.txt" ] || {
    echo "error: Slang submodules are not checked out; run" >&2
    echo "    git -C $SRC submodule update --init --recursive" >&2
    exit 1
}

# Merge a list of archives into one, so the Jai side is a single #library.
# CMake does not bundle transitive static dependencies, so a static Slang is
# half a dozen separate .a files.
merge_archives() {
    out=$1; shift
    for a in "$@"; do
        [ -f "$a" ] || { echo "error: missing archive $a" >&2; exit 1; }
    done
    rm -f "$out"
    {
        echo "create $out"
        for a in "$@"; do echo "addlib $a"; done
        echo save
        echo end
    } | ar -M
}

# Assemble one platform directory: $1 shared build, $2 static build,
# $3 output dir, rest folded into the archive on top of Slang's own.
collect() {
    shared=$1; static=$2; out=$3; shift 3
    rm -rf "$out"; mkdir -p "$out"

    # Kept under Slang's own name: the SONAME is embedded in the file, so a
    # renamed .so would record a DT_NEEDED that does not exist next to the
    # binary the moment anything links against it rather than dlopening it.
    cp "$shared/Release/lib/libslang-compiler.so" "$out/"
    # Slang dlopens these two by their exact versioned names
    # (source/compiler-core/slang-glslang-compiler.cpp), so they keep them.
    if [ "$WITH_GLSLANG" = 1 ]; then
        cp "$shared"/Release/lib/libslang-glslang-*.so "$out/"
    fi
    cp "$shared"/Release/lib/libslang-glsl-module-*.so "$out/"

    merge_archives "$out/libslang-compiler.a" \
        "$static/Release/lib/libslang-compiler.a" \
        "$static/Release/lib/libcompiler-core.a" \
        "$static/Release/lib/libcore.a" \
        "$static/external/miniz/libminiz.a" \
        "$static/external/lz4/build/cmake/liblz4.a" \
        "$static/external/cmark/src/libcmark-gfm.a" \
        "$@"

    # Both flavours share the directory: a plain #library links the archive
    # into the executable and loads the shared library for #run.
}

# slang-guard.cpp is the catch(...) barrier between Slang and Jai, and the only
# thing here compiled with exceptions on purpose.  Built in both flavours for
# the same reason Slang is: the .a goes into the executable, the .so is what the
# Jai compiler dlopens for #run.  $1 tags the object file, $2 is the platform
# directory, $3 the compiler, and anything after that is passed to both the
# compile and the link (the Android target triple).
build_guard() {
    tag=$1; out=$2; cxx=$3; shift 3

    obj=$BUILD/slang-guard-$tag.o
    "$cxx" -std=c++17 -O2 -fPIC -Iinclude "$@" -c slang-guard.cpp -o "$obj"

    rm -f "$out/libslang-guard.a"
    ar rcs "$out/libslang-guard.a" "$obj"

    # Without an explicit soname the linker records the path it was handed, and
    # the executable would then demand it at run time on the build machine.
    "$cxx" -shared "$@" -o "$out/libslang-guard.so" "$obj" \
        -Wl,-soname,libslang-guard.so \
        -L"$out" -l:libslang-compiler.so -Wl,-rpath,'$ORIGIN'
}

# ---------------------------------------------------------------- host

HOST_BUILD=$BUILD/linux-shared

if [ "$DO_HOST" = 1 ]; then
    for type in SHARED STATIC; do
        dir=$BUILD/linux-$(echo $type | tr A-Z a-z)
        cmake -S "$SRC" -B "$dir" -G Ninja $COMMON -DSLANG_LIB_TYPE=$type
        cmake --build "$dir" --parallel "$JOBS" --target all slang-glsl-module
    done

    # Slang is compiled with exceptions, so a static link needs an unwinder.
    # Jai's link line has no -lgcc_s, and there is no libgcc_s.so to point it
    # at on most distributions, only libgcc_s.so.1.  Folding libgcc_eh.a into
    # the archive keeps the Jai side to #library plus the system libraries.
    LIBGCC_EH=$(gcc -print-file-name=libgcc_eh.a 2>/dev/null || true)
    [ -f "$LIBGCC_EH" ] || { echo "error: libgcc_eh.a not found" >&2; exit 1; }

    collect "$BUILD/linux-shared" "$BUILD/linux-static" linux "$LIBGCC_EH"
    build_guard linux linux g++
fi

# ---------------------------------------------------------------- android

if [ "$DO_ANDROID" = 1 ]; then
    NDK=$(find_ndk || true)
    if [ -z "$NDK" ]; then
        echo "note: no Android NDK found, skipping Android"
    elif [ ! -d "$HOST_BUILD/generators" ]; then
        echo "error: Android is a cross build and needs the host generators;" >&2
        echo "       run '$0 linux' first" >&2
        exit 1
    else
        STRIP=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
        echo "using NDK $NDK (API $ANDROID_API)"

        # ANDROID_STL=c++_shared to match Jai's Android/Toolchain, which links
        # -lc++ (the shared runtime) and copies libc++_shared.so next to the
        # output whenever a module declares #library,system "libcpp".
        # The NDK toolchain file forces -g regardless of build type, hence the
        # explicit strip afterwards.
        for abi_pair in "arm64-v8a:arm64" "x86_64:x64"; do
            abi=${abi_pair%%:*}
            arch=${abi_pair##*:}
            for type in SHARED STATIC; do
                dir=$BUILD/android-$arch-$(echo $type | tr A-Z a-z)
                # CMAKE_POSITION_INDEPENDENT_CODE=ON: without it the static
                # archive carries absolute relocations in .text, which Android
                # cannot link into anything - it mandates PIE executables, and
                # shared libraries need PIC throughout. (Slang sets the
                # property on some targets itself, but not the static ones.)
                cmake -S "$SRC" -B "$dir" -G Ninja $COMMON \
                    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
                    -DANDROID_ABI="$abi" \
                    -DANDROID_PLATFORM="android-$ANDROID_API" \
                    -DANDROID_STL=c++_shared \
                    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                    -DSLANG_GENERATORS_PATH="$PWD/$HOST_BUILD/generators/Release/bin" \
                    -DSLANG_ENABLE_SLANGC=OFF \
                    -DSLANG_LIB_TYPE=$type
                cmake --build "$dir" --parallel "$JOBS" \
                    --target all slang-glsl-module
            done

            collect "$BUILD/android-$arch-shared" \
                    "$BUILD/android-$arch-static" "android/$arch"

            case $abi in
                arm64-v8a) machine=aarch64 ;;
                *)         machine=$abi ;;
            esac
            build_guard "android-$arch" "android/$arch" \
                "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++" \
                --target="$machine-linux-android$ANDROID_API"

            "$STRIP" --strip-debug "android/$arch"/*.so "android/$arch"/*.a
        done
    fi
fi

# ---------------------------------------------------------------- headers

if [ "$DO_HOST" = 1 ]; then
    rm -rf include; mkdir -p include
    cp "$SRC"/include/*.h include/
    cp "$BUILD/linux-shared/Release/include/slang-tag-version.h" include/
fi

# ---------------------------------------------------------------- smoke test

# Exercise both shipped flavours the way Jai does: link the archive into an
# executable, and dlopen the shared library the way the compiler does at
# compile time.
if [ "$DO_HOST" = 1 ]; then
    cat > "$BUILD/smoke.cpp" <<'CPP'
#include <slang.h>
#include <dlfcn.h>
#include <cstdio>
int main(int argc, char **argv) {
    slang::IGlobalSession *session = nullptr;
    if (SLANG_FAILED(slang_createGlobalSession(SLANG_API_VERSION, &session))) {
        printf("libslang-compiler.a: creating a global session failed\n");
        return 1;
    }
    printf("libslang-compiler.a: ok (%s)\n", spGetBuildTagString());

    void *handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) { printf("libslang-compiler.so: %s\n", dlerror()); return 1; }
    const char *(*tag)() = (const char *(*)())dlsym(handle, "spGetBuildTagString");
    if (!tag) { printf("libslang-compiler.so: %s\n", dlerror()); return 1; }
    printf("libslang-compiler.so: ok (%s)\n", tag());
    return 0;
}
CPP
    g++ -std=c++17 -Iinclude -DSLANG_STATIC -o "$BUILD/smoke" "$BUILD/smoke.cpp" \
        linux/libslang-compiler.a -ldl -lm -lpthread
    "$BUILD/smoke" "$PWD/linux/libslang-compiler.so"
fi

echo
for d in linux android/x64 android/arm64; do
    if [ -d "$d" ]; then echo "--- $d"; ls -l "$d"; fi
done
