#!/usr/bin/env bash
# CopySDKFromSrc.sh
# Copy Mono SDK artifacts from dotnet/runtime build output into this SDK repository's
# platform subdirectory.
#
# This script does NOT build dotnet/runtime — it only copies pre-built artifacts.
# Use this in CI workflows where the build step is done separately.
#
# Usage:
#   ./CopySDKFromSrc.sh <dotnet-src-dir> <platform> [build-type] [arch]
#
# Arguments:
#   dotnet-src-dir   Path to the dotnet/runtime repository root (must be already built).
#   platform         Target platform: macos | android | ios | iossimulator | linux
#   build-type       Debug (default) | Release
#   arch             x64 | arm64 (defaults to the host architecture).
#                    Cross-arch builds must pass it explicitly.
#
# Output layout matches BuildMonoSDK.sh: arch-qualified dirs for the platforms that
# ship more than one architecture (Mac/<arch>, IOSSimulator/<arch>), flat dirs for
# the single-arch platforms (Win64, Android, IOS, Linux).
#
# Examples:
#   ./CopySDKFromSrc.sh ~/dotnet-runtime macos Release x64
#   ./CopySDKFromSrc.sh ~/dotnet-runtime macos Release arm64
#   ./CopySDKFromSrc.sh ~/dotnet-runtime iossimulator Release arm64
#   ./CopySDKFromSrc.sh ~/dotnet-runtime linux Debug

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
DOTNET_SRC="${1:-}"
PLATFORM="${2:-}"
if [[ -z "$DOTNET_SRC" || -z "$PLATFORM" ]]; then
    echo "Error: missing required arguments." >&2
    echo "Usage: $0 <dotnet-src-dir> <platform> [build-type] [arch]" >&2
    exit 1
fi
DOTNET_SRC="$(cd "$DOTNET_SRC" && pwd)"

# Build type: Debug (default) or Release.
BUILD_TYPE_RAW="${3:-Debug}"
BUILD_TYPE_LOWER="$(echo "$BUILD_TYPE_RAW" | tr '[:upper:]' '[:lower:]')"
case "$BUILD_TYPE_LOWER" in
    debug)   BUILD_TYPE="Debug" ;;
    release) BUILD_TYPE="Release" ;;
    *)
        echo "Error: unknown build-type '${BUILD_TYPE_RAW}'. Use Debug or Release." >&2
        exit 1
        ;;
esac

# Host architecture, used as the default target arch (native build).
case "$(uname -m)" in
    arm64|aarch64) HOST_ARCH="arm64" ;;
    x86_64|amd64)  HOST_ARCH="x64" ;;
    *)             HOST_ARCH="x64" ;;
esac
ARCH="${4:-$HOST_ARCH}"

case "$ARCH" in
    x64|arm64) ;;
    *)
        echo "Error: unknown arch '$ARCH'. Use x64 or arm64." >&2
        exit 1
        ;;
esac

SDK_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== CopySDKFromSrc ==="
echo "  Source    : $DOTNET_SRC"
echo "  Platform  : $PLATFORM"
echo "  Arch      : $ARCH"
echo "  Build type: $BUILD_TYPE"
echo "  SDK dir   : $SDK_DIR"
echo ""

# ── Platform/arch matrix ─────────────────────────────────────────────────────
case "$PLATFORM/$ARCH" in
    macos/x64|macos/arm64|ios/arm64|iossimulator/x64|iossimulator/arm64|android/arm64|linux/x64) ;;
    *)
        echo "Error: unsupported platform/arch combination '$PLATFORM/$ARCH'." >&2
        echo "Supported: macos/{x64,arm64} ios/arm64 iossimulator/{x64,arm64} android/arm64 linux/x64" >&2
        exit 1
        ;;
esac

# ── Set platform-specific variables ──────────────────────────────────────────
SRC_ARTIFACTS="$DOTNET_SRC/artifacts"

case "$PLATFORM/$ARCH" in
    macos/x64)
        MONO_TRIPLE="osx.x64.$BUILD_TYPE"
        RUNTIME_TFM="net10.0-osx-$BUILD_TYPE-x64"
        NATIVE_TFM="net10.0-osx-$BUILD_TYPE-x64"
        ;;
    macos/arm64)
        MONO_TRIPLE="osx.arm64.$BUILD_TYPE"
        RUNTIME_TFM="net10.0-osx-$BUILD_TYPE-arm64"
        NATIVE_TFM="net10.0-osx-$BUILD_TYPE-arm64"
        ;;
    ios/arm64)
        MONO_TRIPLE="ios.arm64.$BUILD_TYPE"
        RUNTIME_TFM="net10.0-ios-$BUILD_TYPE-arm64"
        NATIVE_TFM="net10.0-ios-$BUILD_TYPE-arm64"
        ;;
    iossimulator/x64)
        MONO_TRIPLE="iossimulator.x64.$BUILD_TYPE"
        RUNTIME_TFM="net10.0-iossimulator-$BUILD_TYPE-x64"
        NATIVE_TFM="net10.0-iossimulator-$BUILD_TYPE-x64"
        ;;
    iossimulator/arm64)
        MONO_TRIPLE="iossimulator.arm64.$BUILD_TYPE"
        RUNTIME_TFM="net10.0-iossimulator-$BUILD_TYPE-arm64"
        NATIVE_TFM="net10.0-iossimulator-$BUILD_TYPE-arm64"
        ;;
    android/arm64)
        MONO_TRIPLE="android.arm64.$BUILD_TYPE"
        RUNTIME_TFM="net10.0-android-$BUILD_TYPE-arm64"
        NATIVE_TFM=""
        ;;
    linux/x64)
        MONO_TRIPLE="linux.x64.$BUILD_TYPE"
        RUNTIME_TFM="net10.0-linux-$BUILD_TYPE-x64"
        NATIVE_TFM=""
        ;;
esac

# Destination directory. Every platform uses the same depth -- <Platform>/<arch>/ --
# so the layout rule is one line instead of a per-platform special case:
#   Win64/x64  Android/arm64  IOS/arm64  Linux/x64
#   Mac/{x64,arm64}  IOSSimulator/{arm64,x64}
case "$PLATFORM" in
    macos)        PLATFORM_DIR="Mac" ;;
    ios)          PLATFORM_DIR="IOS" ;;
    iossimulator) PLATFORM_DIR="IOSSimulator" ;;
    android)      PLATFORM_DIR="Android" ;;
    linux)        PLATFORM_DIR="Linux" ;;
esac
DEST="$SDK_DIR/Mono/$PLATFORM_DIR/$ARCH"

echo ">>> Copying artifacts into SDK directory..."
rm -rf "$DEST"
mkdir -p "$DEST"

# ── Copy artifacts (cross-platform safe) ───────────────────────────────────────
# Use cd + cp -Rf . pattern to avoid BSD/GNU cp inconsistency:
#   - macOS (BSD cp): cp -Rf source/. dest/  → copies contents ✅
#   - Linux (GNU cp): cp -Rf source/. dest/  → may nest source dir ❌
#
# Safe pattern:
#   1. cd into source directory
#   2. cp -Rf . "$DEST/subdir/"

# include/ is NOT copied per platform: the shared headers live in the MonoSDK root
# (include/) and are sourced from the Win64 build, which is the superset. See the
# matching comment in BuildMonoSDK.sh.

# lib/: handle both flat and nested (lib/lib/) layouts
if [[ -d "$SRC_ARTIFACTS/obj/mono/$MONO_TRIPLE/out/lib" ]]; then
    cd "$SRC_ARTIFACTS/obj/mono/$MONO_TRIPLE/out/lib"
    # If there's a lib/ subdir, copy from there; otherwise copy current dir contents
    if [[ -d "lib" ]]; then
        cd lib
        cp -Rf . "$DEST/lib/" 2>/dev/null || true
        cd ..
    else
        cp -Rf . "$DEST/lib/" 2>/dev/null || true
    fi
    # Flatten: if lib/ itself got nested, fix it
    if [[ -d "$DEST/lib/lib" ]]; then
        mv "$DEST/lib/lib/"* "$DEST/lib/" 2>/dev/null || true
        rm -rf "$DEST/lib/lib"
    fi
    cd "$SDK_DIR"
fi

# bin/: only exists for macOS (mono-sgen); iOS/Android/Linux may not have it
if [[ -d "$SRC_ARTIFACTS/obj/mono/$MONO_TRIPLE/out/bin" ]]; then
    cd "$SRC_ARTIFACTS/obj/mono/$MONO_TRIPLE/out/bin"
    cp -Rf . "$DEST/bin/" 2>/dev/null || true
    # Flatten: if bin/ itself got nested, fix it
    if [[ -d "$DEST/bin/bin" ]]; then
        mv "$DEST/bin/bin/"* "$DEST/bin/" 2>/dev/null || true
        rm -rf "$DEST/bin/bin"
    fi
    cd "$SDK_DIR"
fi

# runtime/: copy BCL DLLs
if [[ -d "$SRC_ARTIFACTS/bin/runtime/$RUNTIME_TFM" ]]; then
    cd "$SRC_ARTIFACTS/bin/runtime/$RUNTIME_TFM"
    cp -Rf . "$DEST/runtime/" 2>/dev/null || true
    # Flatten: if $RUNTIME_TFM/ itself got nested, fix it
    NESTED=$(find "$DEST/runtime" -maxdepth 1 -type d ! -path "$DEST/runtime" | head -1)
    if [[ -n "$NESTED" && $(find "$DEST/runtime" -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
        mv "$NESTED/"* "$DEST/runtime/" 2>/dev/null || true
        rm -rf "$NESTED"
    fi
    cd "$SDK_DIR"
fi

# IL/: copy IL assemblies
if [[ -d "$SRC_ARTIFACTS/bin/mono/$MONO_TRIPLE/IL" ]]; then
    cd "$SRC_ARTIFACTS/bin/mono/$MONO_TRIPLE/IL"
    cp -Rf . "$DEST/runtime/" 2>/dev/null || true
    cd "$SDK_DIR"
fi

# Apple platforms (macOS / iOS / iOS Simulator): copy native interop libs from
# bin/native/<NATIVE_TFM>/ (see BuildMonoSDK.sh for the layout rationale).
# NATIVE_TFM is empty for the platforms that have none (Android, Linux).
if [[ -n "$NATIVE_TFM" ]]; then
    NATIVE_SRC="$SRC_ARTIFACTS/bin/native/$NATIVE_TFM"

    # See BuildMonoSDK.sh: a wrong TFM would otherwise be silent, and only show up as a
    # DllImport failure at runtime.
    if [[ ! -d "$NATIVE_SRC" ]]; then
        echo "Error: native interop artifact directory not found: $NATIVE_SRC" >&2
        echo "       dotnet/runtime's bin/native layout may have changed." >&2
        exit 1
    fi
    NATIVE_COUNT=0
    for f in "$NATIVE_SRC"/lib*.a "$NATIVE_SRC"/lib*.dylib; do
        [[ -f "$f" ]] && NATIVE_COUNT=$((NATIVE_COUNT + 1))
    done
    if [[ "$NATIVE_COUNT" -eq 0 ]]; then
        echo "Error: $NATIVE_SRC contains no lib*.a or lib*.dylib interop libraries." >&2
        exit 1
    fi

    if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "iossimulator" ]]; then
        mkdir -p "$DEST/tools"
    fi
    cp -f "$NATIVE_SRC"/lib*.a     "$DEST/lib/" 2>/dev/null || true
    cp -f "$NATIVE_SRC"/lib*.dylib "$DEST/lib/" 2>/dev/null || true
    if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "iossimulator" ]]; then
        cp -f "$NATIVE_SRC"/lib*.dylib "$DEST/tools/" 2>/dev/null || true
    fi
fi

# The shared include/ is NOT refreshed here: it lives once at the MonoSDK root and is
# sourced from the Win64 build (the superset). Only BuildMonoSDK.bat writes it.

# ── Validate the produced SDK ─────────────────────────────────────────────────
# See BuildMonoSDK.sh: the copies above tolerate missing sources, so an incomplete
# artifact tree must be caught here rather than at link time or on device.
require_non_empty() {
    local dir="$1" what="$2"
    if [[ ! -d "$dir" ]] || [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        echo "Error: $dir is empty or missing (expected: $what)." >&2
        exit 1
    fi
}
require_non_empty "$DEST/lib"          "the Mono native libraries (libcoreclr/libmonosgen)"
require_non_empty "$DEST/runtime"      "the BCL assemblies"

# ── Write VERSION.txt ──────────────────────────────────────────────────────────
DOTNET_BRANCH="$(cd "$DOTNET_SRC" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
DOTNET_COMMIT="$(cd "$DOTNET_SRC" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

case "$PLATFORM" in
    macos)        PLATFORM_LABEL="macOS ($ARCH)" ;;
    ios)          PLATFORM_LABEL="iOS ($ARCH)" ;;
    iossimulator) PLATFORM_LABEL="iOS Simulator ($ARCH)" ;;
    android)      PLATFORM_LABEL="Android ($ARCH)" ;;
    linux)        PLATFORM_LABEL="Linux ($ARCH)" ;;
esac

cat > "$DEST/VERSION.txt" <<EOF
dotnet/runtime source
  repo:   $(cd "$DOTNET_SRC" && git remote get-url origin 2>/dev/null || echo 'unknown')
  branch: $DOTNET_BRANCH
  commit: $DOTNET_COMMIT

Platform: $PLATFORM_LABEL
Arch: $ARCH
Build type: $BUILD_TYPE
EOF

echo ">>> Done. SDK updated at: $DEST"
