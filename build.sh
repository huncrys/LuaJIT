#!/bin/bash
# Standalone premake build wrapper, modeled on mtasa-blue's linux-build.sh.
# Generates the gmake files with the bundled premake5 and builds one
# architecture/config, selecting the matching cross toolchain.
#
#   ./build.sh [--arch=x86|x64|arm|arm64] [--config=debug|release]
#
# Environment: CC (target compiler override), LUAJIT_HOST_CC (host-tool
# compiler override for the bootstrap), GCC_VERSION (suffix for versioned
# cross packages, e.g. 10 for i686-linux-gnu-gcc-10).
set -eu

cd "$(dirname "$0")"

ARCH=x64
CONFIG=release
for arg in "$@"; do
	case "$arg" in
		--arch=*) ARCH=${arg#*=} ;;
		--config=*) CONFIG=${arg#*=} ;;
		*) echo "usage: $0 [--arch=x86|x64|arm|arm64] [--config=debug|release]" >&2; exit 2 ;;
	esac
done

case "$ARCH" in
	x86) TRIPLE=i686-linux-gnu ;;
	x64) TRIPLE=x86_64-linux-gnu ;;
	arm) TRIPLE=arm-linux-gnueabihf ;;
	arm64) TRIPLE=aarch64-linux-gnu ;;
	*) echo "$0: unknown arch '$ARCH'" >&2; exit 2 ;;
esac

pick() {
	local candidate
	for candidate in "$@"; do
		if command -v "$candidate" >/dev/null 2>&1; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

if [ -z "${CC:-}" ]; then
	CC=$(pick ${GCC_VERSION:+"$TRIPLE-gcc-$GCC_VERSION"} "$TRIPLE-gcc" gcc) ||
		{ echo "$0: no compiler for $ARCH (install $TRIPLE-gcc or set CC)" >&2; exit 1; }
fi
AR=$(pick "$TRIPLE-ar" "${CC%-gcc*}-ar" ar)

export CC
export GCC_VERSION="${GCC_VERSION:-}"

PREMAKE5=${PREMAKE5:-./utils/premake5}
[ -x "$PREMAKE5" ] || { echo "$0: premake5 not found at $PREMAKE5" >&2; exit 1; }

"$PREMAKE5" --os=linux gmake
make -C Build -j"$(nproc)" config="${CONFIG}_${ARCH}" CC="$CC" AR="$AR"
