SHELL := /bin/bash

PROJECT := VirtualTabletPad.xcodeproj
SCHEME := MacHost
MAC_PRODUCT := VirtualTabletPad.app
CONFIG ?= Release
DERIVED ?= /tmp/VirtualTabletPadBuild
UPLOADS ?= $(CURDIR)/build/vpad_uploads
SIZE_MB ?= 1
XCODEGEN ?= $(shell command -v xcodegen 2>/dev/null || echo .tools/xcodegen/xcodegen/bin/xcodegen)

IPAD_CONFIG ?= Debug
IPAD_DERIVED ?= /tmp/VirtualTabletPadiPad
IPAD_PRODUCT := $(IPAD_DERIVED)/Build/Products/$(IPAD_CONFIG)-iphonesimulator/$(MAC_PRODUCT)
IPAD_DEVICE_DERIVED ?= /tmp/VirtualTabletPadiPadDevice
IPAD_SIM ?=

.PHONY: help generate test build run run-dev probe ipad-build ipad-device-build ipad-install ipad-smoke clean

help:
	@printf '%s\n' \
	  'make generate         - regenerate VirtualTabletPad.xcodeproj with XcodeGen' \
	  'make test             - run the VPadProtocol test suite' \
	  'make build            - build VirtualTabletPad and stage build/VirtualTabletPad.app' \
	  'make run              - launch the staged Mac app (default ~/Downloads uploads)' \
	  'make run-dev          - launch the Mac app with uploads in build/vpad_uploads' \
	  'make probe            - run the dev probe against a running Mac host' \
	  'make ipad-build       - build VirtualTabletPad for the iOS Simulator' \
	  'make ipad-device-build - compile-check VirtualTabletPad for a generic iOS device' \
	  'make ipad-install     - install/launch on IPAD_SIM=<simulator UDID>' \
	  'make ipad-smoke       - launch with VPAD_AUTO_SMOKE=1 (debug simulator)' \
	  'make clean            - remove staged app, uploads and /tmp build dirs'

generate:
	$(XCODEGEN) generate --spec project.yml

test:
	cd Packages/VPadProtocol && swift test --disable-sandbox --scratch-path /tmp/VPadProtocolBuild

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	  -destination 'generic/platform=macOS' \
	  -derivedDataPath $(DERIVED) \
	  -clonedSourcePackagesDirPath $(DERIVED)/SourcePackages \
	  build
	# Verify the build product outside the file-provider-managed workspace.
	codesign --verify --deep --strict $(DERIVED)/Build/Products/$(CONFIG)/$(MAC_PRODUCT)
	mkdir -p build
	rm -rf build/$(MAC_PRODUCT) build/MacHost.app
	ditto --norsrc --noextattr $(DERIVED)/Build/Products/$(CONFIG)/$(MAC_PRODUCT) build/$(MAC_PRODUCT)
	@xattr -cr build/$(MAC_PRODUCT) || true
	@echo "Built build/$(MAC_PRODUCT) (signed build verified in $(DERIVED))"

run: build
	@xattr -cr build/$(MAC_PRODUCT) || true
	open -n build/$(MAC_PRODUCT)

run-dev: build
	@xattr -cr build/$(MAC_PRODUCT) || true
	mkdir -p "$(UPLOADS)"
	open -n build/$(MAC_PRODUCT) --env VPAD_UPLOADS_DIR="$(UPLOADS)"

probe:
	python3 Tools/vpad_probe.py --host 127.0.0.1 \
	  --uploads "$(UPLOADS)" --size-mb $(SIZE_MB)

ipad-build: generate
	xcodebuild -project $(PROJECT) -scheme iPadClient -configuration $(IPAD_CONFIG) \
	  -destination 'generic/platform=iOS Simulator' \
	  -derivedDataPath $(IPAD_DERIVED) \
	  -clonedSourcePackagesDirPath $(IPAD_DERIVED)/SourcePackages \
	  build CODE_SIGNING_ALLOWED=NO
	@echo "Built $(IPAD_PRODUCT)"

ipad-device-build: generate
	xcodebuild -project $(PROJECT) -scheme iPadClient -configuration $(IPAD_CONFIG) \
	  -destination 'generic/platform=iOS' \
	  -derivedDataPath $(IPAD_DEVICE_DERIVED) \
	  -clonedSourcePackagesDirPath $(IPAD_DEVICE_DERIVED)/SourcePackages \
	  build CODE_SIGNING_ALLOWED=NO

ipad-install: ipad-build
	@test -n "$(IPAD_SIM)" || (echo "Set IPAD_SIM=<simulator UDID>" >&2; exit 1)
	xcrun simctl boot "$(IPAD_SIM)" 2>/dev/null || true
	xcrun simctl install "$(IPAD_SIM)" "$(IPAD_PRODUCT)"
	xcrun simctl launch "$(IPAD_SIM)" com.vpad.iPadClient

ipad-smoke:
	@test -n "$(IPAD_SIM)" || (echo "Set IPAD_SIM=<booted simulator UDID>" >&2; exit 1)
	SIMCTL_CHILD_VPAD_AUTO_SMOKE=1 xcrun simctl launch "$(IPAD_SIM)" com.vpad.iPadClient

clean:
	rm -rf build/VirtualTabletPad.app build/MacHost.app build/vpad_uploads
	rm -rf /tmp/VirtualTabletPadBuild /tmp/VirtualTabletPadBuildDebug /tmp/VPadProtocolBuild
	rm -rf /tmp/VirtualTabletPadiPad /tmp/VirtualTabletPadiPadDevice
