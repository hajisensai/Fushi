all: Frameworks/*.xcframework Frameworks/.symlinks

# HIBIKI FORK, two reasons (see macos Makefile, kept in sync):
#
# BUG-073: media-kit's "default" flavor omits the truehd/mlp DECODER (demuxer
# only), so TrueHD audio is silent. We need the "-video-full" flavor
# (`--enable-decoders`, includes truehd/mlp).
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
# both the ios-arm64 and ios-arm64_x86_64-simulator slices, and both contain the
# truehd decoder. SHA256 recomputed from the uploaded tarball.
#
# BUG-2691 (Dolby Vision profile 5): this build additionally carries
# `patches/mpv-gl-dovi-p5.patch` (branch hibiki/dovi-p5-gl). mpv 0.36 has no
# libplacebo here, so the render API only has gl_video, which never applied the
# Dolby Vision RPU: profile 5 (IPTPQc2) played purple/green. The patch ports
# libplacebo's pl_shader_dovi_reshape + DOLBYVISION decode into gl_video.
# Verified on a real Mac through the render API + CGL (software and
# videotoolbox decoding): the unpatched framework renders the reference frame
# pink/magenta, this one matches vo=gpu-next. The Dart side relies on it via
# textureRendererReshapesDolbyVision(); dropping the patch means flipping that.
#
# MPV_XCFRAMEWORKS_VERSION is only a cache-path label here, not an upstream tag.
MPV_XCFRAMEWORKS_VERSION=ffmpeg6.1.6-dovi
MPV_XCFRAMEWORKS_SHA256SUM=00184863042aa110f030f41b19d5138701110d0bd51d0c167ecc64522e71f894

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*-ios-universal.tar.gz
	curl -L \
		https://github.com/hajisensai/hibiki/releases/download/vendor-libmpv/libmpv-xcframeworks-ios-universal-video-full-${MPV_XCFRAMEWORKS_VERSION}.tar.gz \
		-o .cache/xcframeworks/libmpv.tar.gz.tmp
	shasum -a 256 -c <<< '${MPV_XCFRAMEWORKS_SHA256SUM}  .cache/xcframeworks/libmpv.tar.gz.tmp'
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz

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
