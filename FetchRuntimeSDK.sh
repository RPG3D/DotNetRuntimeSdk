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
#   ./FetchCoreClrSDK.sh                       # latest release, all platforms
#   ./FetchCoreClrSDK.sh --tag v0.0.5          # explicit release
#   ./FetchCoreClrSDK.sh --tag v0.0.5 android  # explicit release + one platform
#
# Requirements: curl + unzip on PATH. Honors HTTPS_PROXY if you need one:
#   HTTPS_PROXY=http://127.0.0.1:10808 ./FetchCoreClrSDK.sh

set -euo pipefail

REPO="RPG3D/DotNetRuntimeSDK"
TAG=""
PLATFORM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --tag=*) TAG="${1#--tag=}"; shift ;;
    android|ios) PLATFORM="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Resolve release ───────────────────────────────────────────────────────────
if [ -z "$TAG" ]; then
  log "Resolving latest release tag..."
  TAG=$(curl -s --retry 3 --retry-delay 5 "https://api.github.com/repos/$REPO/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
  [ -n "$TAG" ] && [ "$TAG" != "None" ] || { echo "ERROR: cannot resolve latest tag (network?)" >&2; exit 1; }
fi
ASSET="CoreClrSDK-${TAG}-Release.zip"
ZIP="$WORK_DIR/$ASSET"

log "Release: $TAG  asset: $ASSET"

# ── Download (resumable + retried) ────────────────────────────────────────────
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
log "Downloading $URL"
curl -fL --retry 5 --retry-delay 5 --retry-all-errors -C - \
  --connect-timeout 30 --speed-time 60 --speed-limit 1024 \
  -o "$ZIP" "$URL" || { echo "ERROR: download failed (proxy? set HTTPS_PROXY and retry)" >&2; exit 1; }

SIZE=$(stat -f%z "$ZIP" 2>/dev/null || stat -c%s "$ZIP")
[ "$SIZE" -gt 10000000 ] || { echo "ERROR: zip suspiciously small ($SIZE bytes)" >&2; exit 1; }
log "Downloaded $SIZE bytes"

# ── Extract & inspect layout ──────────────────────────────────────────────────
log "Extracting..."
unzip -q "$ZIP" -d "$WORK_DIR/zip"
# Release zip layout (package-release.yml on main): CoreClrSDK/{Android,IOS,
# IOSSimulator}/<arch>/{lib,runtime,...} — the SAME <Platform>/<arch> layout
# this repo uses, so platform dirs copy over one-to-one.
TOP=$(ls "$WORK_DIR/zip" | head -1)
SRC="$WORK_DIR/zip/$TOP"
log "Zip top-level: $TOP"
ls -1 "$SRC"

# ── Install per platform ──────────────────────────────────────────────────────
install_platform() { # $1=zip platform dir  $2=sdk dest dir (same layout)
  local src="$SRC/$1" dst="$SCRIPT_DIR/$2"
  if [ ! -d "$src" ]; then
    echo "WARNING: $1 not present in release zip; skipped." >&2
    return 1
  fi
  # Sanity: payload must contain both the native runtime and the BCL.
  local nativeCount bclCount
  nativeCount=$(find "$src" -name "lib" -type d -exec find {} \( -name "*.so" -o -name "*.dylib" \) \; 2>/dev/null | wc -l | tr -d ' ')
  bclCount=$(find "$src" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
  [ "$nativeCount" -gt 0 ] && [ "$bclCount" -gt 0 ] || {
    echo "ERROR: $1 payload incomplete (native=$nativeCount bcl=$bclCount)" >&2; exit 1; }

  rm -rf "$dst"; mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
  log "Installed $1 -> $2  (native=$nativeCount bcl=$bclCount)"
}

if [ -z "$PLATFORM" ] || [ "$PLATFORM" = "android" ]; then
  install_platform "Android" "Android"
fi
if [ -z "$PLATFORM" ] || [ "$PLATFORM" = "ios" ]; then
  install_platform "IOS" "IOS"
  install_platform "IOSSimulator" "IOSSimulator"
fi

log "Done. SDK populated from $TAG (GitHub Releases; no NuGet)."
