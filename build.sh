#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRONET_SRC="$HOME/src/cronet/chromium/src"
REVANCED_DIR="$HOME/src/revanced-patches"
DEPOT_TOOLS="$HOME/src/cronet/depot_tools"

BASE_APK="$SCRIPT_DIR/com.google.android.youtube@20.12.46.apk"
KEYSTORE="$SCRIPT_DIR/youtube-s5.keystore"
OUTPUT="$SCRIPT_DIR/youtube-s5.apk"
PATCHES="$REVANCED_DIR/patches/build/libs/patches-3.16.0.rvp"

BC_JAR="/var/lib/archbuild/extra-x86_64/nb-4/build/bisq/pkg/bisq/opt/bisq/lib/bcprov-jdk15to18-1.63.jar"
APK_JAR="/opt/android-sdk/build-tools/36.1.0/lib/apksigner.jar"

export PATH="$DEPOT_TOOLS:$PATH"

# --- Step 1: Build Cronet ---
echo "==> Building Cronet..."
ninja -C "$CRONET_SRC/out/Cronet" cronet_package -j8
CRONET_SO="$CRONET_SRC/out/Cronet/cronet/libs/arm64-v8a/libcronet.135.0.7012.3.so"
echo "    Built: $CRONET_SO ($(du -h "$CRONET_SO" | cut -f1))"

# --- Step 2: Build ReVanced patches and patch APK ---
echo "==> Building ReVanced patches..."
(cd "$REVANCED_DIR" && ./gradlew build -q)

echo "==> Patching APK..."
java -jar "$REVANCED_DIR/revanced-cli.jar" patch \
    -p "$PATCHES" \
    -o "$OUTPUT" \
    -f \
    "$BASE_APK" 2>&1 | grep -E "INFO: Saved|SEVERE|socks5|SOCKS5" || true

# --- Step 3: Inject custom Cronet .so ---
echo "==> Injecting custom Cronet .so..."
TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

mkdir -p "$TMPDIR/lib/arm64-v8a"
cp "$CRONET_SO" "$TMPDIR/lib/arm64-v8a/"
cp "$OUTPUT" "$TMPDIR/youtube-s5.apk"

(cd "$TMPDIR" && \
    zip -d youtube-s5.apk lib/arm64-v8a/libcronet.135.0.7012.3.so && \
    zip -0 youtube-s5.apk lib/arm64-v8a/libcronet.135.0.7012.3.so) > /dev/null

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
