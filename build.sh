#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REVANCED_DIR="$SCRIPT_DIR/revanced-patches"

CRONET_VERSION="135.0.7012.3"
CRONET_SO_NAME="libcronet.${CRONET_VERSION}.so"
CRONET_SO="$SCRIPT_DIR/$CRONET_SO_NAME"
CRONET_RELEASE_URL="https://github.com/nikicat/youtube-proxy/releases/download/cronet-${CRONET_VERSION}/${CRONET_SO_NAME}"

BASE_APK="$SCRIPT_DIR/com.google.android.youtube@20.12.46.apk"
KEYSTORE="$SCRIPT_DIR/youtube-s5.keystore"
OUTPUT="$SCRIPT_DIR/youtube-s5.apk"

# Find the patches .rvp (version may vary)
PATCHES="$(ls "$REVANCED_DIR"/patches/build/libs/patches-*.rvp 2>/dev/null | grep -v sources | grep -v javadoc | head -1)"

# BouncyCastle provider jar (needed for BKS keystore signing)
BC_JAR="${BC_JAR:-$(find /usr -name 'bcprov-jdk*.jar' 2>/dev/null | head -1)}"
APK_JAR="${APK_JAR:-$(dirname "$(which apksigner 2>/dev/null || echo /opt/android-sdk/build-tools/36.1.0/apksigner)")/lib/apksigner.jar}"

# --- Step 1: Download prebuilt Cronet ---
if [ ! -f "$CRONET_SO" ]; then
    echo "==> Downloading prebuilt Cronet ${CRONET_VERSION}..."
    curl -fL -o "$CRONET_SO" "$CRONET_RELEASE_URL"
    echo "    Downloaded: $CRONET_SO ($(du -h "$CRONET_SO" | cut -f1))"
else
    echo "==> Using cached Cronet: $CRONET_SO ($(du -h "$CRONET_SO" | cut -f1))"
fi

# --- Step 2: Build ReVanced patches and patch APK ---
echo "==> Building ReVanced patches..."
(cd "$REVANCED_DIR" && ./gradlew build -q)

echo "==> Patching APK..."
java -jar "$REVANCED_DIR/revanced-cli.jar" patch \
    -p "$PATCHES" \
    -e "Override certificate pinning" \
    -o "$OUTPUT" \
    -f \
    "$BASE_APK" 2>&1 | grep -E "INFO: Saved|SEVERE|socks5|SOCKS5|certificate" || true

# --- Step 3: Inject custom Cronet .so ---
echo "==> Injecting custom Cronet .so..."
TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

mkdir -p "$TMPDIR/lib/arm64-v8a"
cp "$CRONET_SO" "$TMPDIR/lib/arm64-v8a/"
cp "$OUTPUT" "$TMPDIR/youtube-s5.apk"

(cd "$TMPDIR" && \
    zip -d youtube-s5.apk "lib/arm64-v8a/$CRONET_SO_NAME" && \
    zip -0 youtube-s5.apk "lib/arm64-v8a/$CRONET_SO_NAME") > /dev/null

# --- Step 4: Re-align and re-sign ---
echo "==> Signing APK..."
zip -d "$TMPDIR/youtube-s5.apk" "META-INF/*" > /dev/null 2>&1 || true
zipalign -f 4 "$TMPDIR/youtube-s5.apk" "$TMPDIR/youtube-s5-aligned.apk"

java -cp "$APK_JAR:$BC_JAR" com.android.apksigner.ApkSignerTool sign \
    --ks "$KEYSTORE" \
    --ks-pass pass: \
    --ks-type BKS \
    --ks-key-alias "ReVanced Key" \
    --key-pass pass: \
    --provider-class org.bouncycastle.jce.provider.BouncyCastleProvider \
    "$TMPDIR/youtube-s5-aligned.apk"

cp "$TMPDIR/youtube-s5-aligned.apk" "$OUTPUT"

echo "==> Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
