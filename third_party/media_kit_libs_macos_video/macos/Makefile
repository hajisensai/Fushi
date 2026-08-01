all: Frameworks/*.xcframework Frameworks/.symlinks

# HIBIKI FORK, two reasons (see ios Makefile, kept in sync):
#
# BUG-073: media-kit's "default" FFmpeg flavor enables the truehd DEMUXER but
# not the truehd/mlp DECODER (meson.build: default omits `--enable-decoders`),
# so TrueHD audio is silent -- same root cause proven on Windows. We need the
# "-video-full" flavor (`audio_full_options=['--enable-decoders',...]`).
#
# TODO-1137: every media-kit release, full flavor included, is built against
# FFmpeg 6.0 (2023-02) -- off the maintenance branches, no security backports,
# and this is the library that decodes whatever file the user opens. It still
# carries the magicyuv OOB write reachable from a crafted mkv/mov/avi, plus the
# vp9, mov CENC and mpegts issues. So this xcframework is built from our own
# fork (hajisensai/libmpv-darwin-build @ hibiki/ffmpeg-6.1.6) at FFmpeg 6.1.6,
# the tip of the 6.1 LTS branch, and mirrored into our permanent
# `vendor-libmpv` release. Staying inside 6.x keeps the FFmpeg API stable, so
# mpv 0.36.0 is untouched.
#
# Verified from the built artifact: Avcodec reports "FFmpeg version 6.1.6" on
# the macos-arm64_x86_64 slice and contains the truehd decoder. SHA256
# recomputed from the uploaded tarball.
#
# MPV_XCFRAMEWORKS_VERSION is only a cache-path label here, not an upstream tag.
MPV_XCFRAMEWORKS_VERSION=ffmpeg6.1.6
MPV_XCFRAMEWORKS_SHA256SUM=716ca82aa1a45b7e8482b7dc723bf1d91047edbc5dedb48d736822c4250732a6

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*-macos-universal.tar.gz
	curl -L \
		https://github.com/hajisensai/hibiki/releases/download/vendor-libmpv/libmpv-xcframeworks-macos-universal-video-full-${MPV_XCFRAMEWORKS_VERSION}.tar.gz \
		-o .cache/xcframeworks/libmpv.tar.gz.tmp
	shasum -a 256 -c <<< '${MPV_XCFRAMEWORKS_SHA256SUM}  .cache/xcframeworks/libmpv.tar.gz.tmp'
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz

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
	rm -rf ./Frameworks/*.xcframework
