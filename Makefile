APP := build/FFmpeg Media Extension.app
EXTENSION := $(APP)/Contents/Extensions/MKVFormatReader.appex
VIDEO_DECODER := $(APP)/Contents/Extensions/FFmpegVideoDecoder.appex
HOST_BINARY := $(APP)/Contents/MacOS/FFmpeg Media Extension
EXTENSION_BINARY := $(EXTENSION)/Contents/MacOS/MKVFormatReader
VIDEO_DECODER_BINARY := $(VIDEO_DECODER)/Contents/MacOS/FFmpegVideoDecoder

FFMPEG_SOURCE ?= FFmpeg
FFMPEG_SOURCE_PATH := $(abspath $(FFMPEG_SOURCE))
DEPLOYMENT_TARGET := 15.0
TEAM_ID ?=
SIGN_IDENTITY ?= Apple Development
MEDIA_DIR ?= $(HOME)/Movies
SHARE_MEDIA_DIR ?=
PROVISION_DERIVED := build/ProvisioningDerived
PROVISIONED_EXTENSION := $(PROVISION_DERIVED)/Build/Products/Debug/MKVFormatReader.appex
PROVISION_XCENT := $(PROVISION_DERIVED)/Build/Intermediates.noindex/FFmpegMediaExtension.build/Debug/ProvisionFormatReader.build/MKVFormatReader.appex.xcent
VIDEO_PROVISION_DERIVED := build/ProvisioningVideoVP9Derived
PROVISIONED_VIDEO_DECODER := $(VIDEO_PROVISION_DERIVED)/Build/Products/Debug/FFmpegVideoDecoder.appex
VIDEO_PROVISION_XCENT := $(VIDEO_PROVISION_DERIVED)/Build/Intermediates.noindex/FFmpegMediaExtension.build/Debug/ProvisionFormatReader.build/FFmpegVideoDecoder.appex.xcent

FFMPEG_FLAGS := \
	--disable-everything --disable-programs --disable-doc --disable-debug \
	--enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
	--enable-demuxer=matroska \
	--enable-decoder=aac,dca \
	--enable-parser=aac,ac3,av1,dca,flac,h264,hevc,mpeg4video,mpegaudio,opus,vp9 \
	--enable-pic --enable-static --disable-shared

FFMPEG_DECODER_FLAGS := \
	--disable-everything --disable-programs --disable-doc --disable-debug \
	--enable-avcodec --enable-avutil --enable-swscale \
	--enable-decoder=vp9,av1,mpeg2video \
	--enable-pic --enable-static --disable-shared

FORMAT_READER_SOURCES := \
	Sources/FormatReader/FMEFormatReader.m \
	Sources/FormatReader/FMEAsset.m \
	Sources/FormatReader/FMETrackReader.m \
	Sources/FormatReader/FMESampleCursor.m

FORMAT_READER_HEADERS := \
	Sources/FormatReader/FMEAsset.h \
	Sources/FormatReader/FMECommon.h \
	Sources/FormatReader/FMESampleCursor.h \
	Sources/FormatReader/FMETrackReader.h

.PHONY: all bundle unsigned provision verify-signing-config verify-test-media sign install register test integration-test probe inspect clean ffmpeg FORCE

all: bundle

ffmpeg: build/ffmpeg/arm64/libavformat/libavformat.a build/ffmpeg-decoder/arm64/libswscale/libswscale.a

FORCE:

build/ffmpeg/arm64/.configuration: FORCE Makefile
	@mkdir -p $(@D)
	@state_file="$@.tmp"; \
	printf '%s\n' \
		"source=$$(git -C '$(FFMPEG_SOURCE_PATH)' rev-parse HEAD 2>/dev/null || stat -f %m '$(FFMPEG_SOURCE_PATH)/configure')" \
		"source-diff=$$(git -C '$(FFMPEG_SOURCE_PATH)' diff --no-ext-diff --binary HEAD 2>/dev/null | shasum -a 256 | awk '{print $$1}')" \
		"deployment=$(DEPLOYMENT_TARGET)" \
		"flags=$(FFMPEG_FLAGS)" > "$$state_file"; \
	if ! cmp -s "$$state_file" "$@"; then mv "$$state_file" "$@"; else rm "$$state_file"; fi

build/ffmpeg-decoder/arm64/.configuration: FORCE Makefile
	@mkdir -p $(@D)
	@state_file="$@.tmp"; \
	printf '%s\n' \
		"source=$$(git -C '$(FFMPEG_SOURCE_PATH)' rev-parse HEAD 2>/dev/null || stat -f %m '$(FFMPEG_SOURCE_PATH)/configure')" \
		"source-diff=$$(git -C '$(FFMPEG_SOURCE_PATH)' diff --no-ext-diff --binary HEAD 2>/dev/null | shasum -a 256 | awk '{print $$1}')" \
		"deployment=$(DEPLOYMENT_TARGET)" \
		"flags=$(FFMPEG_DECODER_FLAGS)" > "$$state_file"; \
	if ! cmp -s "$$state_file" "$@"; then mv "$$state_file" "$@"; else rm "$$state_file"; fi

build/ffmpeg/arm64/libavformat/libavformat.a: build/ffmpeg/arm64/.configuration
	mkdir -p build/ffmpeg/arm64
	@if test -f build/ffmpeg/arm64/Makefile; then $(MAKE) -C build/ffmpeg/arm64 distclean; fi
	cd build/ffmpeg/arm64 && $(FFMPEG_SOURCE_PATH)/configure \
		--arch=arm64 --target-os=darwin --cc='clang -arch arm64' \
		--extra-cflags='-mmacosx-version-min=$(DEPLOYMENT_TARGET)' \
		--extra-ldflags='-mmacosx-version-min=$(DEPLOYMENT_TARGET)' $(FFMPEG_FLAGS)
	$(MAKE) -C build/ffmpeg/arm64 -j$$(sysctl -n hw.ncpu)
build/ffmpeg-decoder/arm64/libswscale/libswscale.a: build/ffmpeg-decoder/arm64/.configuration
	mkdir -p build/ffmpeg-decoder/arm64
	@if test -f build/ffmpeg-decoder/arm64/Makefile; then $(MAKE) -C build/ffmpeg-decoder/arm64 distclean; fi
	cd build/ffmpeg-decoder/arm64 && $(FFMPEG_SOURCE_PATH)/configure \
		--arch=arm64 --target-os=darwin --cc='clang -arch arm64' \
		--extra-cflags='-mmacosx-version-min=$(DEPLOYMENT_TARGET)' \
		--extra-ldflags='-mmacosx-version-min=$(DEPLOYMENT_TARGET)' $(FFMPEG_DECODER_FLAGS)
	$(MAKE) -C build/ffmpeg-decoder/arm64 -j$$(sysctl -n hw.ncpu)

build/host-arm64: Sources/Host/main.swift
	mkdir -p build
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache-arm64 \
		swiftc -module-cache-path $(CURDIR)/build/ModuleCache-arm64 \
		-target arm64-apple-macosx$(DEPLOYMENT_TARGET) -swift-version 6 -O \
		Sources/Host/main.swift -framework AppKit -framework MediaToolbox -framework VideoToolbox \
		-o $@

build/format-reader-arm64: $(FORMAT_READER_SOURCES) $(FORMAT_READER_HEADERS) Makefile build/ffmpeg/arm64/libavformat/libavformat.a
	mkdir -p build
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache-arm64 \
	clang -fobjc-arc -fmodules -fblocks -target arm64-apple-macosx$(DEPLOYMENT_TARGET) \
		-O2 -Werror=return-type -Wno-deprecated-declarations \
		-Ibuild/ffmpeg/arm64 -I$(FFMPEG_SOURCE_PATH) -ISources/FormatReader $(FORMAT_READER_SOURCES) \
		build/ffmpeg/arm64/libavformat/libavformat.a \
		build/ffmpeg/arm64/libavcodec/libavcodec.a \
		build/ffmpeg/arm64/libswresample/libswresample.a \
		build/ffmpeg/arm64/libavutil/libavutil.a \
		-framework Foundation -framework AVFoundation -framework CoreMedia \
		-framework CoreAudio -framework MediaExtension -framework UniformTypeIdentifiers \
		-lz -lbz2 -liconv -Xlinker -e -Xlinker _NSExtensionMain -o $@

build/video-decoder-arm64: Sources/VideoDecoder/FMEVideoDecoder.m Makefile build/ffmpeg-decoder/arm64/libswscale/libswscale.a
	mkdir -p build
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache-arm64 \
	clang -fobjc-arc -fmodules -fblocks -target arm64-apple-macosx$(DEPLOYMENT_TARGET) \
		-O2 -Werror=return-type -Wno-deprecated-declarations \
		-Ibuild/ffmpeg-decoder/arm64 -I$(FFMPEG_SOURCE_PATH) Sources/VideoDecoder/FMEVideoDecoder.m \
		build/ffmpeg-decoder/arm64/libswscale/libswscale.a \
		build/ffmpeg-decoder/arm64/libavcodec/libavcodec.a \
		build/ffmpeg-decoder/arm64/libavutil/libavutil.a \
		-framework Foundation -framework CoreMedia -framework CoreVideo \
		-framework VideoToolbox -framework MediaExtension \
		-liconv -lz \
		-Xlinker -e -Xlinker _NSExtensionMain -o $@

unsigned: build/host-arm64 build/format-reader-arm64 build/video-decoder-arm64 Resources/HostInfo.plist Resources/FormatReaderInfo.plist Resources/VideoDecoderInfo.plist Resources/AppIcon.icns Resources/AppIcon.png Resources/GitHub_Invertocat_Black.svg LICENSE THIRD_PARTY_NOTICES.md FFmpeg/COPYING.LGPLv2.1
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(EXTENSION)/Contents/MacOS" "$(VIDEO_DECODER)/Contents/MacOS"
	cp Resources/HostInfo.plist "$(APP)/Contents/Info.plist"
	cp Resources/FormatReaderInfo.plist "$(EXTENSION)/Contents/Info.plist"
	cp Resources/VideoDecoderInfo.plist "$(VIDEO_DECODER)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp Resources/AppIcon.png "$(APP)/Contents/Resources/AppIcon.png"
	cp Resources/GitHub_Invertocat_Black.svg "$(APP)/Contents/Resources/GitHub_Invertocat_Black.svg"
	cp LICENSE "$(APP)/Contents/Resources/Project-MIT-License.txt"
	cp THIRD_PARTY_NOTICES.md "$(APP)/Contents/Resources/Third-Party-Notices.md"
	cp FFmpeg/COPYING.LGPLv2.1 "$(APP)/Contents/Resources/FFmpeg-LGPL-2.1.txt"
	cp build/host-arm64 "$(HOST_BINARY)"
	cp build/format-reader-arm64 "$(EXTENSION_BINARY)"
	cp build/video-decoder-arm64 "$(VIDEO_DECODER_BINARY)"

verify-signing-config:
	@test -n "$(TEAM_ID)" || { printf '%s\n' 'TEAM_ID is required for provisioning and signed installation targets.' >&2; exit 64; }

provision: verify-signing-config
	xcodebuild -project FFmpegMediaExtension.xcodeproj \
		-scheme ProvisionFormatReader -configuration Debug \
		-derivedDataPath "$(PROVISION_DERIVED)" \
		DEVELOPMENT_TEAM="$(TEAM_ID)" \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration build
	xcodebuild -project FFmpegMediaExtension.xcodeproj \
		-scheme ProvisionFormatReader -configuration Debug \
		-derivedDataPath "$(VIDEO_PROVISION_DERIVED)" \
		DEVELOPMENT_TEAM="$(TEAM_ID)" \
		PRODUCT_BUNDLE_IDENTIFIER=lv.apps.ffmpeg-media-extension.videodecoder.vp9 \
		PRODUCT_NAME=FFmpegVideoDecoder \
		INFOPLIST_FILE=Resources/VideoDecoderInfo.plist \
		CODE_SIGN_ENTITLEMENTS=Resources/VideoDecoder.entitlements \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration build

sign: unsigned provision
	cp "$(PROVISIONED_EXTENSION)/Contents/embedded.provisionprofile" \
		"$(EXTENSION)/Contents/embedded.provisionprofile"
	codesign --force --timestamp=none --sign "$(SIGN_IDENTITY)" \
		--entitlements "$(PROVISION_XCENT)" "$(EXTENSION)"
	cp "$(PROVISIONED_VIDEO_DECODER)/Contents/embedded.provisionprofile" \
		"$(VIDEO_DECODER)/Contents/embedded.provisionprofile"
	codesign --force --timestamp=none --sign "$(SIGN_IDENTITY)" \
		--entitlements "$(VIDEO_PROVISION_XCENT)" "$(VIDEO_DECODER)"
	codesign --force --timestamp=none --sign "$(SIGN_IDENTITY)" "$(APP)"

bundle: unsigned
	codesign --force --timestamp=none --sign - \
		--entitlements Resources/FormatReader.entitlements "$(EXTENSION)"
	codesign --force --timestamp=none --sign - \
		--entitlements Resources/VideoDecoder.entitlements "$(VIDEO_DECODER)"
	codesign --force --timestamp=none --sign - "$(APP)"

install: sign
	ditto "$(APP)" "/Applications/FFmpeg Media Extension.app"
	open -a "/Applications/FFmpeg Media Extension.app"

register: install
	pluginkit -a "/Applications/FFmpeg Media Extension.app/Contents/Extensions/MKVFormatReader.appex"
	pluginkit -a "/Applications/FFmpeg Media Extension.app/Contents/Extensions/FFmpegVideoDecoder.appex"
	pluginkit -m -A -D -i lv.apps.ffmpeg-media-extension.formatreader.mkv
	pluginkit -m -A -D -i lv.apps.ffmpeg-media-extension.videodecoder.vp9

inspect: bundle
	file "$(HOST_BINARY)" "$(EXTENSION_BINARY)"
	plutil -lint "$(APP)/Contents/Info.plist" "$(EXTENSION)/Contents/Info.plist"
	codesign --verify --deep --strict --verbose=2 "$(APP)"

test: integration-test

verify-test-media:
	@found=0; \
	for media in "$(MEDIA_DIR)"/*.mkv "$(MEDIA_DIR)"/*.webm; do \
		if test -f "$$media"; then found=1; break; fi; \
	done; \
	if test $$found -eq 0 && test -n "$(SHARE_MEDIA_DIR)"; then \
		for media in "$(SHARE_MEDIA_DIR)"/*.mkv "$(SHARE_MEDIA_DIR)"/*.webm; do \
			if test -f "$$media"; then found=1; break; fi; \
		done; \
	fi; \
	if test $$found -eq 0; then \
		printf '%s\n' \
			'No MKV/WebM test videos were found.' \
			'Place fixtures in MEDIA_DIR (default: $(MEDIA_DIR)) or run:' \
			'  make test MEDIA_DIR=/path/to/videos TEAM_ID=YOUR_TEAM_ID' \
			'For optional mounted-share fixtures, also set SHARE_MEDIA_DIR=/path/to/share.' >&2; \
		exit 66; \
	fi

integration-test: verify-test-media register build/media-probe
	bash Tests/run.sh "/Applications/FFmpeg Media Extension.app"
	FME_LOCAL_MEDIA_DIR="$(MEDIA_DIR)" FME_SHARE_MEDIA_DIR="$(SHARE_MEDIA_DIR)" \
		bash Tests/integration.sh "$(CURDIR)/build/media-probe"

build/media-probe: Tests/Probe/main.swift
	mkdir -p build
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ProbeModuleCache \
		swiftc -module-cache-path $(CURDIR)/build/ProbeModuleCache \
		-target arm64-apple-macosx$(DEPLOYMENT_TARGET) -swift-version 6 -O \
		Tests/Probe/main.swift -framework AVFoundation -framework ExtensionFoundation -framework MediaToolbox -framework VideoToolbox -o $@

probe: build/media-probe
	build/media-probe "$(MEDIA_DIR)"/*.mkv "$(MEDIA_DIR)"/*.webm

clean:
	rm -rf build
