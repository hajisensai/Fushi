all: Frameworks/*.xcframework Frameworks/.symlinks

# Verified original-menu libmpv bundle. Source and actual slice/closure checks:
# ../native/provenance.json. Keep full TrueHD decoding and the DOVI GL patch.
MPV_XCFRAMEWORKS_VERSION=bluray-51124a35ce79
MPV_XCFRAMEWORKS_SHA256SUM=6f295caece9271cb6d159dbe6b78c2b12fec011449fb0c388a9e9c1d006c704e
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

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*-ios-universal.tar.gz
ifneq ($(FUSHI_LIBMPV_DARWIN_ARCHIVE),)
	cp "$(FUSHI_LIBMPV_DARWIN_ARCHIVE)" .cache/xcframeworks/libmpv.tar.gz.tmp
else
	cp "$(MPV_XCFRAMEWORKS_VENDOR_ARCHIVE)" .cache/xcframeworks/libmpv.tar.gz.tmp
endif
	shasum -a 256 -c <<< '${MPV_XCFRAMEWORKS_SHA256SUM}  .cache/xcframeworks/libmpv.tar.gz.tmp'
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz

# Re-select the cache when switching between an override and the vendored pin.
# A symlink's mtime alone cannot identify which archive it currently points at.
ifneq ($(shell readlink .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz 2>/dev/null),libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz)
.PHONY: .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz
endif

.cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz: .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz
	rm -f .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz
	ln -s libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz

Frameworks/*.xcframework: .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz
	mkdir -p Frameworks
	rm -rf Frameworks/*.xcframework
	tar -xvf .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz --strip-components 1 -C Frameworks
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
	rm -rf ./Frameworks/*.xcframework
