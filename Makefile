# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the kext with the Command Line Tools only (no Xcode needed).
#   make firmware  -> downloads the Realtek firmware from linux-firmware (kernel.org) and checks SHA-256
#   make           -> build/RTL8761BTFirmware.kext, with the firmware embedded unmodified
#   make check     -> checks (kmutil) that Info.plist declares every kernel library the binary uses,
#                     and that the embedded firmware is byte-identical to firmware/*.bin
#   make dist      -> build/RTL8761BTFirmware-<version>-RELEASE.zip
#   make tool      -> build/rtlbtctl (userspace test tool: talks to the dongle without the kext)
#   make clean
# The ld warning "built for newer macOS version (15.5) than being linked (12.0)" is expected:
# the SDK's libkmod objects carry the SDK version, while the kext targets macOS 12+.

NAME      := RTL8761BTFirmware
BUNDLE_ID := io.github.gevuz.RTL8761BTFirmware
VERSION   := 0.1.0
MIN_OS    := 12.0

SDK      := $(shell xcrun --show-sdk-path)
KHEADERS := $(SDK)/System/Library/Frameworks/Kernel.framework/Headers
BUILD    := build
KEXT     := $(BUILD)/$(NAME).kext
BIN      := $(KEXT)/Contents/MacOS/$(NAME)
DIST     := $(BUILD)/$(NAME)-$(VERSION)-RELEASE.zip

FW_URL   := https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain
FW_FILES := firmware/rtl8761bu_fw.bin firmware/rtl8761bu_config.bin firmware/LICENCE.rtlwifi_firmware.txt

COMMON  := -arch x86_64 -mmacosx-version-min=$(MIN_OS) -isysroot $(SDK) \
           -mkernel -nostdinc -I$(KHEADERS) -Isrc -DKERNEL -DDRIVER_PRIVATE \
           -Wall -Wextra -Wno-unused-parameter -O2
# IOUSBHost* is marked "deprecated: Use USBDriverKit", but DriverKit needs an entitlement only Apple
# grants; kexts injected by OpenCore (such as BrcmPatchRAM) keep using this API.
CXXFLAGS := $(COMMON) -std=gnu++17 -fapple-kext -fno-rtti -fno-exceptions \
            -Wno-deprecated-declarations -Wno-inconsistent-missing-override
KCFLAGS  := $(COMMON) -std=gnu11 -DBUNDLE_ID=$(BUNDLE_ID) -DBUNDLE_VERSION='"$(VERSION)"'
# -S: no debug map in the binary (it would carry the build machine's absolute paths).
LDFLAGS  := -arch x86_64 -mmacosx-version-min=$(MIN_OS) -isysroot $(SDK) \
            -nostdlib -Xlinker -kext -Xlinker -S -L$(SDK)/usr/lib -lkmodc++ -lkmod -lcc_kext

KOBJS := $(BUILD)/$(NAME).o $(BUILD)/rtl_epatch.o $(BUILD)/firmware_blob.o $(BUILD)/kmod_info.o

all: $(KEXT)

firmware:
	curl -sfo firmware/rtl8761bu_fw.bin $(FW_URL)/rtl_bt/rtl8761bu_fw.bin
	curl -sfo firmware/rtl8761bu_config.bin $(FW_URL)/rtl_bt/rtl8761bu_config.bin
	curl -sfo firmware/LICENCE.rtlwifi_firmware.txt $(FW_URL)/LICENSES/LICENCE.rtlwifi_firmware.txt
	cd firmware && shasum -a 256 -c SHA256SUMS

$(FW_FILES):
	@echo "Missing $@: run 'make firmware'"; exit 1

# The .bin files become C arrays without any modification; the patch is selected at boot (rtl_epatch.c).
$(BUILD)/firmware_blob.c: $(FW_FILES) firmware/SHA256SUMS | $(BUILD)
	cd firmware && shasum -a 256 -c SHA256SUMS
	(cd firmware && xxd -i rtl8761bu_fw.bin && xxd -i rtl8761bu_config.bin) | sed -E 's/^unsigned /const unsigned /' > $@

$(BUILD)/$(NAME).o: src/$(NAME).cpp src/$(NAME).hpp src/rtl_epatch.h src/firmware_blob.h | $(BUILD)
	clang++ $(CXXFLAGS) -c $< -o $@

$(BUILD)/rtl_epatch.o: src/rtl_epatch.c src/rtl_epatch.h | $(BUILD)
	clang $(KCFLAGS) -c $< -o $@

$(BUILD)/firmware_blob.o: $(BUILD)/firmware_blob.c | $(BUILD)
	clang $(KCFLAGS) -c $< -o $@

$(BUILD)/kmod_info.o: src/kmod_info.c | $(BUILD)
	clang $(KCFLAGS) -c $< -o $@

$(KEXT): $(KOBJS) Info.plist
	mkdir -p $(KEXT)/Contents/MacOS $(KEXT)/Contents/Resources
	clang++ $(LDFLAGS) $(KOBJS) -o $(BIN)
	cp Info.plist $(KEXT)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $(VERSION) $(KEXT)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string $(VERSION) $(KEXT)/Contents/Info.plist
	cp firmware/LICENCE.rtlwifi_firmware.txt $(KEXT)/Contents/Resources/

dist: $(KEXT)
	rm -rf $(BUILD)/dist $(DIST)
	mkdir -p $(BUILD)/dist
	cp -R $(KEXT) LICENSE README.md Changelog.md firmware/LICENCE.rtlwifi_firmware.txt $(BUILD)/dist/
	xattr -cr $(BUILD)/dist
	cd $(BUILD)/dist && zip -qrX ../$(notdir $(DIST)) .
	@echo "$(DIST)"

tool: $(BUILD)/rtlbtctl

$(BUILD)/rtlbtctl: tools/rtlbtctl.m src/rtl_epatch.c src/rtl_epatch.h | $(BUILD)
	clang -Wall -Wextra -O2 -mmacosx-version-min=$(MIN_OS) -c src/rtl_epatch.c -o $(BUILD)/rtl_epatch_user.o
	clang -fobjc-arc -Wall -Wextra -O2 -mmacosx-version-min=$(MIN_OS) -framework Foundation -framework IOKit -framework IOUSBHost \
	      tools/rtlbtctl.m $(BUILD)/rtl_epatch_user.o -o $@

$(BUILD):
	mkdir -p $(BUILD)

# Fails if the binary uses a kernel library that Info.plist does not declare (the kext would not
# load at boot because of unresolved symbols), or if the embedded firmware differs from the files.
check: $(KEXT)
	file $(BIN)
	kmutil libraries -p $(KEXT) --xml 2>/dev/null | grep -oE 'com\.apple\.[A-Za-z.]+' | sort > $(BUILD)/libs-required.txt
	/usr/libexec/PlistBuddy -c "Print :OSBundleLibraries" $(KEXT)/Contents/Info.plist | grep -oE 'com\.apple\.[A-Za-z.]+' | sort > $(BUILD)/libs-declared.txt
	@missing=$$(comm -13 $(BUILD)/libs-declared.txt $(BUILD)/libs-required.txt); \
	if [ -n "$$missing" ]; then echo "Missing from Info.plist OSBundleLibraries: $$missing"; exit 1; fi; \
	echo "OK: declared kernel libraries: $$(tr '\n' ' ' < $(BUILD)/libs-declared.txt)"
	@python3 -c 'import sys; b = open("$(BIN)", "rb").read(); \
	[sys.exit("embedded firmware differs from " + f) for f in ("firmware/rtl8761bu_fw.bin", "firmware/rtl8761bu_config.bin") if b.count(open(f, "rb").read()) != 1]; \
	print("OK: embedded firmware is byte-identical to firmware/*.bin")'

clean:
	rm -rf $(BUILD)

.PHONY: all firmware dist tool check clean
