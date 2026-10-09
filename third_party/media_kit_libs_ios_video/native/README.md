# iOS libmpv Blu-ray framework bundle

This is the verified full-video build from [Darwin PR #2](https://github.com/hajisensai/libmpv-darwin-build/pull/2).
The exact source commit, Actions run, archive checksum and inspection results are recorded in `provenance.json`.
It contains iOS arm64 and arm64/x86_64 simulator slices, libbluray HDMV navigation,
FFmpeg 6.1.6 full decoders, and the retained Dolby Vision profile 5 GL patch.
No Java runtime/BD-J jar is included. Device menu rendering has not been tested.

Rebuild with `tool/bluray/platforms/build_darwin.sh` from the repository root and
verify with `tool/bluray/platforms/verify_darwin_archive.py --platform ios` before replacing this archive.
The package Makefile verifies the SHA-256 before extraction and supports an explicit
`FUSHI_LIBMPV_DARWIN_ARCHIVE` / `FUSHI_LIBMPV_DARWIN_SHA256` development override.
