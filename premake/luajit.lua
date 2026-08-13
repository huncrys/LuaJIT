-- LuaJIT premake5 project definitions.
--
-- Designed to be included either from the standalone workspace in ../premake5.lua
-- or from an outer workspace (e.g. mtasa-blue's MTASA workspace). Defines:
--   luajit-bootstrap - host tools + generated sources (see premake/luajit-bootstrap.*)
--   luajit           - static library (libluajit.a / luajit.lib)
--   luajit-shared    - shared library (libluajit.so / lua51.dll)
--   luajit-cli       - luajit interpreter executable

local root = path.getabsolute(path.join(path.getdirectory(_SCRIPT), ".."))

local function gendir(plat)
	return path.join(root, "build/gen", os.target() .. "_" .. plat)
end

local platforms
if os.target() == "windows" then
	platforms = { "x86", "x64", "arm64" }
else
	platforms = { "x86", "x64", "arm", "arm64" }
end

-- Order matters for the lib_*.c list: buildvm assigns fast-function IDs in
-- file order (src/Makefile LJLIB_C, incl. this fork's lib_utf8.c).
local LJLIB_SOURCES = {
	"lib_base.c", "lib_math.c", "lib_bit.c", "lib_string.c", "lib_table.c",
	"lib_io.c", "lib_os.c", "lib_package.c", "lib_debug.c", "lib_jit.c",
	"lib_ffi.c", "lib_buffer.c", "lib_utf8.c",
}

-- src/Makefile LJCORE_O (minus lj_vm.o, which comes from the bootstrap).
local LJCORE_SOURCES = {
	"lj_assert.c", "lj_gc.c", "lj_err.c", "lj_char.c", "lj_bc.c", "lj_obj.c",
	"lj_buf.c", "lj_str.c", "lj_tab.c", "lj_func.c", "lj_udata.c",
	"lj_meta.c", "lj_debug.c", "lj_prng.c", "lj_state.c", "lj_dispatch.c",
	"lj_vmevent.c", "lj_vmmath.c", "lj_strscan.c", "lj_strfmt.c",
	"lj_strfmt_num.c", "lj_serialize.c", "lj_api.c", "lj_profile.c",
	"lj_lex.c", "lj_parse.c", "lj_bcread.c", "lj_bcwrite.c", "lj_load.c",
	"lj_ir.c", "lj_opt_mem.c", "lj_opt_fold.c", "lj_opt_narrow.c",
	"lj_opt_dce.c", "lj_opt_loop.c", "lj_opt_split.c", "lj_opt_sink.c",
	"lj_mcode.c", "lj_snap.c", "lj_record.c", "lj_crecord.c",
	"lj_ffrecord.c", "lj_asm.c", "lj_trace.c", "lj_gdbjit.c", "lj_ctype.c",
	"lj_cdata.c", "lj_cconv.c", "lj_ccall.c", "lj_ccallback.c",
	"lj_carith.c", "lj_clib.c", "lj_cparse.c", "lj_lib.c", "lj_alloc.c",
	"lib_aux.c", "lib_init.c",
}

-- Compiler/include setup shared by all target projects (not the file list:
-- the CLI compiles only luajit.c but needs the same flags and include path).
local function luajit_flags()
	language "C"
	dependson "luajit-bootstrap"

	for _, plat in ipairs(platforms) do
		filter { "platforms:" .. plat }
			-- gendir first: the generated luajit.h/lj_*.h must win over any
			-- stale artifacts a previous in-tree `make` left in src/.
			includedirs { gendir(plat), path.join(root, "src") }
			if os.target() ~= "windows" then
				forceincludes { path.join(gendir(plat), "luajit_buildflags.h") }
			end
	end

	filter "system:not windows"
		pic "On"
		defines { "_FILE_OFFSET_BITS=64", "_LARGEFILE_SOURCE" }
		buildoptions { "-U_FORTIFY_SOURCE", "-fno-stack-protector", "-fomit-frame-pointer" }
	filter { "system:not windows", "platforms:x86" }
		buildoptions { "-march=i686", "-msse", "-msse2", "-mfpmath=sse" }
	filter "system:windows"
		defines { "_CRT_SECURE_NO_DEPRECATE", "_CRT_STDIO_INLINE=__declspec(dllexport)__inline" }
	filter { "system:windows", "platforms:x86" }
		vectorextensions "SSE2"
	filter {}
end

-- Full library source set: core + libs + the bootstrap-generated VM object.
local function luajit_lib_sources()
	local srcs = {}
	for _, f in ipairs(LJCORE_SOURCES) do table.insert(srcs, path.join(root, "src", f)) end
	for _, f in ipairs(LJLIB_SOURCES) do table.insert(srcs, path.join(root, "src", f)) end
	files(srcs)

	for _, plat in ipairs(platforms) do
		filter { "platforms:" .. plat }
			if os.target() == "windows" then
				-- .obj in files{} is not treated as a link input by the VS
				-- exporter; pass it to lib.exe/link.exe as an option instead.
				linkoptions { '"' .. path.translate(path.join(gendir(plat), "lj_vm.obj")) .. '"' }
			else
				files { path.join(gendir(plat), "lj_vm.S") }
			end
	end
	filter {}
end

project "luajit-bootstrap"
	kind "Makefile"

	for _, plat in ipairs(platforms) do
		local g = gendir(plat)
		filter { "platforms:" .. plat }
		if os.target() == "windows" then
			local bat = 'call "' .. path.translate(root) .. '\\premake\\luajit-bootstrap.bat" '
				.. plat .. ' "' .. path.translate(g) .. '" "$(VsInstallRoot)\\Common7\\Tools\\VsDevCmd.bat"'
			buildcommands { bat }
			rebuildcommands { bat .. " force" }
			cleancommands { 'if exist "' .. path.translate(g) .. '" rmdir /s /q "' .. path.translate(g) .. '"' }
		else
			-- $$CC becomes $CC in the recipe shell: make exports command-line
			-- and environment CC, but its built-in default (cc) is not
			-- exported, so the script's own per-platform defaults apply then.
			local sh = 'bash "' .. root .. '/premake/luajit-bootstrap.sh" --platform ' .. plat
				.. ' --gendir "' .. g .. '" --root "' .. root .. '" --cc "$$CC"'
			buildcommands { sh }
			rebuildcommands { sh .. " --force" }
			cleancommands { 'rm -rf "' .. g .. '"' }
		end
	end
	filter {}

project "luajit"
	kind "StaticLib"
	targetname "luajit"
	luajit_flags()
	luajit_lib_sources()
	filter "system:not windows"
		targetprefix "lib"
	filter {}

project "luajit-shared"
	kind "SharedLib"
	luajit_flags()
	luajit_lib_sources()
	filter "system:not windows"
		targetname "luajit"
		targetprefix "lib"
		links { "m", "dl" }
	filter "system:windows"
		targetname "lua51"
		defines { "LUA_BUILD_AS_DLL" }
	filter {}

project "luajit-cli"
	kind "ConsoleApp"
	targetname "luajit"
	luajit_flags()
	files { path.join(root, "src/luajit.c") }
	filter "system:not windows"
		links { "luajit", "m", "dl" }
		linkoptions { "-Wl,-E" }
	filter "system:windows"
		links { "luajit-shared" }
		-- The exe exports symbols (via _CRT_STDIO_INLINE), so link.exe emits
		-- an import lib for it; keep that out of the target dir where it
		-- would overwrite the static luajit.lib.
		linkoptions { '/IMPLIB:"%{cfg.objdir}\\luajit.lib"' }
	filter {}
