# Fushi Aidoku Runtime

This directory contains Fushi's cross-platform Aidoku source runtime. It
consumes `.aix` packages behind one JSON command contract, while selecting an
execution backend appropriate for each Apple platform.

The implementation uses the MIT-licensed `aidoku-rs` ABI and test-runner
building blocks pinned in `Cargo.toml`. It does not include or derive from the
source-available Swift `AidokuRunner`, whose redistribution terms do not allow
embedding it in Fushi.

The active community extension catalog is
[`Aidoku-Community/sources`](https://github.com/Aidoku-Community/sources).
Fushi should consume its published index and `.aix` packages without copying
repository source code into this runtime.

Current commands:

```text
fushi-aidoku-runtime inspect PACKAGE.aix
fushi-aidoku-runtime search PACKAGE.aix [QUERY] [PAGE]
fushi-aidoku-runtime details PACKAGE.aix MANGA_JSON
fushi-aidoku-runtime pages PACKAGE.aix MANGA_JSON CHAPTER_JSON
```

On macOS the `desktop` feature keeps the existing sidecar based on Wasmer and
`aidoku-test-runner`. On iOS the `embedded` feature builds a static library
with the `wasmi` interpreter, exported through `fushi_aidoku_invoke`. The iOS
backend deliberately does not use JIT or dynamically load executable code.
Flutter reuses the same repository, language filter, search, detail, reader,
image loading and OCR screens on both platforms; only the WASM execution
backend and transport differ.

The embedded host initializes source defaults from `Payload/settings.json`,
selects a content language and base URL from the manifest, and implements the
common HTTP, HTML and JavaScript-context imports. WebView imports are exposed
with the same unsupported behavior as the current desktop test runner; a
source that requires an interactive anti-bot WebView can be inspected and
installed but may still reject browse/search operations.

Build the physical-device archive with:

```text
cargo build --lib --no-default-features --features embedded \
  --target aarch64-apple-ios --locked
```

`fushi/ios/build_aidoku_runtime.sh` is invoked by Xcode and never installs a
Rust target, an iOS platform, or Simulator components. Those prerequisites
must be provisioned explicitly by the developer or CI.
