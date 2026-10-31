# Fushi music source plugins — complete guide

This single file is the whole contract. It is written so you can hand it to an AI coding agent (or read it
yourself) and get a working plugin without reading Fushi's source. Plugin API version: **1**.

A plugin is a small CommonJS JavaScript package that teaches Fushi's music module to browse, search, play
and show lyrics from one online source. Fushi does the UI, playback, karaoke lyrics, dictionary lookup and
study stats; the plugin only fetches data and returns plain JSON objects.

Platforms: Windows, macOS, Linux, Android. **iOS does not run plugins** (App Store rules).

---

## 1. Workflow (Node.js 18+ is the only requirement)

```sh
node fushi-plugin.mjs init my-plugin --id dev.yourname.mysource --name "My Source"
# edit my-plugin/manifest.json and my-plugin/main.js
node fushi-plugin.mjs check my-plugin                 # manifest + files + exports, like the app's installer
node fushi-plugin.mjs run my-plugin search '{"query":"lemon","type":"song","page":0,"pageSize":10}' --trace
node fushi-plugin.mjs smoke my-plugin --query lemon    # every declared capability, chained, + plays the stream
node fushi-plugin.mjs login my-plugin                  # only for plugins with login
node fushi-plugin.mjs keygen --out ~/keys/my-plugin.pem   # once; keep it forever
node fushi-plugin.mjs pack my-plugin --key ~/keys/my-plugin.pem   # → dev.yourname.mysource-0.1.0.fushiplug
```

Install in Fushi: **Settings › Music › Plugin sources › Install from file**, pick the `.fushiplug`. Results
appear on the music page (For you / search).

`run` and `smoke` execute your code in a sandbox that mirrors the app (same prelude, same globals, same
network rules, same limits) and then check every return value the way the app parses it:

The local sandbox is for **your own or trusted code only**: it is Node's `vm`, which is not a security
boundary (a hostile plugin can reach the Node process and your files). The app's QuickJS sandbox is the real
isolation; the local runner only reproduces its rules.

- `ERROR` = the app would fail this call (exit code 1).
- `WARN` = the app would silently drop or ignore something. **Treat warnings as bugs**: a dropped entry is
  the #1 reason "my results don't show". `--strict` makes warnings fail too.
- `smoke` also downloads the first KB of each stream URL with your headers, following redirects through the
  same domain checks as the player.

Optional static check (catches `fetch`, wrong field types, typos): `npx -p typescript tsc -p my-plugin/jsconfig.json`
— `init` writes a `jsconfig.json` that type-checks plain JS against `fushi-plugin.d.ts`.

`storage` / `credentials` written during local runs live in `<plugin>/.fushi-dev/` (`reset` clears it). They
are never packed.

### Recommended loop for an AI agent

1. Read sections 2–5 below. Write the manifest first (capabilities you can really implement, every host you
   will contact).
2. Implement one capability at a time; after each, `run` it and fix every ERROR and WARN.
3. Finish with `smoke --query <a query that has results>` until it prints only `OK` lines, then `pack`.
4. Never invent API endpoints: inspect the real site/API responses (`run ... --trace --full` prints them).

---

## 2. Rules that break most plugins

1. **All ids are non-empty strings.** `{ id: 123 }` is dropped. Use `String(x.id)`.
2. **Durations are milliseconds**, `expiresAt` is **epoch milliseconds**.
3. **No `fetch`, `XMLHttpRequest`, `setTimeout`, `setInterval`, `TextEncoder`, `atob`, `Buffer`, `process`,
   `import`/`export`.** Use `fushi.http.request`, `fushi.encoding`, `fushi.crypto`, `require('./x')`,
   `module.exports`. Modern syntax (async/await, classes, `?.`, `??`, template strings) is fine.
4. **Every capability in `manifest.capabilities` must be exported** from the entry file with the same name,
   and nothing undeclared is ever called.
5. **Every host you touch must be in `network.domains`** — API hosts, CDN hosts of audio and covers, and
   every **redirect target**. `*.example.com` matches subdomains only, not `example.com` itself; list both if
   needed. Non-GET methods must be listed in `network.methods`.
6. **`fushi.http.request` does not reject on 4xx/5xx.** Check `res.status` yourself.
7. **Unplayable → `throw new Error('message for the user')`.** No lyrics → `return null`. Empty search →
   `{ items: [], hasMore: false }`.
8. **`hasMore` must be `true` to load another page.** Pages are 0-based.
9. **Covers outside `network.domains` are hidden**; stream URLs outside it are unplayable.
10. **Stream headers** may only be `User-Agent`, `Referer`, `Origin`, `Cookie`, `Authorization`, `Accept`,
    `Accept-Language` (max 16, no CR/LF).
11. **CPU budget: 2 s per step.** A step is the synchronous work between two awaits; waiting on HTTP is free.
    A long synchronous loop (e.g. pure-JS crypto over megabytes) kills the instance — use `fushi.crypto`.
12. Requests from the plugin cannot reach `localhost`, LAN/private IPs or IP literals at all (also checked
    after DNS). Use host names.
13. The instance lives across calls (module-level caches work) but can be recreated at any time; persist
    anything important with `fushi.storage`.

---

## 3. Package layout and `manifest.json`

```
my-plugin/
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
  "id": "dev.yourname.mysource",
  "name": "My Source",
  "version": "1.2.0",
  "api": 1,
  "entry": "main.js",
  "author": "you",
  "description": "One line shown in the install dialog",
  "homepage": "https://github.com/you/fushi-mysource",
  "capabilities": ["search", "album", "playlist", "artist", "stream", "lyrics", "home"],
  "searchTypes": ["song", "album", "artist", "playlist"],
  "permissions": ["network", "storage"],
  "network": { "domains": ["api.mysource.com", "*.cdn.mysource.com"], "methods": ["GET", "POST"] }
}
```

| Field | Rule |
|---|---|
| `schema` | `1` |
| `id` | 2–64 chars of `a-z 0-9 . _ -`, starts and ends with a letter/digit, no `..`. Never change it: it is the install identity. |
| `name` | 1–64 chars |
| `version` | `X.Y.Z` digits only. Bump it for every release. |
| `api` | `1` |
| `entry` | relative `.js` path inside the package |
| `author` / `description` / `homepage` | optional strings |
| `capabilities` | non-empty, from section 5; no duplicates |
| `searchTypes` | required when `search` is declared: subset of `song`, `album`, `artist`, `playlist` |
| `permissions` | subset of `network`, `storage`, `credentials`, `webAuth`, `insecureHttp` |
| `network.domains` | ≤32 rules: `host.tld` (exact) or `*.host.tld` (subdomains only); lowercase |
| `network.methods` | subset of `GET POST HEAD PUT DELETE PATCH`; default `["GET"]` |

Unknown fields are rejected. Dependencies between declarations:

- `network` permission ⇔ non-empty `network.domains`. `insecureHttp` and `webAuth` need `network`.
- `login` ⇔ `account` (declare both), and they need the `credentials` permission.
- `library` and `like` need `login` + `account`.
- `artistAlbums` / `artistMvs` need `artist`; `artistMvs` needs `mvStream`.
- `searchBest` needs `search`.

Permissions: `network` = `fushi.http`; `storage` = `fushi.storage`; `credentials` = `fushi.credentials`
(encrypted); `webAuth` = the in-app browser login method; `insecureHttp` = allow `http://` URLs (some CDNs
only serve http) — otherwise only `https://`.

---

## 4. Runtime API (globals available to the plugin)

```js
// HTTP. Resolves for every status; rejects only on network errors / policy violations / timeouts.
const res = await fushi.http.request({
  url: 'https://api.mysource.com/search?q=x',   // must match network.domains
  method: 'POST',                               // must be in network.methods
  headers: { 'Content-Type': 'application/x-www-form-urlencoded', Referer: 'https://www.mysource.com/' },
  body: 'a=1&b=2',              // string (sent as UTF-8), or bodyBytes: Uint8Array
  timeoutMs: 15000,             // 1000..60000, default 20000
  responseType: 'json',         // 'text' (default) | 'json' | 'bytes'
});
res.status; res.url;            // final URL after redirects
res.headers['content-type'];    // lowercase names; repeated headers joined with ', '
res.setCookies;                 // raw Set-Cookie strings (one per cookie)
res.text; res.json; res.bytes;  // per responseType
```

- Redirects are followed by the host (max 5), each hop checked against `network.domains`. A 301/302 after
  POST and any 303 become GET without body.
- Gzip/deflate responses are decompressed automatically. Response limit 8 MiB, request body 4 MiB, ≤64
  headers, ≤32 requests in flight.
- Do not send a body with `GET` / `HEAD`: the app passes it through, but the local runner rejects it (Node's
  `fetch` cannot send one) and most servers ignore it anyway.
- You may not set `Host`, `Content-Length`, `Connection`, `Transfer-Encoding`. There is **no cookie jar**:
  read `res.setCookies` and send `Cookie` yourself. The default User-Agent is Dart's; set your own if the
  site cares.
- The app's proxy settings apply to these requests.

```js
await fushi.storage.get(key)            // → string | null           (permission: storage)
await fushi.storage.set(key, value)     // value: string ≤ 1 MiB, key ≤ 256 bytes
await fushi.storage.remove(key)
await fushi.credentials.get/set/remove  // same, encrypted at rest, ≤ 64 KiB, ≤ 64 keys (permission: credentials)

fushi.crypto.md5(data) / sha1(data) / sha256(data)        // → Uint8Array
fushi.crypto.hmac('sha256' | 'sha1' | 'md5', key, data)   // → Uint8Array
fushi.crypto.aes({ mode: 'cbc' | 'ecb', key, iv, data, decrypt: false, padding: 'pkcs7' | 'none' })
                                                          // key 16/24/32 bytes; cbc iv 16 bytes
fushi.crypto.rsaRaw({ modulus: 'hex', exponent: 'hex', data })  // unpadded RSA, left-padded to modulus length
fushi.crypto.randomBytes(n)                               // n ≤ 4096
fushi.encoding.utf8Encode(str) / utf8Decode(bytes)
fushi.encoding.base64Encode(bytes) / base64Decode(str)    // standard alphabet with padding
fushi.encoding.hexEncode(bytes) / hexDecode(str)
console.log / info / debug / warn / error, fushi.log      // visible in `run`/`smoke` output and the app log
fushi.host.api                                            // 1
require('./relative/path')                                // only .js files inside the package
```

`data` / `key` / `iv` accept a `Uint8Array` or a string (UTF-8). Base64url: convert with
`.replace(/-/g, '+').replace(/_/g, '/')` and pad with `=`.

Sandbox limits: 64 MiB heap, 256 KiB stack, 2 s CPU per step, result ≤ 8 MiB, ≤32 host calls
(`http` / `storage` / `credentials`) in flight and ≤64 started in one step — exceeding a host-call limit
kills the plugin instance. The engine is QuickJS (ES2023). There is no `Intl` (format dates and numbers
by hand), no `WebAssembly` and no `Atomics`; `SharedArrayBuffer` exists but there are no threads to share
it with. The local runner removes the same globals.

---

## 5. Capabilities

Export an (async) function per declared capability. It receives one argument object and returns plain data.
Throwing an `Error` shows `error.message` to the user.

| Capability | Args | Return | Where the app uses it |
|---|---|---|---|
| `search` | `{ query, type, page, pageSize }` — `type` is one of your `searchTypes`, `page` from 0, `pageSize` ≈ 30 | `{ items, hasMore, total? }` — items are `Track` / `Album` / `Artist` / `Playlist` matching `type` | Search page tabs |
| `searchBest` | `{ query }` | `{ artist?, playlist?, album? }` or `null` | Top "best match" card |
| `album` | `{ id }` | `{ album: Album, tracks: Track[] }` | Album page |
| `playlist` | `{ id }` | `{ playlist: Playlist, tracks: Track[] }` | Playlist page |
| `artist` | `{ id }` | `{ artist: Artist, albums?: Album[], tracks?: Track[] }` — tracks = top songs (first 50 used). Skip `albums` if you declare `artistAlbums` | Artist page |
| `artistAlbums` | `{ id, page, pageSize }` | `{ items: Album[], hasMore, total? }` | Artist page › Albums |
| `artistMvs` | `{ id, page, pageSize }` | `{ items: Mv[], hasMore, total? }` | Artist page › Videos |
| `stream` | `{ id, quality }` — `standard` / `high` / `lossless` / `hires` | `Stream` | Playback (asked right before playing; also for the queued next track) |
| `mvStream` | `{ id, quality }` | `MvStream` | Music video player (also for `Track.mvId`) |
| `lyrics` | `{ id }` (track id) | `{ original, translation?, romanization? }` or `null` | Lyrics / karaoke view; cached, `null` re-asked after a day; LRCLIB is the fallback |
| `home` | `{ refresh? }` — `refresh: true` when the user asks for new picks | `{ sections: Section[] }` (first 12 sections, 50 items each) | Music page › For you |
| `library` | `{ page, pageSize }` | `{ items: Playlist[], hasMore }` — the account's own + saved playlists, "liked" first; empty page when logged out | Music page › your playlists |
| `like` | `{ op: 'list' }` / `{ op: 'set', id, liked }` | list → `{ ids: string[], playlist?: Playlist }` or `null` (logged out); set → `null`, throw on failure | Heart button = the platform account's "liked songs" |
| `account` | `{}` | `{ loggedIn, name?, avatarUrl?, badge? }` | Settings › plugin account row |
| `login` | see section 6 | | Sign-in screen |

### Entities

Required fields are marked; everything else is optional and may be omitted. Entries missing a required field
are dropped. Text is trimmed; empty strings count as missing.

```ts
Track    { id*, title*, artists?: [{ id?, name* }], album?: { id?, title? }, durationMs?, coverUrl?,
           trackNo?, discNo?, isrc?, playable? (default true), note? ("VIP"), mvId? }
Album    { id*, title*, artists?, coverUrl?, year?, trackCount?, releaseDate? ('YYYY'|'YYYY-MM'|'YYYY-MM-DD'),
           company? (≤200 chars), description? (≤20000) }
Artist   { id*, name*, coverUrl?, aliases?: string[] (≤10), description?, intro?: [{ title?, text* }] (≤20),
           stats?: { trackCount?, albumCount?, mvCount?, fanCount? } }
Playlist { id*, title*, coverUrl?, trackCount?, owner?, description?, playCount?, tags?: string[] (≤10),
           previewTracks?: Track[] (first 3, text only — e.g. a chart's top 3) }
Mv       { id*, title*, artists?, coverUrl? (16:9), durationMs?, playCount?, publishDate? ('YYYY-MM-DD') }
Stream   { url*, headers?, expiresAt?, codec?, bitrateKbps?, sampleRate?, bitDepth?, sizeBytes?,
           trial?: { startMs, endMs } (only a preview is available) }
MvStream { url*, headers?, expiresAt?, width?, height? }
Section  { id*, title*, subtitle?, kind*: 'tracks' | 'playlists' | 'albums', items*: [matching entities] }
LyricText { format*: 'lrc' | 'yrc' | 'qrc' | 'krc' | 'ttml' | 'txt', text*, language? (BCP 47, e.g. 'ja') }
```

Counts must be non-negative numbers. `lyrics` without a usable `original` counts as no lyrics. Word-timed
formats (`yrc`, `qrc`, `krc`, `ttml`) give karaoke highlighting; `lrc` gives line timing; `txt` is unsynced.
A `translation` is paired with the original line by time. Return lyrics in the source's own form: Fushi never
adds machine-generated readings (furigana), but ruby that the source provides is shown.

`fushi-plugin.d.ts` has all of this as TypeScript types; with `/// <reference path="./fushi-plugin.d.ts" />`
and JSDoc (`/** @type {Fushi.Plugin['search']} */`), editors and agents get completion and type errors in plain JS.

---

## 6. Login (`login` + `account`, permission `credentials`)

The plugin never draws UI: it describes a login method and the app renders it.

```js
login({ op: 'methods', platform })     // platform: 'windows' | 'macos' | 'linux' | 'android'
  → { methods: [{ id, type: 'qr' | 'form' | 'web', label, description? }] }
login({ op: 'begin', method, platform })                              → Challenge
login({ op: 'poll', method, session, platform })                      → Challenge   // qr, every pollMs
login({ op: 'submit', method, session, platform, action, inputs })    → Challenge   // form / web
login({ op: 'logout' })                                               → null
account({}) → { loggedIn, name?, avatarUrl?, badge? }

Challenge {
  state: 'pending' | 'done' | 'failed',
  session?,                 // opaque string; passed back to poll / submit
  message?,                 // status text ("Scanned, confirm on your phone")
  qr?: { content? | imageBase64? (PNG), scanned? }, pollMs? (500..10000),
  appUrl?,                  // "open in the official app" button: https inside network.domains, or one of
                            // orpheus, qqmusic, mqqapi, wtloginmqq, kugou, kuwo, migu, snssdk1128
  form?: { fields: [{ id, label, secret?, placeholder?, multiline?, value? }],
           actions: [{ id, label, primary? }] },
  web?: { url, cookieUrl, doneCookie },
  account?                  // with state 'done'
}
```

- `qr`: the app draws the QR and polls until `done` / `failed`.
- `form`: the app draws the fields (SMS code, password, "paste your cookie", …); pressing an action calls
  `submit` with `inputs = { fieldId: value }`. Return another `form` challenge for multi-step flows.
- `web` (needs `webAuth`; `url` and `cookieUrl` inside `network.domains`): the app opens `url` in an in-app
  browser, waits until cookie `doneCookie` exists for `cookieUrl`, then calls `submit` with
  `action: 'web', inputs: { cookie: 'a=b; c=d' }` (all cookies of that site).

Store tokens/cookies yourself with `fushi.credentials`, clear them on `logout`, and make `account()` cheap
(read from credentials, refresh rarely). Uninstalling the plugin deletes its credentials and storage.

Locally, `node fushi-plugin.mjs login <dir>` drives the same flow in the terminal (QR content / PNG is
printed or saved, form fields are prompted, web login asks you to paste the cookie).

---

## 7. Packaging, signing, updates

- `pack` writes `<id>-<version>.fushiplug` and re-verifies it with the installer's rules; `inspect <file>`
  verifies any package.
- Signing is optional but **sign every public release with the same key** (`keygen` once, back it up). An
  update signed by a different key — or unsigned after a signed one — installs as a new plugin and loses its
  login and data. The install dialog shows the signer's public key, the permissions and the domains.
- Users install files manually; there is no plugin store or auto-update. Publish releases wherever you like
  (GitHub Releases works well) and bump `version` each time.
- Fushi verifies the hashes on every load: do not edit installed files, reinstall instead.

---

## 8. Debugging checklist

| Symptom | Check |
|---|---|
| Install refused | `node fushi-plugin.mjs inspect file.fushiplug` prints the exact reason |
| "Plugin unavailable" on a page | `run` that capability: an `ERROR` line or a thrown error explains it |
| Items missing / fewer results | `WARN ... dropped` lines: ids not strings, missing title/name |
| Covers blank | cover host not in `network.domains` (also the host it redirects to) |
| Track won't play | `smoke` media probe: HTTP status, redirect host, missing `Referer` / `User-Agent` header; `expiresAt` too short |
| Request rejected | the error names the host / method / permission that is missing |
| Instance "terminated" | a synchronous loop over 2 s; move heavy work to `fushi.crypto` or split it |
| Works locally, fails in app | site blocks Dart's default User-Agent → set one; the app may use a proxy |

What the local runner does not emulate: the 64 MiB heap limit and engine differences between V8 and QuickJS
(stay with standard ECMAScript and you will not notice).

---

## 9. Prompt template for an AI agent

> Build a Fushi music source plugin for **<site / API>** in `./<dir>`. Follow `GUIDE.md` exactly (it is the
> whole contract; `fushi-plugin.d.ts` has the types). Use only the APIs in section 4. Start with
> `node <sdk>/fushi-plugin.mjs init <dir> --id <id> --name "<name>"`. Implement capabilities: <list>. After
> each one run `node <sdk>/fushi-plugin.mjs run <dir> <capability> '<args json>' --trace` and fix every ERROR
> and WARN. Done means `node <sdk>/fushi-plugin.mjs smoke <dir> --query "<query>" --strict` exits 0 and
> `pack` succeeds. Do not guess endpoints: look at real responses with `--full`.

A complete working example lives in `examples/archive-netlabels/` (Internet Archive netlabel releases +
LRCLIB lyrics: search, album, stream, lyrics, home, `require`, storage cache).
