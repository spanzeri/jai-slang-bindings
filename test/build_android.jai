// Builds the test for Android, pushes it to the connected device (or emulator)
// with Slang's runtime libraries, and runs it:
//
//     jai-linux test/build_android.jai          (x64, from the repository root)
//     jai-linux test/build_android.jai - -arm64 (arm64: link check only)
//
// The test compiles to a shared library (Jai's supported Android output - its
// objects come out PIC, unlike the executable ones) with Slang linked
// dynamically beside it, plus a tiny C stub that loads the library and calls
// the exported entry point. No APK, no Android Studio: everything runs from
// /data/local/tmp, the stub's own output comes back through adb shell, and the
// test output is picked up from logcat (Jai's Android runtime redirects stdout
// there under tag jai-stdout).

STUB_SOURCE :: #string DONE
#include <dlfcn.h>
#include <stdio.h>

int main(int num_args, char* args[]) {
    if (num_args < 2) {
        printf("usage: stub <test-library>\n");
        return 2;
    }
    void* handle = dlopen(args[1], RTLD_NOW);
    if (!handle) {
        printf("dlopen failed: %s\n", dlerror());
        return 2;
    }
    int (*entry)() = (int(*)())dlsym(handle, "slang_test_main");
    if (!entry) {
        printf("dlsym failed: %s\n", dlerror());
        return 2;
    }
    int failures = entry();
    printf("[stub] test library returned %d\n", failures);
    return failures != 0;
}
DONE

#run {
    set_build_options_dc(.{do_output = false});  // No executable for this workspace.

    test_directory := #filepath;  // The directory holding this file, with a trailing separator.
    output_directory := tprint("%1android/", test_directory);
    make_directory_if_it_does_not_exist(output_directory);

    args := get_build_options().compile_time_command_line;
    cpu_target := ifx array_find(args, "-arm64") then CPU_Tag.ARM64 else .X64;
    run_on_device := cpu_target == .X64;  // The emulator here is x86_64.
    arch_name := ifx cpu_target == .X64 then "x64" else "arm64";

    // The module directory, for the prebuilt Slang libraries of the target.
    module_directory := tprint("%1../", test_directory);
    slang_directory := tprint("%1android/%2/", module_directory, arch_name);

    lib_base_name := tprint("test_android_%", cpu_target);
    lib_file_name := tprint("lib%.so", lib_base_name);

    w := compiler_create_workspace("Android test");
    if !w {
        print("could not create workspace.\n");
        return;
    }
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    options.cpu_target = cpu_target;
    options.os_target  = .ANDROID;
    options.output_executable_name = lib_base_name;
    options.output_path = output_directory;
    options.output_type = .DYNAMIC_LIBRARY;
    options.backend = .LLVM;
    options.use_custom_link_command = true;
    // Runtime_Support's crash handler has no Android branch; a device crash
    // still fails the run through the exit code.
    options.backtrace_on_crash = .OFF;

    _, target_triple_with_sdk := get_android_target_triple(cpu_target);
    options.llvm_options.target_system_triple = target_triple_with_sdk;
    set_build_options(options, w);

    build_failed := false;
    compiler_begin_intercept(w);
    add_build_file(tprint("%1test.jai", test_directory), w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .PHASE;
                phase := cast(*Message_Phase) message;
                if phase.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                    link_android_test_library(phase, options, lib_file_name);
                }
            case .ERROR;
                build_failed = true;
            case .COMPLETE;
                complete := cast(*Message_Complete) message;
                if complete.error_code != .NONE  build_failed = true;
                break;
        }
    }
    compiler_end_intercept(w);

    if build_failed {
        print("test library failed to build; skipping its run.\n");
        return;
    }

    if !run_on_device {
        print("arm64 links; nothing runs it here (the emulator is x86_64).\n");
        return;
    }

    if !copy_android_libcpp(cpu_target, output_directory) {
        print("could not copy libc++_shared.so; skipping its run.\n");
        return;
    }

    stub_name := tprint("test_stub_%", cpu_target);
    if !build_stub(output_directory, stub_name, target_triple_with_sdk)  return;

    run_on_device_via_adb(output_directory, stub_name, lib_file_name, slang_directory);
}

// Links the test shared library with the NDK clang driver. Slang goes in
// static, like on every other platform (the Android archives are built
// position-independent for exactly this reason); full archive paths, the way
// Jai links them itself.
link_android_test_library :: (message: *Message_Phase, options: Build_Options, lib_file_name: string) {
    ndk := get_ndk_paths();
    triple_prefix := ifx options.cpu_target == .X64 then "x86_64" else "aarch64";
    // The NDK's per-API driver symlink sets the target and the minSdk level
    // (31, matching the prebuilt Slang libraries) in one go.
    clang := tprint("%/bin/%-linux-android31-clang++", ndk.toolchain, triple_prefix);

    command: [..] string;
    array_add(*command, clang);
    array_add(*command, "-shared");
    array_add(*command, "-o", tprint("%/%", options.output_path, lib_file_name));
    for message.compiler_generated_object_files  array_add(*command, it);

    print("user_libraries   == %\n", message.user_libraries);
    print("system_libraries == %\n", message.system_libraries);

    for message.user_libraries  array_add(*command, it);
    for message.system_libraries {
        if starts_with(it, "-l") {
            if it == "-lcpp"  array_add(*command, "-lc++_shared");
            else              array_add(*command, it);
            continue;
        }
        _, basename, _, _ := path_decomp(it);
        if starts_with(basename, "lib") {
            advance(*basename, 3);
            array_add(*command, tprint("-l%", basename));
        } else {
            array_add(*command, tprint("-l%", basename));
        }
    }
    // Slang's shared libraries want these; the module does not declare them for Android.
    array_add(*command, "-lm");
    array_add(*command, "-ldl");
    array_add(*command, tprint("-Wl,-soname,%", lib_file_name));
    array_add(*command, "-Wl,-rpath,'$ORIGIN'");

    link_result, link_output, link_error := Process.run_command(..command, "", true);
    if link_result.exit_code != 0 {
        compiler_report(tprint("Android link failed with code %:\n%\n%", link_result.exit_code, link_output, link_error));
        return;
    }
    compiler_custom_link_command_is_complete(message.workspace);
}

// Compiles the C stub that loads the test library and calls its entry point.
build_stub :: (output_directory: string, stub_name: string, target_triple_with_sdk: string) -> bool {
    #import "BuildCpp";

    source_path := tprint("%/%_stub.c", output_directory, stub_name);
    write_entire_file(source_path, STUB_SOURCE);
    defer file_delete(source_path);

    extra: [] string;
    extra = .["-target", target_triple_with_sdk];
    if !build_cpp_executable(tprint("%/%", output_directory, stub_name), source_path, target = .ANDROID, debug = false, extra = extra) {
        print("stub failed to build; skipping its run.\n");
        return false;
    }
    return true;
}

// Pushes the stub with exactly the shared libraries it needs and runs it,
// passing its output and exit code back through.
run_on_device_via_adb :: (output_directory: string, stub_name: string, lib_file_name: string, slang_directory: string) {
    remote_directory := "/data/local/tmp/slang-test";

    // adb push does not create the destination directory; a missing one turns
    // the first push into a stray file, so make it (and clear that mistake).
    adb("shell", "rm", "-f", remote_directory);
    adb("shell", "mkdir", "-p", remote_directory);

    // Slang itself is linked in; only its runtime modules travel, the same set
    // copy_runtime_libraries ships on desktop.
    to_push: [..] string;
    array_add(*to_push, tprint("%/%", output_directory, stub_name));
    array_add(*to_push, tprint("%/%", output_directory, lib_file_name));
    array_add(*to_push, tprint("%/libc++_shared.so", output_directory));
    for file_list(slang_directory) {
        _, filename, extension, _ := path_decomp(it);
        if extension != "so"  continue;
        if !starts_with(filename, "libslang-glsl")  continue;
        array_add(*to_push, it);
    }
    for to_push {
        if !adb_push(it, remote_directory) {
            print("adb_push failed for %.\n", it);
            return;
        }
    }

    remote_stub := tprint("%/%", remote_directory, stub_name);
    remote_lib := tprint("%/%", remote_directory, lib_file_name);
    adb("shell", "chmod", "+x", remote_stub);
    // The stub has no runpath of its own, so its Slang dependencies come from
    // LD_LIBRARY_PATH (verified: without it the loader reports
    // libslang-compiler.so not found). Separate arguments throughout: adb
    // joins them with spaces for the device shell, and one pre-joined string
    // would arrive as a single unparsable command name.
    adb("logcat", "-c");
    success, output, error := adb("shell", tprint("LD_LIBRARY_PATH=%", remote_directory), remote_stub, remote_lib);
    if output.count  print("\n%\n", output);
    // Jai's Android runtime redirects stdout to logcat under tag jai-stdout.
    _, device_log, _ := adb("logcat", "-d", "-s", "jai-stdout");
    if device_log.count  print("%\n", device_log);
    if !success {
        if error.count  print("%\n", error);
        compiler_report("test failed on device (see above).");
    }
}

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Android/Toolchain";
Process :: #import "Process";
