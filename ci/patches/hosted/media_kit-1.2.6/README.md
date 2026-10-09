# Fushi media_kit 1.2.6 overlay

Source: [official media_kit 1.2.6 archive](https://pub.dev/api/archives/media_kit-1.2.6.tar.gz).
The pristine `lib/src/player/native/player/real.dart` SHA-256 is
`6286405e40d9102a7fbca968eb23a313a0735ce40355caa779f4767b06f8e032`.
The upstream MIT license and source header remain unchanged.

The only change to `real.dart` is an imported predicate for the existing
`loadfile` versus temporary-playlist branch of `NativePlayer.open`.
`native_open_policy.dart` implements and tests the request boundary:

- A single explicit `Media('bd://...')` or `Media('bluray://...')` uses the
  existing `loadfile ... append` branch. Public state, stream events, pause,
  headers, hooks, playlist position and locking remain in media_kit's normal
  open implementation.
- A `Playlist`, including a one-entry or mixed `fd://`/disc playlist, retains
  mpv's playlist-origin restriction for disc URLs. External playlist files are
  not inspected or promoted to trusted disc requests.
- Existing `fd://` direct opening and disc-free fd playlists retain their
  behavior. Ordinary local files, HTTP URLs and EDL requests are unchanged.
- `load-unsafe-playlists` is never enabled.

mpv marks its Blu-ray stream drivers `STREAM_ORIGIN_UNSAFE`. media_kit's usual
temporary m3u turns even a single explicitly requested disc into a file-origin
playlist entry and mpv rejects it. A native `loadfile`/`loadlist` comparison
using the same bundled DLL and disc reproduced that difference.

`ci/apply-patches.sh` copies this exact-version overlay after dependency
resolution. On a media_kit upgrade, re-evaluate whether upstream has fixed its
single-disc open path and remove or port this overlay. Regression tests live
in `fushi/test/third_party/media_kit_disc_open_policy_test.dart` and import the
actual patched package with real `Media` and `Playlist` inputs.
