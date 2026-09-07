# Jai bindings for Khronos' Slang

Bindings and their generator for the [Slang shader compiler](https://github.com/shader-slang/slang).

Download a copy, or clone it into your module folder:

```
git clone https://github.com/spanzeri/jai-slang-bindings.git modules/ShaderSlang
```

and `#import "ShaderSlang";`.

> [!IMPORTANT]
> Slang loads two of its own libraries at runtime — `libslang-glslang` and
> `libslang-glsl-module` — and they must sit next to your executable. If they
> are missing it does not fail: it quietly emits unoptimised SPIR-V and reports
> success. `copy_runtime_libraries(output_directory)` puts them there; call it
> from your build metaprogram after linking.

## Using it

```jai
#import "ShaderSlang";
```

Slang links into your executable (about 35MB), and the compiler can still run
it during `#run`, so you can compile shaders at compile time and bake the
result into your program: each platform directory holds both the static and the
shared library, and a plain `#library` links the former and loads the latter.

Slang can raise C++ exceptions that Jai cannot catch, and some of them come from
ordinary mistakes like asking for a target it does not support. Anything that
runs the compiler should go through the guarded call instead:

```jai
guarded.IComponentType_getEntryPointCode(linked, 0, 0, *code, *diags)
```

See [The exception barrier](#the-exception-barrier).

`jai-linux test/build.jai` (from the repository root) checks a platform over: it
compiles a shader during `#run` and again at runtime,
requires the two to match byte for byte, reads the reflection back, and makes
sure a broken shader is reported rather than fatal. No platform-specific script
is needed; `test/build.jai` compiles it in its own workspace and runs it right
away.

> [!WARNING]
> Run it as `jai-linux test/build.jai` from the repository root. jai executes
> with the build file's directory (`test/`) as its working directory, and Slang
> finds its glslang module with a bare dlopen against it: a `libslang-glslang`
> copy visible there gets mapped into the compiler itself and segfaults it at
> exit. The layout keeps `test/` free of one (outputs go to `test/bin/`), so
> don't copy any Slang libraries into `test/` by hand.

`jai-linux test/build_android.jai` (from the repository root) does the same on
Android: with a device or emulator attached, it links the test against the
shared Slang libraries, pushes everything to `/data/local/tmp/slang-test`, and
runs it there. `-arm64` selects the arm64 build, which link-checks only. The
Android run skips the compile-time half of the test - the host workspace
inherits the target's OS macros, so it would try to load the Android libraries
on the host - but the on-device compile, reflection, diagnostics and result
codes all run.

## Platform status

| | |
| --- | --- |
| Linux x64 | tested |
| Windows x64 | built |
| Android x64 | tested on an emulator |
| Android arm64 | links; **never run on a device** |
| macOS, everything else | not set up; the module traps at compile time |

## Building Slang

Slang is a git clone in `src/`, with its submodules checked out.

```
./build_linux.sh [all|linux|android|clean]     # Linux, and Android if an NDK is found
.\build_windows.ps1 [clean]                    # from a VS Developer PowerShell
```

Each platform directory ends up with both flavours of the library, because the
Jai compiler needs both: it loads the shared one to run Slang during `#run`, and
links the static one into your executable. A plain `#library` picks the right
one for each - no link-mode option, no `shared/` subdirectory.

| path | contents |
| --- | --- |
| `linux/` | the static library, the shared library, and the two Slang loads at runtime |
| `android/x64/`, `android/arm64/` | the same, built against the NDK |
| `windows/x64/` | the same, with `.lib` and `.dll` (no import library next to the static archive) |
| `include/` | the public headers, for the binding generator |

Android is built automatically when an NDK turns up (`ANDROID_NDK_HOME`, or the
newest one under `$ANDROID_SDK_ROOT/ndk`). It cross-compiles using the host
build's code generators, so the Linux build has to run first. `ANDROID_API`
overrides the API level, which defaults to 31.

`WITH_GLSLANG=0` drops glslang and SPIRV-Tools from the build. It is the only
remaining option with any real mass, and the cost is that SPIR-V output then
only works at `SLANG_OPTIMIZATION_LEVEL_NONE`.

## Regenerating the bindings

`jai generate.jai` from the project root, after a build. It reads the headers
from `include/`, resolves symbols against the built library, and writes
`bindings.jai`.

Slang is really two APIs, and one run covers both:

- **Compiling is COM.** `IGlobalSession`, `ISession`, `IModule`,
  `IComponentType` and `IEntryPoint` are pure-virtual C++ with no flat C entry
  points. Jai's binding generator handles that natively, so `*IModule` converts
  to `*IComponentType` without a cast, and every method gets a plain wrapper
  like `IComponentType_link(...)`.
- **Reflection is flat C.** The `spReflection*` functions. slang.h wraps them in
  inline C++ classes, but those carry no symbols and come out as empty structs,
  so call the C functions and cast:
  `cast(*SlangReflection) IComponentType_getLayout(...)`.

Everything COM-shaped lands inside a `slang` namespace struct, which `module.jai`
brings into scope with `using slang;`.

### One file for every platform

slang.h's declarations do not vary by target — checked by generating a second
time against the Android NDK and diffing — so there is one `bindings.jai` rather
than one per platform. The only host-specific thing in it was slang.h's own
platform detection (`SLANG_LINUX`, `SLANG_PROCESSOR_X86_64` and friends), which
the generator drops. None of it is API; Jai already knows all of it.

If a platform ever does differ — `__declspec(dllimport)` on Windows is the
plausible candidate — splitting the output per platform is a one-line change.

`SLANG_TAG_VERSION` comes from the same run, so the bindings always say which
Slang they were built from.

### What the generator fixes up

Four things, each of which stops the run rather than quietly doing nothing if
Slang changes underneath it.

**Flag sets become `enum_flags`.** Slang writes each one as a typedef plus a
separate anonymous enum of bit values, which would leave you casting every
constant and unable to combine them. The generator merges the pair, so you can
write what you would expect:

```jai
target.flags = .GENERATE_SPIRV_DIRECTLY | .GENERATE_WHOLE_PROGRAM;
```

**The `*Integral` typedefs are folded away.** C++ needs a name to write
`enum SlangSeverity : int`, so slang.h declares one next to every enum. Jai
writes the base type directly, and nothing else uses those names, so they would
be pure noise in your scope.

**The `SlangResult` codes are rebuilt.** Only `SLANG_OK` survives generation —
the rest are function-like macros, which the translator drops — so the generator
adds them back, along with `SLANG_SUCCEEDED` and `SLANG_FAILED`. Use those:
success is any non-negative code, not just `SLANG_OK`.

**Two constants come through as C++ casts** rather than values, and are patched
in the emitted text.

## The exception barrier

Slang is C++ with exceptions, and it throws on paths you can reach by accident:
asking for a target or stage it does not support, or hitting one of its internal
consistency checks. It catches these at a few of its public entry points and not
at most of them — including `getEntryPointCode` and `getLayout`, the two that do
the real work.

Jai cannot catch a C++ exception, so one that escapes takes the whole process
down, without running your cleanup. That is what `slang-guard.cpp` is for: a
small C++ file, the only one here compiled with exceptions on purpose, wrapping
the entry points Slang leaves open. `guard.jai` declares them in a `guarded`
namespace with the same signatures as the generated wrappers, so switching a
call is a matter of adding the prefix.

When one of them fails it returns `SLANG_E_INTERNAL_FAIL` (or null), and
`slang_getLastInternalErrorMessage()` tells you what happened. Your program
carries on.

It covers the calls this module uses rather than all of Slang. Adding another is
a forwarder in `slang-guard.cpp` and a line in `guard.jai`.

Turning Slang's exceptions off is not an option, for the record: it does not
compile that way, and the switch also turns every recoverable failure into
`exit(-1)`.

## Notes on the build

Things that cost time to work out, kept here so they do not have to be worked
out twice.

- Slang defaults to building an IDE's worth of things. Most of the CMake options
  in the build script are turning those off. The two that matter most are
  `SLANG_SLANG_LLVM_FLAVOR=DISABLE`, without which CMake downloads a large
  slang-llvm used only for running shaders on the CPU, and
  `SLANG_ENABLE_RELEASE_DEBUG_INFO=OFF`, which is worth an order of magnitude in
  library size.
- CMake does not bundle transitive static dependencies, so a static Slang is six
  separate libraries. The scripts merge them into one.
- On Linux the archive also gets `libgcc_eh.a` merged in. Jai's link line has no
  way to name the system unwinder, and the exception barrier needs one that
  actually works, not just one that satisfies the linker.
- The libraries keep Slang's own names. The name is recorded inside the file, so
  a renamed shared library asks the loader for something that is not there.
- `slang-glsl-module` is excluded from the default build and has to be asked for
  by name.
- The two libraries Slang loads at runtime sit next to the compiler library in
  every platform directory, because Slang finds them relative to whichever
  Slang library got loaded. That "relative to the loader" resolution is
  Linux's RPATH `$ORIGIN`; Windows has no equivalent, so a `#run` shader
  compile — before `copy_runtime_libraries` has put anything next to the
  executable — falls back to a bare `LoadLibrary("slang-glslang.dll")` and
  whatever the system search order finds first. On a machine with the Vulkan
  SDK on PATH, that is the SDK's own copy, not this one. Harmless as long as
  both produce the same SPIR-V (verified for the test shader), but not
  guaranteed on a shader where they diverge.
- Slang's standard module sources (`import neural` and friends) are not shipped.
  Copy them out of `build/` if you want them.

## Licence

The generator, the module, the guard shim, the tests and the build scripts are
MIT or public domain, whichever you prefer — see `LICENSE.txt`.

The prebuilt libraries and the headers under `include/` are Slang itself, which
is Apache-2.0 WITH LLVM-exception. Its licence travels with them in
`third_party/slang/`, along with the version and commit they were built from.
