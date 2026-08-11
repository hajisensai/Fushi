## BUG-1498 · 多条出站链路绕过统一代理层
- **报告**：2026-08-11（用户：BUG-1493 修完词典下载后拍板「其余裸出站链路（字体 / OCR / 刮削等）一块修」）
- **真实性**：✅ 真 bug（结构性缺陷，非单点疏漏）

### 根因：不是「谁忘了接」，是**形状接不上**

代理解析层 `fushi/lib/src/utils/net/app_proxy.dart:145` `applyAppProxy` 从 BUG-1348 起就存在，
但它的文件头（修前 `:24-28`）白纸黑字列着一份「不经本层」的名单。全仓普查实测：**40+ 条**出站
链路绕过它。

真正的根因在**函数签名**：这些出站点的统一形态是构造函数初始化列表里的

```dart
SomeClient({http.Client? client}) : _client = client ?? http.Client();
```

**初始化列表里不能 `await`**，而 `applyAppProxy` 是异步的（要跑 `reg query` / `scutil` /
`gsettings` 探平台 GUI 系统代理）。于是每个新写出站的人面对的选择只有「把整条构造链改成异步
工厂 + 改所有调用点」或者「就用裸 client」——**结构决定了他们都会选后者**。加多少条注释都没用。

### 附带查出的第二个缺陷：接代理会打断本机 / 局域网功能

Dart 的 `HttpClient.findProxyFromEnvironment` **不做任何隐式 loopback bypass**（浏览器与
Windows `ProxyOverride` 的默认值 `<local>` 都做）。实测（`environment = {http_proxy: 1.2.3.4:8080}`）：

```text
http://127.0.0.1:8765/       -> PROXY 1.2.3.4:8080
http://localhost:8765/       -> PROXY 1.2.3.4:8080
http://192.168.1.34:5000/    -> PROXY 1.2.3.4:8080
http://hibiki-pc.local:8080/ -> PROXY 1.2.3.4:8080
```

而「用户手填代理」那条分支（`app_proxy.dart` 修前 `:153`）更极端——无条件返回
`PROXY host:port`，连 `no_proxy` 都不过。也就是说：**在本轮之前，「把某条链路接进代理层」
一直是个危险动作**，AnkiConnect / Yomitan 本地端口 / Mihon sidecar / 桌面 OAuth 回环回调 /
互联局域网 peer / qBittorrent WebUI / 自建 WebDAV 任何一条被卷进去都会当场坏掉。

### 全仓出站链路普查表

> 路径相对仓库根。「已接」= 本轮接进统一装配点；「不接」= 目标是本机/局域网/自建服务，
> 接了会更坏；「结构不可接」= Dart 层没有注入点。

#### A. 本轮接进代理（公网 / 受阻域）

| 链路 | 文件:行 | 目标域 | 修前 | 处置 |
|---|---|---|---|---|
| manga-OCR 模型下载（~470MB） | `fushi/lib/src/ocr/manga_ocr_model_downloader.dart:36` | huggingface.co | 只读 env 变量，读不到 GUI 系统代理 | **已接** |
| mokuro.moe 目录 / 封面 | `fushi/lib/src/media/manga/online/mokuro_moe_client.dart:130` | mokuro.moe | 只读 env | **已接** |
| mokuro.moe 卷下载 | `fushi/lib/src/media/manga/online/mokuro_moe_volume_downloader.dart:99` | mokuro.moe | 只读 env | **已接** |
| Google Lens 云端 OCR | `fushi/lib/src/media/manga/ocr/google_lens_ocr_service.dart:48` | lensfrontend-pa.googleapis.com | 裸 `HttpClient()` | **已接** |
| Mihon 扩展商店索引 | `fushi/lib/src/media/manga/mihon/mihon_extension_store_client.dart:100` | github.com/keiyoushi | 裸 `http.Client()` | **已接** |
| Bangumi 刮削 | `fushi/lib/src/media/metadata/bangumi_api_client.dart:128` | api.bgm.tv（可自填 base） | 裸 | **已接** |
| Bangumi 追番同步 | `fushi/lib/src/media/tracking/bangumi_api_client.dart:283` | api.bgm.tv | 裸 | **已接** |
| 封面 / 剧照下载 | `fushi/lib/src/media/metadata/image_download.dart:138`、`media/video/scraper/cover_downloader.dart:40`、`media/video/metadata/video_metadata_asset_downloader.dart:31`、`media/video/video_cover_extractor.dart:164` | tmdb / bgm / fanart 图床 | 裸 | **已接** |
| AniList（两份实现） | `fushi/lib/src/media/video/anilist_client.dart:239`、`media/video/scraper/anilist_client.dart:23` | graphql.anilist.co | 裸 | **已接** |
| Jikan（MAL） | `fushi/lib/src/media/video/scraper/jikan_client.dart:23` | api.jikan.moe | 裸 | **已接** |
| TMDB | `fushi/lib/src/media/video/scraper/tmdb_client.dart:26` | api.themoviedb.org / image.tmdb.org | 裸 | **已接** |
| 离线动画库下载 | `fushi/lib/src/media/video/scraper/offline_db_downloader.dart:24` | github.com/manami-project | 裸 | **已接** |
| 元数据共享 transport（TMDB/AniList/Bangumi/Fanart/豆瓣 provider 全经它） | `fushi/lib/src/media/video/metadata/video_metadata_transport.dart:81` | 各刮削源 | 裸 | **已接** |
| 弹幕 | `fushi/lib/src/media/video/dandanplay_client.dart:264` | api.dandanplay.net（可自建） | 裸 | **已接** |
| OpenSubtitles | `fushi/lib/src/media/video/subtitle/open_subtitles_client.dart:169` | api.opensubtitles.com | 裸 | **已接** |
| Jimaku client 默认值 | `fushi/lib/src/media/video/jimaku_client.dart:367` | jimaku.cc | 裸（调用点已注入代理 client） | **已接** |
| 流媒体 liveness 探测 | `fushi/lib/src/media/video/stream_video_launch.dart:27` | googlevideo.com | 裸 | **已接** |
| URL 流播放 | `fushi/lib/src/media/video/url_stream_video.dart:237` | 用户粘贴的任意 http/HLS | 裸 | **已接** |
| mpv / Anime4K shader 下载 | `fushi/lib/src/media/video/video_shader_downloader.dart:331,477` | jsdelivr 四镜像 + 4 个 gh 反代 + raw.githubusercontent | 裸 `Dio(...)`，注释里明说「不走本机代理靠镜像兜底」 | **已接**（镜像回退保留） |
| youtube_explode（5 处） | `fushi/lib/src/media/video/youtube_source_resolver.dart:34,227,477,669,991,1009` | youtube.com / googlevideo.com | 上游 `YoutubeHttpClient` 内部裸 `http.Client()` | **已接**（喂进它的 `http.Client` 形参） |
| YouTube 缩略图 HEAD 探测 | `fushi/lib/src/media/video/youtube_source_resolver.dart:234` | i.ytimg.com | 裸 | **已接** |
| VNDB（galgame 刮削） | `fushi/lib/src/mining/metadata/adapters/vndb_adapter.dart:40` | api.vndb.org | 裸 | **已接** |
| galgame 封面下载 | `fushi/lib/src/mining/galgame_cover_download.dart:101` | vndb / bgm 图床 | 裸 `HttpClient()` | **已接** |
| 阅读器自定义字体下载（12 款） | `fushi/lib/src/pages/implementations/custom_fonts_page.dart:905` | cdn.jsdelivr.net → raw.githubusercontent.com → fonts.google.com 三级回退 | 裸 `Dio(...)` | **已接** |
| 桌面音频剪切 | `fushi/lib/src/utils/misc/desktop_audio_clipper.dart:119` | googlevideo.com | 裸 | **已接** |
| 错误日志上传 | `fushi/lib/src/utils/misc/log_uploader.dart:64` | logs.wrds.xyz | 裸 | **已接** |
| 远端发音源（默认 CF Worker，可自填） | `fushi/lib/src/utils/misc/word_audio_resolver.dart:261` | `fushi-reader.*.workers.dev` 等 | 裸 `Dio(...)` | **已接**（本机源仍直连，闸门保证） |
| 制卡本地/远端音频抓取 | `fushi/lib/src/creator/enhancements/local_audio_enhancement.dart:34` | 依配置 | 裸 | **已接** |
| 番剧订阅后台轮询默认工厂 | `fushi/lib/src/media/torrent/anime_download_subscription.dart:381` | nyaa / torznab | 裸（与前台手动搜索走代理不一致） | **已接** |
| Nyaa client 默认值 | `fushi/lib/src/media/torrent/nyaa_client.dart:406` | nyaa.si | 裸 | **已接** |
| Jimaku 单条对话框回退分支 | `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart:370` | jimaku.cc | 裸 | **已接** |
| **制卡远程音频（AnkiConnect 侧）** | `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:1982` | 任意公网 URL（Forvo / 词典音频源） | 裸 `HttpClient()` | **已接**（包内工厂钩子） |
| **制卡远程音频（AnkiDroid 侧）** | `packages/fushi_anki/lib/src/ankidroid/anki_repository.dart:673` | 同上 | 裸 `HttpClient()` | **已接**（同一钩子） |

#### B. 本轮之前已走代理（不动）

| 链路 | 文件:行 | 目标域 |
|---|---|---|
| 云同步 OAuth + 云盘 API | `fushi/lib/src/sync/sync_http.dart:25` | googleapis / microsoftonline / graph.microsoft / dropboxapi |
| 更新检查 / 更新包下载 | `fushi/lib/src/utils/misc/update_checker_net.dart:338`、`update_checker_release.dart:299,951` | api.github.com + 5 个 gh 反代 |
| 下载发现（AniList / Nyaa / Jimaku / 放送日历） | `fushi/lib/src/media/torrent/download_network_proxy.dart:99` | 同上 |
| 词典包 + index.json（BUG-1493） | `fushi/lib/src/utils/net/dictionary_dio.dart:38` | github / raw.githubusercontent / huggingface |

#### C. **明确不接**——本机 / 局域网 / 用户自建（接了会打断功能）

| 链路 | 文件:行 | 目标 | 理由 |
|---|---|---|---|
| AnkiConnect JSON-RPC | `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart:71-103,246` | `localhost:8765`（可改 LAN） | 制卡全部动作走它；经代理直接失效。它自带 `connectionFactory`，一旦上层给了 proxyHost 会照着代理走 |
| AnkiConnect local-audio 插件发音 | `fushi/lib/src/utils/misc/word_audio_resolver.dart:50` | `localhost:8765/localaudio/get/` | 同上 |
| local-audio-yomichan | `fushi/lib/src/models/preferences_repository.dart:1622` | `localhost:5050` | 本机服务 |
| Yomitan API server（**入站**） | `fushi/lib/src/sync/yomitan_api_server.dart:126` | bind loopback / anyIPv4 | 服务端，不是出站 |
| 浏览器扩展服务端地址 | `fushi/lib/src/pages/implementations/browser_extension_page.dart:89`、`models/app_model.dart:5942` | `127.0.0.1:<port>` | 本机 |
| AnkiMobile 媒体服务器（**入站**） | `fushi/lib/src/anki/ankimobile_repository.dart:481` | bind loopback | 服务端 |
| 桌面 OAuth 回环回调（**入站**） | `fushi/lib/src/sync/desktop_oauth.dart:50`、`google_drive_auth.dart:213`、`dropbox_sync_backend.dart:66`、`onedrive_sync_backend.dart:89` | `127.0.0.1:<port>` / `localhost:9004` | RFC 8252 回环回调；BUG-1348 的原始症状之一就是全局代理吞掉它 |
| texthooker WebSocket | `fushi/lib/src/sync/texthooker_ws_client.dart:59` | `ws://localhost:6677/9001/2333` | 本机 Textractor / LunaTranslator |
| Mihon 桌面 sidecar（控制面 + 封面） | `fushi/lib/src/media/manga/mihon/desktop_mihon_runtime.dart:54,166` | `127.0.0.1:<port>` | 本进程拉起的 sidecar |
| qBittorrent WebUI | `fushi/lib/src/media/torrent/qbittorrent_client.dart:301` | `127.0.0.1:8080`（可 LAN NAS） | 本机 / 内网 |
| Torznab indexer | `fushi/lib/src/media/torrent/torznab_client.dart:411` | 用户自配，多为 loopback/自建 | 源码里另有 loopback 明文放行判据 |
| 互联 POST 传输 | `fushi/lib/src/sync/interconnect_post_transport.dart:29` | 局域网 peer | 内网请求发到公网出口 = 必坏 |
| 互联同步 / 远程库 / 远程视频流 | `fushi/lib/src/sync/interconnect_sync_backend.dart:1480` | 局域网 peer | 同上 |
| 远程 manga-OCR | `fushi/lib/src/sync/interconnect_manga_ocr_client.dart:176` | 局域网另一台机 | 同上 |
| 配对 peer ping / 发现探测 | `fushi/lib/src/sync/pairing/fushi_ping_client.dart:53`、`pairing/discovered_pairing_probe.dart:34` | mDNS 发现的局域网地址 | 同上 |
| 互联 TLS 指纹钉扎 client | `fushi/lib/src/sync/tls/fushi_pinning_http.dart:42` | 局域网 peer 自签证书 | 同上 |
| 远端查词 / 远端发音 keep-alive client | `fushi/lib/src/models/app_model.dart:5824` | 已配对 peer | 同上 |
| 局域网设备发现（mDNS） | `fushi/lib/src/sync/lan_discovery_service.dart:225` | Bonsoir 广播 | 不是 HTTP |
| WebDAV 后端 | `fushi/lib/src/sync/webdav_ops.dart:97` | 用户自填，NAS 是主流 | 内网 |
| SFTP / FTP 后端 | `fushi/lib/src/sync/sftp_sync_backend.dart:446`、`media/source_library/source_file_system.dart:220,269` | 用户自配 | **不是 HTTP**，HTTP 代理无意义 |
| 内置 torrent 引擎 | `packages/fushi_torrent/lib/src/embedded_torrent_engine.dart:137` + `native/fushi_torrent` | BT peer / tracker / DHT | **BT peer 连接不是 HTTP**；Dart 侧只有 FFI 与 `listenInterfaces` 字符串，没有 socket。代理只能设在 libtorrent session 的 `proxy_*` 上，当前 FFI 绑定未导出。**本轮不做** |

#### D. 结构上注入不了代理（记录在案，本轮不动）

| 链路 | 位置 | 为什么 |
|---|---|---|
| `NetworkImage` / `CachedNetworkImageProvider`（8 处） | `video_work_detail_page.dart:177`、`home_video_page.dart:652`、`media_collection_detail_page.dart:495,1813`、`video_discovery_page.dart:971`、`video_discovery_detail_page.dart:762`、`media_source.dart:392`、`mokuro_moe_catalog_view.dart:460` | 走 Flutter 内部 `HttpClient`，没有注入点。要代理只能改成「先下字节再 `MemoryImage`」——那是另一件事 |
| media_kit / libmpv 拉流 | 播放器内部 | Dart 层不经手 |
| `flutter_inappwebview_windows` 的 `getHtml` / favicon / manifest 抓取 | `packages/flutter_inappwebview_windows/lib/src/in_app_webview/in_app_webview_controller.dart:1616,1701,1724` | vendored 上游 fork，且 app 内 WebView 走 `fushi.local` 拦截，实际不出网 |

- **[x] ① 已修复** —
  - `fushi/lib/src/utils/net/app_proxy.dart`：
    - 新增 **`isDirectProxyTarget(String host)`**——本机/局域网直连闸门（`localhost` / `*.localhost` /
      `*.local` / `127/8` / `0.0.0.0` / `10/8` / `172.16-31/12` / `192.168/16` / `169.254/16` /
      `::1` / `::` / `fc00::/7` / `fe80::/10`，含 IPv6 方括号与 zone id 归一、`::ffff:` 映射地址）。
      异步版 `applyAppProxy` 的**两条分支**（手填代理短路 + env/GUI 解析）现在都先过这道闸门。
    - 新增 **`primeAppProxy()`**（缓存平台 GUI 系统代理解析）+ **`applyAppProxySync()`** /
      **`resolveAppProxyDirective(Uri)`**：把异步的那一半搬到进程启动做一次，之后装配纯查表同步。
      这是让 40+ 个「构造函数初始化列表」形态的出站点能一行接上的关键。
    - 抽出 `_hasEnvProxy` / `_directiveFor` / `resolveSystemProxyEnvironment`，同步版与异步版共用
      同一判定，不可能给出不同答案。
  - `fushi/lib/src/utils/net/app_http.dart`（新增）：**单一装配点** `createAppHttpClient()` /
    `createAppHttpIoClient()` / `createAppDio()`，全部同步、可直接写进初始化列表。
  - `packages/fushi_anki/lib/src/anki_remote_media_http.dart`（新增）+ app 侧
    `fushi/lib/src/utils/net/anki_remote_media_http.dart`（新增）：制卡远程媒体的进程级工厂钩子
    （与 BUG-1493 的 `dictionaryDioFactory` 同范式）。**只作用于远程媒体，不碰 AnkiConnect。**
  - `fushi/lib/src/models/app_model.dart:2187,2192`：`primeAppProxy()`（不 await）+
    `installAnkiRemoteMediaHttpClientFactory()` 接线。
  - 上表 A 段共 **34 个出站点、31 个文件**逐点改走装配点。**无代理配置时解析结果就是 `DIRECT`，
    与接线前逐字等价；零新 UI、零新配置项。**
- **[x] ② 已加自动化测试** —
  - `fushi/test/tools/outbound_http_discipline_guard_test.dart`（**新守卫**，11 例）：目录枚举型，
    扫 `fushi/lib` + 6 个 `packages/*/lib`（1136 个 .dart）。裸 `HttpClient(` / `http.Client(` /
    `IOClient(` / `Dio(` 必须要么是装配点自身（9 条）、要么登记在 `kBareOutboundRegistry`（10 条，
    每条写明「为什么走代理会更坏」）。带扫描规模哨兵、陈旧检测、总数常量 `kRegisteredOutboundFileCount`、
    理由非空检查，以及 5 组**合成语料自校验**（四种写法 / `dart format` 折行 / 装配点调用不误判 /
    `yt.YoutubeHttpClient(`·`IOHttpClientAdapter`·`HttpClient.findProxyFromEnvironment(` 不误伤 /
    注释里的名字不算命中）。
  - `fushi/test/utils/net/app_proxy_local_bypass_test.dart`（14 例）：**本机/局域网目标不得被代理**。
    16 个真实本机/内网目标 × 3 种代理配置（手填 / GUI 缓存 / 无配置）恒 `DIRECT`；9 个公网目标必须
    走代理；私网边界（172.15 / 172.32 / 11.x / 192.169 / 169.253 是公网）、`localhost.example.com`
    不误判、IPv6 / zone id / 大小写归一。用 `implements HttpClient` 的捕获式假 client 观测
    `findProxy`（`dart:io` 只有 setter 没有 getter）。
  - **变异实测（三种，全部反向替换还原）**：
    - ① 正向：把 `tmdb_client.dart` 改回裸 `http.Client()` → 守卫红并点名
      `{'fushi/lib/src/media/video/scraper/tmdb_client.dart': Set:['http.Client(']}`。
    - ② 反向：把 `resolveAppProxyDirective` 的闸门短路成 `if (false && ...)` → 行为测试红 3 条
      （「`http://127.0.0.1:8765/` 被塞进了用户手填代理」「`192.168.1.34` 被系统代理吃掉了」
      「装上的就是共享判据」）。
    - ③ 陈旧：把登记项 `interconnect_manga_ocr_client.dart` 改成经装配点 → 「登记清单不得虚挂」红。
  - **扫描器假绿实录（写进守卫注释）**：第一版临时枚举器用「按行砍 `//` + 配对 `/* */`」的朴素剥离，
    在 `app_model.dart` 上从某个字符串字面量里的 `/*` 进入「块注释中」状态，把文件剩余部分整块吞掉，
    于是那条真实的 `http.Client()` **从枚举结果里凭空消失**。守卫最终改用仓库的词法掩码器
    `maskCommentsAndScriptLines`。

- **备注 / 未验证缺口**：
  - **没有真机/真网验证**：「接代理后 OCR 模型 / 字体 / 刮削在代理下确实能下载」没有端到端实测
    （需要一台处于受阻网络、开着 clash 系统代理模式的机器做对照组）。本轮全部结论基于代码结构 +
    `findProxyFromEnvironment` 的实测行为表，运行时正确性由 `isDirectProxyTarget` 的行为单测兜底。
  - **`primeAppProxy()` 不 await**：进程启动到缓存就绪之间的极短窗口里，`applyAppProxySync` 退化成
    `env > DIRECT`（读不到 GUI 系统代理）。这段时间只有启动期后台任务可能出站，且退化结果仍不比
    接线前差，故按 best-effort 处理；用户在设置页改**手填**代理立即生效（`findProxy` 是请求时求值的
    闭包，每次重读 `appUserProxyReader`）。改**系统**代理需要重启 app 或再调一次 `primeAppProxy()`。
  - **`NetworkImage` 那 8 处仍不走代理**（见 D 段）：受阻网络下刮削元数据能拿到、封面图仍可能加载不出。
    要修得把它们换成「下字节 + `MemoryImage`」，是独立的一件事。
  - **内置 torrent 引擎不接**：BT peer 连接不是 HTTP，走 HTTP 代理没有意义；真要做只能给 libtorrent
    session 设 `proxy_*` 并在 FFI 里导出，属另一个任务。
  - 新守卫是**目录枚举型**（`listSync(recursive: true)` 扫 7 棵树），应加入 `docs/agent/fast-workflow.md`
    的「合并后必跑」35 条清单（本轮未改那份文档，留给 integration owner 决定）。
