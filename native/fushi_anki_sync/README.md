# fushi-anki-sync

A small command-line helper that links **Anki's official Rust library (rslib)** so Fushi
can add cards to an Anki collection and sync it to a **self-hosted Anki sync server**
(or AnkiWeb, only when the user explicitly opts in) without Anki installed on the device.

Design and decisions: `docs/specs/2026-09-28-anki-pending-mining-and-sync.md` (phase 3).
Dart client: `packages/fushi_engine/lib/anki_sync/fushi_anki_sync_client.dart`.

## License

It links rslib (AGPL-3.0-or-later), so this program is AGPL-3.0-or-later. It is a separate
process that Fushi talks to over stdin/stdout; the AGPL obligations apply to this program.
Ship its source (this directory + the pinned upstream tag + `patches/`) with any binary.

## Honest client identity

rslib reports itself to sync servers as the official client (`anki,<ver> (<hash>),<os>`).
`patches/0001-sync-client-version-fushi.patch` changes that to
`fushi,<helper version> (anki 26.09.3),<os>` so Fushi never impersonates Anki. The
self-hosted server does not check the string; AnkiWeb's behaviour is unknown and it may
reject a third-party client — Fushi does not try to work around that.

## Build

```sh
./build.sh            # Linux / macOS
.\build.ps1           # Windows
```

The script shallow-clones `ankitects/anki` tag `26.09.3` (commit `29bb700b`) into
`.anki-src/` (git-ignored) with the two translation submodules, verifies the commit,
applies `patches/*.patch` idempotently, then `cargo build --release`. `Cargo.toml`'s
`[patch]` points `anki` and `anki_proto` at that checkout (both must, or `anki_proto`
resolves twice and its types do not match).

`--install-dir DIR` (`-InstallDirectory DIR` on Windows) also copies the binary plus its
AGPL source notice `fushi-anki-sync.SOURCE.txt` (generated from `SOURCE.txt.in` with the
checkout's commit) into `DIR` and smoke-tests the copy with a `version` request.
On macOS it builds for the host architecture only (the macOS app is Apple Silicon /
arm64 only; Intel Macs are not supported), so CI builds it on an arm64 runner. CI
(`.github/actions/setup-fushi-anki-sync` + the desktop / server release workflows) uses
these to put the helper next to `fushi.exe`, inside `fushi.app/Contents/MacOS/` (notice in
`Contents/Resources/`), and in the server's `bundle/bin/`.

Requirements: a Rust toolchain (pinned to 1.97.1 by `rust-toolchain.toml`) and `protoc` (upstream pins v31.1;
set `PROTOC`/`PROTOC_BINARY` or put it on `PATH`). No Python / Node needed. The release
binary is ~14 MB (Windows x64).

## Protocol

One JSON request per line on stdin, one reply per line on stdout:

```
{"id": 1, "cmd": "open", "path": "/data/collection.anki2"}
{"id": 1, "ok": true, "result": {"created": true}}
```

| cmd | args | result |
|---|---|---|
| `version` | – | `{client}` identity sent to servers |
| `login` | `endpoint?`, `username`, `password` | `{hkey}` (`endpoint` null = AnkiWeb) |
| `open` | `path` | `{created}` — a created collection must `full_download` before `add_note` |
| `close` | – | `{}` |
| `list_meta` | – | `{decks, notetypes: [{name, fields}]}` |
| `is_duplicate` | `notetype`, `first_field` | `{duplicate}` |
| `add_note` | `notetype`, `deck`, `fields`, `tags`, `media: [[name, path]]` | `{note_id, media}` |
| `sync` | `hkey`, `endpoint?` | `{status: "ok"\|"full_sync_blocked", full_download, new_endpoint, server_message}` |
| `full_download` | `hkey`, `endpoint?` | `{}` |

Endpoints are the server root (e.g. `http://nas:8080/`); rslib appends `sync/` and `msync/`.

## Data-safety rules

* **Never full-upload.** If the server demands a one-way upload, `sync` returns
  `full_sync_blocked`; the user resolves it in an official Anki client.
* A freshly created collection must be `full_download`ed before the first `add_note`,
  otherwise its schema never matches the server and every later sync is blocked.
* A full download discards local notes not pushed yet. The caller's pending queue is the
  source of truth: only dequeue after a successful sync, replay after a full download.
