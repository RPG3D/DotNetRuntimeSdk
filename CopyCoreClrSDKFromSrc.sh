#!/usr/bin/env bash
# CopySDKFromSrc.sh — copy already-built CoreCLR artifacts from dotnet/runtime into the
# SDK platform directory.
#
# This script does NOT build dotnet/runtime. BuildCoreClrSDK.sh calls it at the end of a
# build; CI can also run it against a separately built tree.
#
# Usage:
#   ./CopySDKFromSrc.sh <dotnet-src-dir> <platform> [build-type] [arch]
#
# Arguments:
#   dotnet-src-dir  Path to the dotnet/runtime repository root (must be built)
#   platform        android | ios | iossimulator
#   build-type      Debug (default) | Release
#   arch            arm64 (default) | x64 (iossimulator only)
#
# Output layout (same convention as MonoSDK):
#   Android/arm64/  IOS/arm64/  IOSSimulator/arm64/
#     lib/       libcoreclr + libclrjit + libclrinterpreter + System.* interop shims
#     runtime/   BCL managed assemblies (pure-IL System.Private.CoreLib.dll)
#     VERSION.txt

set -euo pipefail

DOTNET_SRC="${1:-}"
PLATFORM="${2:-}"
if [[ -z "$DOTNET_SRC" || -z "$PLATFORM" ]]; then
    echo "Error: missing required arguments." >&2
    echo "Usage: $0 <dotnet-src-dir> <platform> [build-type] [arch]" >&2
    echo "       platform: android | ios | iossimulator" >&2
    exit 1
fi
DOTNET_SRC="$(cd "$DOTNET_SRC" && pwd)"

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

ARCH="${4:-arm64}"

SDK_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Platform/arch matrix ──────────────────────────────────────────────────────
case "$PLATFORM/$ARCH" in
    android/arm64)
        CORECLR_TRIPLE="android.arm64.$BUILD_TYPE"
        RUNTIME_RID="android-arm64"
        PLATFORM_DIR="Android"
        EXT="so"
        ;;
    ios/arm64)
        CORECLR_TRIPLE="ios.arm64.$BUILD_TYPE"
        RUNTIME_RID="ios-arm64"
        PLATFORM_DIR="IOS"
        EXT="dylib"
        ;;
    iossimulator/arm64)
        CORECLR_TRIPLE="iossimulator.arm64.$BUILD_TYPE"
        RUNTIME_RID="iossimulator-arm64"
        PLATFORM_DIR="IOSSimulator"
        EXT="dylib"
        ;;
    iossimulator/x64)
        CORECLR_TRIPLE="iossimulator.x64.$BUILD_TYPE"
        RUNTIME_RID="iossimulator-x64"
        PLATFORM_DIR="IOSSimulator"
        EXT="dylib"
        ;;
    *)
        echo "Error: unsupported platform/arch combination '$PLATFORM/$ARCH'." >&2
        echo "Supported: android/arm64 ios/arm64 iossimulator/{arm64,x64}" >&2
        exit 1
        ;;
esac

DEST="$SDK_DIR/CoreCLR/$PLATFORM_DIR/$ARCH"

# Pinned runtime — single source of truth: DotNetRuntime.version.
# The runtime branch follows the BACKEND (CoreCLR -> 11), so the file's default keys
# describe CoreCLR. <KEY>_<PLATFORM> exists only for tracked exceptions (Android CLR
# still on the validated 10.0.12 payload); it is not a general per-platform knob.
VERSION_FILE="$SDK_DIR/DotNetRuntime.version"
PLATFORM_UPPER="$(printf '%s' "$PLATFORM" | tr '[:lower:]' '[:upper:]')"

resolve_version_key() { # $1 = KEY
    local value
    value="$(grep -E "^$1_${PLATFORM_UPPER}=" "$VERSION_FILE" | head -1 | cut -d= -f2- | tr -d '\r')"
    if [ -z "$value" ]; then
        value="$(grep -E "^$1=" "$VERSION_FILE" | head -1 | cut -d= -f2- | tr -d '\r')"
    fi
    printf '%s' "$value"
}

DOTNET_MAJOR="$(resolve_version_key DOTNET_MAJOR)"
DOTNET_TFM="$(resolve_version_key DOTNET_TFM)"
RUNTIME_VERSION="$(resolve_version_key RUNTIME_VERSION)"
BUILD_SUBSET="$(resolve_version_key BUILD_SUBSET)"
SOURCE_TAG="$(resolve_version_key SOURCE_TAG)"

# The payload must come from the branch the version file declares. A release/10.0
# worktree copied into an iOS slot silently produces a runtime without an interpreter;
# fail here instead of on the device.
SRC_MAJOR="$(grep -m1 -oE '<MajorVersion>[0-9]+' "$DOTNET_SRC/eng/Versions.props" 2>/dev/null | grep -oE '[0-9]+' || true)"
if [[ -n "$SRC_MAJOR" && -n "$DOTNET_MAJOR" && "$SRC_MAJOR" != "$DOTNET_MAJOR" ]]; then
    echo "Error: $DOTNET_SRC is dotnet $SRC_MAJOR, but DotNetRuntime.version pins $PLATFORM to $DOTNET_MAJOR." >&2
    echo "       Use the release/$DOTNET_MAJOR.* worktree, or update the version file first." >&2
    exit 1
fi

# CI builds always sit exactly on SOURCE_TAG; local debugging worktrees are allowed to
# float, so a mismatch is a warning about provenance, not an error.
if [[ -n "$SOURCE_TAG" ]]; then
    SRC_TAG="$(git -C "$DOTNET_SRC" describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "$SRC_TAG" && "$SRC_TAG" != "$SOURCE_TAG" ]]; then
        echo "Warning: $DOTNET_SRC is at tag $SRC_TAG, DotNetRuntime.version pins $SOURCE_TAG." >&2
        echo "         The payload will carry that worktree's commit, not the pinned one." >&2
    fi
fi

SRC_ARTIFACTS="$DOTNET_SRC/artifacts"
CORECLR_DIR="$SRC_ARTIFACTS/bin/coreclr/$CORECLR_TRIPLE"
RUNTIME_PACK="$SRC_ARTIFACTS/bin/microsoft.netcore.app.runtime.$RUNTIME_RID/$BUILD_TYPE/runtimes/$RUNTIME_RID"
RUNTIME_PACK_NATIVE="$RUNTIME_PACK/native"
RUNTIME_PACK_MANAGED="$RUNTIME_PACK/lib/$DOTNET_TFM"

echo "=== CopySDKFromSrc ==="
echo "  Source    : $DOTNET_SRC"
echo "  Platform  : $PLATFORM ($ARCH)"
echo "  Build type: $BUILD_TYPE"
echo "  RID       : $RUNTIME_RID"
echo "  SDK dir   : $DEST"
echo ""

if [[ ! -d "$CORECLR_DIR" ]]; then
    echo "Error: CoreCLR artifact directory not found: $CORECLR_DIR" >&2
    echo "       Build first (BuildCoreClrSDK.sh) or check the build-type." >&2
    exit 1
fi
if [[ ! -d "$RUNTIME_PACK_MANAGED" ]]; then
    echo "Error: runtime-pack managed directory not found: $RUNTIME_PACK_MANAGED" >&2
    echo "       The libs.sfx subset must be part of BUILD_SUBSET (see DotNetRuntime.version)." >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/runtime"

# ── 1. Native runtime engines → lib/ ─────────────────────────────────────────
# Only what the host loads.
#
# Android executes JIT code, so libclrjit is required and the interpreter is optional.
# iOS forbids JIT (W^X), so libclrinterpreter is required and the JIT is optional.
# Requiring both would fail a correct build on either platform.
if [[ "$PLATFORM" == "android" ]]; then
    REQUIRED_ENGINES="coreclr clrjit"
    OPTIONAL_ENGINES="clrinterpreter"
else
    REQUIRED_ENGINES="coreclr clrinterpreter"
    OPTIONAL_ENGINES="clrjit"
fi

echo "--- Native runtime engines ---"
for LIB in $REQUIRED_ENGINES $OPTIONAL_ENGINES; do
    SRC="$CORECLR_DIR/lib${LIB}.${EXT}"
    if [[ ! -f "$SRC" && -f "$RUNTIME_PACK_NATIVE/lib${LIB}.${EXT}" ]]; then
        SRC="$RUNTIME_PACK_NATIVE/lib${LIB}.${EXT}"
    fi
    if [[ -f "$SRC" ]]; then
        cp "$SRC" "$DEST/lib/"
        echo "  lib${LIB}.${EXT}"
    elif [[ " $REQUIRED_ENGINES " == *" $LIB "* ]]; then
        echo "Error: lib${LIB}.${EXT} not found in $CORECLR_DIR or $RUNTIME_PACK_NATIVE" >&2
        exit 1
    else
        echo "  lib${LIB}.${EXT} (not produced for $PLATFORM, skipped)"
    fi
done

# ── 1b. Debugger support → lib/ (optional) ───────────────────────────────────
# mscordaccore/mscordbi back the managed debugging stack (ICorDebug research,
# -clrdebug). Not required by the host, so copied only when the build produced
# them; their absence never fails the populate step.
echo "--- Debugger support (optional) ---"
for LIB in mscordaccore mscordbi; do
    SRC="$CORECLR_DIR/lib${LIB}.${EXT}"
    if [[ -f "$SRC" ]]; then
        cp "$SRC" "$DEST/lib/"
        echo "  lib${LIB}.${EXT}"
    else
        echo "  lib${LIB}.${EXT} (not produced, skipped)"
    fi
done

# ── 2. Native interop shims → lib/ ───────────────────────────────────────────
echo "--- Native interop shims ---"
for LIB in System.Native \
           System.IO.Compression.Native \
           System.Globalization.Native \
           System.Net.Security.Native \
           System.Security.Cryptography.Native.Apple \
           System.Security.Cryptography.Native.Android \
           System.Security.Cryptography.Native.OpenSsl; do
    SRC="$RUNTIME_PACK_NATIVE/lib${LIB}.${EXT}"
    if [[ -f "$SRC" ]]; then
        cp "$SRC" "$DEST/lib/"
        echo "  lib${LIB}.${EXT}"
    fi
done

# ── 3. BCL managed assemblies → runtime/ ─────────────────────────────────────
# cp -Rf the whole directory: .dll + .pdb + .json together, no manual file list.
echo ""
echo "--- BCL managed assemblies ---"
(
    cd "$RUNTIME_PACK_MANAGED"
    cp -Rf . "$DEST/runtime/"
)

# Pure-IL CoreLib from clr.corelib. The runtime pack ships the crossgen'd (ReadyToRun)
# build, which the interpreter cannot use on iOS; the IL copy is what CoreCLR loads.
CORECLR_IL_DIR="$CORECLR_DIR/IL"
if [[ -f "$CORECLR_IL_DIR/System.Private.CoreLib.dll" ]]; then
    cp "$CORECLR_IL_DIR/System.Private.CoreLib.dll" "$DEST/runtime/"
    [[ -f "$CORECLR_IL_DIR/System.Private.CoreLib.pdb" ]] \
        && cp "$CORECLR_IL_DIR/System.Private.CoreLib.pdb" "$DEST/runtime/"
    echo "  System.Private.CoreLib.dll (pure IL, from clr.corelib)"
else
    echo "Error: pure-IL CoreLib not found at $CORECLR_IL_DIR/System.Private.CoreLib.dll" >&2
    echo "       clr.corelib must be part of BUILD_SUBSET (see DotNetRuntime.version)." >&2
    exit 1
fi

# ── 4. Validate ──────────────────────────────────────────────────────────────
# Every copy above tolerates a missing optional shim, so a partial or differently
# named artifact tree would otherwise produce a build that "succeeds" and fails on
# device. Fail here instead.
require_non_empty() {
    local dir="$1" what="$2"
    if [[ ! -d "$dir" ]] || [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        echo "Error: $dir is empty or missing (expected: $what)." >&2
        exit 1
    fi
}
require_non_empty "$DEST/lib" "the CoreCLR native runtime"
require_non_empty "$DEST/runtime" "the BCL assemblies"

DLL_COUNT=$(find "$DEST/runtime" -maxdepth 1 -name "*.dll" | wc -l | tr -d ' ')
if [[ "$DLL_COUNT" -lt 100 ]]; then
    echo "Error: only $DLL_COUNT BCL DLLs copied into $DEST/runtime (expected ~170)." >&2
    exit 1
fi

# ── 5. iOS: umbrella framework ───────────────────────────────────────────────
if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "iossimulator" ]]; then
    echo ""
    echo "--- CoreCLR.embeddedframework.zip ---"
    bash "$SDK_DIR/MakeCoreClrFramework.sh" "$PLATFORM" "$DEST/lib" "$DEST/lib"
fi

# ── 6. VERSION.txt ───────────────────────────────────────────────────────────
DOTNET_BRANCH="$(cd "$DOTNET_SRC" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
DOTNET_COMMIT="$(cd "$DOTNET_SRC" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
DOTNET_REMOTE="$(cd "$DOTNET_SRC" && git remote get-url origin 2>/dev/null || echo 'unknown')"

case "$PLATFORM" in
    android)      PLATFORM_LABEL="Android ($ARCH)" ;;
    ios)          PLATFORM_LABEL="iOS ($ARCH)" ;;
    iossimulator) PLATFORM_LABEL="iOS Simulator ($ARCH)" ;;
esac

cat > "$DEST/VERSION.txt" <<EOF
dotnet/runtime source
  repo:   $DOTNET_REMOTE
  branch: $DOTNET_BRANCH
  commit: $DOTNET_COMMIT

Platform: $PLATFORM_LABEL
Runtime: $RUNTIME_VERSION ($DOTNET_TFM)
Build type: $BUILD_TYPE
Build subsets: $BUILD_SUBSET
EOF

echo ""
echo "=== Done. CoreClrSDK populated for $PLATFORM/$ARCH ($BUILD_TYPE) ==="
echo "  Native : $DEST/lib/ ($(find "$DEST/lib" -maxdepth 1 -type f | wc -l | tr -d ' ') files)"
echo "  Managed: $DEST/runtime/ ($DLL_COUNT DLLs)"
