# 互联共享音乐库与 MV 背景（2026-11-23，已拍板，分期实现中）

起因：PR [#4249](https://github.com/hajisensai/Fushi/pull/4249) 让歌词页 / 全屏歌词动画默认放本机 MV（含蓝光
`BDMV/STREAM` 里的 MV，音乐来源扫完后后台自动匹配，声纹与对齐结果缓存在 v172 表）。用户接着问「能不能在互联
的另一台设备上直接打开 MV」。查下来互联目前**根本不共享音乐库**：`fushi_server` 刻意延后
（[server-parity-gaps.md](../agent/server-parity-gaps.md)「Music libraries: deliberately deferred」），app 当 host
也没有任何音乐路由。所以 MV 是这件事的最后一环，前提是先把音乐库本身接进互联。

§9 的 13 条已于 2026-11-23 全部拍板（拍板台 `design-imusic-q0`..`q12`），结果与落地状态见 §9；规模 L/XL，按 §8 分期出 PR。

必读：[subsystem-map.md](../agent/subsystem-map.md)（引擎纯度、互联选路）、
[2026-11-16-interconnect-source-share.md](2026-11-16-interconnect-source-share.md)（同一套门、能力位、iOS 合规先例）、
[feature-blacklist.md](../agent/feature-blacklist.md)（本设计不碰自动注音、不另立歌词编辑界面）、
[2026-10-23-music-module-design.md](2026-10-23-music-module-design.md) §9「服务器曲库」与 §10 数据模型、
[2026-11-06-music-network-sources-design.md](2026-11-06-music-network-sources-design.md)。

---

## 0. 一句话

**先把互联 host 的「功能接入方式」统一成一个模块层**（路由、能力位、免 Basic 路径、流票、客户端通道各只写一次，§3.5），
音乐是第一个按模块写的功能，不再往 `fushi_sync_server.dart` 的手写分发链和 `InterconnectSyncBackend` 里再加一套。
在此之上，**互联 host 在客户端就是第五种「服务器曲库」**（`MusicServerKind.fushiHost`），走音乐模块已有的
`MusicServerBrowser` 契约、服务器曲库页面和混排开关。歌词与 MV 作为契约上的两个**可选能力接口**挂上去。
曲目身份**直接用 host 的 `track_uid`**。host 侧的读逻辑**先搬进 `packages/fushi_engine`**，app 与
`fushi_server` 用同一个实现。MV 匹配只在 host 跑，客户端只收「绑定 + 一条流」。

## 1. 为什么这样定：避免四处补丁

最省事的写法会在四个地方打补丁。本设计逐条换成结构上的做法：

| 补丁写法 | 后果 | 本设计 |
|---|---|---|
| 照现有每种库的样子：分发链再加一段 `if (reqPath.startsWith('/api/library/music'))`、能力位再手写一个 `is MusicLibraryHost`、免 Basic 表再加一个后缀、`InterconnectSyncBackend` 再加一组 `listRemoteMusic*` | 每加一种互联功能就要同时改 4～5 处互不相干的地方，漏一处就是 404 / 能力位撒谎 / 鉴权漏洞；`InterconnectSyncBackend` 已 4884 行、`fushi_library_host_service.dart` 已 4182 行 | 统一的互联模块层：一个功能 = 一个模块对象，自己声明路由前缀、能力位、免 Basic 的流路径；服务器循环分发、循环拼能力位；客户端统一走 `InterconnectHostChannel`（§3.5） |
| 在 app 里另写一套「远端音乐」页面 / 播放入口 | 与 Subsonic / Jellyfin 服务器曲库两套 UI 长期分叉，每个音乐功能都要做两遍 | host 实现 `MusicServerBrowser`，UI、混排、播放项转换、码率、脱敏全部复用（§5.1） |
| 只在 app 侧写 host 实现，服务端以后再说 | 服务端补齐时要重写一遍，两边行为必然不一致（parity 文档里已有前车之鉴） | 第一期就把扫描栈和 host 读层搬进引擎，app 与服务端构造同一个 `EngineMusicLibraryHost`（§4、§8） |
| 复制一份 `_VideoStreamToken` 给音乐 / MV | 吊销、释放（BUG-4461）、TTL、凭据指纹（BUG-4393）三处修过的坑要再踩一遍 | 统一流票 `LibraryMediaStreams`，视频、音频、MV 共用，盘共享与插件中继后续并入（§3.5、§4.3） |
| `MusicMvBackdropController` 里加 `if (remote)` 分支 | 控制器同时管「去哪找 MV」和「怎么跟音频对齐」，每多一种来源加一个分支 | 控制器只吃解析好的 `MusicMvBackdropSource`，「去哪找」交给按曲目来源选的解析器（§6.3） |

## 2. 现状与缺口

### 2.1 服务端（parity 文档那一节的全部内容）

1. 扫描栈在 app：`fushi/lib/src/media/music/music_library_scanner.dart`、`disc/music_disc_import.dart`、
   `metadata/music_scrape_service.dart`、`metadata/music_video_service.dart`、
   `links/theme_song/theme_song_detector.dart`。
   - 这几个文件都没有 `package:flutter`（PR #4249 版的 `music_video_service.dart` 多了一处
     `package:flutter/foundation.dart show immutable`，搬时改成 `package:meta`）。
   - 挡着搬的是 app 内依赖：`source_library/source_file_system.dart`、`models/preference_keys.dart`、
     `storage/app_paths.dart`、`music_local_playlists.dart`、`acoustid_secret.dart`、
     `music_dlsite_scraper.dart`、`music_remote_media.dart`。
   - 另外 `packages/fushi_engine/pubspec.yaml` 目前不依赖 `fushi_music`。它是纯 `dart:ffi` 包，不违反引擎纯度
     （`fushi/test/build/fushi_engine_purity_guard_test.dart` 只禁 Flutter、插件和 `package:fushi`）。
2. 服务端扫描：`packages/fushi_server/lib/src/library_scanner.dart` 的 `scanAll` 没有 `case 'music'`。
   `kServerLibraryRootKinds` 不含 music。`admin_api.dart` 的 `_purgeRoot` 遇 `SourceLibraryKind.music` 直接抛。
3. 原生库：`native/fushi_music` 不在 `release-server.yml` / `build-multiplatform.yml` 里构建和随包。
4. host 面：没有 `/api/library/music*` 路由、`Remote*` DTO、能力位、`LocalLibraryHostService` 接线、
   app 侧客户端与 UI，也没有操作目录描述。
   - `packages/fushi_engine/lib/sync/local_library_host_service.dart` 及其 8 个 part 文件里没有一处 music。
   - 现有的 `/api/library/localaudio` 是**词典音频库**（`RemoteLocalAudioInfo`，`.fushiaudiolib`），与音乐库
     无关。命名容易混，新路由一律用 `music`。

### 2.2 app 当 host

`app_model.dart:1300` 与 `headless_host.dart:1075` 都 `new LocalLibraryHostService(...)`，所以 app 当 host
同样没有音乐。互联里唯一的音乐功能是插件中继（`interconnect_plugin_relay.dart`），那是代跑第三方插件，
不是曲库共享。

### 2.3 现有互联库的形态，以及音乐为什么不能照抄

- 现有库路由（`fushi_sync_server/library.part.dart`、`video.part.dart`）都是**整份清单**，没有分页、游标或
  `since`。书、有声书、词典是**整包导出再下载**（`_serveAssetPackage`）。
- 视频是唯一按区间串流的：先用 `/streamurl`（Basic）签一张 `_VideoStreamToken`（绑 videoId、签发凭据指纹，
  TTL 6 小时），再用 `/stream?token=` 免 Basic 播，由 `serveFileWithRange` 出 Range / ETag。
- 音乐库动辄几万首。整份清单就是 BUG-1891 的坑，整包下载也不是听歌的用法。所以音乐走
  `MusicServerBrowser` 的「按父级分页、客户端只持当前屏」，播放走流票串流。

### 2.4 MV 现状（PR #4249）

- `music_videos`（`packages/fushi_core/lib/src/database/music_tables.dart:222`）：唯一键
  `(trackUid, kind, ref)`，列有 `offsetMs`（**MV 时间 = 音频时间 + offset**）、`confidence`、`isUserBound`、
  `updatedAt`。没有片段起止列。
  - `kind = local` 时 `ref` 是 host 本机路径，蓝光 MV 也是：对齐后直接存 `.m2ts` 路径，没有播放列表信息。
  - `anime_episode` 的 `ref` 是 bookUid + 集号，经视频库解析成文件。
  - `youtube` 的 `ref` 是 URL / id。
- 自动匹配：`music_video_auto_match.dart` 的 `MusicVideoAutoMatcher` → `ThemeSongDetector.mvAlignment`，流程是
  ffmpeg 解 PCM → `fushi_music` chromaprint → align，再过 `acceptMusicVideoAlignment` 门。v172 缓存表
  `music_video_prints` / `music_video_match_checks` 是设备本地缓存，键为 host 路径。
- `MusicMvBackdropController`（`music_lyrics_mv_backdrop.dart:132`）只认**本机文件路径**：
  `musicMvBackdropSelfSource`（曲目本身是视频）或 `database.listMusicVideos` → `resolveMusicMvBackdropSource`
  → `MusicMvBackdropSource{path, offsetMs}`。用 media_kit `Player` 静音、无音轨播放，每 250 ms 按
  「音频位置 + offset」对齐。
- `music_mv_page.dart` 的卡拉 OK 舞台页在 MV 画面下可选「曲库音轨」：`audio-add` 本地文件，
  `audio-delay = offset − cueStart`；页内 ±100 ms 微调写回绑定。

### 2.5 顺带发现的问题

`sync_tombstone_kind.dart:50` 的注释说 `track_uid`「内容派生、跨设备稳定」。这与实际不符：
`native/fushi_music/src/uid.rs:52` 把**路径原文**算进哈希，同一首歌在两台设备上的 uid 不同。本设计 §3
正是因此才用 host uid。第一期 PR 顺手把注释改对。

## 3. 曲目身份（最关键的一条）

- **wire 上曲目 id = host 的 `track_uid`**。专辑用 `album_uid`，艺人用 `artist_uid`，歌单用 `playlist_uid`。
  这些 uid 在 host 上稳定，换标签不变（uid.rs 的设计目的）。
- 客户端播放身份（`MusicPlayItem.trackUid`）有两种选法，见 **拍板 Q1**：
  - **a. 直接用 host uid**（建议）：
    - 客户端在这些曲目上的歌单条目、播放记录、断点、手动歌词、MV 微调，和 host 自己的数据是**同一个键**，
      「音乐」备份类别的合并（`BackupMergeEngine._mergeMusicUserData`，按 `track_uid` LWW / 并集）天然对上；
    - 客户端解析某个 uid 时，本机 `music_tracks` 有就放本机文件，否则查 `music_remote_tracks` 新增的
      `kind = fushi_host` 行，经互联播放。
  - **b. 像 Subsonic 一样用 `musicServerTrackUid(serverId, id)`**（`srv` 命名空间）：实现最省；代价是客户端
    数据和 host 数据永远对不上，同一首歌在两台设备是两首。
- 撞 uid 的情况：只有两台设备在**同一绝对路径**放了**同一段音频**才会撞，此时把它们当成同一首正是想要的
  结果。本机文件优先。

## 3.5 统一的互联模块层（先于音乐落地）

### 3.5.1 现状：同一件事散在五处，每个功能各写一遍

以「给互联加一类功能」为例，今天要手改：

1. **路由分发**：`fushi_sync_server.dart:1551-1609` 是一条手写的 `if (reqPath == … || reqPath.startsWith(…))`
   链，每种库一段（词典、书、漫画、词典音频、有声书、视频元数据、视频、盘共享、聚合、活动、合集、标签、作品图谱…）。
2. **能力位**：`fushi_sync_server/pairing.part.dart:588` 起逐项手写。
   - 库类每位一个 `_libraryService is XHost`；
   - 非库类模块（`_mangaOcrJobs`、`_hostJobs`、`_downloads`、`_torrentEngine`、`_subscriptions`、`_assistant`）
     各有一个 `capability()` 方法，但没有共同接口，各占一个字段、一行 `if (x != null) 'k': x`。
3. **免 Basic 路径**：`auth.part.dart:203` 的 `_kPublicRoutes`、`_kVideoStreamSuffixes`（`:257`），每种流各加
   一条判断。
4. **流票**：视频一套（`_VideoStreamToken`）、盘共享一套（会话 token）、插件中继一套（流票），三套各管签发、
   吊销、释放、TTL。
5. **客户端**：库类方法堆在 `InterconnectSyncBackend`（4884 行，每种库一组 `listRemoteX` / `getRemoteX` /
   `fetchRemoteX`）。较新的功能（任务、下载、助手、订阅、BT 引擎、插件中继）则已经统一走
   `InterconnectHostChannel`（`fushi/lib/src/sync/interconnect_host_channel.dart`：选路、P2P 回落、证书钉扎只写
   一次）。两条客户端通路并存。

漏改任何一处都是真 bug：路由在、能力位没加，客户端就永远不用；能力位在、免 Basic 漏加，播放器带不了头就是 401；
流票各写一套，BUG-4393（吊销后票仍有效）和 BUG-4461（票不释放）都只修在视频那一套上。

### 3.5.2 做法：一个功能 = 一个模块对象

引擎新增接口（`packages/fushi_engine/lib/sync/interconnect_module.dart`）：

```dart
abstract interface class InterconnectHostModule {
  /// `/api/capabilities` 里的键；能力值由 [capability] 给，null = 本 host 此刻不提供（键不出现）。
  String get capabilityKey;
  Future<Map<String, Object?>?> capability();

  /// 本模块拥有的路径前缀（如 `/api/library/music`）。服务器按最长前缀分发，前缀冲突在构造时就报错。
  List<String> get routePrefixes;
  Future<shelf.Response> handle(InterconnectRequest request);

  /// 本模块签发的流用哪种票（免 Basic）；没有流的模块为空。
  List<LibraryMediaStreamKind> get streamKinds;
}
```

- `FushiSyncServer` 持有一个 `List<InterconnectHostModule>`：分发、能力位、免 Basic 判定都是对这张表的循环。
  新功能只写模块、在 app 与服务端的装配点各注册一行，不再动服务器本体。
- `InterconnectRequest` 把已鉴权的 peer 身份、凭据指纹、规范化路径、`hostId` 一次算好交给模块。各模块不再
  自己调 `_requestCredentialFingerprint` 之类的私有函数。
- **流票只有一套**：`LibraryMediaStreams`（引擎），统一负责签发、按凭据指纹吊销（BUG-4393）、`ticket` 释放
  （BUG-4461）、TTL、`serveFileWithRange`。模块只提供「id → 文件」的解析器。统一的流路径是
  `/api/library/media/stream?token=`。视频的老路径 `/api/library/videos/<id>/stream`、`/streamurl`、
  `/streamrelease` 保留为别名（旧客户端），内部同一套。盘共享与插件中继的票后续也并入（见 Q0）。
- **客户端只有一条通路**：新模块的客户端一律建在 `InterconnectHostChannel` 上，加一个通用帮手层
  `InterconnectLibraryClient`，只写一次：
  - 分页列表 `page<T>(path, decode, offset, limit)`；
  - 取流 `acquireStream(kind, id)` → `{uri, release}`；
  - 封面 `cover(path)`（钉扎加载器）。
  音乐、以后的新库都只写「路径 + DTO 解码」。

### 3.5.3 范围

- 第 1 期（§8）把模块层、`LibraryMediaStreams` 立起来，并把**已经接近模块形态**的六个功能（漫画 OCR 任务、
  通用任务、下载、BT 引擎、订阅、助手）迁进去：它们已各有 `capability()` 与独立路由，迁移基本是机械的。
  视频流票迁到 `LibraryMediaStreams`（wire 不变）。音乐从第 2 期起就是模块。
- 书 / 有声书 / 视频 / 漫画 / 词典等**老库类**的路由与 `InterconnectSyncBackend` 里的方法要不要一起迁、何时迁，
  见 **Q0**。不在本期迁的部分登记成待办，不只写在汇报里。

## 4. host 侧（引擎）

### 4.1 接口与实现

- 引擎新增 `MusicLibraryHostModule implements InterconnectHostModule`（§3.5），数据由
  `EngineMusicLibraryHost`（`packages/fushi_engine/lib/media/music/host/`）提供，只依赖 `fushi_core` 数据库与
  `fushi_music`。**不**往 `LocalLibraryHostService` / `fushi_library_host_service.dart` 里加 part 或 `*Host`
  接口，也不在服务器分发链里加分支。
- app（`app_model.dart`）与服务端（`headless_host.dart`）只负责注入：
  - 数据库与路径；
  - 「视频库 bookUid → 文件」解析器，供 `anime_episode` 类 MV 用。视频库 host 已有 `resolveVideoFile`，直接复用；
  - 网络来源字节读取器（app 有，服务端第一版为 null，见 Q4）。
- 搬进引擎的**读层**（host 回答请求要用的）：
  - 歌词的本地层解析：用户指定、sidecar、内嵌、ASR，以及库里已缓存的 provider 行。`MusicLyricsService`
    拆成两层，引擎层只做不联网的解析，app 层在外面叠在线 provider 与插件；
  - MV 绑定解析：`resolveMusicVideoLocalFile` 及 `anime_episode` 引用解析；
  - CUE 起止、编码属性；
  - 封面路径选取：`cover_path` / `cover_track_uid` 内嵌封面抽取。
- 搬进引擎的**写层**（扫描、刮削、MV 自动匹配）：服务端要自己扫描时才需要，属第三期（§8）。
  - 第一期不是硬依赖，但第一期就要把读层和写层的边界划好；
  - app 侧的扫描 / 匹配入口改成调用引擎实现，不留 app 版副本。

### 4.2 路由（模块 `routePrefixes = ['/api/library/music']`，全部 Basic + 已配对 peer）

形状对齐 `MusicServerBrowser`，列表一律分页（`offset` / `limit`，上限 `kMusicServerPageSize = 100`）：

| 路由 | 返回 |
|---|---|
| `GET /api/library/music/albums?offset&limit&sort=name\|newest\|artist\|year` | `MusicServerPage<RemoteMusicAlbum>` |
| `GET /api/library/music/albums/<albumUid>/tracks` | 该专辑曲目（按碟号 / 轨号） |
| `GET /api/library/music/artists`、`/artists/<artistUid>/albums` | 艺人、艺人的专辑 |
| `GET /api/library/music/playlists?offset&limit`、`/playlists/<uid>/tracks` | host 的本地歌单（智能歌单在 host 求值后给结果） |
| `GET /api/library/music/search?q&limit` | 专辑 / 艺人 / 曲目 / 歌单 |
| `GET /api/library/music/tracks/<uid>` | 单曲详情（客户端解析歌单 / 历史里的 uid 时用） |
| `GET /api/library/music/covers/<ref>?size` | 封面（host 侧缩放；与书 / 视频封面同一个 `serveFileWithRange`） |
| `GET /api/library/music/tracks/<uid>/lyrics` | §4.4 |
| `GET /api/library/music/tracks/<uid>/videos` | §6.1 |
| `POST /api/library/media/streamurl {kind: musicTrack\|musicVideo, id}` | 统一流票（`LibraryMediaStreams`），见 §4.3 |

- DTO `RemoteMusicAlbum / RemoteMusicTrack / RemoteMusicArtist / RemoteMusicPlaylist` 字段与
  `MusicServerAlbum / Track / Artist / Playlist` 一一对应，另加 `trackUid`、`cueStartMs/cueEndMs`、
  `isVideo`（曲目本身是视频容器）、`peerPlayable`、`hasVideos`、`updatedAt`。
  - 放在新文件 `packages/fushi_engine/lib/sync/remote_music_dto.dart`。`fushi_library_host_service.dart` 已近
    4000 行，不再往里堆。
- **曲库里只出 host 本机能读到字节的曲目**：
  - `music_remote_tracks` 的 YouTube / 插件 / 服务器曲目**不出**。这类曲目在客户端各有自己的来源与合规门
    （§7），不该借互联绕开；
  - 歌单里引用到它们的条目跳过；
  - 不出的曲目照视频的 `peerPlayable` 惯例标出原因，不静默消失。
- 光盘标题（`isMusicDiscTitlePath`）与 CDDA 第一期 `peerPlayable = false`，见 Q5。

### 4.3 流票：用 §3.5 的统一流票，不复制

- 音乐不自带流票，用 `LibraryMediaStreams`：模块只注册 `musicTrack` / `musicVideo` 两种 kind 的「id → 文件」解析器。
- 取流：`POST /api/library/media/streamurl` 回 `{url, ticket}`，`url` 是 `/api/library/media/stream?token=`，
  免 Basic，`serveFileWithRange` 出 Range / ETag / If-Range。
  - 吊销、释放、TTL 与视频完全同一套；
  - 客户端换歌 / 关页时由 `InterconnectLibraryClient.acquireStream` 返回的 `release` 释放。
- 为什么用票、不让 mpv 带 Basic 头：
  - 与视频、插件中继一致；
  - 交叉淡入的两个 mpv 后端、MV 的第二个 `Player` 都只需一条裸 URL；
  - 凭据不进 mpv 的报错文本（音乐后端已有对流地址的脱敏，票作废后泄露的 URL 也无用）。
- 原样直出，**host 不转码**（音乐方案的 bit-perfect 前提）。码率上限是否请 host 转码见 Q6。

### 4.4 歌词

- `GET …/tracks/<uid>/lyrics` 在 host 上跑**引擎层**解析（不联网），回
  `{source, format, raw, offsetMs, timingQuality, isUserEdited, updatedAt}`。
  - 时间轴缓存不传，客户端用自己的 `fushi_music` 现解析；
  - 没有本地层结果时回 204。
- 客户端 `MusicLyricsService.resolve` 的优先级里，「本机用户指定」之后新增一层 **`host`**：
  - 先用 host 给的（sidecar / 内嵌 / host 上的手动指定都在 host 那台机器上）；
  - 再落到客户端自己的在线 provider 与歌词插件（受客户端自己的合规门约束）。
  - `MusicLyricsTrackRef` 加一个来源描述，取代现在靠路径带不带 `scheme://` 推断的 `isLocalFile`。
- 客户端上改歌词来源、调整首偏移：写回 host 还是只留本机，见 Q3。

## 5. 客户端（app）

### 5.1 接入服务器曲库

- `MusicServerKind` 加 `fushiHost('fushi_host')`（持久化值新增）。
- 新类 `InterconnectMusicBrowser implements MusicServerBrowser, MusicServerLyricsSource, MusicServerVideoSource`
  （后两个是新的可选接口，形态同已有的 `MusicServerPlaylistEditing`）。
  - 传输走 `InterconnectHostChannel` + §3.5 的 `InterconnectLibraryClient`，与插件中继、任务、下载同一条通路；
    **不**往 `InterconnectSyncBackend` 里加方法；
  - `serverId = hostId`，同一台 host 的多条地址归一，换线路不变身份。
- `loadMusicServerBrowsers` 为每台**已配对且能力位为真**的 host 出一个 browser。服务器页、
  「显示在曲库里」混排（`music_server_library_mix`）、`musicServerPlayItem` 全部原样复用。
- 两处要改的：
  - `musicServerPlayItem` 现在固定用 `musicServerTrackUid`。改成由 browser 提供 `playbackUid(track)`：
    Subsonic / Jellyfin 返回原来的 `srv…`，`fushiHost` 按 Q1 决定。
  - `MusicServerBrowser.streamFor` 是同步的，而互联取流要先签票（异步）。播放器已有「起播那一刻再取流」的
    路径（插件、YouTube、网络来源都是）。所以 `fushiHost` 的播放项路径写成
    `fushi-host-music://<hostId>/<trackUid>`，在 `mpv_music_output_backend.dart` 的起播解析里与插件同级处理，
    沿用「先停旧曲再取、下一首异步补排、403/410 原位重取」。
- 封面用已有的 `RemoteCoverImage`（钉扎加载器）。
- 客户端本机曲库里的远端曲目：沿用 `music_remote_tracks`，新增 `kind = fushi_host`（`source_key = hostId`、
  `item_id = trackUid`）。加入歌单、播放历史、断点都按 Q1 的 uid 落库。

### 5.2 哪些功能对远端曲目不可用

照网络来源的先例（`isMusicRemoteSourceTrack`），对远端曲目跳过：

- 响度测量；
- AcoustID 声纹；
- 标签回写；
- 「导出 TTML 到文件旁边」；
- MV 自动匹配 / 手动重新匹配（§6.4）。

判据集中到一个函数（`musicTrackLocality(item)` → `local / networkSource / interconnectHost / …`），不再各处推断路径。

## 6. MV

### 6.1 host 下发绑定

- `GET …/tracks/<uid>/videos` 回 host 上**解析得到文件**的绑定：
  `[{videoId, kind, offsetMs, confidence, isUserBound, durationMs, updatedAt}]`。
  - `videoId` 是 `music_videos.id`（host 本机自增，只在这台 host 内有意义），流票按它签。
  - `local`（含蓝光 `.m2ts`）与 `anime_episode` 由 host 解析成文件。解析不到的（文件不在、光盘没插）不出。
  - `offsetMs` 语义不变：**MV 时间 = 音频时间 + offset**，对 host 曲目的音频时间轴而言。客户端流的就是同一个
    文件，所以偏移直接可用。CUE 分轨曲目的 `startMs` 偏移也照本机一样处理。
  - `youtube` 类绑定是否下发，见 Q7。
- 曲目本身就是 MV 视频（`isVideo = true`）时没有绑定行，客户端直接用曲目自己的流当画面源。
- 不另开清单接口：曲目 DTO 的 `hasVideos` 告诉客户端值不值得发这个请求。

### 6.2 区间串流

- MV 文件与音频**同一套**认证与 Range：`POST /api/library/media/streamurl {kind: musicVideo, id: videoId}` →
  统一流票 → `serveFileWithRange`。
  - 蓝光 `.m2ts` 就是普通文件，不需要盘共享会话（`disc_share_routes.dart` 那套是给带菜单的整盘用的）。
  - 6 GB 的 m2ts 也只按 mpv 的 Range 读取实际播到的部分。
- 画面在客户端解码。host 不转码、不抽帧，host 侧零解码开销。

### 6.3 客户端歌词页背景

`MusicMvBackdropController` 改成**只管播放与对齐**：

```dart
typedef MusicMvSourceResolver =
    Future<MusicMvBackdropSource?> Function(MusicPlayItem item);

class MusicMvBackdropSource {
  final Media media;          // 本机：文件路径；远端：带流票的 URL
  final int offsetMs;
  final Future<void> Function()? release; // 远端：释放流票
}
```

- 解析器按曲目来源选，与 §5.2 用同一个判据：本机走现有的 `musicMvBackdropSelfSource` +
  `listMusicVideos`，`fushiHost` 走 `MusicServerVideoSource`，其他服务器返回 null。控制器里没有任何来源分支。
- 换曲、关页、控制器 dispose 时调 `release`。
- 远端画面起播有延迟，对齐逻辑不变（`planMusicMvBackdropSync` 的 250 ms 节拍与容差照旧）。
  打开期间画面不显示，不阻塞音频。
- 曲目本身是视频时，音频（主播放器）和画面（背景 `Player`）各连一次 host、读同一个文件，带宽是两份，见 Q8。
- 卡拉 OK 舞台页（`music_mv_page.dart`）：
  - 画面同样走解析器；
  - 「曲库音轨」的 `audio-add` 改为加音频流 URL（同一张票的音频那条）；
  - 页内 ±100 ms 微调写回到哪里见 Q3。

### 6.4 匹配只在 host 跑

- 自动匹配（声纹、对齐）只在 host 上、对 host 本机文件跑。v172 缓存表留在 host，键是 host 路径，不出境。
- 客户端**绝不**为远端曲目或远端 MV 解码、算声纹。远端曲目上隐藏「重新匹配 / 手动绑定」入口。
  是否加「请 host 重新匹配」的远程指令见 Q9。
- 服务端自己扫描音乐后也跑同一个 `MusicVideoAutoMatcher`（第三期搬进引擎后两边共用），需要 ffmpeg 与
  `fushi_music`（§8 第三期）。

## 7. 能力位与兼容

- 能力位由模块自己给（`capabilityKey = 'music'`，顶层键，与 `jobs` / `downloads` 同一级），由服务器的模块循环
  拼进 `/api/capabilities`。不在 `liveLibrary` 块里手写。值是对象而不是布尔，以后加能力不用新键：

  ```json
  "music": {"v": 1, "lyrics": true, "videos": true, "writeback": []}
  ```

  - `writeback` 列出 host 接受的回写种类（Q3 拍成回写后才有内容）。
- 旧 host（没有 `music`）：客户端不为它出 browser，服务器页里没有这台。
- 旧客户端：根本不调这些路由。
- 新 host 新客户端、但 host 曲库为空：browser 照出，空页面提示「这台设备还没有音乐来源」。
- 统一流票不改任何现有 wire（视频老路径保留为别名），旧客户端播视频不受影响。模块层迁移同样不改 wire：
  路径、能力键名、JSON 形状都原样保留，只是由谁分发、谁拼装换了。
- 与已有互联门的关系：与其他库路由同级，任何**已配对** peer 都能读，不需要「我的设备」标记。
  - 「我的设备」门（来源共享 §2）只管凭据与第三方代码；音乐库是 host 主人自己的文件，与视频库、书库同一级。
  - 要不要给音乐单独加 host 开关，见 Q2。

### 7.1 iOS 商店合规

- 判据只在 `fushi/lib/src/models/store_compliance.dart` 写一次。
  - 浏览、串流、MV 背景都是**用户自己另一台设备上自有文件**，与 `userConfiguredServersAvailableOn`
    （用户自己的服务器，恒 true）同一性质。
  - 建议新增 `interconnectMusicLibraryAvailableOn({required bool isIOS}) => true` 并在
    `ios_store_compliance_guard_test.dart` 钉住，不复用其他判据，免得以后收回某一项时连带。是否需要单独的
    判据见 Q10。
- 不能借互联绕开的：
  - `onlineMusicSource`（插件 / YouTube）照旧只经插件中继走自己的门；
  - host 曲库响应里不含 YouTube / 插件曲目（§4.2）；
  - YouTube 类 MV 绑定是否下发见 Q7，iOS 客户端无论如何都不显示。
- 与黑名单无冲突：不涉及自动注音，也不新增歌词编辑界面，客户端改歌词仍走通用字幕工作台。

## 8. 分期

每期一个 PR，各自可独立验收。顺序按「先把共用的放进引擎」排，是否这样排见 Q11。

| 期 | 内容 | 验收 |
|---|---|---|
| **0 互联模块层** | `InterconnectHostModule` + 模块表分发 / 能力位 / 免 Basic；`LibraryMediaStreams`（视频流票迁入，wire 不变）；六个已近模块形态的功能（漫画 OCR 任务、任务、下载、BT 引擎、订阅、助手）迁入；客户端 `InterconnectLibraryClient`；按 Q0 登记老库类的迁移待办 | 新守卫：服务器本体里不再出现 `/api/library/…` 以外的手写前缀分支，模块前缀冲突构造即报错；能力 JSON 迁移前后逐字节相同（快照测试）；视频远端播放、流票吊销 / 释放回归绿 |
| **1 引擎读层** | `fushi_music` 进引擎依赖；歌词本地层、MV 引用解析、封面选取搬进引擎，app 改调引擎、删 app 版；修 §2.5 的注释 | 引擎纯度守卫绿；歌词 / MV 解析单测从 app 挪到引擎后照样绿 |
| **2 音乐模块 + 客户端（app 当 host）** | `MusicLibraryHostModule` / `EngineMusicLibraryHost`、路由与 DTO、能力位；`InterconnectMusicBrowser`、`fushiHost` 播放解析、`music_remote_tracks` 新 kind；MV 解析器重构 + 远端解析器；卡拉 OK 页接远端；合规判据 + 守卫 | 引擎路由测试（分页、流票吊销 / 释放、Range、`peerPlayable`、YouTube / 插件曲目不出）；客户端假 host 测试；两台真机：远端曲目播放 + 歌词页 MV 背景对齐（蓝光 m2ts 一例） |
| **3 服务端扫描与随包** | 扫描 / 刮削 / MV 自动匹配写层搬进引擎；`scanAll` 加 music + prune（走音乐扫描器的软删）、`kServerLibraryRootKinds` 加 music、admin purge；`release-server.yml` / `build-multiplatform.yml` 构建随包 `native/fushi_music`（照 `fushi_fsrs`：Rust 缓存、Linux x64、`bin/../lib/` 查找、构建失败即失败）；服务端操作目录 / WebUI 允许 music 根 | 服务端集成测试扫一个带 CUE + 蓝光 MV 的夹具目录，客户端经服务端播放并出 MV 背景；`server-parity-gaps.md` 删掉音乐那一节 |
| 4（均已拍「做」） | Q4 / Q5 / Q6 / Q12 已并入本 PR；Q9 远程重新匹配（BUG-5306）待 #4249；Q3 回写已并入第 2 期 | 各自 |

操作目录：第 2、3 期若新增 `ctl_<域>_routes.dart` 路由（例如服务端 `/api/admin/libraries` 放开 music、
app 侧列出远端曲库），同步写 `op_descriptions_<域>.dart`。本设计不为 AI 新增浏览远端音乐的写操作。

## 9. 拍板结果（2026-11-23）与落地状态

按钮之外以留言为准（Q3 / Q4 / Q8 留言「根本性做完」）。「已做」指分支 `claude/imusic-impl` 的 PR；未做的都登记成
`docs/bugs/` 待办，不留口头尾巴。

| 题 | 拍板 | 落地 |
|---|---|---|
| **Q0** 模块层范围 | a：立模块层 + 统一流票，迁入六个近模块功能，老库类之后逐类迁、登记待办 | 已做：`interconnect_module.dart`、`library_media_streams.dart`，六个功能迁入，能力 JSON 逐字节快照、守卫；老库类迁移 → BUG-5298 |
| **Q1** 播放身份 | a：直接用 host `track_uid` | 已做：`musicServerPlaybackUid` / `musicServerPlaybackAlbumUid`，`music_remote_tracks` 新 kind `fushi_host`（uid = host uid），歌词偏移 / 歌单 / 播放记录与 host 同键 |
| **Q2** 单独开关 | 不加：与视频库 / 书库同级，跟互联总开关走 | 已做：`MusicLibraryHostModule` 无独立开关，app 与服务端同装 |
| **Q3** 写回 host | 你定 + 「根本性做完，照合集」→ c：全部写回 | 已做：歌词整首偏移（LWW `updatedAt`）、换歌词来源（手动指定）、MV 偏移（LWW）、host 歌单编辑（`MusicServerPlaylistEditing`；智能歌单 409）；歌词服务 ⓪ 层以 host 那份为准并写回 |
| **Q4** 网络来源曲目中继 | 做 | 已做：host 用自己的来源解析器代读、Range 透传（`LibraryMediaUpstream` + `library_media_relay.dart`），凭据不出 host（BUG-5303 已修） |
| **Q5** 光盘标题 / CDDA | 做 | 已做：`MusicStreamMaterializer` 按章节 / 盘时间轴截成 FLAC 缓存文件（CDDA 限 Windows host），签票回 `segmentApplied`（BUG-5304 已修） |
| **Q6** host 转码 | 做 | 已做：签票带 `maxBitrateKbps`，源码率高于上限时整首转 AAC 缓存文件（可 seek）；未用视频 HLS 分段方案，理由见 BUG-5305（已修） |
| **Q7** 下发 YouTube MV 绑定 | 做 | host 侧已做（`RemoteMusicVideo.youtubeRef`）；客户端消费随 MV 背景 → BUG-5302 |
| **Q8** MV 曲目两条连接 | 你定 + 根本性做完 → a：接受两条，与本机实现一致 | 随客户端 MV 背景落地 → BUG-5302 |
| **Q9** 远程重新匹配 / 手动绑定 | 做 | 未做：匹配器在未合并的 #4249 → BUG-5306 |
| **Q10** iOS 合规单列判据 | 做 | 已做：`store_compliance.dart` 的 `interconnectMusicLibraryAvailableOn`（恒 true），`music_servers.dart` / `music_remote_tracks.dart` 只问它，守卫钉住 |
| **Q11** 分期顺序 | a：先模块层与引擎 | 已按 a：第 0 期 → 第 1 期（部分）→ 第 2 期；第 1 期余项 → BUG-5300，第 3 期 → BUG-5301 |
| **Q12** 下载到本机 | 做 | 已做：复用插件下载管线，`forDownload` 签票（原样 + 整首），host 歌词写 sidecar，导入后 host uid 记别名并改指引用（BUG-5307 已修） |

### 9.1 实现与原设计的出入

- **播放 / 封面占位**写成 `fushi-host-music:///<serverId>/<trackUid>` 与 `fushi-host-music-cover:///<serverId>/<ref>`
  （两段都在路径里、authority 留空）：放进 URI host 会被 `Uri.parse` 小写化，配对身份 / uid 要原样保住。
  `serverId` 是配对身份 `InterconnectHostRef.key`（换 IP 不变）。
- **CUE 虚拟曲目**：服务器曲目模型没有起止，客户端起播签票时并发取一次 `GET tracks/<uid>`，用 host 曲目行的
  `cueStartMs` / `cueEndMs` 拼 EDL 段；播放项自带的起止优先。
- **流票**：客户端只留最近 3 张曲目票（当前 + 预载 + 余量），更早的主动 `streamrelease`；host 侧 6 小时 TTL 与
  128 张上限兜底。
- **本机放不了的曲目**：只剩这台 host 确实给不出字节的（无头服务端没有网络来源解析器、非 Windows host 的 CDDA），不列出，与服务器页一致。曲目本身是 MV 视频的照常列（Q8 a）。
- **统一流票的解析器**从「id → 文件」改成「请求 → 字节来源」（`LibraryMediaFile` / `LibraryMediaUpstream`），签票可带种类专属 `options`（音乐：`maxBitrateKbps`、`segment`），解析器回的说明并进签票响应。
