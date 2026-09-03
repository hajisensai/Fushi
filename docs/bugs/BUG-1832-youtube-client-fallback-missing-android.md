## BUG-1832 · YouTube 部分视频打不开：兜底 client 链缺 android
- **报告**：2026-08-24（用户：`https://www.youtube.com/watch?v=D8uACXBAqkE` 观看不了）
- **真实性**：✅ 真 bug（已按原始 URL 复现）。根因 `fushi/lib/src/media/video/youtube_source_resolver.dart:383`（旧 `kYoutubeManifestClientFallback = [androidVr, ios, tv]`）；字幕侧同根因在同文件 `_fetchCaptionTracks`（旧代码硬编码 `yt.YoutubeApiClient.androidVr`）。
- **[x] ① 已修复** — 兜底链补入 `yt.YoutubeApiClient.android`（顺序 `androidVr → android → ios → tv`）；`_fetchCaptionTracks` 改为按同一条链逐个试、首个非空即用；外层总超时改为由链长派生。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/youtube_client_fallback_test.dart`（9 条断言，含两轮变异实测）。
- **备注**：见下。

### 复现

`resolveYoutubeSource('https://www.youtube.com/watch?v=D8uACXBAqkE')` 抛：

```
StateError: youtube manifest failed for all clients (...): VideoUnplayableException: Video 'D8uACXBAqkE' is unplayable.
```

即 `_getManifestWithClientFallback` 走完全链仍拿不到流 → 播放页拿不到 `streamUrl` → **视频根本打不开**。

### 根因

逐 client 实测（youtube_explode_dart 2.5.3，目标视频 vs 对照视频 `dQw4w9WgXcQ`）：

| client | D8uACXBAqkE | dQw4w9WgXcQ（对照） |
|---|---|---|
| androidVr | ❌ `VideoUnplayableException` (1.6s) | ✅ muxed 1 / vo 22 / ao 4 |
| ios | ❌ 首流 HEAD 403（itag 313，16.2s） | ✅ vo 22 / ao 5 |
| tv | ❌ `VideoUnplayableException` (9.7s) | ❌ `VideoUnplayableException` |
| **android** | ✅ **muxed 1 / vo 23 / ao 6**（3.0s） | ✅ muxed 1 / vo 23 / ao 6 |

链里恰好只缺唯一能出流的那个 client。**不是**地区限制、年龄门或视频本身不可用——同一时刻 `android` 一次就出全部 30 条流。

`android` 当年被排除的理由（源码注释「默认 android/ios client 签发的直链实测被 403」）在当前版本**已不成立**。实测 `android` 签发的三条流用 `kYoutubeStreamReplayUserAgent`（= youtube_explode 铸流所用的同一完整 Chrome UA）发 Range 请求：

| 流 | 结果 |
|---|---|
| itag 137（1080p avc1）video-only | `206`，65534 字节 |
| itag 251（opus）audio-only | `206`，65534 字节 |
| itag 18（muxed 360p） | `206`，65534 字节 |

与 androidVr 基线逐条一致。当年 403 的根因是**回放 UA 与铸流 UA 不一致**（TODO-1365 / BUG-678 已修），不是 client 本身。

### 同根因的第二处：字幕静默消失

`_fetchCaptionTracks` 硬编码 `androidVr` 取 player response。该视频 androidVr 的 `closedCaptionTrack` **恒为 0 条**，旧代码把它当成「这个视频没字幕」：

| client | D8uACXBAqkE 字幕轨 | dQw4w9WgXcQ |
|---|---|---|
| androidVr | **0** | 6 |
| android | **7**（my, zh-TW, en, **ja**, **ja**, ko, vi） | 6 |
| ios | **7**（同上） | 6 |
| tv | 0 | 0 |

即修完取流后视频能播，但日语字幕（这个 app 的核心功能）仍是空的。

### 顺带修正的既有缺陷：超时预算靠注释人肉维护

旧代码把「每 client 上限 × 链长 ≤ 外层总超时」写在注释里（「13s × 3 = 39s 不超外层 40s」）。这个不变式：

- 加第 4 个 client 时必然失配；
- 且 `resolveYoutubeVideoVariants` 的 20s 默认值**当时就已经容不下 3 × 13s = 39s**——画质菜单在首选 client 慢时必然整体超时。

改为从链长**派生**（`kYoutubeResolveTimeout = kYoutubePerClientManifestTimeout × 链长 + 3s`），两个入口共用同一预算，增删 client 时自动跟随。

### 修复

`fushi/lib/src/media/video/youtube_source_resolver.dart`：

1. `kYoutubeManifestClientFallback` → `[androidVr, android, ios, tv]`。`android` 排在 `ios` 之前：实测 `android` 成功 ~3s，而 `ios` 取流失败要等满首流 HEAD 403 探测（16s）。
2. 新增 `kYoutubePerClientManifestTimeout`（13s）与派生的 `kYoutubeResolveTimeout`；`resolveYoutubeSource` / `resolveYoutubeVideoVariants` 的 `timeout` 参数改为 `Duration?`，null 取派生值。
3. `_fetchCaptionTracks` 改为经新的注入式纯编排 `fetchFirstNonEmptyByClient` 按同一条链逐个试、首个非空即用并短路；单 client 的一次取轨拆到 `_fetchCaptionTracksWithClient`，保持原有的 best-effort（失败返回空表，绝不冒泡阻断播放）。
4. 清掉文件头与 `resolveYoutubeSource` doc 里已被实测推翻的「android/ios 直链必 403」「唯一可取字幕的是 ANDROID_VR」两处陈述。

### 验证

修复后跑真实网络路径（`resolveYoutubeSource` + `resolveYoutubeVideoVariants`）：

| 视频 | 取流 | 画质档 | 字幕 cue |
|---|---|---|---|
| D8uACXBAqkE（原始失败） | ✅ 15.8s，分离流（非 muxed 回退） | 8 档 | **332**（修前 0） |
| dQw4w9WgXcQ（对照，防回归） | ✅ 4.8s | 8 档 | 60（与修前一致） |

自动化测试 `fushi/test/media/video/youtube_client_fallback_test.dart` 9 条全绿，并做了两轮变异实测：

- 变异「把 `android` 从链里删掉」→ 2 条断言变红；
- 变异「去掉短路、跑完全链再返回首个非空」→ 2 条断言变红（结果值仍正确，只有调用序列断言抓到）。

两轮变异后均以 sha256 逐字节校验还原源文件。

`flutter analyze` 全绿（无 issue）。

### 未覆盖

- 未做真机 / 集成测试复测播放画面：本次验证停在解析层（流 URL 可 206 拉取、画质档与字幕 cue 数量），未在真实播放页跑到出画面。
- 测试不含网络断言（CI 无外网，且 YouTube 各 client 的行为本就会漂），锁的是链构成、超时不变式与逐 client 编排行为这三件本地可判定的事实。
