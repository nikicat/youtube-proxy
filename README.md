# YouTube SOCKS5/HTTPS Proxy

A patched YouTube APK that routes **all** traffic through a SOCKS5 or HTTPS CONNECT proxy. The HTTPS proxy mode makes proxy usage indistinguishable from regular HTTPS traffic.

## How It Works

```
Phone (YouTube APK)
  └─ Cronet (native HTTP engine)
       └─ proxy_rules: "https://proxy.example.com:443"
            └─ TLS to proxy ──► CONNECT target:443 ──► target server
```

Two layers of patches:

1. **Cronet native patch** — Adds `proxy_rules` support to Chromium's Cronet via its experimental options JSON. When set, all Cronet traffic routes through the specified proxy (SOCKS5 or HTTPS CONNECT).

2. **ReVanced bytecode patch** — Hooks `CronetEngine.Builder.build()` to:
   - Inject `{"proxy_rules":"https://host:port"}` via `setExperimentalOptions()`
   - Disable QUIC (UDP bypasses TCP proxies)
   - Install `CronetURLStreamHandlerFactory` so Java `HttpURLConnection` calls also route through Cronet's proxy

## Architecture

### Why a custom Cronet build?

YouTube bundles Cronet 135.0.7012.3 as its HTTP engine. Stock Cronet has no API to configure a proxy — it uses the system proxy or none. Our patch adds a `proxy_rules` key to Cronet's experimental options, which configures a `ProxyConfigServiceFixed` with the given proxy rules. Chromium's net stack already has full SOCKS5 and HTTPS proxy support; we're just plumbing the configuration through.

### Why CronetURLStreamHandlerFactory?

YouTube's ReVanced extensions (SponsorBlock, Return YouTube Dislike, streaming data spoofing) use Java's `HttpURLConnection` instead of Cronet. These bypass the native proxy. Cronet includes `CronetURLStreamHandlerFactory` which, when installed via `URL.setURLStreamHandlerFactory()`, makes all `URL.openConnection()` calls use Cronet under the hood. This routes 100% of HTTP traffic through the proxy with zero changes to the extension code.

### Why HTTPS proxy over SOCKS5?

SOCKS5 traffic is distinguishable from regular HTTPS — different protocol, typically non-standard port. An HTTPS CONNECT proxy listens on port 443 with a TLS certificate, making the client-to-proxy connection indistinguishable from browsing a regular website.

## Prerequisites

- **Android SDK**: `zipalign`, `apksigner` (from build-tools)
- **Java 17+**: For ReVanced CLI and Gradle
- **Go**: For the HTTPS proxy server
- **revanced-cli**: Download from [ReVanced releases](https://github.com/ReVanced/revanced-cli/releases) and place at `revanced-patches/revanced-cli.jar`
- **BouncyCastle JAR**: For BKS keystore signing (e.g. `bcprov-jdk15to18-*.jar`)
- **YouTube APK**: `com.google.android.youtube@20.12.46.apk` (place in repo root)

## Building Cronet from Source (optional)

The build script automatically downloads a prebuilt `libcronet.*.so` from [GitHub Releases](https://github.com/nikicat/youtube-proxy/releases). You only need to build from source if you want to modify the Cronet patch.

One-time setup (~2-4 hours, ~100GB disk):

```bash
# 1. Get depot_tools
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/src/cronet/depot_tools
export PATH=~/src/cronet/depot_tools:$PATH

# 2. Fetch Chromium Android source (~30GB)
mkdir -p ~/src/cronet/chromium && cd ~/src/cronet/chromium
fetch --nohooks --no-history android

# 3. Checkout the exact version YouTube uses
cd src
git fetch origin refs/tags/135.0.7012.3:refs/tags/135.0.7012.3 --no-tags
git checkout -B build-135 tags/135.0.7012.3
gclient sync --nohooks --no-history
gclient runhooks

# 4. Apply our proxy patch
git apply /path/to/youtube-socks5/patches/cronet-proxy-support.patch
# Create __init__.py files for Python 3.14 compatibility
touch build/__init__.py build/android/__init__.py build/android/gyp/__init__.py

# 5. Configure and build
./components/cronet/tools/cr_cronet.py gn --out_dir=out/Cronet --release
sed -i 's/use_remoteexec = true/use_remoteexec = false/' out/Cronet/args.gn
sed -i 's/is_official_build = true/is_official_build = false/' out/Cronet/args.gn
gn gen out/Cronet
ninja -C out/Cronet cronet_package -j$(nproc)
```

Output: `out/Cronet/cronet/libs/arm64-v8a/libcronet.135.0.7012.3.so`

To rebuild and use your local build:

```bash
./build-cronet.sh   # builds and copies .so to repo root
./build.sh           # uses the local .so instead of downloading
```

## Building the APK

```bash
# Initialize submodule
git submodule update --init

# Place YouTube APK and revanced-cli in repo root
# Then build:
./build.sh
```

The build script:
1. Downloads prebuilt Cronet .so from GitHub Releases (cached locally)
2. Builds ReVanced patches with Gradle
3. Patches the YouTube APK with revanced-cli
4. Replaces `libcronet.135.0.7012.3.so` with our custom build
5. Re-aligns and re-signs the APK

Output: `youtube-s5.apk`

## Proxy Server Setup

### HTTPS CONNECT Proxy (recommended)

Build and run the included Go proxy:

```bash
# Generate TLS certificate
mkdir -p certs
openssl req -x509 -newkey rsa:2048 -keyout certs/proxy.key -out certs/proxy.crt \
  -days 3650 -nodes -subj "/CN=your-proxy-host" -addext "subjectAltName=DNS:your-proxy-host"

# Build and run
go build -o https-proxy proxy.go
./https-proxy 0.0.0.0:443
```

For self-signed certs, install the CA on Android (Settings > Security > Install certificate) and the APK includes the "Override certificate pinning" patch to trust user CAs.

For production, use a real domain with Let's Encrypt — no CA installation needed.

### SOCKS5 Proxy (alternative)

```bash
# Using dante
sockd -f sockd.conf
```

### App Configuration

In the YouTube S5 app: Settings > SOCKS5 proxy:
- **Enabled**: On
- **Proxy type**: `https` or `socks5`
- **Host**: your proxy hostname/IP
- **Port**: proxy port

## Testing with Blocked Internet

To verify all traffic goes through the proxy, block direct internet on a Tailscale exit node:

```bash
# Block forwarded traffic from Tailscale clients
iptables -I FORWARD 1 -s 100.64.0.0/10 -j DROP

# Undo:
iptables -D FORWARD -s 100.64.0.0/10 -j DROP
```

The phone can still reach the proxy (local to the exit node), but can't access the internet directly. If the app works — recommendations load, videos play — all traffic is going through the proxy.

## Files

| File | Description |
|------|-------------|
| `build.sh` | Builds everything: Cronet, patches, APK |
| `proxy.go` | HTTPS CONNECT proxy server (Go) |
| `patches/cronet-proxy-support.patch` | Chromium/Cronet source patch |
| `revanced-patches/` | ReVanced patches submodule (bytecode + Java extensions) |
| `sockd.conf` | Dante SOCKS5 proxy config (example) |
| `stunnel.conf` | stunnel TLS wrapper config (example) |
| `tinyproxy.conf` | tinyproxy HTTP CONNECT config (example) |

## Key Technical Decisions

- **Experimental options over new API**: Adding a new Java API to Cronet would require modifying the public API surface, protobuf definitions, and Java bindings. Using the existing `setExperimentalOptions()` JSON mechanism required only 3 files changed in native code.

- **CronetURLStreamHandlerFactory over per-call proxying**: Rather than modifying 14+ HTTP calling sites in ReVanced extensions, installing the factory with a single `URL.setURLStreamHandlerFactory()` call routes everything through Cronet automatically.

- **Python 3.14 compatibility fixes**: Chromium 135's build scripts have two issues with Python 3.14: a `%` in an argparse help string (escaped to `%%`), and missing `__init__.py` files for `build.android` package imports.

- **BKS keystore**: ReVanced CLI uses BouncyCastle KeyStore format with empty password. Signing with `apksigner` requires the BouncyCastle provider JAR on the classpath.
