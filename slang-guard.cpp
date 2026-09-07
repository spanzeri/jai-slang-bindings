// A catch(...) barrier between Slang and Jai.
//
// This is the one file in the project compiled with exceptions enabled, because
// catching them is the whole point. Slang raises C++ exceptions on paths a
// caller reaches normally: a fatal diagnostic (SLANG_ABORT_COMPILATION, e.g.
// "unsupported stage." in the Metal and WGSL emitters) and every internal error
// (SLANG_UNEXPECTED, SLANG_UNREACHABLE, SLANG_RELEASE_ASSERT). It catches them
// at some public methods and not others; these are the ones it does not.
//
// Jai emits no landing pads, so an escaping exception finds no handler and
// std::terminate()s the process. Each forwarder below puts a try/catch between
// Slang and Jai with no Jai frame inside the try, so `defer` on the Jai side is
// unaffected. After a failure, slang_getLastInternalErrorMessage() holds the
// text handleSignal recorded before throwing.

#include <slang.h>

// The DLL build needs its exports marked; the static build must not mark them.
#if defined(_WIN32) && defined(SLANG_GUARD_EXPORTS)
#define SLANG_GUARD_API extern "C" __declspec(dllexport)
#else
#define SLANG_GUARD_API extern "C"
#endif

#define SLANG_GUARD(fail_value, call) \
    try                               \
    {                                 \
        return (call);                \
    }                                 \
    catch (...)                       \
    {                                 \
        return fail_value;            \
    }

SLANG_GUARD_API SlangResult slangx_createSession(
    slang::IGlobalSession* self,
    const slang::SessionDesc* desc,
    slang::ISession** outSession)
{
    SLANG_GUARD(SLANG_E_INTERNAL_FAIL, self->createSession(*desc, outSession))
}

SLANG_GUARD_API slang::IModule* slangx_loadModuleFromSourceString(
    slang::ISession* self,
    const char* moduleName,
    const char* path,
    const char* string,
    slang::IBlob** outDiagnostics)
{
    SLANG_GUARD(nullptr, self->loadModuleFromSourceString(moduleName, path, string, outDiagnostics))
}

SLANG_GUARD_API SlangResult slangx_createCompositeComponentType(
    slang::ISession* self,
    slang::IComponentType* const* componentTypes,
    SlangInt componentTypeCount,
    slang::IComponentType** outCompositeComponentType,
    ISlangBlob** outDiagnostics)
{
    SLANG_GUARD(
        SLANG_E_INTERNAL_FAIL,
        self->createCompositeComponentType(
            componentTypes,
            componentTypeCount,
            outCompositeComponentType,
            outDiagnostics))
}

SLANG_GUARD_API SlangResult slangx_linkWithOptions(
    slang::IComponentType* self,
    slang::IComponentType** outLinkedComponentType,
    uint32_t compilerOptionEntryCount,
    slang::CompilerOptionEntry* compilerOptionEntries,
    ISlangBlob** outDiagnostics)
{
    SLANG_GUARD(
        SLANG_E_INTERNAL_FAIL,
        self->linkWithOptions(
            outLinkedComponentType,
            compilerOptionEntryCount,
            compilerOptionEntries,
            outDiagnostics))
}

SLANG_GUARD_API SlangResult slangx_specialize(
    slang::IComponentType* self,
    slang::SpecializationArg const* specializationArgs,
    SlangInt specializationArgCount,
    slang::IComponentType** outSpecializedComponentType,
    ISlangBlob** outDiagnostics)
{
    SLANG_GUARD(
        SLANG_E_INTERNAL_FAIL,
        self->specialize(
            specializationArgs,
            specializationArgCount,
            outSpecializedComponentType,
            outDiagnostics))
}

SLANG_GUARD_API SlangResult slangx_getEntryPointCode(
    slang::IComponentType* self,
    SlangInt entryPointIndex,
    SlangInt targetIndex,
    slang::IBlob** outCode,
    slang::IBlob** outDiagnostics)
{
    SLANG_GUARD(
        SLANG_E_INTERNAL_FAIL,
        self->getEntryPointCode(entryPointIndex, targetIndex, outCode, outDiagnostics))
}

SLANG_GUARD_API SlangResult slangx_getTargetCode(
    slang::IComponentType* self,
    SlangInt targetIndex,
    slang::IBlob** outCode,
    slang::IBlob** outDiagnostics)
{
    SLANG_GUARD(SLANG_E_INTERNAL_FAIL, self->getTargetCode(targetIndex, outCode, outDiagnostics))
}

SLANG_GUARD_API slang::ProgramLayout* slangx_getLayout(
    slang::IComponentType* self,
    SlangInt targetIndex,
    slang::IBlob** outDiagnostics)
{
    SLANG_GUARD(nullptr, self->getLayout(targetIndex, outDiagnostics))
}
