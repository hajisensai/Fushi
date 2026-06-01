# 设置层级重构设计（全局 ↔ 书内统一）

- 日期: 2026-06-01
- 状态: 设计已确认，待写实现计划
- 范围: `hibiki/lib/src/settings/`、`hibiki/lib/src/pages/implementations/display_settings_page.dart`、`hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`、`hibiki/lib/src/pages/implementations/hibiki_settings_page.dart`、i18n、相关测试
- 不在范围: 存储模型不动（仍走全局 `preferences` 表），不引入 per-book 设置，不动 Drift schema 版本

## 1. 背景与问题

当前同一批「阅读器设置」（字号/行高/边距/栏数/spread/书写方向/振假名/翻页行为等）被**三份独立的 UI 代码各描述了一遍**，写的却是同一组 `preferences` key（`src:reader_ttu:*`）：

1. `display_settings_page.dart`（`DisplaySettingsPage`）—— 全局「阅读显示」入口跳转的手写页，用 `setTtu*` 直接读写。
2. `reader_quick_settings_sheet.dart`（`ReaderQuickSettingsSheet`）—— 阅读器内底部抽屉，手写 widget 树（`_buildAppearanceSettingsSection` / `_buildLayoutSettingsSection` / `_buildReaderSwitches` 等）。
3. `settings_schema.dart` 的 `buildReaderQuickSettingsDestination` —— 用 schema 子集拼装的对话框版（`HibikiSettingsDialogPage` 消费），与 #2 并存。

三份描述意味着：新增一个阅读设置要改三处；任意一处漏改就漂移。这是技术债的根因——**「哪些设置存在」与「它出现在哪些界面」这两个维度被耦合并重复书写**。

存储侧无问题：所有设置最终落在扁平的全局 `preferences` 表，profile 通过快照/恢复整张表实现「按 profile 切换」。书内改动是全局生效，**本次重构保持该行为不变**。

## 2. 目标与约束

- **目标**: 消除重复（三份 → 一份 schema 单一真相源）+ 重排全局层级（10 → 8 分组）。
- **切分原则**: 书内面板只放「阅读时会随手调」的项 —— 显示 / 布局 / 阅读导航行为（含音量键翻页类）/ 听书。App 外壳（语言/设计系统/主题系统/图标/导航栏）、查词配置、卡片、Profiles、同步、系统 —— 全局 only。
- **存储约束**: 不动数据库，书内改动仍写全局 `preferences`，向后兼容（Never break userspace）。
- **生效范围**: 书内改字号 = 全局所有书一起变（维持现状）。

## 3. 核心方案：Schema 单一真相源 + 书内投影

把每个 preference 设置抽象为一个**正式 schema item**（`SettingsStepperItem` / `SettingsSliderItem` / `SettingsSegmentedItem` / `SettingsSwitchItem` / `SettingsCustomItem`），其 getter/setter 委托现有 `ReaderHibikiSource` / `AppModel`（不改底层读写）。

引入一个正交维度 `ReaderPlacement`：描述「该 item 是否出现在书内面板、放哪组、什么顺序」。

- 全局设置：按 destination/section 渲染**全部** item（含 reader item）。
- 书内面板：渲染 `item.reader != null` 的项，按 `ReaderGroup` 重组。
- 三个界面（全局 Reading 页、书内抽屉、书内对话框）都消费同一份 item 定义，无任何手写副本。

### 3.1 schema 模型改动（`settings_destination.dart`）

```dart
// 书内分组维度（与全局 destination 正交）
enum ReaderGroup { appearance, layout, behavior, audiobook }

class ReaderPlacement {
  const ReaderPlacement({required this.group, required this.order});
  final ReaderGroup group;
  final int order;
}
```

`SettingsItem` 基类新增可选字段（默认 `null` = 不进书内），并由各子类构造器透传：

```dart
sealed class SettingsItem {
  const SettingsItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.visible,
    this.reader, // 新增
  });
  final ReaderPlacement? reader;
  // ...
}
```

`SettingsDestinationId` 枚举调整：
- 合并 `readingDisplay` + `readingControls` → `reading`。
- `diagnostics` 并入 `system`（删除 `diagnostics` 值）。
- 保留 `readerQuickSettings` 合成 id（HBK-AUDIT-131 防碰撞）。

新增收集函数（建议放 `settings_schema.dart` 或 `settings_destination.dart` 辅助）：

```dart
// 遍历完整 schema，取出带 reader 放置的 item，按 group + order 分组
Map<ReaderGroup, List<SettingsItem>> collectReaderItems(SettingsContext context);
```

`buildReaderQuickSettingsDestination` 重写为：调用 `collectReaderItems`，把 4 个 `ReaderGroup` 各映射成一个 `SettingsSection`，组装成 `readerQuickSettings` destination。删除当前硬编码的 `firstWhere` + id 白名单逻辑。

### 3.2 重排后的全局层级（8 分组）

```
1. 外观 Appearance（全局 only）
   · 界面: 设计系统 / 主题 / 亮暗模式 / App UI 缩放
   · 排版: 自定义字体
   · App 外壳: 语言 / App 图标(Android) / 反转导航栏

2. 阅读 Reading（合并原「阅读显示」+「阅读控制」，含 reader 投影项）
   · 显示: 字号 / 行高 / 首行缩进 / 阅读主题 / 视图模式 / Book CSS
   · 布局: 边距×4 / 栏数 / spread mode / spread direction / 书写方向 /
           竖排朝向 / 振假名模式 / 两端对齐 / 竖排 kerning / font VPAL /
           prioritizeReaderStyles
   · 导航行为: highlight_on_tap / 点空白隐藏 UI(tap_empty_hide_chrome) /
           音量翻页(+反转音量键+翻页速度) / 音量键句导航 /
           反转划动 / 划动灵敏度 / 屏幕常亮 / 查词时朗读 / 查词时暂停 /
           键盘快捷键(→ ShortcutSettingsPage，全局 only，不进书内)

3. 查词 Lookup（全局 only）
   · 管理: 词典 / 词典 CSS / 音频源
   · 查词行为 / 查词显示 / 本地音频

4. 听书 Listening
   · 媒体通知 / 悬浮歌词(+字号)(Android) / 音量键句导航

5. 卡片 Cards（全局 only）—— Anki 设置 + auto_add_book_name_to_tags

6. 配置档 Profiles（全局 only）

7. 同步备份 Sync & Backup（全局 only，沿用 sync_settings_schema.dart）

8. 系统 System（合并原「系统」+「诊断」）
   · 更新: 渠道 / 不再提醒 / 自动安装
   · 系统: 低内存模式 / GitHub
   · 诊断: 错误日志 / 调试日志开关 / 调试日志
```

### 3.3 书内面板结构（`ReaderQuickSettingsSheet`）

分两类：**设置（schema 投影）** 与 **非设置（保留手写）**。

```
书内底部抽屉
├── [非设置·保留] 进度区: 章节/页进度 + 【新增】音频播放进度（仅 controller != null 时）
├── [非设置·保留] 快捷控制: 字号/行高 stepper + 阅读主题 chip + 视图模式
│        （UI 是手感快调，但读写复用 schema item 的 getter/setter，不另写持久化）
├── 设置子页（schema 投影，collectReaderItems 的 4 组）:
│   ├── 外观  (ReaderGroup.appearance)
│   ├── 布局  (ReaderGroup.layout)
│   ├── 行为  (ReaderGroup.behavior)
│   └── 听书  (ReaderGroup.audiobook)  [仅 controller != null]
├── [非设置·保留] 听书播放控制: 音量/速度/AV 同步延迟/图片暂停/skip（运行态 controller，非 preference）
├── [非设置·保留] 位置: 搜索/跳字符/目录/书签/收藏句（per-book 操作）
└── [非设置·保留] 底部操作: 歌词↔书籍模式切换 / 加书签 / 退出
```

**音频进度**：`_buildProgressSection(ThemeData)` 内读取已传入的 `controller`（`AudiobookPlayerController?`，sheet 第 59 行已有字段），`controller != null` 时追加一行音频播放进度（position / duration），与阅读进度并列；无 controller 时不显示。

## 4. 受影响文件清单

| 文件 | 改动 |
|------|------|
| `lib/src/settings/settings_destination.dart` | 新增 `ReaderGroup` / `ReaderPlacement`；`SettingsItem` 基类 + 各子类透传 `reader` 字段；`SettingsDestinationId` 合并 `readingDisplay`+`readingControls`→`reading`、删 `diagnostics` |
| `lib/src/settings/settings_schema.dart` | **核心重写**：10→8 分组；把 `DisplaySettingsPage` 的全部 reader 设置变成正式 schema item 并标 `reader` 放置；`buildReaderQuickSettingsDestination` 改为基于 `collectReaderItems` 的通用过滤；新增 `collectReaderItems` |
| `lib/src/pages/implementations/display_settings_page.dart` | reader 设置上移 schema 后，本页改为 schema 渲染薄页 / 或由 Reading destination 内联展示，删除手写 `setTtu*` 控件 |
| `lib/src/media/audiobook/reader_quick_settings_sheet.dart` | 删 4 个手写设置子页（`_buildAppearanceSettingsSection` / `_buildLayoutSettingsSection` / `_buildReaderSwitches` 等设置部分），改渲染 schema 投影；`_buildProgressSection` 加音频进度；保留进度/快捷控制/位置/听书播放控制/操作行 |
| `lib/src/pages/implementations/hibiki_settings_page.dart` | `HibikiSettingsDialogPage` 适配新 `buildReaderQuickSettingsDestination` |
| `lib/i18n/*.i18n.json` | 分组标题改名（新「阅读」「系统」合并标题等），**必须用 `hibiki/tool/i18n_sync.dart`**，禁止手编逐文件 |
| `test/settings/settings_redesign_static_test.dart` 及相关 | 跟随新枚举/分组/item id 更新断言 |

## 5. 风险与缓解

- **控件表达力**：`DisplaySettingsPage` 个别交互（如带预览的 segmented、Book CSS 编辑器入口）若标准 item 类型表达不了，用 `SettingsCustomItem` 兜底，不强塞标准类型。
- **枚举合并的影响面**：`SettingsDestinationId` 删值会触发现有测试断言失败 —— destination id 仅用于 UI，不持久化，需确认无 DB / preferences 依赖该枚举名（实现时全仓搜 `readingDisplay` / `readingControls` / `diagnostics` 引用）。
- **i18n 一致性**：新增/删除/改名 i18n key 一律走 `tool/i18n_sync.dart`，否则 17 语言会漂移、`test/i18n` 失败。
- **书内非 hibiki reader 分支**：旧 ttu webview 分支（`AudiobookBridge.setReaderSetting` 写 JS 端）在 `isHibikiReader=true` 时已跳过，schema 投影只走 Dart `ReaderHibikiSource`，需确认不回归旧迁移路径。
- **HBK-AUDIT-131**：保留 `readerQuickSettings` 合成 id，不与真实 `reading` destination 碰撞。

## 6. 验证

- `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`
- `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test`（重点跑 `test/settings/`、`test/i18n/`）
- 真机/模拟器复测原始路径：全局「阅读」改字号 → 书内抽屉应同步；书内改边距 → 全局页应同步；书内进度区在有声书打开时显示音频进度。
- 不涉及 Android 资源/manifest/Gradle，无需 `assembleRelease`。
```
