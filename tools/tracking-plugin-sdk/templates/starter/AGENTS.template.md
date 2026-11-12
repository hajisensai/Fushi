# Fushi tracking site plugin: __PLUGIN_NAME__

This directory is a Fushi tracking site plugin. `GUIDE.md` here is the complete contract and
`fushi-tracking-plugin.d.ts` has the types; read GUIDE.md sections 2–7 before changing code.

Commands (the dev tool lives in the Fushi tracking plugin SDK):

```sh
node "__SDK_CLI__" check .
node "__SDK_CLI__" login .                                              # paste a token, saved in .fushi-dev/
node "__SDK_CLI__" run . trackingSearch '{"query":"<title>","kind":"anime"}' --trace
node "__SDK_CLI__" run . trackingSubject '{"id":<id>}'
node "__SDK_CLI__" run . trackingEntry '{"op":"get","id":<id>,"kind":"anime"}'
node "__SDK_CLI__" smoke . --query "<title with results>" --strict
node "__SDK_CLI__" pack . --key <signing key .pem>
```

Rules:

- Only the globals in GUIDE.md section 4 exist (`fushi.http`, `fushi.storage`, `fushi.credentials`,
  `fushi.crypto`, `fushi.encoding`, `console`, `require`, `module.exports`). No fetch / setTimeout / import.
- Ids are positive integers. Every host the plugin contacts (API, redirect targets, the token page used as
  `appUrl`) is in `manifest.json` → `network.domains`.
- Throw `unauthorized:` / `rate_limited:` / `not_found:` errors exactly as GUIDE.md section 8 says; never
  sleep or retry inside the plugin.
- `trackingEntry` `set` writes exactly the fields it is given. Never change progress or status on your own.
- Every `ERROR` and `WARN` printed by `run` / `smoke` is a bug to fix. Done = `smoke --strict` exits 0.
- Never guess endpoints; inspect real responses with `run ... --trace --full`. Only test writes
  (`trackingEntry` `set`) against an entry you are allowed to change.
