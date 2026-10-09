# Windows Blu-ray menu runtime

The vendored native archive is built from mpv
`36abaa32d00a7229ee206aae12dc0e97e7962dca` (2026-10-08),
including upstream HDMV/BD-J navigation added on 2026-08-25. The previous
2026-08-13 binary had neither `discnav` nor `disc-menu`; updating Flutter alone
could not enable original menus.

Archive: `mpv-dev-x86_64-20261008-git-36abaa32d0-fushi-discnav1.7z` (48,455,947 bytes).
SHA-256: `39ded62ef699ef23f36ec09f60f0536d5b32c6e0e12dbacd65738e1e28779aca`.
The `fushi-discnav1` suffix identifies this patched build; it is not an
unmodified zhongfly release. Its DLL and dependency manifests are also tracked
beside this document for review without unpacking the binary.

`patches/disc-navigation-state.patch` is the complete local change against that
upstream revision. It adds:

* `disc-navigation-state` (NODE_MAP) and `disc-navigation-state-json` (STRING),
  schema version 1. Both are obtained from the same snapshot implementation.
* Real `BD_EVENT_TITLE` / `BD_EVENT_PLAYLIST` identities, a navigation generation,
  presentation position, angle, native menu state and BD-J readiness. MPLS
  identifiers never come from edition-list indices or translated labels.
* A presentation gate: a new generation is not stable until the player's
  resync/restart completes. `position` is `get_current_time(mpctx)`, never the
  ahead-of-playback `bd_tell_time` read head.
* Separate graphics visibility and input ownership. BD-J PG subtitles remain
  visible but only IG graphics activate menu keyboard/mouse handling.
* Automatic audio/subtitle selection compares the actual active track with the
  disc's desired track, so handing `aid`/`sid` back to `auto` reapplies an
  unchanged disc selection after explicit Off/external/manual overrides.
  Explicit player selections remain authoritative until that handoff.
* `menu-call-allowed` follows libbluray's `BD_EVENT_UO_MASK_CHANGED` menu-call
  bit. Native menu/input failures propagate to the client instead of reporting
  success after a prohibited or unsupported command.
* `bluray-java-home`, passed to `BLURAY_PLAYER_JAVA_HOME` before opening the disc.
  This selects the private optional JRE without global environment mutation.
* A hard failure when requested BD-J menus lack a Java runtime; upstream's
  silent fallback to an unrelated longest title is deliberately removed.

`menu-domain` identifies top-menu, first-play and visible IG graphics. BD-J
applications may implement their own behavior inside a regular title, so this
is not a claim to infer every possible Xlet's semantic screen. `angle` is
zero-based, `-1` unknown; nonzero angles require matching export support.

## Build and package

`tool/bluray/build_libmpv.ps1` checks out the pinned upstream revision, applies
the patch and builds with MSYS2 mingw64. It uses the existing vendored ANGLE
headers and enables EGL/D3D11 interop. Native compilation holds the repository's
heavy-work lease; the default is three compiler processes.

The runtime uses MSYS2 FFmpeg 9.0.1, libbluray 1.5.0 and libplacebo 7.360.1.
Its `msys2-packages.json` records the exact dependency package versions.
`package_libmpv.py` follows PE imports recursively, fails on unresolved imports,
includes package licenses and records each DLL's size and SHA-256. This closure
includes the TrueHD decoder. Lua/JavaScript player scripts are disabled; Fushi's
Flutter controls and C client/render APIs do not depend on them.

The packager requires Python's `pefile` module. It gives all 121 non-system
dependencies fixed, same-length `fbd` module names, preserving the public
`libmpv-2.dll` entry point. Normal imports, delay imports, export forwarders and
literal ANSI/UTF-16 dynamic-library names are rewritten without shifting PE
RVAs. It rejects name collisions and leftover original dependency references.
`private-dll-map.json`, the runtime source/new hashes and
`dynamic-dll-references.json` make that transformation reviewable. This prevents
the video player from overwriting the P2P client's OpenSSL or another renderer's
libplacebo, threading runtime or Vulkan loader. Optional externally resolved
modules, such as system GPU drivers, AACS and the configured JVM, stay explicit
in the dynamic-reference audit.

The archive includes `runtime-files.cmake`, so installation follows the verified
closure rather than globbing a potentially stale build folder. Extraction is
addressed by the archive hash and shared with media_kit_video through
`MEDIA_KIT_LIBMPV_SRC`. The private Vulkan loader has a distinct name; ANGLE's
existing public loader remains unchanged for existing consumers.

The two matching libbluray JARs sit beside `fbdbluray-4.dll`. The small optional
component bundle and its single-source installer are installed under
`<application>/bluray/bdj/`. See [bdj/README.md](bdj/README.md) for the pinned
private JRE, hashes, source and license details.

## Verification

* `probe_libmpv.py` probes the loaded binary's options, command signatures,
  properties, Blu-ray protocol, TrueHD decoder and render API.
* `test_probe_libmpv.py` checks dependency cycles/missing imports and, with
  `FUSHI_MPV_LIBRARY`, actual ABI and error propagation.
* `verify_menu_render.py` uses the shipped ANGLE and libmpv OpenGL render API
  offscreen. It records native snapshots, logs and rendered PNGs from a readable
  original disc; it does not substitute a title-list UI for disc graphics.
* `test_bdj_runtime.py` checks the pinned artifacts, private JVM and optionally
  real libbluray JNI/AWT startup with a generated unencrypted BD-J fixture.

These tests do not assert that encrypted discs become readable, that every
commercial BD-J application works, or that another platform's binary has the
same capabilities. Platform support is detected from the loaded library.
