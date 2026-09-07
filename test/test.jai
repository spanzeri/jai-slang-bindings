// Checks that the module still works, after a Slang bump or on a new platform.
// Run it through test/build.jai, which builds and runs it:
//
//     jai-linux test/build.jai        (from the repository root)
//
// The interesting part is that the same shader is compiled once during #run and
// again at runtime, and the two have to come out byte-identical. That is what
// catches a missing runtime library: when one is not there Slang does not fail,
// it quietly emits unoptimised code and reports success.

SOURCE :: #string DONE
struct Uniforms { float4 tint; };
ParameterBlock<Uniforms> u;
Texture2D tex;
SamplerState samp;

[shader("fragment")]
float4 fragMain(float2 uv : UV) : SV_Target { return tex.Sample(samp, uv) * u.tint; }
DONE

Compiled :: struct {
    code:             string;
    parameter_count:  int;
    entry_point_count:int;
    entry_point_name: string;
}

compile :: (source: string, entry_point: string) -> Compiled, error: string {
    result: Compiled;

    global: *IGlobalSession;
    if SLANG_FAILED(slang_createGlobalSession(SLANG_API_VERSION, *global))  return result, "createGlobalSession failed";

    target: TargetDesc;
    target.format  = .SPIRV;
    target.profile = IGlobalSession_findProfile(global, "spirv_1_5");
    target.flags   = .GENERATE_SPIRV_DIRECTLY;

    desc: SessionDesc;
    desc.structureSize = size_of(SessionDesc);
    desc.targets       = *target;
    desc.targetCount   = 1;

    session: *ISession;
    if SLANG_FAILED(guarded.IGlobalSession_createSession(global, *desc, *session))  return result, "createSession failed";

    diagnostics: *ISlangBlob;
    module := guarded.ISession_loadModuleFromSourceString(session, "test", "test.slang", source.data, *diagnostics);
    if !module  return result, blob_to_string(diagnostics);

    entry: *IEntryPoint;
    if SLANG_FAILED(IModule_findEntryPointByName(module, entry_point.data, *entry))  return result, "no such entry point";

    components := (*IComponentType).[module, entry];
    composite, linked: *IComponentType;
    if SLANG_FAILED(guarded.ISession_createCompositeComponentType(session, components.data, components.count, *composite, *diagnostics)) {
        return result, blob_to_string(diagnostics);
    }
    if SLANG_FAILED(IComponentType_link(composite, *linked, *diagnostics))  return result, blob_to_string(diagnostics);

    code: *ISlangBlob;
    if SLANG_FAILED(guarded.IComponentType_getEntryPointCode(linked, 0, 0, *code, *diagnostics))  return result, blob_to_string(diagnostics);

    // The reflection classes in slang.h are inline-only and carry no symbols, so
    // the flat C API is the only way in.
    layout := cast(*SlangReflection) guarded.IComponentType_getLayout(linked, 0, null);
    if !layout  return result, "getLayout failed";

    result.parameter_count   = xx spReflection_GetParameterCount(layout);
    result.entry_point_count = xx spReflection_getEntryPointCount(layout);
    if result.entry_point_count > 0 {
        result.entry_point_name = to_string(spReflectionEntryPoint_getName(spReflection_getEntryPointByIndex(layout, 0)));
    }

    blob: string;
    blob.data  = xx ISlangBlob_getBufferPointer(code);
    blob.count = xx ISlangBlob_getBufferSize(code);
    result.code = copy_string(blob);
    return result, "";
}

blob_to_string :: (blob: *ISlangBlob) -> string {
    if !blob  return "failed with no diagnostic";
    s: string;
    s.data  = xx ISlangBlob_getBufferPointer(blob);
    s.count = xx ISlangBlob_getBufferSize(blob);
    return s;
}

// No compile-time compile when targeting Android: the host workspace inherits
// the target's OS macros, so it would try to load the Android libraries on the
// host. The runtime compile below still exercises the device libraries.
#if OS != .ANDROID {
    BAKED :: #run -> Compiled {
        baked, error := compile(SOURCE, "fragMain");
        if error  compiler_report(tprint("compiling at compile time failed: %", error));
        return baked;
    };
}

run_tests :: () -> int {
    failures := 0;
    check :: (condition: bool, format: string, args: ..Any) #expand {
        print("  % %\n", ifx condition then "ok  " else "FAIL", tprint(format, ..args));
        if !condition  `failures += 1;
    }

    print("compile-time and runtime agree\n");
    runtime, error := compile(SOURCE, "fragMain");
    check(!error, "runtime compile succeeded%", ifx error then tprint(": %", error) else "");
    check(runtime.code.count > 0, "produced % bytes of SPIR-V", runtime.code.count);
    check(runtime.code.count >= 4 && (cast(*u32) runtime.code.data).* == 0x0723_0203, "starts with the SPIR-V magic number");
    #if OS != .ANDROID {
        check(runtime.code == BAKED.code, "matches the % bytes baked in at compile time", BAKED.code.count);
    }

    print("reflection\n");
    check(runtime.parameter_count == 3, "3 global parameters, got %", runtime.parameter_count);
    check(runtime.entry_point_count == 1, "1 entry point, got %", runtime.entry_point_count);
    check(runtime.entry_point_name == "fragMain", "entry point is 'fragMain', got '%'", runtime.entry_point_name);

    print("a broken shader is diagnosed rather than fatal\n");
    _, bad := compile("[shader(\"fragment\")] float4 f() : SV_Target { return nope; }", "f");
    check(!!bad, "reported an error and kept going");

    print("result codes\n");
    check(SLANG_FAILED(SLANG_FAIL) && SLANG_FAILED(SLANG_E_INVALID_ARG), "SLANG_FAILED recognises failures");
    check(SLANG_SUCCEEDED(SLANG_OK), "SLANG_SUCCEEDED recognises SLANG_OK");

    print("\n%\n", ifx failures == 0 then "all checks passed" else tprint("% checks FAILED", failures));
    return failures;
}

main :: () {
    if run_tests() != 0  exit(1);
}

#if OS == .ANDROID {
    // Entry point for the C stub that runs this on a device (see
    // build_android.jai). Returns the failure count; the stub turns it into
    // the process exit code. first_thread_context is set up by the runtime
    // support's library initializer before this is ever called.
    #program_export "slang_test_main"
    test_main_android :: () -> s32 #c_call {
        ctx := __jai_runtime_init(0, null);
        push_context ctx {
            failures := run_tests();
            return cast(s32) failures;
        }
    }
}

// Slang looks for its loadable libraries next to the executable, so put them
// there before this one runs. Android deployment is build_android.jai's job.
#if OS != .ANDROID {
    #run {
        if !copy_runtime_libraries(get_build_options().output_path) {
            compiler_report("could not copy Slang's runtime libraries next to the test executable");
        }
    }
}

#import "Basic";
#import "Compiler";
#import,file "../module.jai";
