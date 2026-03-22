#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRONET_SRC="${CRONET_SRC:-$HOME/src/cronet/chromium/src}"
DEPOT_TOOLS="${DEPOT_TOOLS:-$HOME/src/cronet/depot_tools}"

CRONET_VERSION="135.0.7012.3"
CRONET_SO_NAME="libcronet.${CRONET_VERSION}.so"

export PATH="$DEPOT_TOOLS:$PATH"

# Apply patch if not already applied
if ! git -C "$CRONET_SRC" diff --quiet -- components/cronet; then
    echo "==> Cronet patch already applied"
else
    echo "==> Applying Cronet proxy patch..."
    git -C "$CRONET_SRC" apply "$SCRIPT_DIR/patches/cronet-proxy-support.patch"
fi

# Python 3.14 compatibility
touch "$CRONET_SRC/build/__init__.py" \
      "$CRONET_SRC/build/android/__init__.py" \
      "$CRONET_SRC/build/android/gyp/__init__.py"

# Build
echo "==> Building Cronet..."
ninja -C "$CRONET_SRC/out/Cronet" cronet_package -j$(nproc)

CRONET_SO="$CRONET_SRC/out/Cronet/cronet/libs/arm64-v8a/$CRONET_SO_NAME"
cp "$CRONET_SO" "$SCRIPT_DIR/$CRONET_SO_NAME"
echo "==> Done: $SCRIPT_DIR/$CRONET_SO_NAME ($(du -h "$SCRIPT_DIR/$CRONET_SO_NAME" | cut -f1))"
