# Premake build

Alternative build system for this LuaJIT fork using the bundled premake5
(`utils/premake5`, `utils/premake5.exe` - same binaries as mtasa-blue). The
upstream Makefile build (`make`, `src/msvcbuild.bat`) keeps working unchanged.

## Projects

- `luajit-bootstrap` - builds the host tools (minilua, buildvm) and generates
  the arch-specific sources into `build/gen/<os>_<platform>/`. Implemented by
  `premake/luajit-bootstrap.sh` (Linux) and `premake/luajit-bootstrap.bat`
  (Windows/MSVC); both are transliterations of the upstream build
  (`src/Makefile` / `src/msvcbuild.bat`).
- `luajit` - static library (`libluajit.a` / `luajit.lib`)
- `luajit-shared` - shared library (`libluajit.so` / `lua51.dll` + `lua51.lib`)
- `luajit-cli` - the `luajit` interpreter executable

Artifacts land in `Bin/<platform>/<config>/`.

## Linux

Target platforms: `x86`, `x64`, `arm`, `arm64` (Debian: i386, amd64, armhf,
arm64). The easy way:

```
./build.sh [--arch=x86|x64|arm|arm64] [--config=debug|release]
```

Or manually:

```
./utils/premake5 gmake
make -C Build -j$(nproc) config=release_x64
make -C Build -j$(nproc) config=release_arm CC=arm-linux-gnueabihf-gcc AR=arm-linux-gnueabihf-ar
```

Cross builds need the matching Debian cross toolchain (`i686-linux-gnu-gcc`,
`arm-linux-gnueabihf-gcc`, `aarch64-linux-gnu-gcc`) and `CC`/`AR` passed to
make (build.sh does this). The bootstrap picks a host compiler at the
*target's* pointer width automatically (e.g. `i686-linux-gnu-gcc -m32` for the
32-bit targets on an x86_64 host), because buildvm embeds target-sized
structures.

Environment overrides: `CC` (target compiler), `LUAJIT_HOST_CC` (host-tool
compiler), `GCC_VERSION` (suffix for versioned cross packages), `PREMAKE5`
(premake binary for build.sh).

## Windows

Target platforms: `Win32` (x86), `x64`, `ARM64`. Requires VS2022 with the C++
workload; ARM64 additionally needs the "MSVC v143 - VS 2022 C++ ARM64/ARM64EC
build tools" component (host tools are compiled as x64 and cross-compile the
ARM64 VM).

```
utils\premake5.exe vs2022
msbuild Build\LuaJIT.sln /m /p:Configuration=Release /p:Platform=x64
```

or open `Build\LuaJIT.sln` in the IDE.

## Using from an outer workspace

`premake5.lua` defines its workspace only when none is active yet, so an outer
premake workspace (e.g. mtasa-blue) can `include` this repository and gets
just the projects; link against project `luajit`. The outer workspace must
provide `x86`/`x64`/`arm`/`arm64` platform names.

## Notes

- Generated files (incl. `jit/vmdef.lua`) live in
  `build/gen/<os>_<platform>/`, never in `src/`. Different platforms can be
  built side by side; the bootstrap only rewrites files whose content changed,
  so rebuilds stay incremental.
- To use the `jit.*` Lua modules (`-jdump` etc.) with the built CLI, set
  `LUA_PATH="<repo>/src/?.lua;<repo>/build/gen/<os>_<plat>/?.lua;;"`.
- The version header `luajit.h` is generated from git metadata
  (`git show -s --format=%ct`); building from a plain source export without
  git falls back to `.relver` and may yield a `ROLLING` version string, same
  as the Makefile build.
