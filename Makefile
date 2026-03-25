# YouTube SOCKS5/HTTPS Proxy - APK build system
#
# Usage:
#   make              Build the patched APK
#   make install      Build and install to connected device
#   make cronet-build Build Cronet from source (rare, hours)
#   make clean        Remove build artifacts
#   make distclean    Remove everything including downloads

# === Configuration (override with make VAR=value or environment) ===
REVANCED_CLI_VERSION ?= 5.0.1
APKMD_VERSION        ?= 2.0.10
APP_PACKAGE          ?= com.youtube.s5
YT_VERSION           ?= 20.05.46
BASE_APK_NAME        ?= com.google.android.youtube@$(YT_VERSION).apk

# YouTube version → bundled Cronet version mapping.
# Find with: unzip -l <youtube.apk> | grep libcronet
CRONET_VERSION_20.05.46 := 133.0.6876.3
CRONET_VERSION_20.12.46 := 135.0.7012.3

CRONET_VERSION := $(CRONET_VERSION_$(YT_VERSION))
$(if $(CRONET_VERSION),,$(error No Cronet version mapped for YT_VERSION=$(YT_VERSION). Add CRONET_VERSION_$(YT_VERSION) above.))

CHROMIUM_DIR         := chromium
CRONET_SRC           := $(CHROMIUM_DIR)/src
DEPOT_TOOLS          := $(CHROMIUM_DIR)/depot_tools
BC_JAR               ?= /usr/share/java/bcprov/bcprov.jar
APK_JAR              ?= $(shell dirname "$$(readlink -f "$$(which apksigner)")")/lib/apksigner.jar

KEYSTORE             ?= youtube-s5.keystore
KS_ALIAS             ?= ReVanced Key
KS_PASS              ?= pass:
KS_TYPE              ?= BKS

# === Derived paths ===
BUILDDIR        := build
DLDIR           := dl
CRONET_SO_NAME  := libcronet.$(CRONET_VERSION).so
CRONET_SO       := $(DLDIR)/$(CRONET_SO_NAME)
REVANCED_CLI    := $(DLDIR)/revanced-cli.jar
APKMD           := $(DLDIR)/apkmd
BASE_APK        := $(DLDIR)/$(BASE_APK_NAME)
PATCHED_APK     := $(BUILDDIR)/$(APP_PACKAGE)-patched.apk
OUTPUT          := $(BUILDDIR)/$(APP_PACKAGE).apk

CRONET_URL      := https://github.com/nikicat/youtube-proxy/releases/download/cronet-$(CRONET_VERSION)/$(CRONET_SO_NAME)
REVANCED_CLI_URL := https://github.com/ReVanced/revanced-cli/releases/download/v$(REVANCED_CLI_VERSION)/revanced-cli-$(REVANCED_CLI_VERSION)-all.jar
APKMD_URL       := https://github.com/tanishqmanuja/apkmirror-downloader/releases/download/v$(APKMD_VERSION)/apkmd

# Patches source files for dependency tracking.
# Use find-newer to only check if any source is newer than the stamp,
# avoiding expanding hundreds of files as prerequisites.
PATCHES_DIRS := revanced-patches/patches/src revanced-patches/extensions/shared/src

.PHONY: all install uninstall uninstall-all clean clean-all distclean cronet-build chromium-init

all: $(OUTPUT)

install: $(OUTPUT)
	adb install -r -d $<

uninstall:
	adb uninstall $(APP_PACKAGE)

uninstall-all:
	@for uid in $$(adb shell pm list users | grep -oP 'UserInfo\{\K[0-9]+'); do \
		echo "Uninstalling $(APP_PACKAGE) for user $$uid"; \
		adb shell pm uninstall --user $$uid $(APP_PACKAGE) || true; \
	done

# === Downloads (Make skips if file exists and has no newer deps) ===

$(CRONET_SO): | $(DLDIR)
	curl -fL -o $@ $(CRONET_URL)

$(REVANCED_CLI): | $(DLDIR)
	curl -fL -o $@ $(REVANCED_CLI_URL)

$(APKMD): | $(DLDIR)
	curl -fL -o $@ $(APKMD_URL)
	chmod +x $@

$(BASE_APK): $(APKMD) | $(DLDIR)
	./$(APKMD) download google-inc youtube -v "$(YT_VERSION)" -a arm64-v8a -t apk --outdir $(DLDIR) -o "$(basename $(BASE_APK_NAME))"

$(DLDIR):
	mkdir -p $@

# === Build ReVanced patches ===

.patches-built: FORCE revanced-patches/build.gradle.kts revanced-patches/settings.gradle.kts revanced-patches/gradle.properties
	@if [ ! -f $@ ] || [ -n "$$(find $(PATCHES_DIRS) -newer $@ \( -name '*.kt' -o -name '*.java' -o -name '*.xml' \) -print -quit 2>/dev/null)" ]; then \
		(cd revanced-patches && ./gradlew build -q) && touch $@; \
	fi
FORCE:

# === Patch APK with ReVanced CLI ===
# The .rvp filename includes a version from gradle.properties, found via glob.
# NB: -O must immediately precede its -e; picocli binds options to the prior -e otherwise.

$(PATCHED_APK): .patches-built $(REVANCED_CLI) $(BASE_APK)
	@mkdir -p $(BUILDDIR)
	RVP=$$(ls revanced-patches/patches/build/libs/patches-*.rvp 2>/dev/null | grep -v sources | grep -v javadoc | head -1); \
	test -n "$$RVP" || { echo "ERROR: No .rvp found after build"; exit 1; }; \
	java -jar $(REVANCED_CLI) patch \
		-p "$$RVP" \
		-O "packageNameYouTube=$(APP_PACKAGE)" -e "GmsCore support" \
		-e "Override certificate pinning" \
		-t $(CURDIR)/$(BUILDDIR)/temporary-files \
		-o $@ \
		-f \
		$(BASE_APK)

# === Signing keystore (auto-generated if missing) ===

$(KEYSTORE):
	keytool -genkeypair -v \
		-keystore $@ -storetype $(KS_TYPE) \
		-alias "$(KS_ALIAS)" -keyalg EC \
		-storepass "$(subst pass:,,$(KS_PASS))" -keypass "$(subst pass:,,$(KS_PASS))" \
		-dname "CN=ReVanced" \
		-providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
		-providerpath $(BC_JAR)

# === Final APK: inject Cronet .so, align, sign ===

$(OUTPUT): $(PATCHED_APK) $(CRONET_SO) $(KEYSTORE)
	@mkdir -p $(BUILDDIR)/lib/arm64-v8a
	cp $(PATCHED_APK) $@.tmp
	cp $(CRONET_SO) $(BUILDDIR)/lib/arm64-v8a/$(CRONET_SO_NAME)
	# Replace bundled Cronet .so with our proxy-enabled build (all architectures).
	@zip -d $@.tmp "lib/*/$(CRONET_SO_NAME)" >/dev/null 2>&1 || true
	cd $(BUILDDIR) && zip -0 $(notdir $@).tmp "lib/arm64-v8a/$(CRONET_SO_NAME)"
	@zip -d $@.tmp "META-INF/*" >/dev/null 2>&1 || true
	zipalign -f 4 $@.tmp $@.aligned
	java -cp "$(APK_JAR):$(BC_JAR)" com.android.apksigner.ApkSignerTool sign \
		--ks $(KEYSTORE) \
		--ks-pass "$(KS_PASS)" \
		--ks-type $(KS_TYPE) \
		--ks-key-alias "$(KS_ALIAS)" \
		--key-pass "$(KS_PASS)" \
		--provider-class org.bouncycastle.jce.provider.BouncyCastleProvider \
		$@.aligned
	mv $@.aligned $@
	rm -f $@.tmp
	@echo "==> Done: $@ ($$(du -h $@ | cut -f1))"

# === Chromium / Cronet (optional, build from source) ===

$(DEPOT_TOOLS):
	git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $@

$(CRONET_SRC): $(DEPOT_TOOLS)
	mkdir -p $(CHROMIUM_DIR)
	cd $(CHROMIUM_DIR) && printf 'solutions=[{"name":"src","url":"https://chromium.googlesource.com/chromium/src.git","managed":False}]\ntarget_os=["android"]\n' > .gclient
	cd $(CHROMIUM_DIR) && PATH="$(CURDIR)/$(DEPOT_TOOLS):$$PATH" gclient sync --no-history --nohooks

# One-time setup: clone depot_tools and fetch Chromium source (~30 GB).
chromium-init: $(CRONET_SRC)

cronet-build: patches/cronet-proxy-support.patch | $(CRONET_SRC)
	# Checkout the correct Chromium version and sync dependencies.
	git -C "$(CRONET_SRC)" checkout -- .
	git -C "$(CRONET_SRC)" fetch --depth=1 origin tag $(CRONET_VERSION)
	git -C "$(CRONET_SRC)" checkout FETCH_HEAD
	cd "$(CHROMIUM_DIR)" && PATH="$(CURDIR)/$(DEPOT_TOOLS):$$PATH" gclient sync --nohooks --force
	# Apply proxy support patch if not already applied.
	@if git -C "$(CRONET_SRC)" diff --quiet -- components/cronet; then \
		echo "==> Applying Cronet proxy patch..."; \
		git -C "$(CRONET_SRC)" apply "$(CURDIR)/patches/cronet-proxy-support.patch"; \
	else \
		echo "==> Cronet patch already applied"; \
	fi
	touch "$(CRONET_SRC)/build/__init__.py" \
	      "$(CRONET_SRC)/build/android/__init__.py" \
	      "$(CRONET_SRC)/build/android/gyp/__init__.py"
	PATH="$(CURDIR)/$(DEPOT_TOOLS):$$PATH" ninja -C "$(CRONET_SRC)/out/Cronet" cronet_package -j$$(nproc)
	mkdir -p $(DLDIR)
	cp "$(CRONET_SRC)/out/Cronet/cronet/libs/arm64-v8a/$(CRONET_SO_NAME)" $(CRONET_SO)
	@echo "==> Built: $(CRONET_SO) ($$(du -h $(CRONET_SO) | cut -f1))"

# === Cleanup ===

clean:
	rm -f $(BUILDDIR)/$(APP_PACKAGE)-patched.apk $(BUILDDIR)/$(APP_PACKAGE).apk
	rm -f $(BUILDDIR)/$(APP_PACKAGE)-patched.keystore $(BUILDDIR)/$(APP_PACKAGE).apk.aligned.idsig
	rm -rf $(BUILDDIR)/temporary-files

clean-all:
	rm -rf $(BUILDDIR) .patches-built

distclean: clean-all
	rm -rf $(DLDIR)
	cd revanced-patches && ./gradlew clean -q
