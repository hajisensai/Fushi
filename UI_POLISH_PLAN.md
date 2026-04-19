# UI 打磨计划（Phase 3）— ✅ 已完成

**目标**：把 jidoujisho 遗留的 Material 2 风格 UI 统一升级到 Material 3，清理硬编码颜色 / 尺寸，让书架、词典弹窗、阅读器覆盖层视觉现代化。

**状态**：7 个 PR 全部落地（PR-6 拆成 6a / 6b），见下文每节末尾的 commit 引用。

## 原则

- **先基座、再高频交互、最后长尾**：主题 token 先跑通，卡片和弹窗才不用反复调颜色。
- 不重写业务逻辑，只动视觉层。Isar schema / audiobook bridge / ttu WebView 桥逻辑**不碰**。
- 每个 PR 聚焦单一模块，遵循 `analyze → 编译 APK → commit` 三步。
- 能用 `colorScheme.*` 就不要写具体颜色；能用 `textTheme.*` 就不要写 `fontSize`。

## PR 顺序

### PR-1　主题基座

**目的**：启用 Material 3，剩余 PR 才能去硬编码颜色。

- 开启 `useMaterial3: true`
- `ColorScheme.fromSeed`：选一个主色种子（建议和 Hoshi Reader iOS 靠近的深青 / 靛蓝）
- `TextTheme` 统一字号体系，删掉业务层 `fontSize * 0.9` 这类手工缩放
- 深浅色两套 `ThemeData` 对齐 seed

**只改**：`lib/src/pages/theme.dart`（或当前主题入口，第一步读源码确认）+ `MaterialApp` 装配处。

**风险**：主题改了之后，所有页面视觉都会变，必须跑一遍主要路径（书架 → 打开书 → 查词 → 导入字幕 → 打开设置）确认没有"看不见字"这类对比度问题。

✅ 落地：`afc871bcd`

### PR-2　词典弹窗

**目的**：用户读书时每分钟触发的 popup，先改这个体感提升最大。

- `dictionary_dialog_page.dart`：容器改 M3 `Card` + `surfaceContainerHigh`，圆角对齐全局 `shapeTheme`
- `dictionary_term_page.dart` / `dictionary_entry_page.dart`：释义排版调整，间距用 `Spacing.of(context).insets` 而非硬编码
- 删除硬编码深色背景 `Colors.grey.shade900` / `Colors.black` 之类
- 底部操作区（加入卡片、复制、搜索更多）换 `FilledButton.tonal` / `IconButton.filled`

**验证**：在 ttu reader 里点词 → 弹词典 → 翻页条目 → 加入 Anki，流程不中断。

✅ 落地：`682650d26`

### PR-3　书架卡片

**目的**：首屏视觉换代。

文件：`reader_ttu_source_history_page.dart` 的 `_buildSrtCard` 和 `buildMediaItemContent`（以及基类的对应实现，PR-3 先读源码核对）。

- 外层 `ClipRRect`（圆角 12）+ `Card` + `surfaceContainerLow`
- 封面失败占位：M3 `Icon` + `onSurfaceVariant` 色，不用 `Colors.white.withAlpha(0.4)`
- 标题条：底部 `LinearGradient`（透明 → `surface.withAlpha(0.85)`）遮罩，不用纯黑半透明
- 进度条：`colorScheme.primary` 前景、`surfaceContainerHighest` 背景，高度 3px
- 角标（有声书 / 字幕）：`Badge` 或 `Container + colorScheme.secondaryContainer`，不用纯黑方块

**验证**：书架滚动流畅，字幕书和 EPUB 两区视觉一致，进度条在深 / 浅主题都清晰。

✅ 落地：`d3417136e`

### PR-4　AppBar + 浮动搜索栏

**目的**：主题跑通后基本是"删硬编码"。

文件：`lib/src/pages/base_tab_page.dart:65-67` + `home_page.dart` 的 AppBar。

- `base_tab_page.dart` 搜索栏的 `Color.fromARGB(255, 30, 30, 30)` / `Color.fromARGB(255, 229, 229, 229)` 换 `colorScheme.surfaceContainer`
- `backdropColor` 换 `colorScheme.scrim`
- `accentColor` 已经走 `colorScheme.primary`，保持
- AppBar 本身靠 M3 默认（`surfaceTint` 自动处理）

**验证**：主页 AppBar 和搜索栏在深浅色切换时无突兀色块。

✅ 落地：`f25d59445`

### PR-5　对话框统一

**目的**：一类组件集中改，避免零散返工。

覆盖：
- `MediaItemDialogPage`（长按书卡）
- `_confirmDeleteSrtBook` / `_confirmDeleteEpub`
- `AudiobookImportDialog`
- `SrtImportDialog`（四格式导入）
- `dictionary_dialog_delete_page.dart` / `dictionary_dialog_import_page.dart` / `dictionary_settings_dialog_page.dart`
- `language_dialog_page.dart` / `profiles_dialog_page.dart`

统一：
- `Dialog` shape 走全局 `dialogTheme`（圆角 16）
- 主操作按钮 `FilledButton`，次操作 `TextButton`，危险操作 `FilledButton` + `colorScheme.errorContainer`
- 删除确认文案样式对齐

✅ 落地：`ca1995ca2`

### PR-6　阅读器 Flutter 侧覆盖层

**目的**：留在最后，和 audiobook bridge 耦合风险最大。

- ttu WebView 之上的 Flutter 控件（播放器 bar、章节跳转按钮、设置入口）
- `audiobook_bridge.dart` 相关 UI 部分（注意不碰 bridge 的消息协议）
- 底部工具栏 M3 `NavigationBar` 或 `BottomAppBar`

**风险**：改覆盖层容易触发 WebView 布局重测 / 字幕高亮失准，必须在真机上验证 cue 滚动、点击 cue 跳转、高亮跟随播放进度三项。

✅ 落地（拆两步）：
- PR-6a `29184c4d3`：有声书播放条 → M3 `BottomAppBar`
- PR-6b `ce237e64f`：FollowPill → `FilledButton.icon`；同时审计其余覆盖层（Scaffold 黑底防白闪、AudiobookImportFAB Opacity 0.6、词典主题走用户覆盖路径）均刻意保留，不动

## 不在本计划范围

- ttu reader 内部（WebView 里的 HTML / CSS）：那是 ッツ 上游代码，本轮不动
- Isar schema / 存储层
- audiobook bridge 的消息协议 / cueMap 逻辑
- 文案 / i18n 调整（视觉稳定后再单独一轮）

## 执行顺序约束

- PR-1 必须最先；没跑通 M3 主题，PR-2~PR-5 做的颜色都要返工
- PR-2 和 PR-3 可以并行（互不冲突），但 review 建议串行便于排查回归
- PR-6 必须最后（风险隔离）
