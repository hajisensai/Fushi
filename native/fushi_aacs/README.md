# fushi_aacs

The libaacs ABI module that libbluray (inside the bundled libmpv) loads for
AACS discs. In a disc-menu session libbluray reads every menu, IG and title
stream itself through `aacs_decrypt_unit()`; without a loadable libaacs an
encrypted disc menu cannot open at all (BUG-3074).

This is Fushi's own implementation of the subset libbluray 1.5 resolves, not
VideoLAN libaacs. It has no key policy of its own: the app resolves the exact
disc-ID volume unique key from KEYDB (`aacs_configuration.dart`) and registers
it with `fushi_aacs_set_disc_key()` before opening the disc. Decryption matches
`AacsContentDecoder`. Not supported (same as title playback): bus encryption,
AACS 2, BD+, media key block processing, drive access.

| Platform | File | How libbluray finds it |
|---|---|---|
| Windows | `libaacs.dll` next to `fushi.exe` | `LoadLibraryExW("libaacs.dll", APPLICATION_DIR)` |
| Android | `libfushi_aacs.so`, soname `libaacs.so.0` | app preloads it; bionic matches `dlopen("libaacs.so.0")` by soname |
| macOS | `Contents/Frameworks/libaacs.dylib` | `dlopen("@rpath/libaacs.dylib")` |
| Linux | not bundled | system libmpv/libbluray/libaacs |

Build wiring: `fushi/windows/CMakeLists.txt`, the Android app native build
(`native/fushidicts/CMakeLists.txt`), `fushi/macos/bundle_fushi_aacs.sh`.
Guard: `fushi/test/build/fushi_aacs_packaging_guard_test.dart`.

Self-test:

```
cmake -S native/fushi_aacs -B build/fushi_aacs -DFUSHI_AACS_BUILD_TESTS=ON
cmake --build build/fushi_aacs --config Release
ctest --test-dir build/fushi_aacs -C Release --output-on-failure
```
