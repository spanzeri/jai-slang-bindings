// Builds and runs the test:
//
//     jai-linux test/build.jai        (from the repository root)
//
// No platform-specific script needed: the test compiles in its own workspace,
// then Autorun runs the executable and reports a nonzero exit as a compile
// error.
//
// Outputs go to test/bin/, not test/: jai runs with its working directory set
// to the build file's directory (test/), and Slang finds its glslang module
// with a bare dlopen that resolves against it. A libslang-glslang copy mapped
// into jai itself segfaults it at exit (upstream teardown issue - the test
// executable is unaffected), so test/ itself must stay free of one while the
// executable still finds its libraries next to itself through -rpath=$ORIGIN.

#run {
    set_build_options_dc(.{do_output=false});  // No executable for this workspace.

    test_directory := #filepath;  // The directory holding this file, with a trailing separator.
    output_directory := tprint("%1bin/", test_directory);
    make_directory_if_it_does_not_exist(output_directory);

    w := compiler_create_workspace();
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    options.output_path = output_directory;
    options.output_executable_name = "test";
    set_build_options(options, w);

    compiler_begin_intercept(w);
    add_build_file(tprint("%1test.jai", test_directory), w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == .COMPLETE {
            mc := cast(*Message_Complete) message;
            if mc.error_code != .NONE
                print("test failed to build; skipping its run.\n");
            else
                Autorun.run_build_result_of_workspace(w);
            break;
        }
    }
    compiler_end_intercept(w);
}

#import "Basic";
#import "Compiler";
#import "File";
Autorun :: #import "Autorun";
