# Hibiki 全局 MD3 UI 重设计实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or inline execution with review checkpoints. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 参照 Seal 的 Material Design 3 视觉语法，把 Hibiki 的 Material 路径从零散页面样式收口为统一的全局 MD3 组件系统，并让主要页面族继承该系统。

**Architecture:** 先改 token/theme/shared component，再迁移页面族。全局页面不能靠局部装饰堆出来；`HibikiDesignTokens`、`HibikiCard`、`HibikiListItem`、`AdaptiveSettings*`、`adaptiveAlertDialog`、`adaptiveModalSheet` 是边界。

**Tech Stack:** Flutter, Material 3, Cupertino adaptive branch, Slang i18n, existing Hibiki shared components.

---

## 设计来源

- Seal 参考图：`.codex-test/reference/seal/1.jpg` 到 `9.jpg`。
- 全界面设计稿：`docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md`。
- 覆盖审计：`docs/design/md3-cupertino/UI_COVERAGE_AUDIT.md`，当前设计覆盖 84 个界面/组件。

## 非谈判约束

- 当前 EPUB 阅读器仍是 Hoshi/Hibiki 路径，不能把问题带回旧 TTU。
- 不改持久化 key，不破坏导入、查词、Anki、阅读位置、音频同步。
- iOS/Cupertino 分支保留；本轮主要收口 Material 路径，兼容已有 adaptive API。
- 工作区已有无关 dirty 改动，提交时只 stage 本任务相关文件。

## 当前缺口判断

旧计划只覆盖 token/theme/settings 的窄面，不能满足“所有地方”。真正缺口在：

- 普通输入框仍散落在导入、媒体、标签、WebSocket、歌词、字体、阅读器设置里。
- `adaptiveAlertDialog` 只交给主题，缺少统一宽度、形状、按钮区间距。
- `adaptiveModalSheet` 默认不显示 drag handle，和 Seal sheet 语法不一致。
- `HibikiTag` 还是矩形色块，不符合 MD3 chip 语法。
- 空状态只是大图标+大字，没有 MD3 tonal 容器和行动区。
- 页面族仍有直接 `AlertDialog`、`TextField`、`OutlineInputBorder` 和局部按钮布局。

## Task 1: 共享组件硬化

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_material_components.dart`
- Modify: `hibiki/lib/src/utils/components/settings_shared.dart`
- Modify: `hibiki/lib/src/utils/adaptive/adaptive_widgets.dart`
- Modify: `hibiki/lib/src/utils/components/hibiki_tag.dart`
- Modify: `hibiki/lib/src/utils/components/hibiki_placeholder_message.dart`

- [x] 保留已完成的 token/theme 基础：12dp card/group、28dp dialog/sheet、primary section label、tonal `HibikiCard`。
- [ ] 新增可复用 `HibikiTextField`，统一 Seal 风格 outlined/floating-label 输入框。
- [ ] 让 `AdaptiveSettingsTextField` 复用 `HibikiTextField`，避免 settings 和普通页面出现两套输入框。
- [ ] 让 `adaptiveAlertDialog` 的 Material 分支统一 28dp shape、合理 max width、actions padding。
- [ ] 让 `adaptiveModalSheet` Material 分支默认显示 drag handle。
- [ ] 将 `HibikiTag` 从矩形 `Container` 改为 8dp chip surface。
- [ ] 将 `HibikiPlaceholderMessage` 改为轻量 MD3 empty state surface。

## Task 2: 输入框页面族迁移

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/book_import_dialog.dart`
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
- Modify: `hibiki/lib/src/pages/implementations/blur_options_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/custom_fonts_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/custom_theme_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/lyrics_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/media_item_edit_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/profile_management_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/tag_management_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/websocket_dialog_page.dart`
- Modify: `hibiki/lib/src/settings/settings_schema.dart`
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart`

- [ ] 把普通 `TextField`/`TextFormField` + `OutlineInputBorder` 替换为 `HibikiTextField` 或 `AdaptiveSettingsTextField`。
- [ ] 保持 controller、initialValue、onChanged、onSubmitted、maxLines、expands、keyboardType 行为不变。
- [ ] 编辑器类大文本保留 monospace，但走 `HibikiEditorPanel` 或 `HibikiTextField(maxLines: null)`。

## Task 3: 页面族视觉收口

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`
- Modify: `hibiki/lib/src/pages/base_history_page.dart`
- Modify: `hibiki/lib/src/pages/base_media_search_bar.dart`
- Modify: `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/tag_filter_sheet.dart`
- Modify: `hibiki/lib/src/pages/implementations/tag_picker_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/tag_management_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/reading_statistics_page.dart`

- [ ] 首页/导航保留自适应壳，确保 FAB、NavigationBar、NavigationRail 使用主题 shape。
- [ ] 书架/历史/统计使用 tonal cards、MD3 row density、selected state。
- [ ] 标签筛选 sheet 使用统一 chip 选中态。
- [ ] 字典搜索和弹窗不再把结果焦点强制拉回输入框。

## Task 4: 阅读器相关 UI 收口

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
- Modify: `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart`
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
- Modify: `hibiki/lib/src/pages/implementations/display_settings_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/book_css_editor_page.dart`

- [ ] 保持正文优先，阅读器 chrome 只在需要时出现。
- [ ] 有声书播放栏和 WebView inset 不能互相遮挡。
- [ ] 快捷设置 sheet 使用 28dp sheet、primary section label、MD3 输入框和选中态。
- [ ] 修改后需要真实设备/模拟器验证阅读器路径，留下截图/UI XML/log 或明确说明阻塞。

## Task 5: 静态和 Widget 测试

**Files:**
- Modify: `hibiki/test/settings/md3_design_system_static_test.dart`
- Modify: existing focused widget tests when assertions depend on changed shared components.

- [ ] 静态测试禁止已迁移文件重新出现裸 `OutlineInputBorder`、局部旧 TextField 样式和旧矩形 tag。
- [ ] Widget 测试覆盖 `HibikiTextField`、`AdaptiveSettingsTextField`、`adaptiveModalSheet` drag handle 默认值、`HibikiTag` 圆角。
- [ ] 保留既有 Cupertino tests，不能因为 Material 改造破坏 iOS 分支。

## Task 6: 审查、验证和归档

- [ ] 运行 `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`。
- [ ] 运行 `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test`。
- [ ] 对 >30 行变更执行 CCG 双模型审查；若 wrapper 环境失败，记录失败原因并使用可用 CCG review agent 兜底。
- [ ] 修复 Critical/Warning 后重新验证。
- [ ] 检查 `.ccg/spec/` 是否存在；如有新沉淀，追加对应 spec。
- [ ] 只 stage 本任务相关文件，运行 `git diff --cached --check`。
- [ ] 提交实现。
- [ ] 归档 `.ccg/tasks/md3-global-redesign` 到 `.ccg/tasks/archive/2026-05/` 并提交归档。
