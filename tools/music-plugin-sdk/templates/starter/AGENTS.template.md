# Fushi music source plugin: __PLUGIN_NAME__

This directory is a Fushi music source plugin. `GUIDE.md` here is the complete contract and
`fushi-plugin.d.ts` has the types; read GUIDE.md sections 2–5 before changing code.

Commands (the dev tool lives in the Fushi plugin SDK):

```sh
node "__SDK_CLI__" check .
node "__SDK_CLI__" run . <capability> '<args json>' --trace     # e.g. search '{"query":"x","type":"song","page":0,"pageSize":10}'
node "__SDK_CLI__" smoke . --query "<query with results>" --strict
node "__SDK_CLI__" pack . --key <signing key .pem>
```

Rules:

- Only the globals in GUIDE.md section 4 exist (`fushi.http`, `fushi.storage`, `fushi.credentials`,
  `fushi.crypto`, `fushi.encoding`, `console`, `require`, `module.exports`). No fetch / setTimeout / import.
- Ids are strings, durations are milliseconds, every host (API, CDN, covers, redirect targets) is in
  `manifest.json` → `network.domains`.
- Every `ERROR` and `WARN` printed by `run` / `smoke` is a bug to fix. Done = `smoke --strict` exits 0.
- Never guess endpoints; inspect real responses with `run ... --trace --full`.
