#!/usr/bin/env bash
# BuildMonoSDK.sh
# Build Mono runtime + libs from dotnet/runtime source, then copy artifacts
# into this SDK repository's platform subdirectory.
#
# Usage:
#   ./BuildMonoSDK.sh <dotnet-src-dir> [platform] [build-type] [arch]
#
# Arguments:
#   dotnet-src-dir   Path to the dotnet/runtime repository root.
#   platform         Target platform: macos | android | ios | iossimulator | linux
#                    Defaults to the host platform (macos on macOS).
#   build-type       Debug (default) | Release
#                    Both Debug and Release output to the same {Platform}/ directory.
#                    To keep a Release build, copy it out before running Debug.
#   arch             x64 | arm64. Defaults to the host architecture, which is the
#                    right answer for a native build. Cross-arch builds (e.g. macos
#                    x64 on an Apple Silicon runner) must pass it explicitly.
#
# Output layout:
#   Platforms that ship a single architecture keep their flat directory:
#     Win64/  Android/  IOS/  Linux/
#   Platforms that ship more than one architecture are split per arch, so two
#   builds of the same platform can coexist and UBT can pick the matching one:
#     Mac/arm64/  Mac/x64/
#     IOSSimulator/arm64/  IOSSimulator/x64/
#   (Mac and IOSSimulator are the only platforms with an x64 and an arm64 SDK;
#   IOS device is arm64-only, Android is arm64-only, Win64/Linux are x64-only.)
#
# Examples:
#   ./BuildMonoSDK.sh ~/Documents/Code/DotNet                                  # host platform + host arch
#   ./BuildMonoSDK.sh ~/Documents/Code/DotNet macos Release arm64
#   ./BuildMonoSDK.sh ~/Documents/Code/DotNet macos Release x64
#   ./BuildMonoSDK.sh ~/Documents/Code/DotNet iossimulator Release arm64
#   ./BuildMonoSDK.sh ~/Documents/Code/DotNet iossimulator Release x64
#   ./BuildMonoSDK.sh ~/Documents/Code/DotNet android Release arm64

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
DOTNET_SRC="${1:-}"
if [[ -z "$DOTNET_SRC" ]]; then
    echo "Error: dotnet source directory is required." >&2
    echo "Usage: $0 <dotnet-src-dir> [platform] [build-type] [arch]" >&2
    exit 1
fi
DOTNET_SRC="$(cd "$DOTNET_SRC" && pwd)"

case "$(uname -s)" in
    Darwin) HOST_PLATFORM="macos" ;;
    Linux)  HOST_PLATFORM="linux" ;;
    *)      HOST_PLATFORM="macos" ;;
esac
PLATFORM="${2:-$HOST_PLATFORM}"

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

# Build type: Debug (default) or Release.
# Case-normalise to capitalised form expected by dotnet/runtime artifact paths.
# Use tr for lowercase conversion (compatible with bash 3.x on macOS).
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

SDK_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Platform/arch matrix ──────────────────────────────────────────────────────
# Only the (platform, arch) combinations dotnet/runtime can actually build are
# accepted, so a typo fails here instead of silently producing an empty SDK dir.
case "$PLATFORM/$ARCH" in
    macos/x64|macos/arm64|ios/arm64|iossimulator/x64|iossimulator/arm64|android/arm64|linux/x64) ;;
    *)
        echo "Error: unsupported platform/arch combination '$PLATFORM/$ARCH'." >&2
        echo "Supported: macos/{x64,arm64} ios/arm64 iossimulator/{x64,arm64} android/arm64 linux/x64" >&2
        exit 1
        ;;
esac

# dotnet/runtime spells the macOS target OS "osx"; the SDK directory keeps the
# Unreal platform name "Mac". Everything else matches one-to-one.
case "$PLATFORM" in
    macos) DOTNET_OS="osx" ;;
    *)     DOTNET_OS="$PLATFORM" ;;
esac

echo "=== BuildMonoSDK ==="
echo "  Source    : $DOTNET_SRC"
echo "  Platform  : $PLATFORM (dotnet -os $DOTNET_OS)"
echo "  Arch      : $ARCH"
echo "  Build type: $BUILD_TYPE"
echo "  SDK dir   : $SDK_DIR"
echo ""

# ── Build ──────────────────────────────────────────────────────────────────────
cd "$DOTNET_SRC"

# Cross-platform / cross-arch builds leave stale NuGet restore caches that
# reference the previously built host TFM (e.g. net10.0-osx). If present they
# cause NETSDK1005 "doesn't have a target for net10.0-<target>" errors.
# Delete them before every non-native build so NuGet re-restores for the right TFM.
if [[ "$PLATFORM" != "$HOST_PLATFORM" || "$ARCH" != "$HOST_ARCH" ]]; then
    echo ">>> Clearing stale NuGet restore caches for cross-platform build..."
    rm -f "$DOTNET_SRC/artifacts/obj/sfx-src/project.assets.json"
    rm -f "$DOTNET_SRC/artifacts/obj/sfx-finish/project.assets.json"
fi

echo ">>> Building Mono + libs for $PLATFORM ($ARCH, $BUILD_TYPE)..."
# NuGet audit advisories must not fail this build. dotnet/runtime treats audit warnings
# as errors, so a newly published advisory against a *build-time tooling* package breaks
# the whole SDK build with no change on our side -- e.g. NU1902/NU1903 on
# System.Security.Cryptography.Pkcs 9.0.6, pulled in by Crossgen2Tasks/installer.tasks.
# Demoting the NU1901-NU1904 codes to warnings keeps every advisory visible in the log
# while decoupling the SDK build from advisory churn. The shipped runtime is not affected
# by advisories in those tooling packages; scanning the produced SDK belongs to the
# consumer, not here.
#
# Two details that make this work:
#   - %3B is MSBuild's escape for ';'. A literal ';' in a /p: value splits it into
#     several properties on the MSBuild command line and fails with MSB1006.
#   - eng/common/build.sh forwards unrecognised arguments straight to MSBuild.
./build.sh mono+libs -os "$DOTNET_OS" -arch "$ARCH" -configuration "$BUILD_TYPE" \
    "/p:WarningsNotAsErrors=NU1901%3BNU1902%3BNU1903%3BNU1904"

echo ""
echo ">>> Build complete. Copying artifacts into SDK directory..."

# ── Copy artifacts ─────────────────────────────────────────────────────────────
# SDK directory layout:
#   MonoSDK/
#     Mac/              — include/  lib/  bin/  runtime/
#     Android/          — include/  lib/  bin/  runtime/
#     IOS/              — include/  lib/  bin/  runtime/
#     IOSSimulator/     — include/  lib/  bin/  runtime/
#     include/          (shared mono headers, always updated from the latest build)
#
# Both Debug and Release builds write to the same {Platform}/ directory.
# To preserve a Release build separately, copy it out before building Debug.

SRC_ARTIFACTS="$DOTNET_SRC/artifacts"

# ── dotnet/runtime artifact naming + destination ──────────────────────────────
# MONO_TRIPLE  : obj/mono/<triple>/  (native build tree)
# RUNTIME_TFM  : bin/runtime/<tfm>/  (BCL managed DLLs)
# NATIVE_TFM   : bin/native/<tfm>/   (native interop dylibs; Apple platforms only)
# DEST         : platform dir, arch-qualified when the platform ships >1 arch
#                (Mac, IOSSimulator). Single-arch platforms stay flat so existing
#                SDK downloads keep working.
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

rm -rf "$DEST"
mkdir -p "$DEST"

# ── Copy artifacts (cross-platform safe) ───────────────────────────────────────
# Use rsync if available; fall back to cd + cp -Rf * pattern.
# The "cp -Rf source/. dest/" pattern behaves differently on macOS (BSD cp) vs Linux (GNU cp):
#   - macOS: copies contents of source/ into dest/  ✅
#   - Linux:  may nest source dir itself inside dest/  ❌
#
# Cross-platform safe pattern:
#   1. cd into source directory
#   2. cp -Rf * "$DEST/subdir/"   (NOT "." — use explicit glob)

# include/ is NOT copied per platform: the shared headers live once at the MonoSDK root
# (include/) and are sourced from the Win64 x64 build, which emits the superset (it adds
# the jit.h variants the other platforms' builds omit). BuildMonoSDK.bat -- the Win64
# build -- is what refreshes that root copy; this script leaves headers alone entirely.

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
# bin/native/<NATIVE_TFM>/. These are NOT in obj/mono/<TRIPLE>/out/lib/ and must
# be copied separately. NATIVE_TFM is empty for the platforms that have none
# (Android, Linux), which is what gates this block.
#   lib/*.a     — static libs (Globalization etc.) linked by MonoSDK.Build.cs (iOS)
#   lib/*.dylib — BCL DllImport targets; staged next to the executable at runtime
#                 (macOS: RuntimeDependencies; iOS: Mono.embeddedframework.zip)
#   tools/*.dylib — framework payload for MakeMonoFramework.sh (iOS / simulator)
if [[ -n "$NATIVE_TFM" ]]; then
    NATIVE_SRC="$SRC_ARTIFACTS/bin/native/$NATIVE_TFM"

    # The copies below tolerate a missing source, so verify up front that this directory
    # holds what we expect. A wrong TFM would otherwise be completely silent: the SDK
    # would build, and the BCL's DllImports (System.Native, ...) would only fail at
    # runtime, on device.
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
# sourced from the Win64 build (the superset -- see the comment at the include/ copy
# site above). Only BuildMonoSDK.bat writes it.

# ── Validate the produced SDK ─────────────────────────────────────────────────
# Every copy above is written to tolerate a missing source, so a partial or
# differently-named dotnet/runtime artifact tree produces a build that "succeeds" and
# then fails at link time or, worse, on device. Fail the job here instead.
require_non_empty() {
    local dir="$1" what="$2"
    if [[ ! -d "$dir" ]] || [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        echo "Error: $dir is empty or missing (expected: $what)." >&2
        exit 1
    fi
}
require_non_empty "$DEST/lib"          "the Mono native libraries (libcoreclr/libmonosgen)"
require_non_empty "$DEST/runtime"      "the BCL assemblies"

# ── Write VERSION.txt into the platform directory ──────────────────────────────
DOTNET_BRANCH="$(cd "$DOTNET_SRC" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
DOTNET_COMMIT="$(cd "$DOTNET_SRC" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
DOTNET_REMOTE="$(cd "$DOTNET_SRC" && git remote get-url origin 2>/dev/null || echo 'unknown')"

case "$PLATFORM" in
    macos)        PLATFORM_LABEL="macOS ($ARCH)" ;;
    ios)          PLATFORM_LABEL="iOS ($ARCH)" ;;
    iossimulator) PLATFORM_LABEL="iOS Simulator ($ARCH)" ;;
    android)      PLATFORM_LABEL="Android ($ARCH)" ;;
    linux)        PLATFORM_LABEL="Linux ($ARCH)" ;;
esac
BUILD_CMD="./build.sh mono+libs -os $DOTNET_OS -arch $ARCH -configuration $BUILD_TYPE /p:WarningsNotAsErrors=NU1901%3BNU1902%3BNU1903%3BNU1904"

cat > "$DEST/VERSION.txt" <<EOF
dotnet/runtime source
  repo:   $DOTNET_REMOTE
  branch: $DOTNET_BRANCH
  commit: $DOTNET_COMMIT

Platform: $PLATFORM_LABEL
Arch: $ARCH
Build type: $BUILD_TYPE
Build command: $BUILD_CMD
EOF

# ── iOS / IOSSimulator: AOT-compile System.Private.CoreLib ────────────────────
# iOS forbids JIT (W^X). Mono's INTERP mode requires at least System.Private.CoreLib
# to have an AOT module so the runtime can bootstrap without generating any code.
# We use mono-aot-cross (cross-compiler built alongside the runtime) to produce a
# static library that exports the symbol mono_aot_module_System_Private_CoreLib_info,
# which is then registered in CSMonoRuntime.cpp via mono_aot_register_module().
#
# The tools and input DLL are kept in <DEST>/tools/ so the SDK is self-contained
# and re-running AOT does not require the dotnet/runtime source tree.
#
# IOSSimulator clang invocation targets the simulator ABI slice explicitly (arm64
# or x86_64 depending on the requested arch) so the resulting .o is accepted by the
# linker when building for the simulator target.
#
# MVID alignment: each platform AOT-compiles its own CoreLib from MONO_TRIPLE artifacts,
# so the MVID in the resulting .a always matches the DLL in {Platform}/runtime/.
# PackageProjectMono.cs stages each platform's own BCL without cross-platform substitution.
if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "iossimulator" ]]; then
    echo ""
    echo ">>> AOT-compiling System.Private.CoreLib for $PLATFORM ($ARCH)..."

    TOOLS_DIR="$DEST/tools"
    mkdir -p "$TOOLS_DIR"

    # Copy mono-aot-cross tool and input CoreLib into the SDK tools/ dir.
    # Use the platform's own CoreLib so the MVID in the .a matches {Platform}/runtime/.
    CROSS_SRC="$SRC_ARTIFACTS/obj/mono/$MONO_TRIPLE/cross/mono/mini"
    CORELIB_SRC="$SRC_ARTIFACTS/obj/mono/System.Private.CoreLib/$MONO_TRIPLE/System.Private.CoreLib.dll"

    if [[ ! -f "$CORELIB_SRC" ]]; then
        echo "Error: CoreLib not found at $CORELIB_SRC" >&2
        exit 1
    fi

    cp "$CROSS_SRC/mono-aot-cross"       "$TOOLS_DIR/mono-aot-cross"
    cp "$CROSS_SRC/mono-aot-cross.dwarf" "$TOOLS_DIR/mono-aot-cross.dwarf" 2>/dev/null || true
    chmod +x "$TOOLS_DIR/mono-aot-cross"
    cp "$CORELIB_SRC" "$TOOLS_DIR/System.Private.CoreLib.dll"

    # Run AOT cross-compiler: produces System.Private.CoreLib.dll.s
    cd "$TOOLS_DIR"
    ./mono-aot-cross --aot=asmonly,static,interp System.Private.CoreLib.dll

    # Assemble .s → .o with the correct SDK and ABI target.
    # clang arch name: x64 → x86_64.
    CLANG_ARCH="$ARCH"
    [[ "$ARCH" == "x64" ]] && CLANG_ARCH="x86_64"

    if [[ "$PLATFORM" == "ios" ]]; then
        xcrun -sdk iphoneos clang -arch "$CLANG_ARCH" \
            -o System.Private.CoreLib.dll.o \
            -c System.Private.CoreLib.dll.s
    else
        xcrun -sdk iphonesimulator clang -arch "$CLANG_ARCH" \
            -target "${CLANG_ARCH}-apple-ios15.0-simulator" \
            -o System.Private.CoreLib.dll.o \
            -c System.Private.CoreLib.dll.s
    fi

    # Pack into a static library and install into lib/.
    ar rcs System.Private.CoreLib.dll.a System.Private.CoreLib.dll.o
    cp System.Private.CoreLib.dll.a "$DEST/lib/System.Private.CoreLib.dll.a"

    cd "$DOTNET_SRC"
    echo ">>> AOT CoreLib static lib: $DEST/lib/System.Private.CoreLib.dll.a"
fi

# ── iOS / IOSSimulator: build Mono.embeddedframework.zip ──────────────────────
# Delegated to MakeMonoFramework.sh which can also be run standalone after a build.
if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "iossimulator" ]]; then
    bash "$SDK_DIR/MakeMonoFramework.sh" "$PLATFORM" "$DEST" "$ARCH"
fi

echo ">>> Done. SDK updated at: $DEST"
