# Fushi tracking site plugins — complete guide

This single file is the whole contract. It is written so you can hand it to an AI coding agent (or read it
yourself) and get a working plugin without reading Fushi's source. Plugin API version: **1**.

A tracking plugin teaches Fushi to keep the user's list on one tracking site in step with what they watch
and read in Fushi: read and write the user's list entry for a work, look works up by id (also by another
site's id), and optionally search by title. **Fushi makes every decision** (when to send, what to link,
which status and progress to write, never lowering progress); the plugin only talks to the site and returns
plain JSON.

Tracking plugins are their own plugin system (`"kind": "tracking"`): a music plugin cannot be installed as a
tracking plugin, or the reverse. Both run in the same sandbox, so the runtime API is the same as for music
plugins.

Platforms: Windows, macOS, Linux, Android. **iOS does not run plugins** (App Store rules), and the headless
server does not either.

---

## 1. Workflow (Node.js 18+ is the only requirement)

```sh
node fushi-tracking-plugin.mjs init my-site --id dev.yourname.tracking.mysite --name "My Site"
# edit my-site/manifest.json (tracking.siteId, siteHost, network.domains) and my-site/main.js
node fushi-tracking-plugin.mjs check my-site                  # manifest + files + exports, like the app's installer
node fushi-tracking-plugin.mjs login my-site                  # paste a token; saved locally in my-site/.fushi-dev/
node fushi-tracking-plugin.mjs run my-site trackingSearch '{"query":"frieren","kind":"anime"}' --trace
node fushi-tracking-plugin.mjs run my-site trackingSubject '{"id":52991}'
node fushi-tracking-plugin.mjs run my-site trackingEntry '{"op":"get","id":52991,"kind":"anime"}'
node fushi-tracking-plugin.mjs smoke my-site --query frieren --strict   # read-only tour of every capability
node fushi-tracking-plugin.mjs keygen --out ~/keys/my-site.pem          # once; keep it forever
node fushi-tracking-plugin.mjs pack my-site --key ~/keys/my-site.pem    # → <id>-<version>.fushiplug
node fushi-tracking-plugin.mjs inspect dev.yourname.tracking.mysite-0.1.0.fushiplug
```

Install in Fushi: **Settings › Media tracking › Tracking plugins › Install**, pick the `.fushiplug`, confirm
name, permissions, domains and signer, then sign in from the plugin's account row.

`run` and `smoke` execute your code in a local sandbox that mirrors the app (the same prelude, globals,
network rules and limits as the app's engine; it is the music kit's runner, shared) and then check the
arguments and every return value against this guide:

- `ERROR` = the app cannot use this result (exit code 1).
- `WARN` = the app silently drops, caps or ignores something, or would never send those arguments. **Treat
  warnings as bugs.** `--strict` makes warnings fail too.
- `THROW` = your function threw one of the deliberate errors of section 8; the next lines say how the app
  reads it and what the user sees.

`smoke` never calls `trackingEntry` with `op: 'set'`: test writes with `run`, on an entry you may change.

The local sandbox is for **your own or trusted code only**: it is Node's `vm`, not a security boundary. The
app's QuickJS sandbox is the real isolation; the local runner only reproduces its rules.

Optional static check: `npx -p typescript tsc -p my-site/jsconfig.json` (type-checks plain JS against
`fushi-tracking-plugin.d.ts`, which `init` copies next to your code).

`storage` / `credentials` written during local runs live in `<plugin>/.fushi-dev/` (`reset` clears it). They
are never packed.

### Recommended loop for an AI agent

1. Read sections 2–8. Write the manifest first (every host you will contact, the kinds and progress modes
   the site really tracks).
2. Implement `login` + `account` first and sign in with `login`. Then `trackingSubject`, `trackingSearch`,
   `trackingLookup`, `trackingEntry` get, and last `trackingEntry` set.
3. After each one, `run` it and fix every ERROR and WARN. Finish with `smoke --strict`, then `pack`.
4. Never invent API endpoints or field names: read the site's API documentation and look at real responses
   (`run ... --trace --full`).

---

## 2. Rules that break most plugins

1. **Ids are positive integers** (`id: 52991`, not `"52991"`). A subject with a string id is dropped.
2. **`manifest.json` must say `"kind": "tracking"`** and declare `login`, `account`, `trackingEntry`,
   `trackingSubject`, and the `network` + `credentials` permissions.
3. **No `fetch`, `XMLHttpRequest`, `setTimeout`, `setInterval`, `TextEncoder`, `atob`, `Buffer`, `process`,
   `import`/`export`.** Use `fushi.http.request`, `fushi.encoding`, `fushi.crypto`, `require('./x')`,
   `module.exports`. Modern syntax (async/await, classes, `?.`, `??`) is fine. **You cannot sleep**: never
   wait and retry inside the plugin (section 8).
4. **Every capability in `manifest.capabilities` must be exported** from the entry file with the same name.
5. **Every host you touch must be in `network.domains`**, including redirect targets and the token page you
   pass as `appUrl`. `*.example.com` matches subdomains only. Non-GET methods must be listed in
   `network.methods`. Only `https://`.
6. **`fushi.http.request` does not reject on 4xx/5xx.** Check `res.status` and map it to the error prefixes
   (401/403 → `unauthorized:`, 429 → `rate_limited:`, 404 → `not_found:` where it means the item is gone).
7. **"Not there" is `null`, not an error**: unknown subject → `trackingSubject` returns `null`; not on the
   user's list → `trackingEntry` get returns `null`. No search results → `{ items: [] }`.
8. **`trackingEntry` set writes exactly what it is given.** Never raise, lower, or "fix" progress or status;
   only the fields present in the arguments change. The host already decided.
9. **Sign-in is a form.** The tracking host renders only `form` login methods (no QR, no in-app browser).
   The usual pattern is "paste a personal access token" (section 6).
10. **CPU budget: 2 s per step** (the synchronous work between two awaits; waiting on HTTP is free).
11. Requests cannot reach `localhost`, LAN/private IPs or IP literals (also checked after DNS).
12. The instance lives across calls (module-level caches work) but can be recreated at any time; persist
    anything important with `fushi.storage` (needs the `storage` permission).

---

## 3. Package layout and `manifest.json`

```
my-site/
  manifest.json      required
  main.js            entry (any name, set by "entry")
  lib/util.js        optional, loaded with require('./lib/util')
```

`pack` includes `manifest.json` and every `.js` file (skipping dot-folders and `node_modules`), and generates
`files.json` (sha256 of every file) plus `signature.json` when signed. Limits: ≤128 files, ≤4 MiB per file,
≤16 MiB total. Paths are `/`-separated, no `..`.

```json
{
  "schema": 1,
  "kind": "tracking",
  "id": "dev.yourname.tracking.mysite",
  "name": "My Site",
  "version": "0.1.0",
  "api": 1,
  "entry": "main.js",
  "author": "you",
  "description": "One line shown in the install dialog",
  "homepage": "https://github.com/you/fushi-tracking-mysite",
  "capabilities": ["login", "account", "trackingEntry", "trackingSubject", "trackingSearch", "trackingLookup"],
  "permissions": ["network", "credentials"],
  "network": { "domains": ["api.mysite.example", "mysite.example"], "methods": ["GET", "POST"] },
  "tracking": {
    "siteId": "mysite",
    "siteHost": "mysite.example",
    "kinds": ["anime", "manga", "novel"],
    "defaultKinds": ["anime"],
    "modes": ["episode", "chapter", "volume"],
    "requestsPerMinute": 30
  }
}
```

| Field | Rule |
|---|---|
| `schema` | `1` |
| `kind` | `"tracking"` (absent or `"music"` = a music plugin; use the music kit for those) |
| `id` | 2–64 chars of `a-z 0-9 . _ -`, starts and ends with a letter/digit, no `..`. Never change it: it is the install identity. |
| `name` | 1–64 chars |
| `version` | `X.Y.Z` digits only. Bump it for every release. |
| `api` | `1` |
| `entry` | relative `.js` path inside the package |
| `author` / `description` / `homepage` | optional strings |
| `capabilities` | subset of `login`, `account`, `trackingEntry`, `trackingSubject`, `trackingSearch`, `trackingLookup`; the first four are required; no duplicates |
| `permissions` | subset of `network`, `storage`, `credentials`; `network` and `credentials` are required. `webAuth` and `insecureHttp` are rejected. |
| `searchTypes` | absent or `[]` |
| `network.domains` | non-empty, ≤32 rules: `host.tld` (exact) or `*.host.tld` (subdomains only); lowercase |
| `network.methods` | subset of `GET POST HEAD PUT DELETE PATCH`; default `["GET"]` |
| `tracking.siteId` | `[a-z0-9]{2,32}`, and not `mal` (reserved: the host's own id space; `check` rejects it). `bangumi` belongs to the Bangumi plugin bundled with Fushi: the app registers it only for that exact package (`check` warns). The provider id Fushi stores with every link, and the key other sites use for this site in `linkedIds` / `trackingLookup`. **Never change it** (links would be orphaned). Two enabled plugins with the same `siteId` are not allowed. |
| `tracking.siteHost` | plain lowercase host name (no scheme, path, port or wildcard), used to recognize a pasted link to the site |
| `tracking.kinds` | non-empty subset of `anime`, `manga`, `novel` |
| `tracking.defaultKinds` | optional subset of `kinds` (may be empty): kinds switched on by default for this site |
| `tracking.modes` | non-empty subset of `episode`, `chapter`, `volume`: which progress counters the site keeps |
| `tracking.requestsPerMinute` | integer 1–600: the host spaces your HTTP requests to stay under it (section 8) |

Unknown fields are rejected, in the manifest and in `tracking`.

---

## 4. Runtime API (globals available to the plugin)

The same as for music plugins (same engine). In short:

```js
const res = await fushi.http.request({
  url: 'https://api.mysite.example/v1/works/52991',  // must match network.domains, https only
  method: 'POST',                                     // must be in network.methods
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ status: 'current' }),        // string (UTF-8), or bodyBytes: Uint8Array
  timeoutMs: 15000,                                   // 1000..60000, default 20000
  responseType: 'json',                               // 'text' (default) | 'json' | 'bytes'
});
res.status; res.url; res.headers['retry-after']; res.setCookies; res.json;

await fushi.credentials.get(key) / set(key, value) / remove(key)  // encrypted; ≤64 KiB per value, ≤64 keys
await fushi.storage.get(key) / set(key, value) / remove(key)      // needs "storage"; ≤1 MiB per value
fushi.crypto.sha256(data), hmac('sha256', key, data), randomBytes(n), md5, sha1, aes, rsaRaw
fushi.encoding.utf8Encode / utf8Decode / base64Encode / base64Decode / hexEncode / hexDecode
console.log / info / debug / warn / error, fushi.log              // visible in `run` output and the app log
require('./relative/path')                                        // only .js files inside the package
```

- Resolves for every HTTP status; rejects only on network errors, policy violations and timeouts.
- Redirects are followed by the host (max 5), each hop checked against `network.domains`.
- Response limit 8 MiB, request body 4 MiB, ≤64 headers, ≤32 host calls in flight, ≤64 started per step.
- No cookie jar (read `res.setCookies`, send `Cookie` yourself). The default User-Agent is Dart's; set your
  own if the site asks for one (many tracking APIs want an identifying `User-Agent`).
- **There is no `fetch`, no `setTimeout` / `setInterval`, no `Intl`, no `TextEncoder`.** The engine is
  QuickJS (ES2023). Sandbox: 64 MiB heap, 2 s CPU per step, result ≤ 8 MiB.

`fushi-tracking-plugin.d.ts` types all of it.

---

## 5. Capabilities and entities

Export an (async) function per declared capability. It receives one argument object and returns plain data.

| Capability | Args | Return |
|---|---|---|
| `account` | `{}` | `{ loggedIn: boolean, name?: string }` — keep it cheap (read credentials). Extra fields are ignored: the host reads only `loggedIn` and `name` |
| `login` | section 6 | section 6 |
| `trackingSubject` | `{ id, kind? }` | `Subject` or `null` (no such work). `kind` is sent whenever the host knows which kind it expects: return `null` when the subject is of another kind |
| `trackingSearch` | `{ query, kind }` | `{ items: Subject[] }` — the host uses the first 20 |
| `trackingLookup` | `{ idType, id, kind? }` | `{ items: Subject[] }` — this site's works for an id in another id space; only the first 20 are used. `idType` is `"mal"` or another site's `siteId` |
| `trackingEntry` | `{ op: 'get', id, kind }` | `Entry` or `null` (not on the user's list) |
| `trackingEntry` | `{ op: 'set', id, kind, create, status, progress?, progressVolume? }` | `null`. `create: true` = the host saw no entry (create it, or update it if one appeared meanwhile); `create: false` and the entry is gone = throw `not_found:`. Only the given fields change |

`kind` on `trackingEntry` is always sent (`anime`, `manga` or `novel`): it is the kind of Fushi's item. Use it for
sites whose ids are per list (the same number can be an anime and a manga there); sites with one id space can
ignore it.

```ts
Subject { id*: positive integer, name*: string, kind*: 'anime' | 'manga' | 'novel',
          titles?: string[],          // every known title, any script (native, romaji, English, synonyms)
          authors?: string[],
          totalEpisodes?, totalChapters?, finalVolume?,   // non-negative integers; omit when unknown
          finished?: boolean,         // the work itself is complete (not the user's status)
          linkedIds?: { [idType]: positive integer } }    // e.g. { mal: 30831, otherSite: 44893 }
Entry   { status*: 'planned' | 'current' | 'completed' | 'paused' | 'dropped' | 'repeating',
          progress*: non-negative integer,   // episodes (anime) or chapters (manga and novels)
          progressVolume?: non-negative integer }
```

A site without chapter counts returns `progress: 0` and uses `progressVolume`. An entry whose status or counts the
host cannot read is left alone: nothing is written for it.

The host treats results as untrusted: strings are trimmed and cut (name / each title 500 characters, at most
50 titles and 20 authors); a count that is not a non-negative integer counts as missing; a subject without a
positive integer `id`, a `name` or a known `kind` is dropped; `linkedIds` keeps at most 16 positive integers.
Map the site's own statuses to the six above (for example "watching" / "reading" → `current`, "on hold" →
`paused`, "plan to watch" → `planned`, "rewatching" → `repeating`).

Give `titles` generously (every script the site has): Fushi matches its local titles against them when it
suggests links. Give `linkedIds` whenever the site knows them (MAL ids especially): that is how Fushi links a
work across sites without guessing.

### Optional extensions (spec `docs/specs/2026-11-11-bangumi-bundled-plugin.md` §2)

All optional; a plugin that uses none of them is valid as before.

- **Games**: declare `"game"` in `tracking.kinds` together with `"status"` in `tracking.modes` (both or
  neither). A game subject has `kind: 'game'` and no totals. For a game link the host sends
  `trackingEntry { op: 'set', id, kind: 'game', create, status }` with no progress: the status is the user's
  choice and is written as is (going back from `completed` to `current` is allowed). `get` returns
  `{ status, progress: 0 }`.
- **One-book subjects**: `Subject.singleVolume: true` (manga / novels) says the subject is one book (a volume,
  or a work of at most one volume). In `chapter` mode, finishing Fushi's item then completes the entry even
  without a chapter total, and with `finalVolume: 1` the host also sends `progressVolume: 1`.
- **Page address**: `tracking.subjectUrl`, e.g. `"https://example.org/subject/{id}"` (`{kind}` optional, host =
  `siteHost` or a subdomain). The app's "Open on site" uses it. When the site's address differs per kind
  (e.g. novels under `/manga/`), give one template per kind instead:
  `{ "anime": "https://example.org/anime/{id}", "novel": "https://example.org/manga/{id}" }` (keys must be in
  `tracking.kinds`; a kind left out has no page address).
- **The user's list** (capability `trackingList`): `{ kind, status, offset }` → `{ items: ListItem[], next? }`,
  `ListItem { subject: Subject, status, progress, progressVolume?, updatedAt?: ISO 8601 }`. Return one page
  from `offset` and `next` = the offset of the following page (omit it on the last page). The host reads at
  most 40 pages / 2000 items. Read only (used for "View all watched anime").

### Worked example: `trackingSubject`

```js
/** @type {FushiTracking.Plugin['trackingSubject']} */
async function trackingSubject({ id }) {
  const res = await fushi.http.request({ url: `https://api.mysite.example/v1/works/${id}`, responseType: 'json' });
  if (res.status === 404) return null;                          // no such work: null, not an error
  if (res.status === 429) throw new Error('rate_limited: My Site asks to slow down.');
  if (res.status !== 200) throw new Error(`My Site answered HTTP ${res.status}`);   // temporary
  const w = res.json;
  return {
    id: Number(w.id),                                           // integer
    name: w.title,
    kind: w.media_type === 'novel' ? 'novel' : w.media_type === 'manga' ? 'manga' : 'anime',
    titles: [w.title, w.title_native, ...(w.synonyms ?? [])].filter(Boolean),
    totalEpisodes: w.episodes ?? undefined,                     // omit unknown counts; never send 0 for "unknown"
    finished: w.status === 'finished',
    linkedIds: w.mal_id ? { mal: Number(w.mal_id) } : undefined,
  };
}
```

`run my-site trackingSubject '{"id":52991}'` must print only `OK`.

### Worked example: `trackingSearch` and `trackingLookup`

```js
async function trackingSearch({ query, kind }) {
  const j = await api(`/v1/search?type=${kind}&q=${encodeURIComponent(query)}&limit=10`);
  return { items: j.results.map(toSubject) };                   // the host uses the first 20
}

async function trackingLookup({ idType, id, kind }) {
  if (idType !== 'mal') return { items: [] };                   // id spaces the site cannot map: empty, not an error
  const j = await api(`/v1/works?mal_id=${id}${kind ? `&type=${kind}` : ''}`);
  return { items: j.results.map(toSubject) };
}
```

### Worked example: `trackingEntry`

```js
async function trackingEntry(args) {
  const token = await fushi.credentials.get('token');
  if (!token) throw new Error('unauthorized: Sign in to My Site.');
  if (args.op === 'get') {
    const j = await api(`/v1/me/list/${args.id}?type=${args.kind}`, { token, notFoundIsNull: true });   // args.kind: ids are per list here
    if (!j) return null;                                        // not on the list
    return { status: STATUS_FROM_SITE[j.status], progress: j.episodes_watched ?? j.chapters_read ?? 0,
             progressVolume: j.volumes_read ?? undefined };
  }
  const body = { status: STATUS_TO_SITE[args.status] };         // exactly the given fields
  if (args.progress !== undefined) body.progress = args.progress;
  if (args.progressVolume !== undefined) body.volumes = args.progressVolume;
  await api(`/v1/me/list/${args.id}`, { method: args.create ? 'POST' : 'PATCH', token, body });
  return null;
}
```

---

## 6. Sign-in: a pasted token in a form (`login` + `account`, permission `credentials`)

The plugin never draws UI: it describes a form and the app renders it. The tracking host renders **only
`form` methods** (no QR code, no in-app browser). `appUrl` (an `https://` link inside `network.domains`) is
shown as an **Open site** button: point it at the page where the user creates a token.
Every `login` call carries `platform` (`windows`, `macos`, `linux` or `android`).

```js
login({ op: 'methods', platform })   → { methods: [{ id, type: 'form', label, description? }] }
login({ op: 'begin', method, platform })                              → Challenge
login({ op: 'submit', method, session, platform, action, inputs })    → Challenge
login({ op: 'logout' })                                               → null
account({})                                                           → { loggedIn, name? }

Challenge {
  state: 'pending' | 'done' | 'failed',
  session?,      // opaque string, passed back to submit
  message?,      // help / status text shown above the form
  appUrl?,       // https inside network.domains → "Open site" button
  form?: { fields: [{ id, label, secret?, placeholder?, multiline?, value? }],
           actions: [{ id, label, primary? }] },        // required while pending
  account?       // { loggedIn: true, name? } with state 'done'
}
```

The pattern:

```js
async function login(args) {
  if (args.op === 'methods') return { methods: [{ id: 'token', type: 'form', label: 'Paste an access token' }] };
  if (args.op === 'logout') {
    await fushi.credentials.remove('token');
    await fushi.credentials.remove('name');
    return null;
  }
  const form = (message) => ({
    state: 'pending', message, appUrl: 'https://mysite.example/settings/tokens',
    form: { fields: [{ id: 'token', label: 'Access token', secret: true }],
            actions: [{ id: 'save', label: 'Sign in', primary: true }] },
  });
  if (args.op === 'begin') return form('Create a personal access token on My Site and paste it here.');
  const token = (args.inputs.token ?? '').trim();
  const me = await fushi.http.request({ url: 'https://api.mysite.example/v1/me', responseType: 'json',
                                        headers: { Authorization: `Bearer ${token}` } });
  if (me.status !== 200) return form('That token was not accepted. Copy it again.');   // stay on the form
  await fushi.credentials.set('token', token);
  await fushi.credentials.set('name', String(me.json.name));   // so account() needs no request
  return { state: 'done', account: { loggedIn: true, name: me.json.name } };
}

async function account() {
  const token = await fushi.credentials.get('token');
  return token ? { loggedIn: true, name: (await fushi.credentials.get('name')) ?? undefined } : { loggedIn: false };
}
```

- Verify the token with one request before saving it; on failure return the form again with a message.
- Store secrets **only** in `fushi.credentials` (encrypted, removed with the plugin, unreadable by any other
  plugin and by music plugins). Never put tokens in `fushi.storage`, in logs or in error messages.
- If the site's tokens expire, throw `unauthorized:` when the API rejects one; the app asks the user to sign
  in again. Multi-step forms work too: return another `pending` form from `submit`.

Locally, `node fushi-tracking-plugin.mjs login <dir>` drives the same flow in the terminal (prints the Open
site link, prompts each field; answers can be piped).

---

## 7. What the host decides (not negotiable by a plugin)

- The host reads the entry (`get`), plans, then writes (`set`). **Progress is never lowered**; a `completed`
  or `repeating` entry keeps its status; `completed` is written only when Fushi's item is finished and the
  site's total (when known) is reached. A secondary chapter count kept next to a volume link (a "chapter
  companion") keeps the entry's status. One planner serves every site.
- So `set` must write **exactly** the given fields, nothing else. Do not compare with the current entry, do
  not clamp to totals, do not change the status on your own, do not touch score, dates or notes.
- When to sync, what to link, which suggestions to show: all Fushi's. Return facts, not decisions.
- Links, suggestions and queued updates are kept when the plugin is disabled or removed and are used again
  when a plugin with the same `siteId` comes back. Credentials are removed with the plugin.

---

## 8. Errors and rate limit

Throw `new Error(message)`. The host reads the start of the message:

| Message starts with | The app |
|---|---|
| `unauthorized:` | marks the account signed out and asks the user to sign in again |
| `rate_limited:` | stops this sync round and tries again later |
| `not_found:` | treats the item as gone (permanent for this item) |
| anything else | treats it as temporary and retries later |

The rest of the message (after the prefix) is shown to the user, so write it for a person:
`throw new Error('not_found: My Site removed this work.')`. Use a plain `Error`: the host strips only the
built-in names (`Error: `, `TypeError: `, …) from the reported text, so a custom error class hides the prefix.
`run` prints how the app would read every thrown error.

**Rate limit.** `tracking.requestsPerMinute` is enforced by the host: it delays your HTTP requests to stay
under it. You cannot sleep (no `setTimeout`), so never wait or retry inside the plugin. When the site answers
429 (or its equivalent), throw `rate_limited:` and let the app come back later. Keep each call to a few
requests: a call gets 60 s in the app, and time spent waiting for the request budget counts toward that
timeout, so one call should make only a few requests.

---

## 9. Packaging, signing, updates

- `pack` writes `<id>-<version>.fushiplug` and re-verifies it with the installer's rules; `inspect <file>`
  verifies any package.
- Signing is optional but **sign every public release with the same key** (`keygen` once, back it up). An
  update signed by a different key — or unsigned after a signed one — installs as a new plugin and loses its
  sign-in. The install dialog shows the signer's public key, the permissions and the domains.
- Users install files manually; there is no plugin store or auto-update. Publish releases wherever you like
  and bump `version` each time. Never change `id` or `tracking.siteId` between releases.
- Fushi verifies the hashes on every load: do not edit installed files, reinstall instead.

---

## 10. Debugging checklist

| Symptom | Check |
|---|---|
| Install refused | `inspect file.fushiplug` prints the exact reason (often `kind`, a missing required capability / permission, or `tracking.*`) |
| "Plugin unavailable" / sync error | `run` that capability: an `ERROR` line or a thrown error explains it |
| Search shows fewer works | `WARN ... dropped` lines: string ids, missing name, unknown kind |
| Signed out again and again | something throws `unauthorized:` for a reason that is not a rejected token |
| Sync stops early every round | something throws `rate_limited:` too eagerly |
| An item is never synced again | it threw `not_found:`; use that only when the work is really gone |
| Progress on the site looks wrong | `set` must write the given fields verbatim (section 7) |
| Sign-in button does nothing | `login` methods must include a `form`; a pending challenge needs `form.fields` and `form.actions` |
| No "Open site" button | `appUrl` must be `https://` inside `network.domains` |
| Request rejected | the error names the host / method / permission that is missing |
| Works locally, fails in app | site blocks Dart's default User-Agent → set one; the app may use a proxy |

The local runner does not emulate the 64 MiB heap limit, V8-vs-QuickJS differences, or the host's request
pacing (it reports when one call makes more requests than `requestsPerMinute`).

---

## 11. Prompt template for an AI agent

> Build a Fushi tracking site plugin for **<site>** in `./<dir>`. Follow `GUIDE.md` exactly (it is the whole
> contract; `fushi-tracking-plugin.d.ts` has the types). Use only the APIs in section 4; there is no fetch
> and no setTimeout. Start with `node <sdk>/fushi-tracking-plugin.mjs init <dir> --id <id> --name "<name>"`,
> set `tracking.siteId` to `<siteId>` and list every API host in `network.domains`. Sign-in is a form where
> the user pastes a personal access token from `<token page URL>`; store it with `fushi.credentials`.
> Implement login, account, trackingSubject, trackingSearch, trackingLookup (idType "mal"), trackingEntry.
> After each one run `node <sdk>/fushi-tracking-plugin.mjs run <dir> <capability> '<args json>' --trace` and
> fix every ERROR and WARN. Map HTTP 401/403 to `unauthorized:`, 429 to `rate_limited:`. `trackingEntry` set
> writes exactly the given fields. Done means `smoke <dir> --query "<title>" --strict` exits 0 and `pack`
> succeeds. Do not guess endpoints: use the site's API documentation and real responses (`--full`). Only test
> writes on an entry I said you may change: `<subject id>`.

A complete, offline example lives in `examples/demo-list/`: a made-up site with its catalog in code and the
user's list in `fushi.storage`, a token form (any token starting with `demo-`), every capability, `require`,
and the `unauthorized:` / `not_found:` errors. The starter template (`init`) shows a real HTTP helper that
maps 401/403, 429 and 404 to the three prefixes.
