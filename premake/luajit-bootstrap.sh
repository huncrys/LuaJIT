#!/bin/bash
# LuaJIT premake bootstrap (Linux): builds the host tools (minilua, buildvm)
# and generates the arch-specific sources the premake projects consume.
#
# This is a transliteration of the corresponding parts of src/Makefile
# (target probe, DASM flag derivation, generated-file rules). The host tools
# must be runnable on the build host but compiled at the TARGET's pointer
# width and with the target's arch defines, because buildvm embeds
# target-sized structures and target VM code.
#
# Outputs (into --gendir):
#   luajit.h lj_bcdef.h lj_ffdef.h lj_libdef.h lj_recdef.h lj_folddef.h
#   lj_vm.S jit/vmdef.lua luajit_buildflags.h luajit_relver.txt
#   host/minilua host/buildvm host/buildvm_arch.h
set -eu

usage() {
	echo "usage: $0 --platform {x86|x64|arm|arm64} --gendir DIR --root DIR [--cc CC] [--force]" >&2
	exit 2
}

PLATFORM= GENDIR= ROOT= TARGET_CC_ARG= FORCE=
while [ $# -gt 0 ]; do
	case "$1" in
		--platform) PLATFORM=$2; shift 2 ;;
		--gendir) GENDIR=$2; shift 2 ;;
		--root) ROOT=$2; shift 2 ;;
		--cc) TARGET_CC_ARG=$2; shift 2 ;;
		--force) FORCE=1; shift ;;
		*) usage ;;
	esac
done
[ -n "$PLATFORM" ] && [ -n "$GENDIR" ] && [ -n "$ROOT" ] || usage
case "$PLATFORM" in x86|x64|arm|arm64) ;; *) usage ;; esac

ROOT=$(cd "$ROOT" && pwd)
GCC_VERSION=${GCC_VERSION:-10}

case "$PLATFORM" in
	x86|arm) TARGET_BITS=32 ;;
	x64|arm64) TARGET_BITS=64 ;;
esac

# First candidate whose command exists on PATH (candidates may carry flags).
pick_cc() {
	local candidate
	for candidate in "$@"; do
		if command -v "${candidate%% *}" >/dev/null 2>&1; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

# Target compiler: explicit arg, then env, then per-platform defaults.
TARGET_CC=${TARGET_CC_ARG:-${LUAJIT_CC:-${CC:-}}}
if [ -z "$TARGET_CC" ]; then
	case "$PLATFORM" in
		x86) TARGET_CC=$(pick_cc "i686-linux-gnu-gcc-$GCC_VERSION" i686-linux-gnu-gcc "gcc -m32") ;;
		x64) TARGET_CC=$(pick_cc "x86_64-linux-gnu-gcc-$GCC_VERSION" x86_64-linux-gnu-gcc gcc) ;;
		arm) TARGET_CC=$(pick_cc "arm-linux-gnueabihf-gcc-$GCC_VERSION" arm-linux-gnueabihf-gcc) ;;
		arm64) TARGET_CC=$(pick_cc "aarch64-linux-gnu-gcc-$GCC_VERSION" aarch64-linux-gnu-gcc gcc) ;;
	esac || { echo "$0: no target compiler found for $PLATFORM (set CC or LUAJIT_CC)" >&2; exit 1; }
fi

# Host compiler: must produce binaries that run on this machine, at the
# target's bit-width. Prefer a dedicated cross package, fall back to
# multilib -m32/-m64. arm<->aarch64 has no multilib equivalent, so a
# 32-bit target on an aarch64 host needs the real arm cross-compiler.
HOST_CC=${LUAJIT_HOST_CC:-}
if [ -z "$HOST_CC" ]; then
	case "$(uname -m)" in
		x86_64|amd64)
			if [ "$TARGET_BITS" = 32 ]; then
				HOST_CC=$(pick_cc \
					"i686-linux-gnu-gcc-$GCC_VERSION -m32" "i686-linux-gnu-gcc -m32" \
					"gcc-$GCC_VERSION -m32" "gcc -m32")
			else
				HOST_CC=$(pick_cc \
					"x86_64-linux-gnu-gcc-$GCC_VERSION -m64" "x86_64-linux-gnu-gcc -m64" \
					"gcc-$GCC_VERSION -m64" "gcc -m64")
			fi ;;
		aarch64|arm64)
			if [ "$TARGET_BITS" = 32 ]; then
				HOST_CC=$(pick_cc "arm-linux-gnueabihf-gcc-$GCC_VERSION" arm-linux-gnueabihf-gcc)
			else
				HOST_CC=$(pick_cc "aarch64-linux-gnu-gcc-$GCC_VERSION" aarch64-linux-gnu-gcc "gcc-$GCC_VERSION" gcc)
			fi ;;
	esac || { echo "$0: no host compiler for a $TARGET_BITS-bit target on $(uname -m) (set LUAJIT_HOST_CC)" >&2; exit 1; }
fi

# Target probe, same as src/Makefile TARGET_TESTARCH: everything below is
# derived from the target compiler's macro dump of lj_arch.h.
PROBE_CFLAGS="-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -U_FORTIFY_SOURCE"
TESTARCH=$($TARGET_CC $PROBE_CFLAGS -E "$ROOT/src/lj_arch.h" -dM) ||
	{ echo "$0: target probe failed: $TARGET_CC -E lj_arch.h" >&2; exit 1; }

has() { case "$TESTARCH" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

if has "LJ_TARGET_X64 "; then LJARCH=x64
elif has "LJ_TARGET_X86 "; then LJARCH=x86
elif has "LJ_TARGET_ARM "; then LJARCH=arm
elif has "LJ_TARGET_ARM64 "; then LJARCH=arm64
else
	echo "$0: unsupported target architecture (compiler: $TARGET_CC)" >&2
	exit 1
fi
if [ "$LJARCH" != "$PLATFORM" ]; then
	echo "$0: compiler '$TARGET_CC' targets $LJARCH but platform is $PLATFORM (wrong CC?)" >&2
	exit 1
fi

DASM_FLAGS=
TARGET_ARCH="-DLUAJIT_TARGET=LUAJIT_ARCH_$LJARCH"
if [ "$LJARCH" = arm64 ] && has "__AARCH64EB__ "; then
	TARGET_ARCH="$TARGET_ARCH -D__AARCH64EB__=1"
fi
if has "LJ_LE 1"; then DASM_FLAGS="$DASM_FLAGS -D ENDIAN_LE"; else DASM_FLAGS="$DASM_FLAGS -D ENDIAN_BE"; fi
if has "LJ_ARCH_BITS 64"; then DASM_FLAGS="$DASM_FLAGS -D P64"; fi
if has "LJ_HASJIT 1"; then DASM_FLAGS="$DASM_FLAGS -D JIT"; fi
if has "LJ_HASFFI 1"; then DASM_FLAGS="$DASM_FLAGS -D FFI"; fi
if has "LJ_DUALNUM 1"; then DASM_FLAGS="$DASM_FLAGS -D DUALNUM"; fi
if has "LJ_ARCH_HASFPU 1"; then
	DASM_FLAGS="$DASM_FLAGS -D FPU"
	TARGET_ARCH="$TARGET_ARCH -DLJ_ARCH_HASFPU=1"
else
	TARGET_ARCH="$TARGET_ARCH -DLJ_ARCH_HASFPU=0"
fi
if has "LJ_ABI_SOFTFP 1"; then
	TARGET_ARCH="$TARGET_ARCH -DLJ_ABI_SOFTFP=1"
else
	DASM_FLAGS="$DASM_FLAGS -D HFABI"
	TARGET_ARCH="$TARGET_ARCH -DLJ_ABI_SOFTFP=0"
fi
if has "LJ_NO_UNWIND 1"; then
	DASM_FLAGS="$DASM_FLAGS -D NO_UNWIND"
	TARGET_ARCH="$TARGET_ARCH -DLUAJIT_NO_UNWIND"
fi
if has "LJ_ABI_PAUTH 1"; then
	DASM_FLAGS="$DASM_FLAGS -D PAUTH"
	TARGET_ARCH="$TARGET_ARCH -DLJ_ABI_PAUTH=1"
fi
if has "LJ_ABI_BRANCH_TRACK 1"; then
	DASM_FLAGS="$DASM_FLAGS -D BRANCH_TRACK"
	TARGET_ARCH="$TARGET_ARCH -DLJ_ABI_BRANCH_TRACK=1"
fi
if has "LJ_ABI_SHADOW_STACK 1"; then
	DASM_FLAGS="$DASM_FLAGS -D SHADOW_STACK"
	TARGET_ARCH="$TARGET_ARCH -DLJ_ABI_SHADOW_STACK=1"
fi
ARCH_VERSION=$(echo "$TESTARCH" | sed -n 's/.*LJ_ARCH_VERSION \([0-9]*\).*/\1/p' | head -n1)
DASM_FLAGS="$DASM_FLAGS -D VER=$ARCH_VERSION"

DASM_ARCH=$LJARCH
if [ "$LJARCH" = x64 ] && ! has "LJ_FR2 1"; then
	DASM_ARCH=x86
fi

# Whether the target toolchain always generates unwind tables (src/Makefile
# TARGET_TESTUNWIND). The result affects target compiles, so it is delivered
# via the generated luajit_buildflags.h instead of a compiler flag.
UNWIND_EXTERNAL=
if ! has "LJ_NO_UNWIND 1"; then
	UNWIND_TMP=$(mktemp /tmp/luajit-unwind-XXXXXX.o)
	if echo 'extern void b(void);int a(void){b();return 0;}' |
		$TARGET_CC -c -x c - -o "$UNWIND_TMP" 2>/dev/null &&
		grep -qa -e eh_frame -e __unwind_info "$UNWIND_TMP" 2>/dev/null; then
		UNWIND_EXTERNAL=1
	fi
	rm -f "$UNWIND_TMP"
fi

# Order matters: fast-function IDs are assigned in file order (src/Makefile
# LJLIB_C, incl. this fork's lib_utf8.c).
LJLIB_C="lib_base.c lib_math.c lib_bit.c lib_string.c lib_table.c lib_io.c
	lib_os.c lib_package.c lib_debug.c lib_jit.c lib_ffi.c lib_buffer.c
	lib_utf8.c"

RELVER=$(git -C "$ROOT" show -s --format=%ct 2>/dev/null || cat "$ROOT/.relver" 2>/dev/null || :)

# Up-to-date check: skip regeneration when the configuration fingerprint is
# unchanged and no input is newer than the stamp.
STAMP=$GENDIR/.stamp
FINGERPRINT="platform=$PLATFORM
target_cc=$TARGET_CC
host_cc=$HOST_CC
dasm_arch=$DASM_ARCH
dasm_flags=$DASM_FLAGS
target_arch=$TARGET_ARCH
unwind_external=$UNWIND_EXTERNAL
relver=$RELVER"
if [ -z "$FORCE" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$FINGERPRINT" ] &&
	[ -z "$(find "$ROOT/src" "$ROOT/dynasm" -type f -newer "$STAMP" -print -quit)" ]; then
	echo "LuaJIT bootstrap: $PLATFORM up to date"
	exit 0
fi

echo "LuaJIT bootstrap: $PLATFORM (target: $TARGET_CC, host: $HOST_CC)"
echo "  dasm: vm_$DASM_ARCH.dasc$DASM_FLAGS"

TMP=$GENDIR/.tmp
rm -rf "$TMP"
mkdir -p "$TMP/host" "$TMP/jit" "$GENDIR/host" "$GENDIR/jit"

HOST_CFLAGS="-O2 -Wall"

printf '%s\n' "$RELVER" >"$TMP/luajit_relver.txt"
$HOST_CC $HOST_CFLAGS -o "$TMP/host/minilua" "$ROOT/src/host/minilua.c" -lm
MINILUA=$TMP/host/minilua
"$MINILUA" "$ROOT/src/host/genversion.lua" "$ROOT/src/luajit_rolling.h" \
	"$TMP/luajit_relver.txt" "$TMP/luajit.h"

# Run from src/ like the Makefile does: dynasm embeds the .dasc path in its
# output, and buildvm resolves the lib .c arguments relative to the cwd.
cd "$ROOT/src"
"$MINILUA" "$ROOT/dynasm/dynasm.lua" $DASM_FLAGS \
	-o "$TMP/host/buildvm_arch.h" "vm_$DASM_ARCH.dasc"
$HOST_CC $HOST_CFLAGS -I "$TMP" -I "$TMP/host" -I "$ROOT/src" $TARGET_ARCH \
	-o "$TMP/host/buildvm" "$ROOT/src/host/buildvm"*.c
BUILDVM=$TMP/host/buildvm
"$BUILDVM" -m elfasm -o "$TMP/lj_vm.S"
"$BUILDVM" -m bcdef -o "$TMP/lj_bcdef.h" $LJLIB_C
"$BUILDVM" -m ffdef -o "$TMP/lj_ffdef.h" $LJLIB_C
"$BUILDVM" -m libdef -o "$TMP/lj_libdef.h" $LJLIB_C
"$BUILDVM" -m recdef -o "$TMP/lj_recdef.h" $LJLIB_C
"$BUILDVM" -m vmdef -o "$TMP/jit/vmdef.lua" $LJLIB_C
"$BUILDVM" -m folddef -o "$TMP/lj_folddef.h" lj_opt_fold.c

if [ -n "$UNWIND_EXTERNAL" ]; then
	echo "#define LUAJIT_UNWIND_EXTERNAL 1" >"$TMP/luajit_buildflags.h"
else
	: >"$TMP/luajit_buildflags.h"
fi

# Install only changed files, so unchanged mtimes don't force the compiler's
# dependency tracking to rebuild the world.
install_if_changed() {
	if ! cmp -s "$TMP/$1" "$GENDIR/$1"; then
		cp "$TMP/$1" "$GENDIR/$1"
	fi
}
for f in luajit.h luajit_relver.txt luajit_buildflags.h lj_vm.S \
	lj_bcdef.h lj_ffdef.h lj_libdef.h lj_recdef.h lj_folddef.h \
	jit/vmdef.lua host/buildvm_arch.h; do
	install_if_changed "$f"
done
cp "$TMP/host/minilua" "$TMP/host/buildvm" "$GENDIR/host/"
rm -rf "$TMP"
printf '%s' "$FINGERPRINT" >"$STAMP"
echo "LuaJIT bootstrap: $PLATFORM done"
