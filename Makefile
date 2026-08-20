# Inspector Xcode build and jailbreak Debian packaging (roothide + rootless)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/Inspector.xcodeproj
SCHEME              := Inspector
CONFIGURATION       ?= Release
DERIVED_DATA        ?= /private/tmp/inspector-deriveddata
APP_BUNDLE          := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/Inspector.app
DAEMON_BINARY       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/cocoainspectord
CLI_BINARY          := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/cocoainspector
PACKAGE_ID          ?= wiki.qaq.inspector
PROJECT_OBJECT_VERSION := 77

# FLAVOR selects the jailbreak layout the .deb is built for:
#   roothide - files ship at rootful paths; roothide's dpkg relocates them into
#              the randomized bootstrap root. Architecture iphoneos-arm64e.
#   rootless - files ship under /var/jb, the fixed rootless prefix (Dopamine,
#              palera1n rootless, ...). Architecture iphoneos-arm64.
# The Mach-O slices are identical for both; only the layout differs.
FLAVOR              ?= roothide
ifeq ($(FLAVOR),roothide)
INSTALL_PREFIX      :=
DEFAULT_ARCHITECTURE := iphoneos-arm64e
else ifeq ($(FLAVOR),rootless)
INSTALL_PREFIX      := /var/jb
DEFAULT_ARCHITECTURE := iphoneos-arm64
else
$(error FLAVOR must be roothide or rootless, got '$(FLAVOR)')
endif
PACKAGE_ARCHITECTURE ?= $(DEFAULT_ARCHITECTURE)
CONFIG_DIR          := $(ROOT_DIR)/Configuration
VERSION_CONFIG      := $(CONFIG_DIR)/Version.xcconfig
BASE_CONFIG         := $(CONFIG_DIR)/Base.xcconfig
xcconfig_setting     = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(VERSION_CONFIG)"))
base_xcconfig_setting = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(BASE_CONFIG)"))
APP_VERSION         := $(call xcconfig_setting,MARKETING_VERSION)
BUILD_NUMBER        := $(call xcconfig_setting,CURRENT_PROJECT_VERSION)
MINIMUM_IOS_VERSION := $(call base_xcconfig_setting,IPHONEOS_DEPLOYMENT_TARGET)
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
VERSION_APPLIER     := $(ROOT_DIR)/Scripts/apply-version.sh
DEB_VERIFIER        := $(ROOT_DIR)/Scripts/verify-deb.sh
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/Inspector.entitlements
DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/CocoaInspectord.entitlements
CLI_ENTITLEMENTS    := $(ROOT_DIR)/Packaging/CocoaInspectorCLI.entitlements
LAUNCH_DAEMON       := $(ROOT_DIR)/Packaging/wiki.qaq.cocoainspectord.plist

XCODEBUILD := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY="" \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Configuration/Version.xcconfig)
endif
ifeq ($(BUILD_NUMBER),)
$(error CURRENT_PROJECT_VERSION is missing from Configuration/Version.xcconfig)
endif

.PHONY: all help print-version print-build-number print-deb-path print-flavor set-version check harness build deb deb-roothide deb-rootless deb-all clean

all: deb-all

help:
	@echo "Inspector:"
	@echo "  build       Build the unsigned Inspector.app for iPhoneOS"
	@echo "  deb         Build, ad-hoc sign, and package the .deb for FLAVOR (default roothide)"
	@echo "  deb-all     Package both the roothide and the rootless .deb"
	@echo "  check       Validate the Xcode project and packaging inputs"
	@echo "  harness     Run the shared data-layer tests on macOS"
	@echo "  set-version Write VERSION=x.y.z [BUILD=n] into Configuration/Version.xcconfig"
	@echo "  clean       Remove Inspector derived data and generated packages"

print-version:
	@echo "$(APP_VERSION)"

print-build-number:
	@echo "$(BUILD_NUMBER)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

print-flavor:
	@echo "$(FLAVOR)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3 [BUILD=42]" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)" $(BUILD)

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: Inspector.xcodeproj is missing" >&2; exit 66; }
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@test -x "$(DEB_PACKAGER)" || { echo "error: package-deb.sh is not executable" >&2; exit 66; }
	@test -x "$(VERSION_APPLIER)" || { echo "error: apply-version.sh is not executable" >&2; exit 66; }
	@test -x "$(DEB_VERIFIER)" || { echo "error: verify-deb.sh is not executable" >&2; exit 66; }
	@for xcconfig in Version Base Development Release; do \
		test -f "$(CONFIG_DIR)/$$xcconfig.xcconfig" || { echo "error: Configuration/$$xcconfig.xcconfig is missing" >&2; exit 66; }; \
	done
	@[[ "$(APP_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: MARKETING_VERSION must look like 1.2.3, got '$(APP_VERSION)'" >&2; exit 65; }
	@[[ "$(BUILD_NUMBER)" =~ ^[0-9]+$$ ]] || { echo "error: CURRENT_PROJECT_VERSION must be an integer, got '$(BUILD_NUMBER)'" >&2; exit 65; }
	@[[ "$(MINIMUM_IOS_VERSION)" =~ ^[0-9]+\.[0-9]+$$ ]] || { echo "error: IPHONEOS_DEPLOYMENT_TARGET must look like 16.0, got '$(MINIMUM_IOS_VERSION)'" >&2; exit 65; }
	@grep -qE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) =' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: versions must live in Configuration/Version.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -q 'IPHONEOS_DEPLOYMENT_TARGET' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: deployment target must live in Configuration/Base.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -Fq "Depends: firmware (>= $(MINIMUM_IOS_VERSION))" "$(CONTROL_TEMPLATE)" \
		|| { echo "error: Debian firmware dependency must match iOS $(MINIMUM_IOS_VERSION)" >&2; exit 65; }
	@objver="$$(sed -n 's/^[[:space:]]*objectVersion = \([0-9]*\);.*/\1/p' "$(PROJECT)/project.pbxproj")"; \
		[[ "$$objver" == "$(PROJECT_OBJECT_VERSION)" ]] || { echo "error: project.pbxproj objectVersion must stay $(PROJECT_OBJECT_VERSION) so Xcode 16+ and the CI runner can read it, got '$$objver' (newer Xcode rewrites it on save)" >&2; exit 65; }
	@plutil -lint "$(ENTITLEMENTS)"
	@plutil -lint "$(DAEMON_ENTITLEMENTS)" "$(CLI_ENTITLEMENTS)" "$(LAUNCH_DAEMON)"
	@targets="$$(xcodebuild -project "$(PROJECT)" -list)"; \
	grep -F "CocoaInspectord" <<<"$$targets" >/dev/null; \
	grep -F "CocoaInspectorCLI" <<<"$$targets" >/dev/null; \
	grep -F "Inspector" <<<"$$targets" >/dev/null

harness:
	@harness_bin="$$(mktemp /tmp/cocoainspector-harness.XXXXXX)"; \
	trap 'rm -f "$$harness_bin"' EXIT; \
	xcrun --sdk macosx swiftc -swift-version 5 "$(ROOT_DIR)"/Shared/*.swift "$(ROOT_DIR)/Tests/DataLayerHarness.swift" -o "$$harness_bin"; \
	"$$harness_bin"

build: check harness
	XCBUILD_LABEL=build-ios $(XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS" \
		build

deb: build
	"$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(DAEMON_BINARY)" \
		"$(CLI_BINARY)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DAEMON_ENTITLEMENTS)" \
		"$(CLI_ENTITLEMENTS)" \
		"$(LAUNCH_DAEMON)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(FLAVOR)" \
		"$(INSTALL_PREFIX)"
	"$(DEB_VERIFIER)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(INSTALL_PREFIX)"

deb-roothide:
	@$(MAKE) --no-print-directory deb FLAVOR=roothide

deb-rootless:
	@$(MAKE) --no-print-directory deb FLAVOR=rootless

deb-all: deb-roothide deb-rootless

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "$(ROOT_DIR)/build/Packages"
