#!/usr/bin/env bash
# MakeMonoFramework.sh
# Build Mono.embeddedframework.zip for iOS / iOS Simulator from an already-populated
# MonoSDK platform directory (i.e. after BuildMonoSDK.sh has run).
#
# The embedded framework packages the 5 native interop dylibs into an iOS
# Frameworks/ bundle so Xcode/UAT can stage them into the IPA Frameworks/.
#
# The stub Mono binary (intentionally empty — runtime is statically linked via
# libmonosgen-2.0.a) together with Info.plist / Headers / Modules are reused
# from the existing SDK framework zip; they are build-type-independent.
# If no existing zip is present yet, a minimal stub is compiled on the fly as fallback.
#
# Usage:
#   ./MakeMonoFramework.sh <platform> <sdk-platform-dir> [arch]
#
# Arguments:
#   platform          ios | iossimulator
#   sdk-platform-dir  Path to the arch-specific MonoSDK platform directory that
#                     contains lib/ and tools/, e.g.
#                       /path/to/MonoSDK/IOS
#                       /path/to/MonoSDK/IOSSimulator/arm64
#                       /path/to/MonoSDK/IOSSimulator/x64
#   arch              arm64 (default) | x64 — only used to compile the fallback
#                     stub binary; the reused stub from an existing zip is
#                     architecture-specific too, so keep the arch consistent with
#                     the directory.
#
# Examples:
#   ./MakeMonoFramework.sh iossimulator IOSSimulator/arm64 arm64
#   ./MakeMonoFramework.sh iossimulator IOSSimulator/x64   x64
#   ./MakeMonoFramework.sh ios IOS

set -euo pipefail

PLATFORM="${1:-}"
DEST="${2:-}"
ARCH="${3:-arm64}"

if [[ -z "$PLATFORM" || -z "$DEST" ]]; then
    echo "Usage: $0 <platform> <sdk-platform-dir> [arch]" >&2
    echo "  platform: ios | iossimulator" >&2
    exit 1
fi

if [[ "$PLATFORM" != "ios" && "$PLATFORM" != "iossimulator" ]]; then
    echo "Error: platform must be 'ios' or 'iossimulator', got '$PLATFORM'" >&2
    exit 1
fi

case "$ARCH" in
    x64|arm64) ;;
    *)
        echo "Error: arch must be 'x64' or 'arm64', got '$ARCH'" >&2
        exit 1
        ;;
esac

DEST="$(cd "$DEST" && pwd)"
SDK_DIR="$(cd "$(dirname "$0")" && pwd)"

# clang spells 64-bit x86 as x86_64.
CLANG_ARCH="$ARCH"
[[ "$ARCH" == "x64" ]] && CLANG_ARCH="x86_64"

echo "=== MakeMonoFramework ==="
echo "  Platform : $PLATFORM"
echo "  Arch     : $ARCH"
echo "  SDK dir  : $DEST"
echo ""
echo ">>> Building Mono.embeddedframework.zip..."

# ── Existing SDK zip (reuse stub binary + metadata) ───────────────────────────
# Derived from DEST so it works for both the flat IOS/ dir and the arch-qualified
# IOSSimulator/<arch>/ dirs.
DEBUG_ZIP="$DEST/lib/Mono.embeddedframework.zip"

# ── Assemble framework tree in a temp directory ───────────────────────────────
FW_WORK="$(mktemp -d)"
FW_ROOT="$FW_WORK/Mono.embeddedframework/Mono.framework"
mkdir -p "$FW_ROOT/Frameworks"
mkdir -p "$FW_ROOT/Headers"
mkdir -p "$FW_ROOT/Modules"

# ── 5 native interop dylibs (staged to tools/ by BuildMonoSDK.sh) ────────────
for DYLIB in \
    libSystem.Native.dylib \
    libSystem.Globalization.Native.dylib \
    libSystem.IO.Compression.Native.dylib \
    libSystem.Net.Security.Native.dylib \
    libSystem.Security.Cryptography.Native.Apple.dylib
do
    if [[ -f "$DEST/tools/$DYLIB" ]]; then
        cp "$DEST/tools/$DYLIB" "$FW_ROOT/Frameworks/$DYLIB"
    else
        echo "Warning: $DYLIB not found in $DEST/tools/" >&2
    fi
done

# ── Stub Mono binary + metadata ───────────────────────────────────────────────
# Preferred: reuse from existing SDK zip (platform-independent content).
# Fallback:  compile a minimal stub on the fly when no existing zip is present.
if [[ -f "$DEBUG_ZIP" ]]; then
    unzip -p "$DEBUG_ZIP" "Mono.embeddedframework/Mono.framework/Mono" > "$FW_ROOT/Mono"
    chmod +x "$FW_ROOT/Mono"

    mkdir -p "$FW_WORK/meta/Headers" "$FW_WORK/meta/Modules"
    unzip -jo "$DEBUG_ZIP" "Mono.embeddedframework/Mono.framework/Info.plist"        -d "$FW_WORK/meta"          > /dev/null
    unzip -jo "$DEBUG_ZIP" "Mono.embeddedframework/Mono.framework/Headers/Mono.h"    -d "$FW_WORK/meta/Headers"  > /dev/null
    unzip -jo "$DEBUG_ZIP" "Mono.embeddedframework/Mono.framework/Modules/module.modulemap" -d "$FW_WORK/meta/Modules" > /dev/null
    cp "$FW_WORK/meta/Info.plist"               "$FW_ROOT/Info.plist"
    cp "$FW_WORK/meta/Headers/Mono.h"           "$FW_ROOT/Headers/Mono.h"
    cp "$FW_WORK/meta/Modules/module.modulemap" "$FW_ROOT/Modules/module.modulemap"
else
    echo "    [Note] Existing framework zip not found at $DEBUG_ZIP; generating stub on the fly."

    touch "$FW_ROOT/Headers/Mono.h"

    cat > "$FW_ROOT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Mono</string>
    <key>CFBundleIdentifier</key><string>com.unrealsharp.mono</string>
    <key>CFBundleName</key><string>Mono</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>10.0</string>
    <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

    cat > "$FW_ROOT/Modules/module.modulemap" <<'MODMAP'
framework module Mono {
  umbrella header "Mono.h"
  export *
  module * { export * }
}
MODMAP

    STUB_C="$FW_WORK/mono_stub.c"
    cat > "$STUB_C" <<'CSTUB'
__attribute__((visibility("default"))) const char MonoVersionString[] = "10.0";
__attribute__((visibility("default"))) const double MonoVersionNumber = 10.0;
CSTUB

    if [[ "$PLATFORM" == "ios" ]]; then
        xcrun -sdk iphoneos clang -arch "$CLANG_ARCH" \
            -dynamiclib \
            -install_name "@rpath/Mono.framework/Mono" \
            -compatibility_version 10.0 -current_version 10.0 \
            -miphoneos-version-min=15.0 \
            -o "$FW_ROOT/Mono" "$STUB_C"
    else
        xcrun -sdk iphonesimulator clang -arch "$CLANG_ARCH" \
            -target "${CLANG_ARCH}-apple-ios15.0-simulator" \
            -dynamiclib \
            -install_name "@rpath/Mono.framework/Mono" \
            -compatibility_version 10.0 -current_version 10.0 \
            -o "$FW_ROOT/Mono" "$STUB_C"
    fi
fi

# ── Pack into zip ─────────────────────────────────────────────────────────────
cd "$FW_WORK"
zip -r --symlinks "$DEST/lib/Mono.embeddedframework.zip" Mono.embeddedframework > /dev/null
rm -rf "$FW_WORK"

echo ">>> Mono.embeddedframework.zip: $DEST/lib/Mono.embeddedframework.zip"
