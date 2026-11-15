# Fushi tracking plugin SDK

Developer kit for Fushi **tracking site plugins** (`"kind": "tracking"`): plugins that keep the user's list on
a tracking site in step with what they watch and read in Fushi. Zero-dependency Node CLI (Node.js 18+), types,
a starter template and an offline example. **The whole contract is [GUIDE.md](GUIDE.md)**, written to be handed
to an AI coding assistant as is.

Music source plugins are a different plugin system with their own kit: [`../music-plugin-sdk/`](../music-plugin-sdk/).
This kit reuses that kit's sandbox runner, package code and network policy (both kinds run in the same engine),
so check out both folders:

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/hajisensai/fushi.git
cd fushi && git sparse-checkout set tools/tracking-plugin-sdk tools/music-plugin-sdk
```

## Commands

```sh
node fushi-tracking-plugin.mjs init my-site --id dev.yourname.tracking.mysite --name "My Site"
node fushi-tracking-plugin.mjs check my-site
node fushi-tracking-plugin.mjs login my-site
node fushi-tracking-plugin.mjs run my-site trackingSearch '{"query":"frieren","kind":"anime"}' --trace
node fushi-tracking-plugin.mjs smoke my-site --query frieren --strict
node fushi-tracking-plugin.mjs keygen --out my-site-key.pem
node fushi-tracking-plugin.mjs pack my-site --key my-site-key.pem
node fushi-tracking-plugin.mjs inspect dev.yourname.tracking.mysite-0.1.0.fushiplug
```

`ERROR` = the app cannot use the result; `WARN` = the app drops, caps or ignores something; `THROW` = a
deliberate `unauthorized:` / `rate_limited:` / `not_found:` error, with how the app reads it. The local runner
is Node's `vm`, **not a security boundary**: only run plugins you wrote or trust.

Try it offline on the example (a made-up site, no account, no network traffic):

```sh
node fushi-tracking-plugin.mjs check examples/demo-list
node fushi-tracking-plugin.mjs run examples/demo-list trackingSearch '{"query":"orbit","kind":"anime"}'
echo demo-alice | node fushi-tracking-plugin.mjs login examples/demo-list
node fushi-tracking-plugin.mjs run examples/demo-list trackingEntry '{"op":"set","id":101,"kind":"anime","create":true,"status":"current","progress":3}'
```

## Contents

| Path | What |
|---|---|
| `GUIDE.md` | The contract: workflow, manifest, runtime API, capabilities and entities, token sign-in, host rules, errors, packaging, debugging, AI prompt |
| `fushi-tracking-plugin.mjs` | CLI: `init` / `check` / `run` / `smoke` / `login` / `reset` / `keygen` / `pack` / `inspect` |
| `fushi-tracking-plugin.d.ts` | Types for the manifest, entities, capabilities and the `fushi.*` globals |
| `lib/rules.mjs` | Tracking manifest rules and vocabulary (mirrors `native/fushi_music/src/plugin/manifest.rs`) |
| `lib/validate.mjs` | Argument and result checks (spec §3 / §4) |
| `templates/starter/` | Used by `init` |
| `examples/demo-list/` | Offline example plugin |

## Maintenance (inside the Fushi repo)

Source of truth: `docs/specs/2026-11-10-tracking-plugins.md` and `native/fushi_music/src/plugin/manifest.rs`.
The six vocabulary lists, the `requestsPerMinute` bounds, the `siteId` pattern, the `d.ts` capability names and
the rule "no own copy of the prelude / sandbox limits" are pinned by
`fushi/test/build/tracking_plugin_sdk_sync_guard_test.dart`; the shared runner and limits are pinned to the host
by `fushi/test/build/music_plugin_sdk_sync_guard_test.dart`.

## Tests without network

`lib/harness.mjs` runs a plugin in the same sandbox runner as `run`, with HTTP answered from fixtures and
storage / credentials in memory; `call()` checks arguments and results like the host. Use it from
`node --test` files next to the plugin (example: `plugins/tracking/bangumi/test/bangumi.test.mjs`).
