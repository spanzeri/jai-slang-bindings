// Exception-safe forwarders for the Slang entry points that carry no try/catch
// of their own; see slang-guard.cpp for which and why. The signatures match the
// generated wrappers, so a call site changes by prefix only:
//
//     IComponentType_getEntryPointCode(linked, 0, 0, *code, *diags)
//     guarded.IComponentType_getEntryPointCode(linked, 0, 0, *code, *diags)
//
// On failure they return SLANG_E_INTERNAL_FAIL (or null), and
// slang_getLastInternalErrorMessage() holds the message Slang recorded before
// throwing. The unguarded versions terminate the process instead.
guarded :: struct {
    IGlobalSession_createSession :: (this: *IGlobalSession, desc: *SessionDesc, outSession: **ISession) -> SlangResult #foreign libguard "slangx_createSession";

    ISession_loadModuleFromSourceString :: (this: *ISession, moduleName: *u8, path: *u8, _string: *u8, outDiagnostics: **IBlob = null) -> *IModule #foreign libguard "slangx_loadModuleFromSourceString";
    ISession_createCompositeComponentType :: (this: *ISession, componentTypes: **IComponentType, componentTypeCount: SlangInt, outCompositeComponentType: **IComponentType, outDiagnostics: **ISlangBlob = null) -> SlangResult #foreign libguard "slangx_createCompositeComponentType";

    IComponentType_linkWithOptions :: (this: *IComponentType, outLinkedComponentType: **IComponentType, compilerOptionEntryCount: u32, compilerOptionEntries: *CompilerOptionEntry, outDiagnostics: **ISlangBlob = null) -> SlangResult #foreign libguard "slangx_linkWithOptions";
    IComponentType_specialize :: (this: *IComponentType, specializationArgs: *SpecializationArg, specializationArgCount: SlangInt, outSpecializedComponentType: **IComponentType, outDiagnostics: **ISlangBlob = null) -> SlangResult #foreign libguard "slangx_specialize";
    IComponentType_getEntryPointCode :: (this: *IComponentType, entryPointIndex: SlangInt, targetIndex: SlangInt, outCode: **IBlob, outDiagnostics: **IBlob = null) -> SlangResult #foreign libguard "slangx_getEntryPointCode";
    IComponentType_getTargetCode :: (this: *IComponentType, targetIndex: SlangInt, outCode: **IBlob, outDiagnostics: **IBlob = null) -> SlangResult #foreign libguard "slangx_getTargetCode";
    IComponentType_getLayout :: (this: *IComponentType, targetIndex: SlangInt = 0, outDiagnostics: **IBlob = null) -> *ProgramLayout #foreign libguard "slangx_getLayout";
}
