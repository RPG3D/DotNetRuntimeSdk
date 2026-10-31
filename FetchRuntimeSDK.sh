#!/usr/bin/env bash
# FetchCoreClrSDK.sh — populate CoreClrSDK platform payloads from GitHub Releases.
#
# Single source of truth: RPG3D/CoreClrSDK releases (CI-built, self-consistent
# runtime+BCL per tag). NuGet/microsoft.netcore.app.runtime.* is intentionally
# NOT a fallback — those packages don't carry our mobile host fixes and the
# native/BCL pair must match the CI tag exactly.
#
# The SDK binaries are git-ignored (large, version-bound). Run this once after
# cloning, or when upgrading to a newer release tag.
#
# Usage:
#   ./FetchRuntimeSDK.sh                        # latest release, BOTH payloads (mono + coreclr)
#   ./FetchRuntimeSDK.sh mono                   # latest release, mono payload only
#   ./FetchRuntimeSDK.sh coreclr ios            # latest release, coreclr, iOS device only
#   ./FetchRuntimeSDK.sh --tag v0.1.0 mono      # explicit release
#   ./FetchCoreClrSDK.sh --tag v0.0.5          # explicit release
#   ./FetchCoreClrSDK.sh --tag v0.0.5 android  # explicit release + one platform
#
# Requirements: curl + unzip on PATH. Honors HTTPS_PROXY if you need one:
#   HTTPS_PROXY=http://127.0.0.1:10808 ./FetchCoreClrSDK.sh

set -euo pipefail

REPO="RPG3D/DotNetRuntimeSdk"
TAG=""
PLATFORM=""
# No backend argument = download BOTH release assets (MonoSDK + CoreClrSDK).
BACKENDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --tag=*) TAG="${1#--tag=}"; shift ;;
    --backend) BACKENDS="$2"; shift 2 ;;
    mono|coreclr) BACKENDS="$1"; shift ;;
    android|ios) PLATFORM="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$BACKENDS" in
  "")       BACKENDS="mono coreclr" ;;
  mono)     ;;
  coreclr)  ;;
  mono,coreclr|coreclr,mono) BACKENDS="mono coreclr" ;;
  *) echo "Unknown backend: $BACKENDS" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Install per platform ──────────────────────────────────────────────────────
# $1 = zip root that already holds the backend layer (Mono/... or CoreCLR/...)
install_platform() { # $1=zip platform dir  $2=sdk dest dir (same layout)
  local src="$1" dst="$SCRIPT_DIR/$2"
  if [ ! -d "$src" ]; then
    echo "WARNING: $2 not present in release zip; skipped." >&2
    return 1
  fi
  # Sanity: payload must contain both the native runtime and the BCL.
  local nativeCount bclCount
  nativeCount=$(find "$src" -name "lib" -type d -exec find {} \( -name "*.so" -o -name "*.dylib" \) \; 2>/dev/null | wc -l | tr -d ' ')
  bclCount=$(find "$src" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
  [ "$nativeCount" -gt 0 ] && [ "$bclCount" -gt 0 ] || {
    echo "ERROR: $2 payload incomplete (native=$nativeCount bcl=$bclCount)" >&2; exit 1; }

  rm -rf "$dst"; mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
  log "Installed $2  (native=$nativeCount bcl=$bclCount)"
}

if [ -z "$TAG" ]; then
  log "Resolving latest release tag..."
  TAG=$(curl -s --retry 3 --retry-delay 5 "https://api.github.com/repos/$REPO/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
  [ -n "$TAG" ] && [ "$TAG" != "None" ] || { echo "ERROR: cannot resolve latest tag (network?)" >&2; exit 1; }
fi
log "Release: $TAG  backends: $BACKENDS"

for BACKEND in $BACKENDS; do
  case "$BACKEND" in
    mono)    PREFIX="MonoSDK"    ;;
    coreclr) PREFIX="CoreClrSDK" ;;
  esac
  # Asset names embed the build run number (MonoSDK-<ver>-r<n>-Release.zip), so
  # resolve by listing the release's assets and matching the backend prefix —
  # exactly one asset per backend lives in a release.
  ASSET="$(curl -s --retry 3 --retry-delay 5 "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
    | python3 -c "import json,sys; print(' '.join(a['name'] for a in json.load(sys.stdin).get('assets', [])))" \
    | tr ' ' '\n' | grep "^${PREFIX}-" | head -1)"
  [ -n "$ASSET" ] || { echo "ERROR: no $PREFIX asset found in release $TAG" >&2; exit 1; }
  ZIP="$WORK_DIR/$ASSET"
  log "Asset: $ASSET"
  log "Downloading $ASSET"

  # ── Download (resumable + retried) ──────────────────────────────────────
  URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
  curl -fL --retry 5 --retry-delay 5 --retry-all-errors -C - \
    --connect-timeout 30 --speed-time 60 --speed-limit 1024 \
    -o "$ZIP" "$URL" || { echo "ERROR: download failed (proxy? set HTTPS_PROXY and retry)" >&2; exit 1; }

  SIZE=$(stat -f%z "$ZIP" 2>/dev/null || stat -c%s "$ZIP")
  [ "$SIZE" -gt 10000000 ] || { echo "ERROR: $ASSET suspiciously small ($SIZE bytes)" >&2; exit 1; }
  log "Downloaded $SIZE bytes"

  # ── Extract & install one-to-one ─────────────────────────────────────────
  # Release zip layout (package-release.yml): the backend layer at the zip root
  # (Mono/<Platform>/<arch> or CoreCLR/<Platform>/<arch>) — the SAME layout this
  # repo uses, so backend dirs copy over one-to-one.
  unzip -q "$ZIP" -d "$WORK_DIR/zip-$BACKEND"
  TOP=$(ls "$WORK_DIR/zip-$BACKEND" | head -1)
  SRC="$WORK_DIR/zip-$BACKEND/$TOP"
  log "$ASSET top-level: $TOP"
  ls -1 "$SRC"

  if [ "$BACKEND" = "coreclr" ]; then
    if [ -z "$PLATFORM" ] || [ "$PLATFORM" = "android" ]; then
      install_platform "$SRC/Android" "CoreCLR/Android"
    fi
    if [ -z "$PLATFORM" ] || [ "$PLATFORM" = "ios" ]; then
      install_platform "$SRC/IOS" "CoreCLR/IOS"
      install_platform "$SRC/IOSSimulator" "CoreCLR/IOSSimulator"
    fi
  else
    if [ -z "$PLATFORM" ] || [ "$PLATFORM" = "android" ]; then
      install_platform "$SRC/Android" "Mono/Android"
    fi
    if [ -z "$PLATFORM" ] || [ "$PLATFORM" = "ios" ]; then
      install_platform "$SRC/IOS" "Mono/IOS"
      install_platform "$SRC/IOSSimulator" "Mono/IOSSimulator"
    fi
    if [ -z "$PLATFORM" ]; then
      # Desktop mono payloads ride the same release; hostfxr desktop CoreCLR
      # needs none. Include/ (shared headers) ships inside each artifact's
      # platform dir (Win64) — copy it to the backend root for the resolver.
      install_platform "$SRC/Linux" "Mono/Linux"
      install_platform "$SRC/Mac" "Mono/Mac"
      install_platform "$SRC/Win64" "Mono/Win64"
      if [ -d "$SRC/Win64/x64/include" ] && [ ! -d "$SCRIPT_DIR/Mono/include" ]; then
        cp -R "$SRC/Win64/x64/include" "$SCRIPT_DIR/Mono/include"
        log "Installed Mono/include (from Win64 superset)"
      fi
    fi
  fi
done

log "Done. SDK populated from $TAG (GitHub Releases; no NuGet).
"
