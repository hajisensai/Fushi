# Apple Music 官方集成（MusicKit 播放后端）

状态（2026-11-01）：**P1 基础设施已合入**（能力标志 + `MusicRoutingBackend`，路由表为空、行为不变；签发端 Worker 见 §3.6）；**P1b 已实现**（`AppleMusicTokenSource` + catalog 来源，见 §6）；其余阶段（P0 spike 起，§6）**待所有者拍板**（§9），拍板前不动 P1 / P1b 以外的代码。

## 0. 一句话

经 Apple 官方 MusicKit 接入 Apple Music：曲库浏览 + 整曲播放，DRM 全程由 Apple 授权的播放器
（系统 MusicKit / 浏览器 CDM）处理，Fushi 只发控制命令、收播放进度；歌词、查词、学习统计照常
走现有链路。它是**本体内置的官方集成**（与 Jellyfin / Subsonic 同类），不是在线音源插件。

## 1. 为什么不是插件

[音乐在线音源插件](2026-10-28-music-plugins.md) 的契约是「插件给 URL → mpv 播」，§1 明确不做
DRM 解密；Apple Music 整曲是 FairPlay（Apple 平台）/ Widevine（Chromium、Android）加密流，
mpv 拿不到明文，插件路线最多到 30 秒试听。合规播放只能让 Apple 授权的播放器解密，
因此必须由本体提供新的播放后端。另外：

- iOS 不带插件宿主（`StoreRestrictedCapability.onlineMusicSource`），而原生 MusicKit 是
  App Store 认可用法，**不进受限能力**，iOS 也提供。
- 原生 MusicKit 的授权绑 App ID（Bundle ID），本质是 app 自身能力，第三方插件无法持有。

## 2. 平台矩阵（2026-10-31 调研，标 ⚠ 的须 spike 实测）

| 平台 | 方案 | 整曲播放 | 开发者 token | 备注 |
|---|---|---|---|---|
| iOS ≥15.1 | Swift MusicKit `ApplicationMusicPlayer` + `MusicCatalog*Request` | ✅ | App ID 勾 MusicKit 服务后**自动生成** | 需 `NSAppleMusicUsageDescription` |
| macOS ≥14（本仓最低 13.4） | 同上，`#available(macOS 14)` 守卫，13.x 不提供 | ⚠ | 同上 | 论坛报：原生 target 偶有不工作（Catalyst 正常）、AirPlay 路由无效、无应用级音量、26.3 早期构建播放失效 |
| Windows | 隐藏 WebView2 跑 MusicKit JS v3，JS 桥控制 | ⚠ | Worker 代签（§3.6） | WebView2 走 Edge 运行时，Widevine 据称开箱可用但无官方文档；论坛有 Windows Chrome/Edge 上 `authorize()` 报 Unauthorized 的未解帖；页面必须从 https 源加载 |
| Android | 隐藏 Android WebView 跑 MusicKit JS | ⚠ | 同 Windows | 官方 MusicKit for Android SDK 多年未更新、AAR 专有不可再分发，**不采用** |
| Linux | 只浏览 + 30 s 试听（catalog REST + 预览 m4a 走 mpv） | ❌ | Worker 代签 | WPE WebKit 无 Widevine，也无官方 Apple Music app |

MusicKit JS 经网页播放上限 256 kbps AAC（原生 MusicKit 由系统决定，可能更高，含无损与否待测）。

## 3. 架构

### 3.1 一个桥，两种实现

```
AppleMusicBridge (Dart 接口：授权 / 订阅状态 / 播放控制 / 事件流)
 ├─ AppleMusicNativeBridge   method/event channel → Swift MusicKit（iOS、macOS 14+）
 └─ AppleMusicWebBridge      隐藏 InAppWebView 加载 https://<fushi 域名>/musickit/ → MusicKit JS
```

桥**只管授权（含 Music-User-Token）、订阅状态与播放**。catalog 浏览不经桥：Dart 侧
`AppleMusicTokenSource` 从签发端取 developer token、直接调 `api.music.apple.com`（以 §3.6 为准）。

### 3.2 来源：`MusicServerBrowser` 的 Apple Music 实现

- 新增 `kind = appleMusic` 的 `MusicServerBrowser`（契约
  `packages/fushi_engine/lib/media/music/server/music_server.dart:194`），复用服务器曲库那套浏览页面
  （`music_server_pages.dart`），在 `music_servers.dart:24` 的分发处装配。
- 播放项路径 `fushi-apple-music://song/<catalogId>`（仿 `fushi-music-plugin://`），`trackUid` 同法派生。
  `streamFor` 不适用（没有 URL），由播放后端按路径识别。
- catalog 自带 ISRC：歌词检索（LRCLIB 等现有 provider）优先按 ISRC / 时长匹配。

### 3.3 播放：路由后端 + MusicKit 后端

现状：`MusicPlayerEngine` 只有一个 `backendFactory`（`app_model.dart:1750`），实现只有 mpv
（外包 `MusicCrossfadeBackend`），**没有按曲目切后端的机制，也没有能力标志**。

- 新增 `MusicRoutingBackend implements MusicOutputBackend`：按 `MusicPlayItem.path` 的 scheme 把
  `openPair / replaceNext` 分给 mpv 链或 `MusicKitOutputBackend`，对引擎仍表现为单个后端。
  - 当前曲与下一首同属一个后端：原样转发（mpv 照旧无缝 / 交叉淡入）。
  - 跨后端：当前后端只收到 `current`（`next = null`），收到 `Completed` 后由路由层在另一后端
    `openPair(next, …, play: true)` 并补发 `Advanced(next.trackUid)`。跨后端**不保证无缝**。
  - 事件只转发「当前活动后端」的；切换时先 `stop` 旧后端。
- `MusicKitOutputBackend`：`openPair` → 桥的 `setQueue([current])` + `play`；`Position` 由桥的进度事件
  （原生 ~250 ms 轮询 `playbackTime`，网页监听 `playbackTimeDidChange`）喂出，歌词时钟已有外推
  （`music_lyrics_clock.dart` 的 `extrapolateMusicPosition`），不要求高频。
  只给 MusicKit 单曲队列，Fushi 队列仍是唯一真相，避免两套队列分叉。
- 能力标志（P1 已落地）：`MusicBackendCapabilities{signalPath, abLoop}` 由路由**静态声明**
  （`MusicBackendRoute.capabilities`），引擎经 `capabilitiesOf` 按**当前曲目**给出
  `MusicPlayerEngine.capabilities`；歌词页 A-B 循环按钮、信号路径入口（歌词页菜单、播放条菜单）
  按它隐藏，引擎侧 `setAbLoop` / `readSignalPath` 同样拒绝。不进 `MusicOutputBackend` 接口（免得
  每个测试替身都要实现）。均衡器 / 交叉淡入 / 独占 / 设备 / DSD 是全局设置、只作用于默认链路，
  不按曲目置灰。

### 3.4 系统 Now Playing / 媒体键（⚠ 冲突点）

现状：`audio_service`（`FushiAudioHandler`）独占系统媒体会话，`music_session.dart:289` 推元数据。

- iOS / macOS：`ApplicationMusicPlayer` 自己写 `MPNowPlayingInfoCenter` 并处理远程命令，与
  `audio_service` 撞同一个系统条目。方案：播放 Apple Music 曲目期间音乐会话**让出**
  （`MediaSessionOwner.none`），由 MusicKit 接管；因 MusicKit 队列只有单曲，系统「下一首」需验证
  能否回到 Fushi（spike 项；不行则保留 audio_service 并验证谁覆盖谁）。
- Windows：WebView2 内 MusicKit JS 会设 `navigator.mediaSession`，Chromium 可能向 SMTC 注册第二个
  会话；spike 验证并在页面里清空 mediaSession handler / 关闭 WebView2 的媒体会话。

### 3.5 制卡与学习

- 歌词点词查词、整句制卡：照常（歌词来自现有 provider）。
- **卡片音频：不提供**。拿不到 PCM，录制输出违反 MusicKit 条款；卡片只有文本 + 封面，UI 写明原因。
- 听歌时长进学习统计：照常（`music_study_tracker.dart` 只读引擎状态）。

### 3.6 developer token 与页面托管（2026-10-31 已落地签发端；token 归属与 catalog 路径以本节为准）

- 签发端：排行榜 Worker `GET https://rank.fushi.moe/v1/musickit/token` → `{token, expiresAt}`
  （PR hajisensai/Fushi#2712，`services/leaderboard/src/musickit.js`；ES256、claims 只有
  `iss/iat/exp`、**无 `origin` 声明**、有效 1 天、过半重签、免登录按 IP 限流、缺 secret 回 503）。
  私钥只在 Worker secret，不进 app / git / GitHub secrets。密钥登记见 `docs/agent/apple-signing.md`
  「MusicKit 密钥」。
- 客户端：Dart 侧 `AppleMusicTokenSource` 取 token 并缓存到 `expiresAt` 前；503 / 网络失败时
  Apple Music 来源整体显示「暂不可用」，不影响其它音乐来源。
- **catalog 浏览因此不必经桥**：五端（含 Linux）都可由 Dart 直接调 `api.music.apple.com`
  （`createAppHttpClient`，走全应用代理）；§3.1 的桥只负责授权、订阅状态与播放。
  用户私有数据（资料库、喜欢）需要 Music-User-Token，仍由桥授权后取得。
- Apple 平台原生 MusicKit **不用这枚 token**（系统按 App ID 自动生成），但 App ID 仍须勾 MusicKit 服务。
- 网页桥：MusicKit JS 页面（`musickit/index.html`）仍须从 https 源加载（`authorize()` 不认
  `file://` / 自定义 scheme），可由同一 Worker 托管（如 `rank.fushi.moe/musickit/`），页面启动时向
  `/v1/musickit/token` 取 token 后 `MusicKit.configure`。token 无 origin 声明，页面源不受限。
- 取舍：免登录端点等于任何人都能拿到一枚有效 token（网页版 MusicKit 应用的 token 本来也对访客
  可见，行业通行做法）；风险是被滥用触发 Apple 侧限流 / 吊销而全体用户同时失效。1 天有效期 +
  IP 限流是现有缓解；若出现滥用，再加 app 安装签名校验（复用排行榜现有账户签名）。
- 用户登录：MusicKit JS `authorize()` 弹 Apple ID 登录，得 Music-User-Token，WebView 存储隔离在
  独立 profile；退出时清除。

## 4. 设置与 UI

- 设置 › 音乐 › Apple Music：连接 / 断开、订阅状态、当前 storefront；未订阅时只能浏览 + 试听
  （原生可调 `.musicSubscriptionOffer`）。
- 音乐页来源列表多一项「Apple Music」，复用服务器曲库页面；条目带 Apple Music 标识（品牌规范）。
- 混排进本地曲库：不做（与服务器曲库一样留 opt-in，v1 不开）。
- 新页面按 CLAUDE.md 规则带动效、工具栏自适应溢出；i18n 走 `i18n_sync`。

## 5. 非目标

- 离线下载、缓存音频、录制输出、卡片音频片段。
- Apple 私有接口（逐字 TTML 歌词 `syllable-lyrics`、amp-api 等）：不碰，歌词只用现有公开 provider。
- 电台、MusicKit for Android SDK、Linux。
- 均衡器 / 交叉淡入 / 独占 / ReplayGain / bit-perfect 对 Apple Music 曲目不生效（§3.3 能力标志置灰）。

## 6. 阶段

| 阶段 | 内容 | 前置 |
|---|---|---|
| P0 spike | ① Mac + iPhone：Flutter 宿主里 `ApplicationMusicPlayer` 整曲播放、进度、Now Playing 与 audio_service 共存；② Windows WebView2 + MusicKit JS：`authorize()`、整曲（非 30 s）播放、SMTC 是否多出会话；③ Android WebView 同②；每项记证据 | §9 ①② |
| P1 ✅ | `MusicBackendCapabilities` + `MusicRoutingBackend`（`music_routing_backend.dart`；路由表暂空、行为不变；`test/media/music/music_routing_backend_test.dart` 钉跨后端接力） | — |
| P2 | Apple 平台：Swift 桥 + `AppleMusicNativeBridge` + 来源浏览 + 设置页 | P0① 通过 |
| P1b ✅ | `AppleMusicTokenSource` + catalog REST 来源（五端浏览 + 预览试听走 mpv）：`packages/fushi_engine/lib/media/music/apple_music/`，`MusicServerKind.appleMusic`；设置 › 音乐 › 服务器曲库里显式打开（`music_apple_music_enabled`，默认关）+ 选 storefront（`music_apple_music_storefront`，默认 `jp`）；专辑分区 = 热门专辑榜、艺人分区 = 榜单专辑的艺人、主入口是搜索；无预览的曲目不列出；不参与混排；测试 `packages/fushi_engine/test/media/music/apple_music/` | #2712 合入并部署 |
| P3 | Windows：Worker 托管页 + `AppleMusicWebBridge` | P0② 通过、§9 ③ |
| P4 | Android：复用 P3 的网页桥 | P0③ 通过 |

验证：每阶段在真机走「搜索 → 播放整曲 → 歌词逐字跟随 → 点词查词 → 学习统计入账」；
Apple 平台按全局规则在 `ssh mac` 上验（iPhone 真机 + macOS 14+），不以模拟器代替（模拟器无 Apple Music 播放）。

## 7. 改动面（预估）

- 新：`fushi/lib/src/media/music/apple_music/`（桥接口、两种桥、来源 browser、后端）、
  `fushi/ios/Runner/AppleMusicChannel.swift` 与 macOS 对应文件、托管页（仓库位置待定）、CI 部署步骤。
- 改：`music_output_backend.dart`（能力标志）、`music_crossfade.dart` / `mpv_music_output_backend.dart`
  （填能力）、`app_model.dart:1750`（装配路由后端）、`music_servers.dart`、`music_session.dart`
  （会话让出）、`settings_schema_music.dart`、信号路径面板 / A-B 循环入口、iOS/macOS
  `Info.plist`（`NSAppleMusicUsageDescription`）与 entitlements。
- 安装包增量：Apple 平台几十 KB（系统框架），Windows / Android 约 0（WebView 已在包内，MusicKit JS
  运行时从 Apple CDN 加载），Dart 部分约 100–300 KB。

## 8. 风险

- macOS 原生 `ApplicationMusicPlayer` 稳定性差（§2），可能只能先上 iOS。
- WebView2 / Android WebView 的 Widevine 与 `authorize()` 未证实；不通过则 Windows / Android 只剩
  浏览 + 试听，或改做「伴随模式」（读官方 app 的系统媒体会话同步歌词，另立方案）。
- 依赖 Apple 账号状态：开发者账号 / MusicKit key 被吊销时全体用户同时失效。
- 条款变化：MusicKit / Apple Music API 条款与品牌规范上线前须再核一遍原文。

## 9. 待所有者拍板

1. 是否同意 Fushi 本体内置 Apple Music 官方集成（不同于 10-29 的插件改判，这是本体能力）。
2. ~~新建 MusicKit 私钥~~（已完成，进 Worker secret，§3.6）；**仍待**：主 App ID（iOS / macOS）
   勾选 MusicKit 服务（原生播放只认这个，与 Worker token 无关）。
3. 网页桥托管页是否放排行榜 Worker（`rank.fushi.moe/musickit/`）。
4. macOS 是否接受「仅 14+、稳定性视 spike 结果」，不行就先只上 iOS。

## 参考

- WWDC26「Integrate MusicKit into your app」：https://developer.apple.com/videos/play/wwdc2026/254/
- MusicKit for Android 现状：https://developer.apple.com/forums/thread/734577 、https://developer.apple.com/forums/thread/741338
- macOS ApplicationMusicPlayer：https://developer.apple.com/forums/thread/707436 、https://developer.apple.com/forums/thread/731343 、https://developer.apple.com/forums/thread/744128
- MusicKit JS 社区实践：https://github.com/simonepelosi/vibez 、https://github.com/Laellekoenig/musik
- WebView2 Widevine：https://github.com/microsoft/live-share-sdk/issues/14
