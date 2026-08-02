# Inspector build and rootless Debian packaging

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/Inspector.xcodeproj
SCHEME              := Inspector
CONFIGURATION       ?= Release
DERIVED_DATA        ?= /private/tmp/inspector-deriveddata
APP_BUNDLE          := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/Inspector.app
PACKAGE_ID          ?= wiki.qaq.inspector
PACKAGE_ARCHITECTURE ?= iphoneos-arm64e
APP_VERSION         := $(strip $(shell awk -F= '/MARKETING_VERSION =/ { gsub(/[;[:space:]]/, "", $$2); print $$2; exit }' "$(PROJECT)/project.pbxproj"))
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/Inspector.entitlements

XCODEBUILD := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY="" \
	IPHONEOS_DEPLOYMENT_TARGET=17.0 \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Inspector.xcodeproj)
endif

.PHONY: all help check build deb clean

all: deb

help:
	@echo "Inspector:"
	@echo "  build   Build the unsigned Inspector.app for iPhoneOS"
	@echo "  deb     Build, ad-hoc sign, and package the rootless .deb"
	@echo "  check   Validate the Xcode project and packaging inputs"
	@echo "  clean   Remove Inspector derived data and generated packages"

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: Inspector.xcodeproj is missing" >&2; exit 66; }
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@test -x "$(DEB_PACKAGER)" || { echo "error: package-deb.sh is not executable" >&2; exit 66; }
	@plutil -lint "$(ENTITLEMENTS)"
	@xcodebuild -project "$(PROJECT)" -list | grep -F "Inspector" >/dev/null

build: check
	XCBUILD_LABEL=build-ios $(XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS" \
		build

deb: build
	"$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)"

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "$(ROOT_DIR)/build/Packages"
