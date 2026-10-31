#!/usr/bin/env bash
# BuildCoreClrSDK.sh — build CoreCLR + BCL from dotnet/runtime source and populate the
# SDK platform directory.
#
# Usage:
#   ./BuildCoreClrSDK.sh <dotnet-runtime-dir> <platform> [build-type] [arch]
#
# Arguments:
#   dotnet-runtime-dir  Path to the dotnet/runtime repository clone
#   platform            android | ios | iossimulator
#                       Only the platforms UnrealSharp actually consumes are listed:
#                       desktop runs the upstream hostfxr host and needs no SDK.
#   build-type          Debug (default) | Release
#   arch                arm64 (default) | x64
#                       x64 is only meaningful for iossimulator.
#
# Output layout (same convention as MonoSDK/<Platform>/<arch>/):
#   Android/arm64/  IOS/arm64/  IOSSimulator/arm64/
#     lib/       native runtime + interop libraries
#     runtime/   BCL managed assemblies
#     VERSION.txt
#
# The build subset comes from DotNetRuntime.version (BUILD_SUBSET) — a single source of
# truth shared with CI and CopySDKFromSrc.sh. Adding subsets here and in the workflow
# separately is exactly how the two drifted apart before.
#
# Examples:
#   ./BuildCoreClrSDK.sh ~/dotnet-runtime android        Release
#   ./BuildCoreClrSDK.sh ~/dotnet-runtime ios            Release
#   ./BuildCoreClrSDK.sh ~/dotnet-runtime iossimulator   Release

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
RUNTIME_DIR="${1:-}"
PLATFORM="${2:-}"
if [[ -z "$RUNTIME_DIR" || -z "$PLATFORM" ]]; then
    echo "Error: missing required arguments." >&2
    echo "Usage: $0 <dotnet-runtime-dir> <platform> [build-type] [arch]" >&2
    echo "       platform: android | ios | iossimulator" >&2
    exit 1
fi
RUNTIME_DIR="$(cd "$RUNTIME_DIR" && pwd)"

# Build type: Debug (default) or Release, capitalised for dotnet/runtime artifact paths.
BUILD_TYPE_RAW="${3:-Debug}"
BUILD_TYPE_LOWER="$(echo "$BUILD_TYPE_RAW" | tr '[:upper:]' '[:lower:]')"
case "$BUILD_TYPE_LOWER" in
    debug)   BUILD_TYPE="Debug" ;;
    release) BUILD_TYPE="Release" ;;
    *)
        echo "Error: unknown build-type '$BUILD_TYPE_RAW'. Use Debug or Release." >&2
        exit 1
        ;;
esac

# Host platform/arch, used for the cross-build NuGet cache reset below.
case "$(uname -s)" in
    Darwin) HOST_OS="osx" ;;
    Linux)  HOST_OS="linux" ;;
    *)      HOST_OS="windows" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) HOST_ARCH="arm64" ;;
    x86_64|amd64)  HOST_ARCH="x64" ;;
    *)             HOST_ARCH="x64" ;;
esac
ARCH="${4:-arm64}"

SDK_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Platform/arch matrix ──────────────────────────────────────────────────────
# Reject anything dotnet/runtime cannot build, so a typo fails here instead of
# producing a half-populated SDK that only fails on device.
case "$PLATFORM/$ARCH" in
    android/arm64|ios/arm64|iossimulator/arm64|iossimulator/x64) ;;
    *)
        echo "Error: unsupported platform/arch combination '$PLATFORM/$ARCH'." >&2
        echo "Supported: android/arm64 ios/arm64 iossimulator/{arm64,x64}" >&2
        exit 1
        ;;
esac

# dotnet/runtime spells the simulator OS "iossimulator" — same as the SDK directory.
DOTNET_OS="$PLATFORM"

# ── Subset (single source of truth) ───────────────────────────────────────────
VERSION_FILE="$SDK_DIR/DotNetRuntime.version"
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Error: $VERSION_FILE not found." >&2
    exit 1
fi
BUILD_SUBSET="$(grep -E '^BUILD_SUBSET=' "$VERSION_FILE" | cut -d= -f2- | tr -d '\r')"
if [[ -z "$BUILD_SUBSET" ]]; then
    echo "Error: BUILD_SUBSET is empty in $VERSION_FILE." >&2
    exit 1
fi

echo "=== BuildCoreClrSDK ==="
echo "  Source    : $RUNTIME_DIR"
echo "  Platform  : $PLATFORM (dotnet -os $DOTNET_OS)"
echo "  Arch      : $ARCH"
echo "  Build type: $BUILD_TYPE"
echo "  Subsets   : $BUILD_SUBSET"
echo "  SDK dir   : $SDK_DIR"
echo ""

cd "$RUNTIME_DIR"

# ── Cross-build NuGet cache reset ─────────────────────────────────────────────
# Cross-platform/arch builds leave stale restore caches that reference the host TFM
# (e.g. net11.0-osx) and fail with NETSDK1005. Same fix as MonoSDK/BuildMonoSDK.sh.
if [[ "$DOTNET_OS" != "$HOST_OS" || "$ARCH" != "$HOST_ARCH" ]]; then
    echo ">>> Clearing stale NuGet restore caches for cross-platform build..."
    rm -f "$RUNTIME_DIR/artifacts/obj/sfx-src/project.assets.json"
    rm -f "$RUNTIME_DIR/artifacts/obj/sfx-finish/project.assets.json"
fi

# ── Apple-mobile: drop the -Static interop install that the graph does not build ──
# .NET 11 extended the runtime-component install of libs -Static libraries to iOS
# device AND iOS Simulator (System.IO.Compression.Native / System.Native /
# System.Globalization.Native), but those targets are not in the default build graph
# there, so cmake install fails with FILE_NOT_FOUND (first hit on CI:
# iossimulator rc.3, 2026-10-30). The SDK does not consume the -Static outputs.
# Idempotent: the pattern is gone after the first run.
if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "iossimulator" ]]; then
    echo ">>> Patching libs-native runtime installs for $PLATFORM..."
    # The pattern is .NET 11-only; on release/10.0 there is nothing to patch, and
    # `grep` returning 1 would abort this script under `set -o pipefail`.
    PATCHED=$(grep -rl "CLR_CMAKE_HOST_IOS OR " "$RUNTIME_DIR"/src/native/libs/*/CMakeLists.txt 2>/dev/null || true)
    if [ -n "$PATCHED" ]; then
        printf '%s\n' "$PATCHED" | xargs sed -i.bak 's/CLR_CMAKE_HOST_IOS OR //'
        echo "    patched: $(printf '%s\n' "$PATCHED" | wc -l | tr -d ' ') file(s)"
    else
        echo "    nothing to patch on this runtime branch (skipped)"
    fi
fi

# ── Build ─────────────────────────────────────────────────────────────────────
# NuGet audit advisories must not fail the build: dotnet/runtime treats them as errors,
# so a new advisory against a *build-time tooling* package would break the SDK with no
# change on our side. %3B is MSBuild's escape for ';' (a literal ';' splits the /p: value
# into several properties and fails with MSB1006). Same rationale as MonoSDK.
#
# iOS keeps the default feature set. Measured on device, builds with and without
# -DFEATURE_DYNAMIC_CODE_COMPILED behave identically (iOS runs the interpreter either
# way), so passing /p:FeatureDynamicCodeCompiled=false added no value and was reverted.
#
# The argument list is built before expansion: macOS ships bash 3.2, where
# `"${empty_array[@]}"` under `set -u` aborts with "unbound variable".
BUILD_ARGS=(
    "$BUILD_SUBSET"
    -os "$DOTNET_OS"
    -arch "$ARCH"
    -configuration "$BUILD_TYPE"
    "/p:WarningsNotAsErrors=NU1901%3BNU1902%3BNU1903%3BNU1904"
)

# The native build keeps its generator choice in CMakeCache.txt. Reusing a tree that
# was configured with Ninja while this invocation would default to Unix Makefiles
# aborts with "generator does not match", so pin Ninja whenever it is available —
# that is also what the earlier successful SDK trees were built with.
if command -v ninja >/dev/null 2>&1 || command -v ninja-build >/dev/null 2>&1; then
    BUILD_ARGS+=(-ninja)
    echo ">>> Using Ninja generator ($(command -v ninja || command -v ninja-build))"
else
    echo ">>> Ninja not found; using the default CMake generator"
fi

echo ">>> Building CoreCLR + libs for $PLATFORM ($ARCH, $BUILD_TYPE)..."
./build.sh "${BUILD_ARGS[@]}"

echo ""
echo ">>> Build complete. Populating the SDK directory..."
bash "$SDK_DIR/CopyCoreClrSDKFromSrc.sh" "$RUNTIME_DIR" "$PLATFORM" "$BUILD_TYPE" "$ARCH"
