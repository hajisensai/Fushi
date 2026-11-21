## BUG-4973 · 字幕面板每次搜索都按未变的 Jimaku key 重建下载管线运行时
- **报告**：2026-11-20（来源：路线图 `docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md` 的 gap-subpanels-1，c35 组）
- **真实性**：✅ 真 bug。单集搜索面板 `fushi/lib/src/pages/implementations/subtitle_search_panel.dart:742` 与合集面板 `fushi/lib/src/pages/implementations/subtitle_collection_panel.dart:774` 都拿输入框里的 key 和**面板打开时**的 `widget.initialApiKey` 比；用户在面板里改过一次 key 后，`initialApiKey` 不会刷新，之后每次搜索都按同一个新值调 `onApiKeyChanged`。根因在汇合点 `fushi/lib/src/models/app_model.dart:7228` 的 `AppModel.setJimakuApiKey`：不看值有没有变，每次都写偏好并 `reloadVideoDownloadPipelineRuntime()`，结果是作废查字幕 registry（下次搜索重建 http client、重读 AJATT 目录缓存），下载模块开着时还要拆掉、重起整套下载管线运行时。
- **[x] ① 已修复** — `AppModel.setJimakuApiKey` 在值没变时直接返回。面板侧的比较不改：所有写 key 的入口都经过这一个汇合点，值没变就不重建，这才是要的契约。提交见本文件 Git 历史（分支 `pr/subtitle-generation-fixes`）。
- **[x] ② 已增加自动化测试** — `fushi/test/models/app_model_jimaku_key_noop_test.dart`：真实 `AppModel` 接内存库与偏好仓，按同一个 key 再存一次后 `subtitleSearchRegistry()` 必须返回同一个实例（修复前会作废、重建出新实例，测试红）；改成不同的 key 仍会重建。
- **备注**：不涉及阅读器 / 播放布局。
