#scope_export

// Each platform directory holds both flavours, because Jai needs both: it loads
// the shared library to run Slang during #run, and links the static one into the
// executable. A plain #library does that on its own - the archive goes into the
// final link, the shared library is what the compiler loads at compile time.

#if OS == .LINUX {
    LIBRARY_SUBDIRECTORY :: "linux";

    libslang :: #library "linux/libslang-compiler";
    libguard :: #library "linux/libslang-guard";

    // Only the static link needs these; the shared libraries bring their own.
    libstdcpp :: #library,system,link_always "libstdc++";
    libm      :: #library,system,link_always "libm";
} else #if OS == .ANDROID {
    #if CPU == .X64 {
        LIBRARY_SUBDIRECTORY :: "android/x64";
        libslang :: #library "android/x64/libslang-compiler";
        libguard :: #library "android/x64/libslang-guard";
    } else #if CPU == .ARM64 {
        LIBRARY_SUBDIRECTORY :: "android/arm64";
        libslang :: #library "android/arm64/libslang-compiler";
        libguard :: #library "android/arm64/libslang-guard";
    } else {
        #assert false "Slang on Android supports only x64 and arm64.";
    }

    // Jai's Android toolchain watches for "-lcpp": it links libc++ and copies
    // libc++_shared.so next to the output.
    libcpp :: #library,system,link_always "libcpp";
} else #if OS == .WINDOWS {
    // No import library sits next to the static archive, so the plain #library
    // below can only mean the static one; the DLLs alongside are what the
    // compiler loads for #run.
    #if CPU == .X64 {
        LIBRARY_SUBDIRECTORY :: "windows/x64";
        libslang :: #library "windows/x64/slang-compiler";
        libguard :: #library "windows/x64/slang-guard";
    } else {
        #assert false "Slang on Windows has only been set up for x64.";
    }

    // What a static Slang is expected to pull in beyond what Jai already
    // links. Trim it down to whatever the linker actually asks for.
    // Slang's own Windows Registry lookups (Visual Studio detection) and
    // file operations (Path::removeNonEmpty).
    libadvapi32 :: #library,system,link_always "advapi32";
    libshell32  :: #library,system,link_always "shell32";

    // The C++ standard library's static-CRT implementation (std::locale,
    // std::cout, ...), matching /MT on the static Slang build.
    libcpmt :: #library,system,link_always "libcpmt";
} else #if OS == .MACOS {
    #assert false "Slang on macOS is not set up yet. build_linux.sh is close to what it needs - a Darwin build, libc++ instead of libstdc++, and .dylib in place of .so.";
} else {
    #assert false "Slang has only been set up for Linux, Android and Windows.";
}

// One file for every target: generate.jai drops the platform detection out of
// slang.h, which is the only part of the output that differs between them.
#load "bindings.jai";

using slang;

#load "guard.jai";

// Slang loads these next to the running executable the first time it needs them.
// When they are missing it quietly emits unoptimised SPIR-V instead of failing,
// so call this from your build metaprogram after linking. Cross compiling, pass
// the target's directory rather than taking the default.
copy_runtime_libraries :: (to_directory: string, from_directory := LIBRARY_DIRECTORY) -> bool {
    ok := true;
    for file_list(from_directory) {
        _, _, _, filename := path_decomp(it);
        if !ends_with(filename, SHARED_LIBRARY_SUFFIX)  continue;
        if array_find(LINKED_INTO_THE_EXECUTABLE, filename)  continue;

        if !copy_file(it, tprint("%/%", to_directory, filename)) {
            log_error("Slang: could not copy % to %.", it, to_directory);
            ok = false;
        }
    }
    return ok;
}

LIBRARY_DIRECTORY :: #run sprint("%1%2", #filepath, LIBRARY_SUBDIRECTORY);

// Slang's own loadable modules are the only ones the executable still needs;
// the compiler and guard libraries are linked into it.
#if OS == .WINDOWS {
    SHARED_LIBRARY_SUFFIX      :: ".dll";
    LINKED_INTO_THE_EXECUTABLE :: string.["slang-compiler.dll", "slang-guard.dll"];
} else {
    SHARED_LIBRARY_SUFFIX      :: ".so";
    LINKED_INTO_THE_EXECUTABLE :: string.["libslang-compiler.so", "libslang-guard.so"];
}

#scope_module

#import "Basic";
#import "File_Utilities";
#import "String";
