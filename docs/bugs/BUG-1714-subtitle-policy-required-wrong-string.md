## BUG-1714 · 「附带字幕 · 必选」选项复用播放器控件文案，选项读不通
- **报告**：2026-08-18（随 TODO-2935 资源搜索链路排查发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart:1228`（修复前）把
  `VideoDownloadSubtitlePolicy.required` 的下拉标签拼成 `'${t.anime_download_include_subs} · ${t.video_control_reject_required}'`，
  而 `video_control_reject_required` = 「必选控制必须保留在播放器上。」是播放器控件布局编辑器的拒绝提示（唯一正当用法在
  `fushi/lib/src/media/video/video_control_layout_editor.dart:629`）。选项渲染出来是「附带字幕 · 必选控制必须保留在播放器上。」，语义完全不搭。
- **[x] ① 已修复** — 提交 `<pending>`。新增 i18n key `anime_download_require_subs`（en `Subtitles required` / zh 「必须有字幕」），下拉直接用它。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_discovery_acquisition_dialogs_test.dart` 的
  `必须有字幕的选项不复用播放器控件文案`：展开下拉后必须出现新文案，且整棵树不含 `video_control_reject_required`。
  变异实测：把旧拼串换回去 → 该用例红；还原后文件 sha256 与变异前逐字节一致。
- **备注**：无。
