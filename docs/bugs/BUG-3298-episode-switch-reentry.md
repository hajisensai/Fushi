## BUG-3298 · 视频换集 _switchEpisode 无防重入
- **报告**：2026-10-13（审查子代理发现，无用户反馈编号）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi/episode.part.dart` `_switchEpisode` 本地分支：`await _controller?.pause()` 与 `pushReplacement` / 接管 `removeRoute` 之间隔着 await，而 `_autoAdvanceInFlight` 只挡自动连播自身；手动点选（剧集列表 / 上下集键）与倒计时归零可同时进入，第二次再压一页新集页，并对已被第一次摘掉的本页路由再 `removeRoute`（抛异常）。
- **[x] ① 已修复** — 本页同一时刻只允许一次本地换集在飞：`_localEpisodeSwitchInFlight`（`video_fushi_page.dart`）在本地分支第一个 await 之前置位、finally 复位，先到者为准；远端换集不受限（靠 `_episodeLoadSeq` 后者取代前者）。提交见本分支。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_episode_switch_reentry_guard_test.dart`（源码守卫：标志声明、置位早于首个 await、finally 复位且导航在 try 内）。真页面双触发的 widget 测试需整套 media_kit 播放器宿主，本批未落地。
- **备注**：
