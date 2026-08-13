-- Standalone premake5 workspace for LuaJIT.
--
-- Generate with the bundled premake: ./utils/premake5 gmake (Linux) or
-- utils\premake5.exe vs2022 (Windows), or use ./build.sh. When this file is
-- included from an outer workspace (e.g. mtasa-blue), the workspace block is
-- skipped and only the projects are defined.

if premake.api.scope.workspace == nil then
	workspace "LuaJIT"
		configurations { "Debug", "Release" }
		if os.target() == "windows" then
			platforms { "x86", "x64", "arm64" }
		else
			platforms { "x86", "x64", "arm", "arm64" }
		end
		location "Build"
		symbols "On"
		targetdir "Bin/%{cfg.platform}/%{cfg.buildcfg}"

		filter "platforms:x86"
			architecture "x86"
		filter "platforms:x64"
			architecture "x86_64"
		filter "platforms:arm"
			architecture "ARM"
		filter "platforms:arm64"
			architecture "ARM64"
		filter "configurations:Release"
			optimize "On"
		filter {}
end

include "premake/luajit.lua"
