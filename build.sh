#!/bin/bash
# Builds and installs "AI Activity.app".
#
# This script is committed on purpose: LLMMenu.app was built ad hoc with nothing
# in the repo, which made it unreproducible. Adapted from the working pattern in
# ~/qwen-control-mac/install.sh (lines 129-173), with LSUIElement removed (this
# app is window-first) and NSAllowsLocalNetworking added (it talks plain HTTP to
# loopback).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AI Activity"
VERSION="0.1.0"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
if ! git diff --quiet 2>/dev/null; then BUILD="${BUILD}-dirty"; fi
DEST="${1:-$HOME/Applications}"
STAGE="build/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release --product AIActivity

echo "==> assembling ${APP_NAME}.app  (${VERSION} ${BUILD})"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
sed -e "s/@VERSION@/${VERSION}/" -e "s/@BUILD@/${BUILD}/" \
    Resources/Info.plist.in > "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp .build/release/AIActivity "$STAGE/Contents/MacOS/AIActivity"

if [ Resources/icon-1024.png -nt Resources/AppIcon.icns ] 2>/dev/null || [ ! -f Resources/AppIcon.icns ]; then
  echo "==> icon"
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc sign"
# Ad-hoc signing gives the bundle a stable code identity, so macOS does not
# re-prompt for permissions on every rebuild. NOT sandboxed: the app reads other
# processes via libproc and the GPU via IOKit, both of which the sandbox blocks.
codesign --force --sign - --timestamp=none "$STAGE"
codesign --verify --deep --strict "$STAGE"

echo "==> install to ${DEST}"
mkdir -p "$DEST"
rsync -a --delete "$STAGE/" "$DEST/${APP_NAME}.app/"
touch "$DEST"
# Make Spotlight see it now rather than whenever mds gets around to it.
mdimport "$DEST/${APP_NAME}.app" 2>/dev/null || true

echo "==> done: $DEST/${APP_NAME}.app"
echo "    launch:  open -a \"${APP_NAME}\""
