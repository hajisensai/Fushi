# Fushi Aidoku Runtime

This directory contains Fushi's isolated, cross-platform Aidoku source
runtime. It consumes `.aix` packages and communicates with the Flutter app
through a versioned JSON process protocol.

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

The first milestone intentionally runs as a sidecar instead of an in-process
FFI library. Untrusted source traps and dependency failures therefore cannot
directly corrupt the Flutter process. Resource limits and a long-lived JSON
RPC transport are follow-up runtime hardening work before UI exposure.
