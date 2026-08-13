@rem LuaJIT premake bootstrap (Windows/MSVC): builds the host tools (minilua,
@rem buildvm) and generates the arch-specific sources the premake projects
@rem consume. Transliteration of src\msvcbuild.bat, but generates into the
@rem given directory instead of src\ and always uses explicit arch flags.
@rem
@rem   luajit-bootstrap.bat {x86|x64|arm64} GENDIR VSDEVCMD [force]
@rem
@rem The host tools must run on the build machine at the TARGET's pointer
@rem width: x86 targets use x86 host tools (WOW64), x64/arm64 targets use
@rem x64 host tools (arm64 additionally passes /DLUAJIT_TARGET explicitly).
@setlocal
@set PLATFORM=%~1
@set GENDIR=%~2
@set VSDEVCMD=%~3
@set ROOT=%~dp0..

@set DASMTARGET=
@if "%PLATFORM%"=="x86" (
  set DASC=vm_x86.dasc
  set "DASMFLAGS=-D WIN -D JIT -D FFI -D ENDIAN_LE -D FPU"
  set VSARCH=x86
) else if "%PLATFORM%"=="x64" (
  set DASC=vm_x64.dasc
  set "DASMFLAGS=-D WIN -D JIT -D FFI -D ENDIAN_LE -D FPU -D P64"
  set VSARCH=x64
) else if "%PLATFORM%"=="arm64" (
  set DASC=vm_arm64.dasc
  set "DASMFLAGS=-D WIN -D JIT -D FFI -D ENDIAN_LE -D FPU -D P64"
  set "DASMTARGET=/DLUAJIT_TARGET=LUAJIT_ARCH_ARM64"
  set VSARCH=x64
) else (
  echo usage: %~nx0 {x86^|x64^|arm64} GENDIR VSDEVCMD [force]
  exit /b 2
)

@rem Get a host-arch cl on PATH regardless of the environment MSBuild set up
@rem for the target platform (mirrors msvcbuild.bat :SETHOSTVARS). The
@rem VsDevCmd path passed by premake ($(VsInstallRoot)) may be empty when
@rem MSBuild runs outside VS, so fall back to VSINSTALLDIR, then vswhere.
@if not exist "%VSDEVCMD%" if defined VSINSTALLDIR set "VSDEVCMD=%VSINSTALLDIR%Common7\Tools\VsDevCmd.bat"
@if not exist "%VSDEVCMD%" for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -find Common7\Tools\VsDevCmd.bat`) do @set "VSDEVCMD=%%i"
@set "VSCMD_START_DIR=%CD%"
@if exist "%VSDEVCMD%" call "%VSDEVCMD%" -no_logo -arch=%VSARCH%
@if not defined INCLUDE goto :FAIL

@set LJCOMPILE=cl /nologo /c /O2 /W3 /D_CRT_SECURE_NO_DEPRECATE /D_CRT_STDIO_INLINE=__declspec(dllexport)__inline
@set LJLINK=link /nologo
@rem Order matters: buildvm assigns fast-function IDs in file order
@rem (src\Makefile LJLIB_C, incl. this fork's lib_utf8.c - note that
@rem msvcbuild.bat's ALL_LIB is missing it).
@set ALL_LIB=lib_base.c lib_math.c lib_bit.c lib_string.c lib_table.c lib_io.c lib_os.c lib_package.c lib_debug.c lib_jit.c lib_ffi.c lib_buffer.c lib_utf8.c

@set TMP_DIR=%GENDIR%\.tmp
@if exist "%TMP_DIR%" rmdir /s /q "%TMP_DIR%"
@mkdir "%TMP_DIR%\host" 2>nul
@mkdir "%TMP_DIR%\jit" 2>nul
@mkdir "%GENDIR%\host" 2>nul
@mkdir "%GENDIR%\jit" 2>nul

@cd /d "%ROOT%\src"

%LJCOMPILE% /Fo"%TMP_DIR%\minilua.obj" host\minilua.c
@if errorlevel 1 goto :BAD
%LJLINK% /out:"%TMP_DIR%\host\minilua.exe" "%TMP_DIR%\minilua.obj"
@if errorlevel 1 goto :BAD
@set MINILUA=%TMP_DIR%\host\minilua.exe

if exist ..\.git ( git show -s --format=%%ct >"%TMP_DIR%\luajit_relver.txt" ) else ( type ..\.relver >"%TMP_DIR%\luajit_relver.txt" )
"%MINILUA%" host\genversion.lua luajit_rolling.h "%TMP_DIR%\luajit_relver.txt" "%TMP_DIR%\luajit.h"
@if errorlevel 1 goto :BAD

"%MINILUA%" ..\dynasm\dynasm.lua -LN %DASMFLAGS% -o "%TMP_DIR%\host\buildvm_arch.h" %DASC%
@if errorlevel 1 goto :BAD

%LJCOMPILE% /I "%TMP_DIR%" /I "%TMP_DIR%\host" /I "." /I ..\dynasm %DASMTARGET% /Fo"%TMP_DIR%\\" host\buildvm*.c
@if errorlevel 1 goto :BAD
%LJLINK% /out:"%TMP_DIR%\host\buildvm.exe" "%TMP_DIR%\buildvm*.obj"
@if errorlevel 1 goto :BAD
@set BUILDVM=%TMP_DIR%\host\buildvm.exe

"%BUILDVM%" -m peobj -o "%TMP_DIR%\lj_vm.obj"
@if errorlevel 1 goto :BAD
"%BUILDVM%" -m bcdef -o "%TMP_DIR%\lj_bcdef.h" %ALL_LIB%
@if errorlevel 1 goto :BAD
"%BUILDVM%" -m ffdef -o "%TMP_DIR%\lj_ffdef.h" %ALL_LIB%
@if errorlevel 1 goto :BAD
"%BUILDVM%" -m libdef -o "%TMP_DIR%\lj_libdef.h" %ALL_LIB%
@if errorlevel 1 goto :BAD
"%BUILDVM%" -m recdef -o "%TMP_DIR%\lj_recdef.h" %ALL_LIB%
@if errorlevel 1 goto :BAD
"%BUILDVM%" -m vmdef -o "%TMP_DIR%\jit\vmdef.lua" %ALL_LIB%
@if errorlevel 1 goto :BAD
"%BUILDVM%" -m folddef -o "%TMP_DIR%\lj_folddef.h" lj_opt_fold.c
@if errorlevel 1 goto :BAD

@rem Install only changed files, so unchanged timestamps don't make MSBuild
@rem recompile everything on every build.
@for %%f in (luajit.h luajit_relver.txt lj_vm.obj lj_bcdef.h lj_ffdef.h lj_libdef.h lj_recdef.h lj_folddef.h jit\vmdef.lua host\buildvm_arch.h) do @(
  fc /b "%TMP_DIR%\%%f" "%GENDIR%\%%f" >nul 2>&1
  if errorlevel 1 copy /y "%TMP_DIR%\%%f" "%GENDIR%\%%f" >nul
)
@copy /y "%MINILUA%" "%GENDIR%\host\" >nul
@copy /y "%BUILDVM%" "%GENDIR%\host\" >nul
@rmdir /s /q "%TMP_DIR%"

@echo LuaJIT bootstrap: %PLATFORM% done
@exit /b 0

:BAD
@echo *** LuaJIT bootstrap FAILED for %PLATFORM% ***
@exit /b 1
:FAIL
@echo LuaJIT bootstrap: no MSVC environment (VsDevCmd.bat not found at "%VSDEVCMD%")
@exit /b 1
