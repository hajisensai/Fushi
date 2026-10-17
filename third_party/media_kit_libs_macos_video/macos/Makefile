all: Frameworks/*.xcframework Frameworks/.symlinks Frameworks/.unified-ffmpeg

# Fushi unified FFmpeg (tool/ffmpeg-unified): the FFmpeg frameworks Mpv.framework
# links through @rpath/lib*.framework, from the same build whose ffmpeg/ffprobe
# programs release-desktop.yml installs into Contents/MacOS. One FFmpeg for
# playback and card mining. ../native/ffmpeg-unified-macos.tar.gz is the
# fushi.app/Contents layout (Frameworks/ + MacOS/) built and verified by
# .github/workflows/ffmpeg-unified-mobile.yml (tool/ffmpeg-unified/mobile/build_macos.sh).
UNIFIED_FFMPEG_ARCHIVE=$(abspath ../native/ffmpeg-unified-macos.tar.gz)
UNIFIED_FFMPEG_SHA256SUM=3442c8ecaa48203fb794bd0809d050b46c74673208096406c456b8b04573657d

Frameworks/.unified-ffmpeg: $(UNIFIED_FFMPEG_ARCHIVE)
	shasum -a 256 -c <<< '${UNIFIED_FFMPEG_SHA256SUM}  $(UNIFIED_FFMPEG_ARCHIVE)'
	mkdir -p Frameworks
	rm -rf Frameworks/lib*.framework .cache/unified-ffmpeg
	mkdir -p .cache/unified-ffmpeg
	tar -xf $(UNIFIED_FFMPEG_ARCHIVE) -C .cache/unified-ffmpeg Frameworks
	cp -R .cache/unified-ffmpeg/Frameworks/lib*.framework Frameworks/
	touch Frameworks/.unified-ffmpeg

# Verified original-menu libmpv bundle. Source and actual slice/closure checks:
# ../native/provenance.json. Keep full TrueHD decoding and the DOVI GL patch.
MPV_XCFRAMEWORKS_VERSION=unified-0f29c43057bb
MPV_XCFRAMEWORKS_SHA256SUM=4cb73ff047d8ba1e6def51059570f26a897a815ba5b2d906357fc0cf064ecc49
MPV_XCFRAMEWORKS_VENDOR_ARCHIVE=$(abspath ../native/libmpv-xcframeworks-bluray.tar.gz)

# Explicit local build verification, without publishing or changing production pins.
# Supply both values; content hash also isolates the extraction cache.
ifneq ($(FUSHI_LIBMPV_DARWIN_ARCHIVE),)
ifeq ($(FUSHI_LIBMPV_DARWIN_SHA256),)
$(error FUSHI_LIBMPV_DARWIN_SHA256 is required with FUSHI_LIBMPV_DARWIN_ARCHIVE)
endif
MPV_XCFRAMEWORKS_VERSION=local-$(FUSHI_LIBMPV_DARWIN_SHA256)
MPV_XCFRAMEWORKS_SHA256SUM=$(FUSHI_LIBMPV_DARWIN_SHA256)
endif

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*-macos-universal.tar.gz
ifneq ($(FUSHI_LIBMPV_DARWIN_ARCHIVE),)
	cp "$(FUSHI_LIBMPV_DARWIN_ARCHIVE)" .cache/xcframeworks/libmpv.tar.gz.tmp
else
	cp "$(MPV_XCFRAMEWORKS_VENDOR_ARCHIVE)" .cache/xcframeworks/libmpv.tar.gz.tmp
endif
	shasum -a 256 -c <<< '${MPV_XCFRAMEWORKS_SHA256SUM}  .cache/xcframeworks/libmpv.tar.gz.tmp'
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz

# Re-select the cache when switching between an override and the vendored pin.
# A symlink's mtime alone cannot identify which archive it currently points at.
ifneq ($(shell readlink .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz 2>/dev/null),libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz)
.PHONY: .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz
endif

.cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz: .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz
	rm -f .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz
	ln -s libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz

Frameworks/*.xcframework: .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz
	mkdir -p Frameworks
	rm -rf Frameworks/*.xcframework
	tar -xvf .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz --strip-components 1 -C Frameworks
	touch Frameworks/*.xcframework

Frameworks/.symlinks: Frameworks/*.xcframework
	rm -rf Frameworks/.symlinks
	mkdir -p Frameworks/.symlinks/mpv
	sed -i '' 's/\r$$//g' create_framework_symlinks.sh # remove CRLF line terminator added by Flutter packaging (https://github.com/media-kit/media-kit/issues/338)
	sh create_framework_symlinks.sh Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv

.PHONY: clean
clean:
	rm -rf .cache
	rm -f ./Headers/mpv/*.h
	rm -rf ./Frameworks/*.xcframework ./Frameworks/lib*.framework ./Frameworks/.unified-ffmpeg
