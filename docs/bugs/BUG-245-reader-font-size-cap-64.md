## BUG-245 · 阅读器正文字号最大只能调到 64（TODO-299「为什么字体大小只有64最大」）

- **报告**：2026-06-14（用户：TODO-299）
- **真实性**：✅ 真限制，但纯属保守 UI 上限，**无任何技术原因**。
  - 用户指的「字体大小」= 阅读器正文字号 `reading_display.font_size`（设置页/阅读器快捷设置同一条 schema，zh 标题就叫「字体大小」）。
  - 上限位置：`hibiki/lib/src/settings/settings_schema.dart:236` 的 `SettingsStepperItem(id: 'reading_display.font_size', min: 8, max: 64, ...)`。这是该字号的**唯一**上限来源——`material_settings_renderer.dart:380-381` / `cupertino_settings_renderer.dart` 只把 `stepper.max` 透传给步进行；阅读器快捷设置面板（`reader_quick_settings_sheet.dart` 的 `fontSize` 分支 → `setTtuFontSize`）也复用这条 schema。
  - 持久化链路 `setTtuFontSize`（`reader_hibiki_source.dart:678`）→ `ReaderSettings.setFontSize`（`reader_settings.dart:107`）→ 直写 `ttu_font_size`，**无任何 clamp**；存什么生效什么。
  - 渲染链路 `ReaderContentStyles.css`（`reader_content_styles.dart:415/467`）只是 `font-size: ${settings.fontSize}px`；振假名 rt 用相对 `0.45em`（随基字缩放），column-gap / padding-bottom 也只是按字号加几像素。字号再大，WebView/分页都按渲染高度重新换行——**没有上限依赖**，64 只是当年随手定的保守值。
- **[x] ① 已修复** — `settings_schema.dart` 把 `reading_display.font_size` 的 `max: 64` 抬到 `max: 128`（并加注释说明 64 非技术限制）。下限 `min: 8`、step、持久化 key、渲染链路全不动；旧持久化值（≤64）继续合法，向后兼容。提交：（见本轮 commit）。
- **[x] ② 已加自动化测试** — `hibiki/test/settings/reader_font_size_cap_test.dart`：
  - 守卫（widget）：从真实 schema 取 `reading_display.font_size` 这条 stepper，断言 `min==8` 且 `max>64`（当前 ==128），防止保守上限回潮。
  - 行为：`setFontSize(96)`（>64，旧上限到不了）→ 同实例生效 + DB 往返重读仍是 96（不被 clamp 砍回 64）→ `ReaderContentStyles.css` 真生成 `font-size: 96.0px`（且不含 `font-size: 64`），证明 >64 字号能真写穿并渲染。
- **备注**：S 级，单文件改 1 行（+注释）。`flutter analyze` 0 issue；`flutter test test/settings/reader_font_size_cap_test.dart` 2 绿；`test/settings/` + `reader_content_styles_test` 套件 `reading/Font Size` 行 PASS（同套件预存 2 个失败 `reading/Volume button page turning` / `Invert volume buttons` 是平台门控的音量键开关在桌面测试宿主下的**既有失败**，已对照 HEAD 基线确认与本改动无关）。真机/大屏更大字号下的分页布局表现待用户复测（CLAUDE.md 阅读器验证纪律）。
