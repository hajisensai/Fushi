## BUG-4711 · 扩展 YouTube 默认挂无关语言的字幕轨；手动选的轨取不到时永远停在「选中加载」
- **报告**：2026-11-16（应用内反馈 0RgCNJFQmJ / GitHub #3401，Win11 Edge、扩展 0.1.0 / app 3.3.0：浮层默认挂阿拉伯语 / 俄语 / 韩语轨，与视频语言无关；手动选日语后一直「待加载」）
- **真实性**：✅ 真 bug，两处根因。
  1. 默认轨选错：`tools/browser-extension/youtube-bridge.js:72-77`（修复前）`prioritizeCaptionTracks` 只从 `#movie_player.getAudioTrack()` 返回的对象上按字段名读 `defaultCaptionTrackIndex` / `languageCode`。那是播放器内部的压缩类实例，字段名随播放器版本被混淆（反馈人实测读出为空）→ 规则 ①「默认轨」②「音轨同语言」同时失效，排序退化成「原始顺序里第一条人工轨」，急取并挂上的就是第一条翻译轨（ar…）。
  2. 失败回执无人接：桥按需取轨失败会发 `{__fushiStream:'cuesFailed'}`，`subtitle-providers.js:817-827` 转给 `window.fushiSubtitlePanelOnTrackFailed`，但这个钩子只有 app 的 `web_video_glue.js` 实现，扩展的 `subtitle-panel.js` 没有 → 回执被丢，轨永远显示「选中加载」，`requestLazyIfPending`（`subtitle-panel.js:164`）还每 5 秒替用户再打一次注定失败的请求。
- **[x] ① 已修复** —
  - 桥：排序信号改从结构稳定的数据推（`captionHints`）：运行时音轨字段（仍认）→ 同视频播放器响应 `captions.playerCaptionsTracklistRenderer`（服务端 JSON：`audioTracks[defaultAudioTrackIndex].defaultCaptionTrackIndex`（`hasDefaultTrack !== false`）给默认轨，按 vssId / 语言码+ASR 对上运行时轨；`captionTrackIndices` 圈本音轨范围）→ 本音轨范围里唯一的 ASR 语言 = 音轨语言。播放器响应按 `videoDetails.videoId` 核对，SPA 换片后残留的 `ytInitialPlayerResponse` 不用。三路取轨各自带自己的排序上下文（运行时音轨的默认索引不再拿去索引 Android 响应的轨）。同语言内人工轨先于 ASR 轨。
  - 面板：`subtitle-panel.js` 实现 `fushiSubtitlePanelOnTrackFailed`：占位轨失败记 `lazyFailed`，侧栏 / 播放器菜单 / app 内浏览器侧栏显示「加载失败，重新选择可重试」，活动轨失败弹提示；失败后不自动重试，用户再次选中（三条选轨入口）才重取；cue 到了清掉失败。
- **[x] ② 已加自动化测试** — `tools/browser-extension/youtube-bridge-track-priority.test.js`「#3401」4 条（混淆字段 + 唯一 ASR 语言、播放器响应默认轨、自动配音按 captionTrackIndices 认语言、残留响应不作数；修复前 4 条全红）；`tools/browser-extension/subtitle-panel.test.js`「#3401」1 条（失败回执 → failed + 提示、不自动重试、重选重取、cue 到清失败；修复前红）；`fushi/test/web_browser/features/extension_host/web_browser_subtitle_panel_test.dart`「轨状态带 failed」。
- **备注**：没在真 YouTube 页面复测（无真机 / 浏览器环境）；为什么那条日语轨的按需请求会失败（POT / 空响应等）未在真页面定位，本修复保证失败可见且可重试。「可排序的优先字幕语言」「按视频记住手动选择」属功能扩展，不在本修复内。
