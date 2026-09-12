## BUG-2487 · 视频来源回看无法继续播放且导航使用阅读文案
- **报告**：2026-09-10（用户：不能继续播放，继续按钮使用阅读文案，继续后需要返回卡片片段）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi_page.dart:1557` 的 `_onSourceReviewChanged` 只开启观看记录并刷新位置，没有调用播放；来源加载明确使用 `autoPlay: false`。加载未完成时提前置 `_reviewContinued` 还会让后续初始化错过继续请求。`source_review_session.dart` 对视频复用阅读按钮和卡片来源标题，且没有返回片段入口。
- **[x] ① 已修复** — 继续观看使用一次性待播放请求，播放器就绪后启动播放与进度记录；视频使用独立文案，返回卡片片段重新走来源路由。已继续的会话在跨集时不会被后续草稿通知误触发播放。
- **[x] ② 已加自动化测试** — `fushi/test/pages/card_source_media_review_guard_test.dart` 覆盖继续请求生命周期；`fushi/test/anki/source_review_session_test.dart` 覆盖视频文案、回跳防重入及失败保护；`fushi/integration_test/video_card_source_return_test.dart` 以真实 libmpv 与数据库验证播放、定位、正常观看落盘和回看隔离（Windows 真应用 1/1 通过，退出码 0）。
- **备注**：返回片段复用来源解析路由，正常观看先落盘，再进入独立回看，避免直接 seek 覆盖正常进度。


- **Windows 证据**：fushi/.codex-test/windows-itest/video-card-source-return-2418-r2/，真实 libmpv 回到 5000ms，正常进度保留 19100ms；两张 Flutter 截图确认回看/观看文案与按钮。用户安装版进程在运行前后保持不变。
