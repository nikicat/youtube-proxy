# YouTube SOCKS5/HTTPS Proxy - APK build system
#
# Usage:
#   make              Build the patched APK
#   make install      Build and install to connected device
#   make cronet-build Build Cronet from source (rare, hours)
#   make clean        Remove build artifacts
#   make distclean    Remove everything including downloads

# === Configuration (override with make VAR=value or environment) ===
CRONET_VERSION       ?= 135.0.7012.3
REVANCED_CLI_VERSION ?= 5.0.1
APP_NAME             ?= youtube-s5
BASE_APK             ?= com.google.android.youtube@20.12.46.apk

CRONET_SRC           ?= $(HOME)/src/cronet/chromium/src
DEPOT_TOOLS          ?= $(HOME)/src/cronet/depot_tools
BC_JAR               ?= /usr/share/java/bcprov/bcprov.jar
APK_JAR              ?= $(shell dirname "$$(readlink -f "$$(which apksigner)")")/lib/apksigner.jar

KEYSTORE             ?= $(APP_NAME).keystore
KS_ALIAS             ?= ReVanced Key
KS_PASS              ?= pass:
KS_TYPE              ?= BKS

# === Derived paths ===
CRONET_SO       := libcronet.$(CRONET_VERSION).so
REVANCED_CLI    := revanced-patches/revanced-cli.jar
OUTPUT          := $(APP_NAME).apk
PATCHED_APK     := $(APP_NAME)-patched.apk
BUILDDIR        := build

CRONET_URL      := https://github.com/nikicat/youtube-proxy/releases/download/cronet-$(CRONET_VERSION)/$(CRONET_SO)
REVANCED_CLI_URL := https://github.com/ReVanced/revanced-cli/releases/download/v$(REVANCED_CLI_VERSION)/revanced-cli-$(REVANCED_CLI_VERSION)-all.jar

# Patches source files for dependency tracking
PATCHES_SRC := $(shell find revanced-patches/patches/src revanced-patches/extensions/shared/src -name '*.kt' -o -name '*.java' -o -name '*.xml' 2>/dev/null)

.PHONY: all install clean distclean cronet-build

all: $(OUTPUT)

install: $(OUTPUT)
	adb install $<

# === Downloads (Make skips if file exists and has no newer deps) ===

$(CRONET_SO):
	curl -fL -o $@ $(CRONET_URL)

$(REVANCED_CLI):
	curl -fL -o $@ $(REVANCED_CLI_URL)

# === Build ReVanced patches ===

.patches-built: $(PATCHES_SRC) revanced-patches/build.gradle.kts revanced-patches/settings.gradle.kts revanced-patches/gradle.properties
	cd revanced-patches && ./gradlew build -q
	touch $@

# === Patch APK with ReVanced CLI ===
# The .rvp filename includes a version from gradle.properties, found via glob.
# revanced-cli creates $(APP_NAME)-temporary-files/ as a side effect.

$(PATCHED_APK): .patches-built $(REVANCED_CLI) $(BASE_APK)
	RVP=$$(ls revanced-patches/patches/build/libs/patches-*.rvp 2>/dev/null | grep -v sources | grep -v javadoc | head -1); \
	test -n "$$RVP" || { echo "ERROR: No .rvp found after build"; exit 1; }; \
	java -jar $(REVANCED_CLI) patch \
		-p "$$RVP" \
		-e "Override certificate pinning" \
		-o $@ \
		-f \
		$(BASE_APK)

# === Final APK: inject Cronet .so, align, sign ===

$(OUTPUT): $(PATCHED_APK) $(CRONET_SO) $(KEYSTORE)
	@mkdir -p $(BUILDDIR)/lib/arm64-v8a
	cp $(PATCHED_APK) $(BUILDDIR)/$(APP_NAME).apk
	cp $(CRONET_SO) $(BUILDDIR)/lib/arm64-v8a/
	cd $(BUILDDIR) && zip -d $(APP_NAME).apk "lib/arm64-v8a/$(CRONET_SO)" 2>/dev/null || true
	cd $(BUILDDIR) && zip -0 $(APP_NAME).apk "lib/arm64-v8a/$(CRONET_SO)"
	zip -d $(BUILDDIR)/$(APP_NAME).apk "META-INF/*" 2>/dev/null || true
	zipalign -f 4 $(BUILDDIR)/$(APP_NAME).apk $(BUILDDIR)/$(APP_NAME)-aligned.apk
	java -cp "$(APK_JAR):$(BC_JAR)" com.android.apksigner.ApkSignerTool sign \
		--ks $(KEYSTORE) \
		--ks-pass "$(KS_PASS)" \
		--ks-type $(KS_TYPE) \
		--ks-key-alias "$(KS_ALIAS)" \
		--key-pass "$(KS_PASS)" \
		--provider-class org.bouncycastle.jce.provider.BouncyCastleProvider \
		$(BUILDDIR)/$(APP_NAME)-aligned.apk
	mv $(BUILDDIR)/$(APP_NAME)-aligned.apk $@
	@echo "==> Done: $@ ($$(du -h $@ | cut -f1))"

# === Build Cronet from source (optional, rare) ===

cronet-build: patches/cronet-proxy-support.patch
	@if git -C "$(CRONET_SRC)" diff --quiet -- components/cronet; then \
		echo "==> Applying Cronet proxy patch..."; \
		git -C "$(CRONET_SRC)" apply "$(CURDIR)/patches/cronet-proxy-support.patch"; \
	else \
		echo "==> Cronet patch already applied"; \
	fi
	touch "$(CRONET_SRC)/build/__init__.py" \
	      "$(CRONET_SRC)/build/android/__init__.py" \
	      "$(CRONET_SRC)/build/android/gyp/__init__.py"
	PATH="$(DEPOT_TOOLS):$$PATH" ninja -C "$(CRONET_SRC)/out/Cronet" cronet_package -j$$(nproc)
	cp "$(CRONET_SRC)/out/Cronet/cronet/libs/arm64-v8a/$(CRONET_SO)" $(CRONET_SO)
	@echo "==> Built: $(CRONET_SO) ($$(du -h $(CRONET_SO) | cut -f1))"

# === Cleanup ===

clean:
	rm -rf $(BUILDDIR) $(PATCHED_APK) $(OUTPUT) .patches-built
	rm -rf $(APP_NAME)-temporary-files

distclean: clean
	rm -f $(CRONET_SO) $(REVANCED_CLI)
	cd revanced-patches && ./gradlew clean -q
