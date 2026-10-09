## BUG-3218 · 跳过片头/片尾按钮无法关闭，按用户决定移除该功能
- **报告**：2026-10-09（用户：反馈处理台 svSfwFdmdM，Windows）
- **真实性**：✅ 真 bug（沿真实代码路径确认）。片源带命名章节（如 `Intro` / `OP` / `ED` / `Credits`）时，播放页常驻弹出「跳过片头 / 片尾」按钮，设置里没有任何关闭入口，盖在 OP/ED 画面上。根因：
  - `fushi/lib/src/media/video/video_chapter_skip.dart:27` `videoSkippableChapterKind` 按章节标题正则把 `Intro` / `OP` / `Opening` / `ED` / `Credits` / `オープニング` 等判成可跳过章节；文件头注释明写「这是被动提示，不需要开关」——没有偏好、没有设置项。
  - `fushi/lib/src/pages/implementations/video_fushi/chapter.part.dart:239` `_buildSkipChapterButton` 只要当前位置落在这类章节且后面还有下一章就挂 `VideoSkipChapterButton`（`video_m3e_chrome.dart:1780`），出现条件**不跟控制条可见性**（只认 `showBottomButtonBar` 密度档），所以控制条隐藏后按钮仍常驻画面右下角（用户截图即此状态）。
  - 挂载点 `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart:581`。
  - 盘点：无偏好键、无专属快捷键（按钮按下走的是 `controller.nextChapter()`，与保留的 `videoNextChapter` 快捷键共用）、无在线来源（无 AniSkip 之类请求）、无音频指纹；只有两个 i18n key `video_skip_opening` / `video_skip_ending` 与 `video_m3e_chrome_test.dart` 里的判据单测。
- **[x] ① 已修复** — 用户拍板整条砍掉而非加开关：删 `video_chapter_skip.dart`、`VideoSkipChapterButton`、`_buildSkipChapterButton` 及挂载点、两个 i18n key（`i18n_sync --remove`）、对应判据单测。章节面板、进度条章节刻度、章节跳转 / 下一章快捷键保留不动。提交见 PR `pr/video-remove-skip-intro`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_skip_chapter_removed_guard_test.dart`（源码扫描守卫：播放页合并语料与 M3E chrome 里不得再有跳过按钮 / 章节判据，判据文件不得存在；同时钉住章节刻度、章节面板、章节跳转仍接线）；`fushi/integration_test/video_chapter_first_load_test.dart` 加一段：带 `Intro`/`Middle`/`Credits` 章节的真 MKV 停在 Intro 内（后面还有下一章——旧实现弹按钮的条件），断言画面无跳过按钮并出真实像素截图。
- **备注**：偏好层本就没有键，无需迁移。
