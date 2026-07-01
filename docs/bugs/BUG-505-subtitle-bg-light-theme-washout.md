## BUG-505 · TODO-1059 字幕背景浅色泛白+缺调节控件
- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug。根因两处：
  - 泛白：`hibiki/lib/src/pages/implementations/video_hibiki_page.dart:656` 的 `_subtitleBackgroundColor(cs) => cs.surface` 把字幕盒默认底色喂成当前主题 `surface`（经 `layout.part.dart:355` 的 `resolveBackgroundColor` 解析）；浅色主题 `surface` 近白 → 字幕背景变浅色板、与白色字幕对比极低、违和。overlay 侧同样的 `?? Theme.of(context).colorScheme.surface`（`video_subtitle_overlay.dart:374`）。
  - 缺控件：设置面板 `video_quick_settings_sheet.dart` 的字幕外观段只有背景**不透明度**滑条（`:2179`）与「无背景」动作，没有背景**颜色**选择控件——`VideoSubtitleStyle.backgroundColor` 字段/copyWith/编解码都在（`video_subtitle_style.dart:193/247/302`），只差 UI。
- **[x] ① 已修复** — 方案A：字幕盒默认底色改为固定半透明黑常量 `kDefaultSubtitleBackgroundColor`（`video_subtitle_style.dart`，`video_hibiki_page.dart:_subtitleBackgroundColor`、`video_subtitle_overlay.dart` 兜底同步），不再跟随主题 surface（仅 `backgroundColor==null` 时生效，显式选过的用户数据逐字尊重）。方案B：`_buildSubtitleDetail` 加 `AdaptiveSettingsPickerRow<int>` 背景色选择行（默认黑/白/灰/红/蓝/绿），落 `backgroundColor`，`copyWith` 加 `resetBackgroundColor` 标志把「默认」项清成 null；选非默认色且当前透明度为 0 时顶到 0.6 可见基线。提交：（见分支 fix-1059-subtitle-controls-v2）
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_bg_light_theme_test.dart`（浅色主题 + opacity>0 + backgroundColor==null 断言底色=固定黑×opacity、显式色逐字尊重、opacity==0 透明）+ `hibiki/test/media/video/video_subtitle_bg_color_row_guard_test.dart`（源码守卫：背景色选择行 + 默认常量 + resetBackgroundColor）。
- **备注**：i18n 新增 7 key（title + 6 预设色名，17 语言经 i18n_sync + slang 重生成）。
