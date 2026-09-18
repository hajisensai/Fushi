# Fushi Aidoku Runtime

This directory contains Fushi's Aidoku source runtime library. It consumes
`.aix` packages behind one JSON command contract.

**No Fushi build currently bundles it.** The iOS host was removed for App
Store compliance and the macOS sidecar (`fushi-aidoku-runtime`, the `desktop`
feature built on Wasmer and `aidoku-test-runner`) was removed afterwards, so
`AidokuRuntimeFactory.isSupported` is `false` on every platform. The crate is
kept as the reference implementation of the ABI for a future host.

The implementation uses the MIT-licensed `aidoku-rs` ABI building blocks
pinned in `Cargo.toml`. It does not include or derive from the
source-available Swift `AidokuRunner`, whose redistribution terms do not allow
embedding it in Fushi.

The active community extension catalog is
[`Aidoku-Community/sources`](https://github.com/Aidoku-Community/sources).
Fushi should consume its published index and `.aix` packages without copying
repository source code into this runtime.

Commands behind the JSON contract (`invoke_json`):

```text
inspect PACKAGE.aix
search PACKAGE.aix [QUERY] [PAGE]
details PACKAGE.aix MANGA_JSON
pages PACKAGE.aix MANGA_JSON CHAPTER_JSON
```

The `embedded` feature builds a static library with the `wasmi` interpreter,
exported through `fushi_aidoku_invoke`. It deliberately does not use JIT or
dynamically load executable code.

The embedded host initializes source defaults from `Payload/settings.json`,
selects a content language and base URL from the manifest, and implements the
common HTTP, HTML and JavaScript-context imports. WebView imports are exposed
as unsupported; a source that requires an interactive anti-bot WebView can be
inspected and installed but may still reject browse/search operations.

Build the library with:

```text
cargo build --lib --features embedded --locked
```
