# 音乐在线音源插件（v1）

状态：实现中（PR #2634）。所有者 2026-10-29 已改判音乐模块设计
（[`2026-10-23-music-module-design.md`](2026-10-23-music-module-design.md)）的两条决定——§1 非目标
「不做在线流媒体平台播放」与 D3「国内平台在线歌词暂不做」——改为允许，走本插件方案。
D11「不做歌词编辑与自动注音」不在改判范围，照旧。

## 1. 范围与边界

- 音乐模块多一类来源「插件音源」：用户自行安装的 JS 插件提供搜索、专辑 / 歌单 / 艺人详情、
  取流与歌词；播放、逐字歌词渲染、查词制卡、学习统计全部走现有链路。
- **仓库不内置任何平台的协议实现，也不内置插件仓库**。平台插件独立于本仓开发、
  分发；本仓只提供宿主与契约。
- **iOS 不提供**：插件宿主属于「下载并执行第三方代码 + 接入未授权来源」，归入
  `StoreRestrictedCapability.onlineMusicSource`；iOS 伞形静态库也不编入 JS 引擎
  （`fushi_music` 的 `plugin` 特性在 `fushi_ios_umbrella` 里关闭）。
- 不做：DRM 解密、插件仓库 / 自动更新、插件自定义 UI（登录界面由宿主按插件给的数据渲染，见 §4.1）。

## 2. 插件包 `.fushiplug`

zip，必须包含：

| 文件 | 说明 |
|---|---|
| `manifest.json` | 清单（下表） |
| `files.json` | `{"files": {"<相对路径>": "<sha256 小写十六进制>"}}`，覆盖除它自身与 `signature.json` 外的**每个**文件，多一个少一个都拒装 |
| `signature.json`（可选） | `{"publicKey": base64(Ed25519 公钥 32B), "signature": base64(64B)}`，签 `files.json` 原始字节 |
| 入口 `.js` 及其 `require` 的 `.js` | CommonJS |

上限：≤128 个文件、单文件 ≤4 MiB、总计 ≤16 MiB；路径必须是 `/` 分隔的相对路径，不得含
`..` / `.` 段、反斜杠、冒号、控制字符。

清单（未知字段拒装）：

```json
{
  "schema": 1,
  "id": "moe.example.music",
  "name": "示例音乐",
  "version": "0.1.0",
  "api": 1,
  "entry": "main.js",
  "author": "...", "description": "...", "homepage": "https://...",
  "capabilities": ["search", "album", "playlist", "artist", "stream", "lyrics"],
  "searchTypes": ["song", "album", "artist", "playlist"],
  "permissions": ["network", "storage", "credentials", "webAuth", "insecureHttp"],
  "network": { "domains": ["api.example-music.com", "*.img.example-music.com"], "methods": ["GET", "POST"] }
}
```

- `id`：`[a-z0-9][a-z0-9._-]{1,63}`；`version`：`X.Y.Z`；`api` ≤ 宿主 API 版本（当前 1）。
- `network.domains`：`host` 只匹配该主机；`*.host` 只匹配其子域（不含裸域）。声明了域名就必须
  有 `network` 权限，反之亦然。`methods` 缺省为 `["GET"]`。
- `insecureHttp`：允许 `http://`（部分平台 CDN 只给 http 地址）；否则只许 `https://`。
- `credentials`：`fushi.credentials`（加密存储，见 §4.1）。声明 `login` 能力必须有它。
- `webAuth`：允许 `web` 类登录方式（宿主打开内嵌浏览器、捕获指定 Cookie）；登录页地址同样必须在
  `network.domains` 内。
- 任何规则下都拒绝 IP 字面量、`localhost` 与回环 / 私网 / 链路本地地址。

**信任**：签名只证明「包由该公钥持有者产出」。v1 宿主没有内置信任公钥，任何插件安装时都会
展示清单、权限、网络域名与签名者，由用户确认；用户确认的是包摘要（`files.json` 的 sha256），
安装时再次校验摘要一致。已装插件每次加载都按 `files.json` 重新哈希，被改过就拒载。

## 3. 运行时

- Rust 胖核心：`native/fushi_music/src/plugin/`（QuickJS，经 rquickjs ≥0.14）。每个插件一个
  运行时：内存 64 MiB、JS 栈 256 KiB、单步 CPU 预算（默认 2 s，超出则实例作废、宿主重建）。
- **步进式驱动**（不在 FFI 上回调 Dart）：`ffm_plugin_step(handle, ops)` 收一批操作——
  `{"op":"invoke","inv":N,"method":"search","args":{...}}` 或
  `{"op":"complete","call":M,"ok":true,"value":...}`——执行到无事可做，返回
  `{"settled":[{inv,ok,value|error}], "calls":[{id,op,args}], "logs":[{level,message}], "fatal"?}`。
  `calls` 是插件发出、已通过授权核对的宿主调用（`http` / `storage.get|set|remove`），由 Dart
  执行后在下一次 step 用 `complete` 交回。
- **字节不走 JSON / base64**（2026-10-29，按粗 FFI 规则）：`ffm_plugin_step(handle, ops, blob)`
  另收一块二进制区，`complete` 的响应体写成 `value.body: {off, len}` 引用它；输出帧为
  `[u32 LE json 长度][json][二进制区]`，`http` 调用参数里的请求体同样是 `body: {off, len}`。Dart 侧
  每个实例一个长驻后台 isolate（`MusicPluginStepWorker`）跑 step，字节经 `TransferableTypedData`
  转移，ops / 结果的 JSON 编解码也在后台 isolate；UI isolate 只做网络 IO（app 代理配置在这里）。
- 插件可见的全局（其余原生桥在前奏结束后删除）：

```js
fushi.http.request({ url, method?, headers?, body?: string, bodyBytes?: Uint8Array,
                     timeoutMs?, responseType?: 'text' | 'json' | 'bytes' })
  // → Promise<{ status, url, headers, setCookies: string[], text?, json?, bytes? }>；非 2xx 不抛错。
  // headers 里同名多值按 ', ' 连接；Set-Cookie 另以原样数组给出（Expires 里有逗号，不能拼接）。
fushi.storage.get(key) / set(key, value: string) / remove(key)   // 需 storage 权限；按插件隔离
fushi.credentials.get(key) / set(key, value: string) / remove(key)
  // 需 credentials 权限：AES-256-GCM 加密落盘、按插件 + 键名做附加认证数据（拷到别的插件 / 键名下解不开）；
  // 数据密钥 Windows 用 DPAPI（当前用户）保护；其它平台存系统安全存储（iOS / macOS Keychain、
  // Android Keystore、Linux libsecret，经 flutter_secure_storage），宿主取出后随调用交给 Rust，不落盘
  // （2026-10-29 所有者拍板；旧版明文密钥文件首次启动迁入安全存储后删除）。
  // 防的是凭据文件被单独拷走，不防本机同用户的恶意程序。
fushi.crypto.md5|sha1|sha256(data) → Uint8Array
fushi.crypto.hmac('sha256'|'sha1'|'md5', key, data) → Uint8Array
fushi.crypto.aes({ mode: 'cbc'|'ecb', key, iv?, data, decrypt?: bool, padding?: 'pkcs7'|'none' })
fushi.crypto.rsaRaw({ modulus: hex, exponent: hex, data })   // 无填充 RSA，左补零到模长
fushi.crypto.randomBytes(n)
fushi.encoding.utf8Encode|utf8Decode|base64Encode|base64Decode|hexEncode|hexDecode
console.log/info/debug/warn/error, fushi.log
require('./relative')   // 只能加载包内已校验的 .js
```

  data / key / iv 参数接受 `Uint8Array` 或字符串（按 UTF-8）。没有 `fetch` / `setTimeout` /
  `TextEncoder`。

- 网络请求由 Dart 执行（`createAppHttpClient`，走全应用代理）：自动解压 gzip；不自动跟随
  重定向，每一跳都回到 Rust 按授权核对（最多 5 跳）；DNS 解析后的地址同样拒绝私网段；响应体
  上限 8 MiB；超时由插件给（1–60 s，缺省 20 s）。

## 4. 能力契约（v1）

入口模块导出与 `capabilities` 同名的函数（可为 async），参数是一个对象：

| 能力 | 参数 | 返回 |
|---|---|---|
| `search` | `{ query, type: 'song'\|'album'\|'artist'\|'playlist', page: 0 起, pageSize }` | `{ items: [对应类型实体], hasMore: bool, total?: int }` |
| `album` | `{ id }` | `{ album: Album, tracks: [Track] }` |
| `playlist` | `{ id }` | `{ playlist: Playlist, tracks: [Track] }` |
| `artist` | `{ id }` | `{ artist: Artist, albums?: [Album], tracks?: [Track] }`：tracks = 热门曲（宿主取前 50）；artist 可带简介 / 分段介绍 / 别名 / 统计（见 Artist）。声明了 `artistAlbums` 的插件这里不必再给 albums |
| `artistAlbums` | `{ id, page: 0 起, pageSize }` | `{ items: [Album], hasMore, total? }`：艺人专辑分页。需同时声明 `artist` |
| `artistMvs` | `{ id, page: 0 起, pageSize }` | `{ items: [Mv], hasMore, total? }`：艺人 MV 分页。需同时声明 `artist` 与 `mvStream` |
| `mvStream` | `{ id, quality }` | `MvStream`；不可播放时抛错（错误信息给用户看）。quality 同 `stream`，插件自行映射到分辨率 |
| `searchBest` | `{ query }` | `{ artist?: Artist, playlist?: Playlist, album?: Album }` 或 `null`：平台自己的「最佳匹配」（综合搜索置顶卡）。需同时声明 `search` |
| `stream` | `{ id, quality: 'standard'\|'high'\|'lossless'\|'hires' }` | `Stream`；不可播放时抛错（错误信息给用户看） |
| `lyrics` | `{ id }` | `{ original?: LyricText, translation?: LyricText, romanization?: LyricText }` 或 `null` |
| `lyricsSearch` | `{ query, title, artist?, album?, durationMs? }` | `{ items: [{ ref, title, artist, durationMs? }] }`：按本地 / 服务器曲目的标题 + 艺人搜歌词候选（不要求插件有自己的曲目）。必须与 `lyricsFetch` 同时声明；可以只声明这两个能力（纯歌词插件，详见 2026-10-30-lyrics-plugins.md） |
| `lyricsFetch` | `{ ref }` | `{ original?: LyricText, translation?: LyricText, romanization?: LyricText }` 或 `null`：取 `lyricsSearch` 选中候选的歌词。必须与 `lyricsSearch` 同时声明 |
| `home` | `{}` | `{ sections: [Section] }`：音乐页「推荐」页签的内容（每日推荐、推荐歌单、榜单等）；登录后可给个性化内容 |
| `library` | `{ page: 0 起, pageSize }` | `{ items: [Playlist], hasMore: bool }`：已登录账号自己的歌单与收藏的歌单（「我喜欢」排第一）；未登录返回空页。需同时声明 `account` |
| `like` | `{ op: 'list' }` / `{ op: 'set', id, liked: bool }` | list → `{ ids: [曲目 id], playlist?: Playlist }`（平台账号喜欢的全部曲目 + 承载它们的「喜欢」歌单），未登录返回 `null`；set → `null`，未登录或平台拒绝时抛错（消息给用户看）。需同时声明 `login` / `account` |

实体（`id` 一律字符串，由插件定义，宿主只做不透明键）：

```ts
Track    { id, title, artists: [{ id?, name }], album?: { id?, title }, durationMs?, coverUrl?,
           trackNo?, discNo?, isrc?, playable?: bool /* 缺省 true */, note?: string /* 如「VIP」 */,
           mvId?: string /* 这首歌的 MV，插件声明了 mvStream 才会被用到 */ }
Album    { id, title, artists: [{ id?, name }], coverUrl?, year?, trackCount?,
           releaseDate?: 'YYYY' | 'YYYY-MM' | 'YYYY-MM-DD', company?, description? }
Artist   { id, name, coverUrl?, aliases?: [string] /* 别名 + 译名 */, description?: string /* 简介全文 */,
           intro?: [{ title?, text }] /* 其它介绍段落 */,
           stats?: { trackCount?, albumCount?, mvCount?, fanCount? } }
Mv       { id, title, artists?: [{ id?, name }], coverUrl? /* 16:9 */, durationMs?, playCount?,
           publishDate?: 'YYYY-MM-DD' }
MvStream { url, headers?: {k: v}, expiresAt?: epochMs, width?, height? }
Playlist { id, title, coverUrl?, trackCount?, owner?, description?, playCount?, tags?: [string],
           previewTracks?: [{ id, title, artists: [{ id?, name }], ...Track 其余字段可选 }] }
           /* previewTracks：卡片上直接显示的前几首（如榜单前三），只显示文字。宿主丢掉缺 id/title 的
              坏条目、截断到前 3 条、丢弃其中的 coverUrl；主要用于 home 的 playlists 段 */
Stream   { url, headers?: {k: v}, expiresAt?: epochMs, codec?, bitrateKbps?, sampleRate?, bitDepth?,
           sizeBytes?, trial?: { startMs, endMs } /* 只给了试听片段 */ }
Section  { id, title, subtitle?, kind: 'tracks' | 'playlists' | 'albums', items: [对应实体] }
           /* 宿主最多取前 12 段、每段前 50 项；空段不显示 */
LyricText { format: 'yrc' | 'lrc' | 'ttml' | 'qrc' | 'krc' | 'txt', text, language?: 'zh-Hans' 等 BCP 47 }
```

`stream.url`、`mvStream.url`、`coverUrl` 交给宿主前都会按插件网络授权再核对一次（`purpose = media`）：越权的
封面当没有，越权的流地址当不可播放。

宿主对不可信文本的处理（都只影响显示，不让整页失败）：字符串去首尾空白、空串当缺失；简介 / 介绍段落 / 专辑与
歌单简介截断到 20000 字符（按码点），公司 / 创建者 / 段落标题 200，别名最多 10 条、每条 100（去重、去掉与
本名相同的），歌单标签最多 10 条、每条 32，介绍段落最多 20 段（无 text 的段丢弃）；计数（统计、播放数、
时长、曲目数）必须是非负数，否则当缺失；日期不合上述形状当缺失；`mvId` 等 id 只收字符串。新字段与新能力都是
可选的：旧插件不给，对应信息 / 页签不出现。

搜索最佳匹配：声明了 `searchBest` 的插件给的结果优先（艺人卡在前，同时给了歌单就并排第二张）；都没给时宿主
只看第一个有在线艺人结果的插件返回的**第一个**艺人，名字或别名与查询词归一化后一致才用，否则看本地同名艺人 /
同名专辑 / 同名歌曲，再退到第一首歌——不在全部结果里按名字全等挑（同名小号常排在后面）。

在线 MV 交给音乐的 MV 页（`music_mv_page.dart`，同一个 media_kit 播放器）播放：进页才取流，不取歌词、
没有曲库音轨 / 偏移微调，进页时暂停音乐。

### 4.1 登录（能力 `login` + `account`，需 `credentials` 权限）

登录方式由插件声明、界面由宿主渲染（插件不提供 UI），四种类型：

| type | 宿主行为 |
|---|---|
| `qr` | 画二维码（`qr.content` 文本，或 `qr.imageBase64` PNG），按 `pollMs` 轮询 `poll` 直到 done / failed；有 `appUrl` 时多一个「在本机 App 中确认」按钮（外部打开） |
| `form` | 按 `form.fields` 画输入框（短信验证码、粘贴 Cookie 等），按钮是 `form.actions`，点了调 `submit(action, inputs)` |
| `web` | 需 `webAuth` 权限：内嵌浏览器打开 `web.url`，轮询 `web.cookieUrl` 下的 Cookie，出现 `web.doneCookie` 时把该站全部 Cookie 拼成 `a=b; c=d` 调 `submit(action: 'web', inputs: { cookie })` |

```ts
account() → { loggedIn: bool, name?, avatarUrl?, badge? /* 如「黑胶 VIP」 */ }
login({ op: 'methods', platform: 'windows'|'macos'|'linux'|'android' })
  → { methods: [{ id, type: 'qr'|'form'|'web', label, description? }] }
login({ op: 'begin', method, platform })                      → Challenge
login({ op: 'poll', method, session, platform })              → Challenge   // qr
login({ op: 'submit', method, session, platform, action, inputs }) → Challenge   // form / web
login({ op: 'logout' })                                       → null
Challenge {
  state: 'pending' | 'done' | 'failed',
  session?: string,        // 不透明，宿主原样回传
  message?: string,        // 给用户看的状态（「已扫码，请在手机上确认」）
  qr?: { content?, imageBase64?, scanned?: bool }, pollMs?: 500–10000,
  appUrl?: string,         // https（须在网络授权内）或白名单官方 App scheme（orpheus 等）
  form?: { fields: [{ id, label, secret?, placeholder?, multiline?, value? }],
           actions: [{ id, label, primary? }] },
  web?: { url, cookieUrl, doneCookie },
  account?: Account        // state = done 时
}
```

网页登录的内嵌浏览器内部跳转不受网络授权约束（只核对起始登录页与 Cookie 地址），与 QPlayer 同一取舍：`webAuth` 等于授权插件在该站跑浏览器。凭据只由插件自己经 `fushi.credentials` 保存；宿主不解读任何平台 Cookie。卸载插件时连同加密凭据一起删。

## 5. 宿主接线

- Dart 宿主：`packages/fushi_music/lib/src/plugin/`（FFI 绑定、驱动循环、DTO、安装 / 启停 /
  卸载管理）。插件目录 `<数据库目录>/music_plugins/<id>/`，插件存储
  `<数据库目录>/music_plugins/.storage/<id>.json`，启停状态 `.state.json`。
- app：设置 › 音乐 › 插件音源（安装 / 启停 / 卸载 / 详情）；插件音源以「服务器曲库」同一套页面
  浏览（`MusicServerBrowser` 的插件实现，kind = `plugin`），播放项路径
  `fushi-music-plugin://<插件 id>/<曲目 id>`，在 mpv 后端 `resolveMusicMedia` 打开前才取流
  （当前曲与预排的下一首各取一次，过期地址自然随重开刷新）。
- 登录：设置 › 音乐 › 插件音源里每个声明了 `login` 的插件下有账号行（状态 + 登录 / 退出）；登录页
  `music_plugin_login.dart` 按 §4.1 三种类型渲染，网页登录复用站点浏览器的 WebView2 环境
  （`MangaWebViewEnvironment`，WebView 与 CookieManager 必须同一环境）。凭据保险库在 Rust
  （`native/fushi_music/src/plugin/vault.rs`），卸载插件时一并清除。
- 歌词：插件曲目的歌词来源 `provider:plugin:<id>`，按 `music_lyrics` 现有缓存表落库，排在
  LRCLIB 之前（插件没有歌词或报错时仍回落 LRCLIB）。有译文时与原文按时间配对合进同一条时间轴、
  落库存 TTML；`romanization` v1 不用。插件说「没有」时负缓存 1 天。

- 歌曲收藏（用户 2026-10-29 拍板「歌曲收藏是对应在线媒体的」）：收藏 = 平台账号的「喜欢」，不建本地
  收藏表。`MusicSession.canFavorite / isFavorite / toggleFavorite` 委托
  `media/music/plugin/music_plugin_favorites.dart`：喜欢集合按插件缓存在内存（首次被问到才拉；登录 /
  退出、装卸 / 启停插件后重拉），喜欢 / 取消喜欢调 `like` 成功后才改缓存。本地 / 服务器曲目不能收藏。
  推荐页顶部「我喜欢的音乐」快捷格直接打开 `like` 给的平台歌单（插件歌单详情页），未登录时去登录。

## 5.1 第三方开发包

面向插件作者（含 AI 编程助手）的开发包在 `tools/music-plugin-sdk/`：单文件契约 `GUIDE.md`（英文，§2–§4 的
作者向改写）、零依赖 Node CLI `fushi-plugin.mjs`（`check` / `run` / `smoke` / `login` / `pack` / `inspect`，
本地沙箱复用同一份前奏、同一套网络授权与上限，返回值按 Dart 解析逻辑逐项核对）、类型 `fushi-plugin.d.ts`、
模板与示例插件。改本文 §2–§4 或宿主规则时同步改开发包；前奏副本与能力 / 权限等清单由
`fushi/test/build/music_plugin_sdk_sync_guard_test.dart` 钉住。

## 6. 待决

- 信任公钥 / 官方插件仓库是否要有、由谁签。
- 无头服务端是否也带插件宿主（`fushi_music` 目前不随服务端发布）。
