// Generates bindings.jai:
//
//     jai generate.jai
//
// Run build_linux.sh (or build_windows.ps1) first: the generator resolves
// symbols against the built library and reads the headers it copied into
// include/.
//
// One file covers every target. Verified by generating a second time against
// the NDK sysroot with -target aarch64-linux-android31: after the header's own
// platform detection is dropped (see CONFIGURATION_MACROS) the two outputs are
// identical, and the preprocessed declarations Slang owns match byte for byte.
//
// Three fix-ups keep the output usable, each of which fails loudly rather than
// quietly doing nothing if Slang changes underneath it: CONFIGURATION_MACROS
// drops the header's own platform detection, FLAG_ENUMS turns each
// typedef-plus-anonymous-enum flag set into one enum_flags type, and
// unwrap_integral_typedefs folds away the names C++ needs for enum base types.
//
// slang.h is C++, and the compile API is COM - IGlobalSession, ISession,
// IModule, IComponentType are pure-virtual classes with no flat C entry points.
// Bindings_Generator emits those as vtable structs with #cpp_method, plus
// `#as using,except(vtable)` for the inheritance chain, so *IModule converts to
// *IComponentType with no cast. The reflection half is the opposite: 170-odd
// flat spReflection* functions that slang.h wraps in inline C++ classes. Both
// halves come out of the same run.
//
// Everything lands inside a `slang` namespace struct; module.jai does
// `using slang;`.

OUTPUT_FILE :: "bindings.jai";

AT_COMPILE_TIME :: true;

#if AT_COMPILE_TIME {
    #run,stallable {
        set_build_options_dc(.{do_output = false});
        if !generate_bindings_for_host()  compiler_set_workspace_status(.FAILED);
    }
} else {
    #import "System";

    main :: () {
        set_working_directory(path_strip_filename(get_path_of_running_executable()));
        if !generate_bindings_for_host()  exit(1);
    }
}

generate_bindings_for_host :: () -> bool {
    fixups: Fixups;

    options: Generate_Bindings_Options;
    {
        using options;

        // Not "slang": that identifier is taken by the namespace struct.
        #if OS == .LINUX {
            array_add(*library_search_paths, "linux");
            array_add(*libraries, .{filename = "libslang-compiler", identifier = "libslang"});
        } else #if OS == .WINDOWS {
            array_add(*library_search_paths, "windows/x64");
            // No "lib" prefix: that is a Linux naming convention, and
            // os_load_library() does not add it for you, so the name has to
            // match what build_windows.ps1 actually produces.
            array_add(*libraries, .{filename = "slang-compiler", identifier = "libslang"});
        } else {
            #assert false "Run the generator on Linux or Windows; those are the platforms with a build script.";
        }

        array_add(*include_paths, "include");
        // slang.h does not include the version stamp, so ask for it separately:
        // it is the only record of which Slang these bindings were built from.
        array_add(*source_files, "include/slang.h", "include/slang-tag-version.h");
        array_add(*extra_clang_arguments, "-x", "c++", "-std=c++17", "-DSLANG_STATIC");

        // module.jai declares the library itself, since it owns the platform,
        // architecture and link-mode switch.
        generate_library_declarations = false;

        generate_compile_time_struct_checks = true;
        log_stripped_declarations           = true;

        footer = RESULT_CODES;

        visitor_with_data = fix_up_declarations;
        visitor_data      = *fixups;
    }

    bindings, ok := generate_bindings(options, log_results = true);
    if !ok  return false;

    for fixups.seen_configuration_macros {
        if it  continue;
        log_error("'%' is listed in CONFIGURATION_MACROS but slang.h no longer defines it.", CONFIGURATION_MACROS[it_index]);
        ok = false;
    }
    for fixups.flag_enum_matches {
        if it == 1  continue;
        log_error("Expected exactly one enum printed as '%', found %. See FLAG_ENUMS.", FLAG_ENUMS[it_index].enum_name, it);
        ok = false;
    }
    if !ok  return false;

    source := builder_to_string(*bindings);

    source, ok = fix_functional_casts(source);
    if !ok  return false;

    source, ok = unwrap_integral_typedefs(source);
    if !ok  return false;

    if !write_entire_file(OUTPUT_FILE, source) {
        log_error("Could not write '%'.", OUTPUT_FILE);
        return false;
    }
    return true;
}

// slang.h builds every SlangResult except SLANG_OK out of function-like macros
// (SLANG_MAKE_ERROR and friends), which the macro translator drops, so they are
// rebuilt here from the facility constants that did survive. Without them there
// is no way to tell SLANG_FAIL from SLANG_E_INVALID_ARG in Jai.
RESULT_CODES :: #string DONE

// The generator closes with #scope_file for its own imports, so reopen.
#scope_export

SLANG_ERROR_SEVERITY :: 0x8000_0000;

SLANG_FAIL                : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_WIN_GENERAL << 16) | 0x4005 | SLANG_ERROR_SEVERITY);
SLANG_E_NOT_IMPLEMENTED   : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_WIN_GENERAL << 16) | 0x4001 | SLANG_ERROR_SEVERITY);
SLANG_E_NO_INTERFACE      : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_WIN_GENERAL << 16) | 0x4002 | SLANG_ERROR_SEVERITY);
SLANG_E_ABORT             : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_WIN_GENERAL << 16) | 0x4004 | SLANG_ERROR_SEVERITY);

SLANG_E_INVALID_HANDLE    : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_WIN_API << 16) | 0x06 | SLANG_ERROR_SEVERITY);
SLANG_E_OUT_OF_MEMORY     : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_WIN_API << 16) | 0x0e | SLANG_ERROR_SEVERITY);
SLANG_E_INVALID_ARG       : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_WIN_API << 16) | 0x57 | SLANG_ERROR_SEVERITY);

SLANG_E_BUFFER_TOO_SMALL  : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 1 | SLANG_ERROR_SEVERITY);
SLANG_E_UNINITIALIZED     : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 2 | SLANG_ERROR_SEVERITY);
SLANG_E_PENDING           : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 3 | SLANG_ERROR_SEVERITY);
SLANG_E_CANNOT_OPEN       : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 4 | SLANG_ERROR_SEVERITY);
SLANG_E_NOT_FOUND         : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 5 | SLANG_ERROR_SEVERITY);
SLANG_E_INTERNAL_FAIL     : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 6 | SLANG_ERROR_SEVERITY);
SLANG_E_NOT_AVAILABLE     : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 7 | SLANG_ERROR_SEVERITY);
SLANG_E_TIME_OUT          : SlangResult : cast,no_check(s32) ((SLANG_FACILITY_CORE << 16) | 8 | SLANG_ERROR_SEVERITY);

// Success is any non-negative code, not just SLANG_OK.
SLANG_SUCCEEDED :: inline (result: SlangResult) -> bool { return result >= 0; }
SLANG_FAILED    :: inline (result: SlangResult) -> bool { return result < 0; }

SLANG_GET_RESULT_FACILITY :: inline (result: SlangResult) -> s32 { return (result >> 16) & 0x7fff; }
SLANG_GET_RESULT_CODE     :: inline (result: SlangResult) -> s32 { return result & 0xffff; }

// Two C++ types slang.h leaves at their compiler's default representation
// rather than pinning with a typedef, so the generator can't derive them from
// source truth the way it does the flag enums. Named aliases instead of a
// literal type, so the printed bindings are the same text regardless of which
// platform generated them, and only resolve to a concrete type - correctly -
// once a real Jai target is known.
//
// SlangCLong: raw `long` (ISlangProfiler::getEntryTimeMS's return type) is 8
// bytes under LP64 (Linux, Android), 4 under LLP64 (Windows).
//
// SlangCEnum: a plain enum with no fixed underlying type is `int` under MSVC
// and `unsigned int` under Itanium-ABI compilers (GCC, Clang) when every
// enumerator fits - see PORTABLE_ENUMS.
#if OS == .WINDOWS {
    SlangCLong :: s32;
    SlangCEnum :: s32;
} else {
    SlangCLong :: s64;
    SlangCEnum :: u32;
}
DONE

Fixups :: struct {
    seen_configuration_macros: [CONFIGURATION_MACROS.count] bool;
    flag_enum_matches:         [FLAG_ENUMS.count] int;
    flag_enum_types:           [FLAG_ENUMS.count] *CType; // from the typedef being replaced
}

fix_up_declarations :: (decl: *Declaration, parent_decl: *Declaration, user_data: *void) -> Declaration_Visit_Result {
    using fixups := cast(*Fixups) user_data;

    // A few inline C++ wrapper methods aren't inlined away and get a real,
    // name-mangled symbol. The mangling differs between MSVC and Itanium, so
    // it can't survive in one cross-platform bindings.jai - strip it like an
    // unresolved symbol.
    if decl.library && is_mangled_cpp_name(decl.foreign_name) {
        decl.decl_flags |= .OMIT_FROM_OUTPUT;
        log("Stripping non-portable (mangled) symbol: %", decl.foreign_name);
        return .RECURSE;
    }

    if decl.kind == {
        case .MACRO_DEFINITION;
            if !parent_decl {   // macros are always top level
                for CONFIGURATION_MACROS {
                    if decl.name != it  continue;
                    decl.decl_flags |= .OMIT_FROM_OUTPUT;
                    seen_configuration_macros[it_index] = true;
                    break;
                }
            }

        case .STRUCT;
            // ISlangUnknown::QueryInterface takes "struct _GUID const&" with no
            // prior declaration in scope, which C++ injects as a forward decl -
            // into ISlangUnknown on platforms with no real ::_GUID already in
            // scope (i.e. not Windows, which gets it from the SDK). The method
            // itself is inline-only and already stripped on every platform, so
            // this placeholder is dead weight only some platforms produce.
            if decl.name == "_GUID"  decl.decl_flags |= .OMIT_FROM_OUTPUT;

        case .TYPEDEF;
            for FLAG_ENUMS {
                if decl.name != it.typedef_name  continue;
                decl.decl_flags |= .OMIT_FROM_OUTPUT;
                // slang.h fixes this type explicitly (e.g. "typedef unsigned
                // int SlangCompileFlags") - use it instead of the anonymous
                // enum's own ABI-inferred type, which is not always the same.
                flag_enum_types[it_index] = (cast(*Typedef) decl).type;
            }

        case .ENUM;
            enum_decl := cast(*Enum) decl;
            for FLAG_ENUMS {
                matches := ifx it.match_member
                    then has_member(enum_decl, it.match_member)
                    else decl.output_name == it.enum_name;
                if !matches  continue;
                enum_decl.flags |= .IS_ENUM_FLAGS;
                if flag_enum_types[it_index]  enum_decl.type = flag_enum_types[it_index];
                decl.output_name = it.typedef_name;
                flag_enum_matches[it_index] += 1;
            }
            for PORTABLE_ENUMS {
                if decl.output_name != it  continue;
                enum_decl.type = make_hardcoded_type("SlangCEnum", size = 4);
            }

        case .FUNCTION;
            if decl.name == "getEntryTimeMS" {
                current_size := decl.type.type_of_function.return_type.size;
                change_return_type(decl, make_hardcoded_type("SlangCLong", current_size));
            }
    }

    return .RECURSE;
}

has_member :: (e: *Enum, name: string) -> bool {
    for e.enumerates  if it.name == name  return true;
    return false;
}

// Plain enums with no explicit underlying type - see SlangCEnum in RESULT_CODES.
PORTABLE_ENUMS :: string.[
    "SlangEmitSpirvMethod", "SlangEmitCPUMethod", "SlangDiagnosticColor",
    "SlangReflectionGenericArgType", "SlangLanguageVersion",
];

make_hardcoded_type :: (name: string, size: int) -> *CType {
    ty := New(CType);
    ty.hardcoded_jai_string = name;
    ty.size = size;
    return ty;
}

// MSVC decorates as "?...", Itanium mangles as "_Z...". Neither collides with
// any of Slang's real extern "C" names.
is_mangled_cpp_name :: (name: string) -> bool {
    return begins_with(name, "_Z") || begins_with(name, "?");
}

// slang.h opens by detecting its own build environment: which compiler, which
// OS, which processor, pointer size, endianness. None of it is API - Jai knows
// all of it already - and it is the only part of the output that would differ
// between targets, so dropping it is what lets one file serve all of them.
// Anything that goes missing upstream is reported rather than ignored.
CONFIGURATION_MACROS :: string.[
    "SLANG_STATIC", "SLANG_CLANG", "SLANG_VC", "SLANG_SNC",
    "SLANG_GHS", "SLANG_GCC", "SLANG_LINUX", "SLANG_WINRT",
    "SLANG_XBOXONE", "SLANG_WIN64", "SLANG_X360", "SLANG_WIN32",
    "SLANG_ANDROID", "SLANG_IOS", "SLANG_OSX", "SLANG_PS3",
    "SLANG_PS4", "SLANG_PSP2", "SLANG_WIIU", "SLANG_WASM",
    "SLANG_GCC_FAMILY", "SLANG_WINDOWS_FAMILY", "SLANG_MICROSOFT_FAMILY", "SLANG_LINUX_FAMILY",
    "SLANG_APPLE_FAMILY", "SLANG_UNIX_FAMILY", "SLANG_ENABLE_DXVK", "SLANG_ENABLE_VKD3D",
    "SLANG_ENABLE_DIRECTX", "SLANG_ENABLE_DXGI_DEBUG", "SLANG_ENABLE_DXBC_SUPPORT", "SLANG_ENABLE_PIX",
    "SLANG_HAS_EXCEPTIONS", "SLANG_HAS_MOVE_SEMANTICS", "SLANG_HAS_ENUM_CLASS", "SLANG_PROCESSOR_X86_64",
    "SLANG_PROCESSOR_ARM", "SLANG_PROCESSOR_ARM_64", "SLANG_PROCESSOR_X86", "SLANG_PROCESSOR_POWER_PC",
    "SLANG_PROCESSOR_POWER_PC_64", "SLANG_PROCESSOR_WASM", "SLANG_PROCESSOR_FAMILY_X86", "SLANG_PROCESSOR_FAMILY_ARM",
    "SLANG_PROCESSOR_FAMILY_POWER_PC", "SLANG_PTR_IS_64", "SLANG_PTR_IS_32", "SLANG_LITTLE_ENDIAN",
    "SLANG_UNALIGNED_ACCESS", "SLANG_BIG_ENDIAN", "SLANG_HAS_BACKTRACE",
];

// Slang writes each flag set as a uint32 typedef plus a separate anonymous enum
// of bit values, and every function and field takes the typedef. Emitted as-is
// that gives you `desc.flags = xx SLANG_TARGET_FLAG.DUMP_IR` and no way to or
// two values together, so the enum takes the typedef's name and becomes
// enum_flags, and the typedef itself is dropped: `desc.flags = .DUMP_IR`.
//
// enum_name is what the generator prints, not what the header says - these
// enums are anonymous, and the name is inferred from the members' common
// prefix. Each has to match exactly one enum, so a second anonymous enum
// turning up upstream is an error rather than a silent mis-rename.
//
// SessionFlags has only one member, so it falls back to a sequential name
// ("anon_enum", "anon_enum_1", ...) by position in the translation unit. That
// position isn't portable - Windows parses extra anonymous enums ahead of it
// that Linux doesn't - so it's matched by its one member's name instead.
//
// slang::CompileCoreModuleFlags is left alone: its enum is nested inside a
// CompileCoreModuleFlag wrapper struct, which output_name cannot undo.
Flag_Enum :: struct { enum_name: string; typedef_name: string; match_member: string = ""; }
FLAG_ENUMS :: Flag_Enum.[
    .{enum_name = "SLANG_TARGET_FLAG",     typedef_name = "SlangTargetFlags"},
    .{enum_name = "SLANG_COMPILE_FLAG",    typedef_name = "SlangCompileFlags"},
    .{enum_name = "SLANG_DIAGNOSTIC_FLAG", typedef_name = "SlangDiagnosticFlags"},
    .{enum_name = "anon_enum", typedef_name = "SessionFlags", match_member = "kSessionFlags_None"},
];

// Two constants in slang.h are written as C++ functional casts, which the macro
// translator turns into Jai type instantiations:
//
//     #define SLANG_UNBOUNDED_SIZE (~size_t(0))            -> ~u64(0)
//     inline constexpr uint32_t k... = ~uint32_t(0);       -> ~0  (s64 in Jai)
fix_functional_casts :: (source: string) -> string, bool {
    result := source;

    Fix :: struct { from: string; to: string; }
    fixes :: Fix.[
        .{"SLANG_UNBOUNDED_SIZE :: ~u64(0);", "SLANG_UNBOUNDED_SIZE :: ~cast(u64)0;"},
        .{"kUnboundedSyntheticResourceArraySize: u32 : ~0;", "kUnboundedSyntheticResourceArraySize :: ~cast(u32)0;"},
    ];

    for fixes {
        count: s64;
        result, count = replace(result, it.from, it.to);
        if count != 1 {
            log_error(
                "Expected exactly one '%' in the generated bindings, found %. Slang may have changed it; check whether the fix is still needed.",
                it.from,
                count,
            );
            return result, false;
        }
    }

    return result, true;
}

// Slang typedef an integral time that is just used to name the underlying type
// of the following enum. Fold those away.
unwrap_integral_typedefs :: (source: string) -> string, bool {
    Typedef :: struct { name: string; underlying: string; }
    typedefs: [..] Typedef;

    builder: String_Builder;
    first := true;
    for line: split(source, "\n") {
        code := trim_left(line);
        separator := find_index_from_left(code, " :: ");
        if separator > 0 && ends_with(code, ";") {
            name := slice(code, 0, separator);
            if ends_with(name, "Integral") {
                value_start := separator + " :: ".count;
                array_add(*typedefs, .{name, slice(code, value_start, code.count - value_start - 1)});
                continue;
            }
        }

        if !first  append(*builder, "\n");
        append(*builder, line);
        first = false;
    }

    result := builder_to_string(*builder);

    for typedefs {
        count: s64;
        result, count = replace(result, tprint("enum %", it.name), tprint("enum %", it.underlying));
        if count == 0 {
            log_error("'%' is not used as an enum base type, so folding it away is no longer safe.", it.name);
            return result, false;
        }
    }

    for typedefs {
        if find_index_from_left(result, it.name) < 0  continue;
        log_error("'%' survived the rewrite; Slang must now use it somewhere other than an enum base.", it.name);
        return result, false;
    }

    return result, true;
}

#import "Basic";
#import "Bindings_Generator";
#import "Compiler";
#import "File";
#import "String";

