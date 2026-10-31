#!/usr/bin/env bash
# MakeCoreClrFramework.sh
# Build a SINGLE CoreCLR.embeddedframework.zip for iOS / iOS Simulator.
#
# All CoreCLR native dylibs are packaged into one umbrella framework (mirrors
# MonoSDK's Mono.embeddedframework.zip layout), instead of one framework per dylib:
#   CoreCLR.framework/CoreCLR      <- libcoreclr.dylib (REAL runtime binary, not a stub)
#   CoreCLR.framework/Frameworks/  <- other runtime dylibs (libclrjit, libclrinterpreter,
#                                     libSystem.* native shims)
#   CoreCLR.framework/Info.plist
#
# UBT stages the framework into IPA/Frameworks/ via PublicAdditionalFrameworks
# (LinkAndCopy in CoreClrSDK.Build.cs): the linker resolves coreclr_* symbols from
# CoreCLR.framework/CoreCLR, and the whole framework (with sub-Frameworks/) is copied
# into the .app bundle.
#
# The framework binary IS the real libcoreclr.dylib (not a stub) - CoreCLR is
# dynamically linked via LC_LOAD_DYLIB, and uses _dyld_get_image_name(0) to locate
# its own path at runtime.
#
# NOTE (@rpath): the sub-framework dylibs in CoreCLR.framework/Frameworks/ are loaded
# by CoreCLR at runtime via dlopen. dyld's default @rpath (@executable_path/Frameworks)
# does NOT resolve into a framework's inner Frameworks/ dir, so if CoreCLR fails to
# load libclrjit/libSystem.* at runtime, adjust the dylib install_names here with
# install_name_tool -id @rpath/CoreCLR.framework/Frameworks/<name> (requires Mac/iOS
# testing to confirm).
#
# Usage:
#   ./MakeCoreClrFramework.sh <platform> <dylibs-dir> <output-lib-dir>
#   platform: ios | iossimulator

set -euo pipefail

PLATFORM="${1:-}"
DYLIBS_DIR="${2:-}"
OUTPUT_DIR="${3:-}"

if [[ -z "$PLATFORM" || -z "$DYLIBS_DIR" || -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <platform> <dylibs-dir> <output-lib-dir>" >&2
    echo "  platform: ios | iossimulator" >&2
    exit 1
fi

case "$PLATFORM" in
    ios|iossimulator) ;;
    *)
        echo "Error: platform must be 'ios' or 'iossimulator', got '$PLATFORM'" >&2
        exit 1
        ;;
esac

DYLIBS_DIR="$(cd "$DYLIBS_DIR" && pwd)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd)" || true
if [[ -z "$OUTPUT_DIR" ]]; then
    mkdir -p "${3}"
    OUTPUT_DIR="$(cd "${3}" && pwd)"
fi

echo "=== MakeCoreClrFramework (single umbrella framework) ==="
echo "  Platform  : $PLATFORM"
echo "  Dylibs dir: $DYLIBS_DIR"
echo "  Output dir: $OUTPUT_DIR"

# The main framework binary is libcoreclr.dylib (real runtime - NOT a stub).
# The host links coreclr_* symbols from it; CoreCLR uses _dyld_get_image_name(0)
# to locate its own path.
CORECLR_DYLIB="$DYLIBS_DIR/libcoreclr.dylib"
if [[ ! -f "$CORECLR_DYLIB" ]]; then
    echo "Error: libcoreclr.dylib not found in $DYLIBS_DIR" >&2
    exit 1
fi

# Execution engines (JIT / interpreter). CoreCLR resolves these from the directory
# of its own image (vm/codeman.cpp: GetClrModulePathName -> <dir>/libclrjit.dylib),
# so they must sit NEXT TO the framework binary, not in Frameworks/.
EXEC_ENGINE_DYLIBS=(
    libclrjit.dylib
    libclrinterpreter.dylib
)

# P/Invoke interop shims. Kept in Frameworks/ and reached through the host runtime
# contract (__Internal -> dlsym(RTLD_DEFAULT)) or the app's native search paths.
OTHER_DYLIBS=(
    libSystem.Native.dylib
    libSystem.IO.Compression.Native.dylib
    libSystem.Net.Security.Native.dylib
    libSystem.Security.Cryptography.Native.Apple.dylib
    libSystem.Globalization.Native.dylib
)

FW_WORK="$(mktemp -d)"
FW_ROOT="$FW_WORK/CoreCLR.embeddedframework/CoreCLR.framework"
mkdir -p "$FW_ROOT/Frameworks"

# Main binary: copy libcoreclr.dylib as the framework executable and give it the
# install name the linker will record. Without this the app's LC_LOAD_DYLIB stays
# "@rpath/libcoreclr.dylib" and dyld looks for SharpDemo.app/Frameworks/libcoreclr.dylib,
# which does not exist inside a framework bundle.
cp "$CORECLR_DYLIB" "$FW_ROOT/CoreCLR"
chmod +x "$FW_ROOT/CoreCLR"
install_name_tool -id @rpath/CoreCLR.framework/CoreCLR "$FW_ROOT/CoreCLR"

# Execution engines: next to the framework binary (see EXEC_ENGINE_DYLIBS).
for DYLIB in "${EXEC_ENGINE_DYLIBS[@]}"; do
    if [[ -f "$DYLIBS_DIR/$DYLIB" ]]; then
        cp "$DYLIBS_DIR/$DYLIB" "$FW_ROOT/$DYLIB"
        install_name_tool -id "@rpath/CoreCLR.framework/$DYLIB" "$FW_ROOT/$DYLIB"
    else
        echo "Warning: $DYLIB not found in $DYLIBS_DIR - skipping" >&2
    fi
done

# Interop shims: Frameworks/ subdirectory.
for DYLIB in "${OTHER_DYLIBS[@]}"; do
    if [[ -f "$DYLIBS_DIR/$DYLIB" ]]; then
        cp "$DYLIBS_DIR/$DYLIB" "$FW_ROOT/Frameworks/$DYLIB"
    else
        echo "Warning: $DYLIB not found in $DYLIBS_DIR - skipping" >&2
    fi
done

# NOTE: System.Private.CoreLib.dll is deliberately NOT placed here. The runtime looks
# for it beside its own image (vm/appdomain.cpp: m_BaseLibrary = m_SystemDirectory +
# g_pwBaseLibrary), and the mobile host answers that lookup from the extracted save dir
# through the external_assembly_probe contract - the same single mechanism on iOS and
# Android. CoreLib therefore ships inside the PAK with the rest of the BCL, so it stays
# hot-updatable and there is exactly one copy to reason about.

# Info.plist (required for dyld validation).
cat > "$FW_ROOT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CoreCLR</string>
    <key>CFBundleIdentifier</key><string>com.unrealsharp.coreclr</string>
    <key>CFBundleName</key><string>CoreCLR</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

# Pack into .embeddedframework.zip (UE5's expected format).
# Remove the previous zip first: `zip -r` updates in place and would keep stale
# entries (for example the old Frameworks/libclrjit.dylib) after a layout change.
cd "$FW_WORK"
rm -f "$OUTPUT_DIR/CoreCLR.embeddedframework.zip"
zip -r --symlinks "$OUTPUT_DIR/CoreCLR.embeddedframework.zip" CoreCLR.embeddedframework > /dev/null
rm -rf "$FW_WORK"

echo ">>> Created: $OUTPUT_DIR/CoreCLR.embeddedframework.zip"
echo "    (libcoreclr.dylib as CoreCLR binary + ${#EXEC_ENGINE_DYLIBS[@]} engines next to it + ${#OTHER_DYLIBS[@]} dylibs in Frameworks/)"
