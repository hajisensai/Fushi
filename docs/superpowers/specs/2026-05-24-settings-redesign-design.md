# Hibiki 设置重设计方案

## 背景

当前设置已经有一层 `AdaptiveSettingsScaffold`、`AdaptiveSettingsSection`、`AdaptiveSettingsRow`，也能在 Android 和 iOS 之间切换部分控件。但这只是控件皮肤适配，不是设置系统设计。设置项、分组、路由、业务写入、平台判断仍散落在页面文件里，结果是：

- 主设置页把主题、Profile、Anki、阅读器、更新、杂项和日志塞进线性列表，用户要靠记忆找配置。
- Android 和 iOS 只是同一结构换控件，没有分别遵守 Material Design 3 和 Cupertino 的交互方式。
- 设置项没有统一数据模型，每个页面自己决定分组、图标、控件、导航和保存逻辑。
- 新设置容易继续长成一次性代码，尤其是阅读器、Anki、词典、更新和调试入口。

这次重设计允许重构路由和文件结构。目标不是给旧页面换圆角，而是把设置变成一套清晰的数据结构，再用平台原生语法渲染。

## 目标

1. Android 走 Material Design 3：使用 Material 3 navigation、list、switch、segmented button、slider、dialog、sheet 和宽屏布局。
2. iOS 走 Cupertino：使用 large title、grouped list、Cupertino switch、sliding segmented control、Cupertino push route 和 iOS 风格确认弹窗。
3. 设置项按用户任务重新分组，而不是按历史文件名堆放。
4. 设置定义集中到 schema，页面只负责渲染和绑定行为。
5. 保留现有持久化 key 和业务行为，不破坏旧书籍、Profile、阅读器设置、Anki 设置、更新设置和调试日志。
6. 宽屏上提供 master-detail，手机上提供 push navigation。
7. 重构后每个设置项有明确类型、位置、平台展示和验证路径。

## 非目标

- 不重命名 `ttu_*`、`reader_*`、Anki、Profile、更新等现有持久化 key。
- 不把当前 Hoshi 阅读器问题转移到旧 TTU 资产或 `D:\ttu-fork`。
- 不在这次设置重设计中改 EPUB 渲染、音频 cue 匹配、字典 FFI 或数据库 schema。
- 不新增设置搜索，除非实现阶段发现分类仍不足以解决查找问题。
- 不把整个应用 shell 重写为独立 Router；本设计只重构设置域。

## 设计依据

现有项目设计基线来自 `docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md`：

- Settings board 选 `B: Grouped Cupertino settings`。
- Reader customization board 选 `B: Preview studio`。
- Creator and Anki board 选 `C: Mapping panel`。
- Dictionary management board 选 `C: Admin workspace`。
- Component system board 选 `C: Hybrid density kit`。

Flutter 官方组件文档确认可直接落地的组件：

- Android/Material：`NavigationBar`、`NavigationRail`、`SegmentedButton`、`Switch`、`Slider`、`ListTile`、`AlertDialog`、`ModalBottomSheet`。
- iOS/Cupertino：`CupertinoSliverNavigationBar`、`CupertinoListSection`、`CupertinoListTile`、`CupertinoSwitch`、`CupertinoSlidingSegmentedControl`、`CupertinoAlertDialog`、`CupertinoPageRoute`。

## 核心方案

采用 schema-first 平台双渲染。

设置系统由三层组成：

1. `SettingsDestination`：设置页主分类，例如外观、阅读、有声书、词典与制卡、系统、诊断。
2. `SettingsSection`：分类内的语义分组，例如主题、排版、导航、Anki 连接、更新通道。
3. `SettingsItem`：具体配置项，例如 switch、segmented、stepper、slider、navigation、action、custom。

平台渲染器只消费这个模型：

- Android 渲染器把 schema 映射成 MD3 list、segmented controls、switches、sliders、dialogs 和 wide layout。
- iOS 渲染器把同一 schema 映射成 Cupertino grouped lists、push pages、large title、Cupertino controls 和 iOS alerts。

业务读写仍调用现有 `AppModel`、`ReaderHibikiSource`、`ReaderSettings`、`AnkiViewModel`、`DebugLogService`、`UpdateChecker`、platform channels。schema 只集中描述“设置项是什么、放哪里、怎么显示、触发什么行为”，不复制业务状态。

## 信息架构

主设置分为六个 destination。

### 外观与平台

用途：应用级视觉和语言身份。

包含：

- 设计系统：自动、Material 3、Cupertino。
- 主题色：系统色、预设色、自定义主题入口。
- 明暗模式：浅色、跟随系统、深色。
- Profile：当前 Profile selector，Profile 管理入口。
- 语言：语言选择入口。

放置理由：这些设置影响整个应用，不属于阅读器或字典的业务行为。

### 阅读

用途：Hoshi 阅读器正文、排版、导航和查词行为。

包含：

- 显示设置入口：字体大小、行高、缩进、边距、列数、横排/竖排、分页/滚动、双页、假名显示、正文样式优先级。
- 自定义字体入口。
- 自定义书籍 CSS 入口。
- 阅读导航：点击高亮、滑动方向、音量键翻页、音量键翻页速度、音量键方向反转。
- 查词行为：自动朗读、弹窗最大宽度。
- 保持屏幕常亮。

放置理由：这些设置都直接影响打开书后的行为和阅读器布局，需要集中。

### 有声书

用途：音频播放和歌词覆盖层。

包含：

- 媒体通知显示。
- 悬浮歌词开关。
- 悬浮歌词字号。
- 音量键句子导航。
- 播放栏相关入口，保留当前 `AudiobookSettingsSheet` 的阅读中快速控制能力。

放置理由：有声书设置既和阅读器相关，又是独立工作流，不能混在杂项。

### 词典与制卡

用途：查词、字典管理、Anki 卡片配置。

包含：

- Anki 设置入口：fetch 配置、deck、note type、field mapping、tags、allow duplicates、compact glossaries。
- 词典设置入口：已安装词典、导入、排序、CSS、本地音频源。
- 弹窗宽度。
- 自动朗读。
- 与制卡相关的 recorder、crop、segmentation 工作流入口。

放置理由：用户查词后最常做的是制卡，这两类设置应靠近。

### 系统

用途：应用运行、更新、平台能力。

包含：

- 更新设置：不再提醒、自动安装、beta channel、debug channel 确认。
- 低内存模式。
- 启动器图标：Android preset icon 和 custom shortcut；iOS 隐藏或显示不可用说明，取决于后续平台能力。
- WebSocket 或外部服务入口。
- GitHub/关于入口。

放置理由：这些设置不应污染学习工作流。

### 诊断

用途：错误和调试。

包含：

- 错误日志入口，显示当前错误数量。
- 调试日志开关。
- 调试日志入口，仅在启用或已有记录时显示。
- 低内存、导入、WebView renderer 等运行状态的证据入口，后续可扩展。

放置理由：诊断是支持面，不该和正常配置混在一起。

## 平台行为

### Android

手机：

- 主设置页是 MD3 分组列表。
- 顶部使用普通 `AppBar` 或现有 home tab app bar。
- 每个 destination 是带 leading icon、title、summary、trailing chevron 的 `ListTile` 风格行。
- 进入详情页用 `MaterialPageRoute`。
- 布尔项用 `Switch`。
- 互斥项用 `SegmentedButton`。
- 小步数值用 stepper；连续数值用 `Slider`。
- 危险或不可逆操作用 `AlertDialog`。

宽屏：

- 设置 tab 内使用 master-detail。
- 左侧为 destination list 或 `NavigationRail` 风格分类栏。
- 右侧为当前 destination 的 sections。
- 不额外打开全屏 route，除非是复杂编辑器，例如 CSS editor、Anki handlebar picker、字典导入。

### iOS

手机：

- 设置页使用 Cupertino grouped list。
- 顶部使用 large title。
- 每个 destination 通过 `CupertinoPageRoute` push。
- 布尔项用 `CupertinoSwitch`。
- 互斥项用 `CupertinoSlidingSegmentedControl`。
- 数值项优先使用 inline stepper 或 Cupertino slider。
- 确认使用 `CupertinoAlertDialog`。

宽屏或 macOS：

- 可复用 master-detail，但视觉上仍是 grouped list，不使用 Material rail 外观。
- 详情页保留 iOS grouped section rhythm。

### 共同约束

- 不使用一套 Android list 冒充 iOS。
- 不在 iOS 页面里显示 Material 的 `SegmentedButton`、`Switch`、`AlertDialog`。
- 不在 Android 页面里显示 Cupertino 控件。
- 行高和 padding 由平台渲染器决定，设置 schema 不写布局细节。

## 数据模型草案

```dart
enum SettingsItemKind {
  navigation,
  action,
  boolean,
  segmented,
  slider,
  stepper,
  custom,
}

enum SettingsDestinationId {
  appearance,
  reading,
  audiobook,
  dictionaryAndCards,
  system,
  diagnostics,
}

class SettingsDestination {
  const SettingsDestination({
    required this.id,
    required this.title,
    required this.icon,
    required this.sections,
    this.summary,
    this.visible,
  });

  final SettingsDestinationId id;
  final String title;
  final IconData icon;
  final String? summary;
  final bool Function(SettingsContext context)? visible;
  final List<SettingsSection> sections;
}

class SettingsSection {
  const SettingsSection({
    required this.items,
    this.title,
    this.footer,
    this.visible,
  });

  final String? title;
  final String? footer;
  final bool Function(SettingsContext context)? visible;
  final List<SettingsItem> items;
}

class SettingsItem {
  const SettingsItem({
    required this.id,
    required this.kind,
    required this.title,
    this.subtitle,
    this.icon,
    this.visible,
  });

  final String id;
  final SettingsItemKind kind;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool Function(SettingsContext context)? visible;
}
```

实现时可以把它细化成 sealed class，例如 `SettingsSwitchItem`、`SettingsSegmentedItem<T>`、`SettingsNavigationItem` 和 `SettingsCustomItem`。关键不是类名，而是设置结构不再藏在一次性 widget 代码里。

## 状态与写入契约

`SettingsContext` 应暴露现有状态所有者：

- `AppModel appModel`
- `WidgetRef ref`
- `ReaderHibikiSource readerSource`
- `ReaderSettings? readerSettings`
- `BuildContext context`
- `VoidCallback refresh`

写入必须调用现有 source of truth：

- 主题和设计系统写入走 `appModel.themeNotifier`。
- 应用主题写入走 `AppModel.setAppThemeKey`、明暗模式方法和自定义主题页。
- 阅读器显示写入走 `ReaderHibikiSource`，并且必须调用 `ReaderHibikiSource.onSettingsChangedLive`。
- `keepScreenAwake` 继续使用 `WakelockPlus`。
- Anki 写入走 `AnkiViewModel`。
- 更新设置写入走现有 `AppModel` update setters，并保留 debug channel 确认。
- 启动器图标写入保留 Android platform channel 行为和 source-of-truth 校验。
- 调试日志写入走 `DebugLogService`。

如果现有 repository/model 方法已经拥有某个行为，设置项不得直接写 SharedPreferences、Drift 或 platform channel。

## 文件结构

新增设置功能目录：

```text
hibiki/lib/src/settings/
  settings_context.dart
  settings_destination.dart
  settings_schema.dart
  settings_actions.dart
  settings_renderer.dart
  material_settings_renderer.dart
  cupertino_settings_renderer.dart
  settings_detail_page.dart
  settings_home_page.dart
```

保留 route 级兼容：

- `hibiki_settings_page.dart` becomes a thin bridge to `SettingsHomePage`.
- `display_settings_page.dart`, `anki_settings_page.dart`, `miscellaneous_settings_page.dart`, `switch_settings_page.dart` can remain route files during migration, but their shared rows should migrate to schema-backed sections where practical.
- 复杂编辑器继续保留为独立页面：自定义主题、自定义字体、书籍 CSS、词典管理、Anki handlebar picker；启动器图标选择器如果继续膨胀，也应独立。

## Migration plan

### Phase 1: Shared model and renderers

- Add settings schema classes and `SettingsContext`.
- Add Material and Cupertino renderers.
- Add tests that the same schema renders Material controls on Android and Cupertino controls on iOS.
- Keep existing settings pages working.

### Phase 2: New settings home

- Replace `HibikiSettingsContent` with schema-driven `SettingsHomePage`.
- Add six destination groups.
- Keep existing destination pages reachable.
- Add wide master-detail behavior for settings tab.

### Phase 3: Reading and appearance consolidation

- Move theme, design system, brightness, Profile, language into `appearance`.
- Move display, fonts, CSS, reader navigation, popup width, keep-awake into `reading`.
- Ensure every reader write still calls live refresh.

### Phase 4: Anki, dictionary, system, diagnostics

- Move Anki entry and mapping workflow under `dictionaryAndCards`.
- Move update, low memory, launcher icon, WebSocket/about under `system`.
- Move error/debug logs under `diagnostics`.
- Keep Android-only icon controls hidden or disabled on unsupported platforms.

### Phase 5: Cleanup

- Remove old duplicated helper builders from `hibiki_settings_page.dart` after call sites migrate.
- Collapse platform branching into renderers.
- Leave persisted keys untouched.
- Add static test that old keys still appear where required and no TTU/Hoshi compatibility key was renamed.

## Testing

Minimum tests before implementation completion:

- Widget test: Android settings home renders Material `Switch`, `SegmentedButton`, and Material navigation rows.
- Widget test: iOS settings home renders `CupertinoSwitch`, `CupertinoSlidingSegmentedControl`, and grouped Cupertino rows.
- Widget test: six destinations exist and are ordered as specified.
- Widget test: hidden items do not render on unsupported platforms, especially launcher icon custom shortcut.
- Focused unit/static test: persisted key strings used by reader settings are not renamed.
- Existing `settings_shared_test.dart` remains passing or is replaced with equivalent renderer tests.
- Run `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`.
- Run `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test`.

Manual validation before claiming runtime completion:

- Android compact: settings home, each destination, switch, segmented, slider/stepper, route navigation.
- Android wide: master-detail selection, no unexpected full-screen detours for ordinary settings.
- iOS or forced Cupertino mode: large/grouped settings, Cupertino switches, segmented controls, alerts and push navigation.
- Reader open while settings change: display and behavior settings update live.
- Anki settings still fetch deck/note type and save mappings.
- Update debug channel still asks confirmation.
- Launcher icon setting remains Android-only and does not claim unsupported custom icon behavior.

## Failure modes to avoid

- Recreating settings from scratch while losing existing behavior.
- Renaming persisted keys because the old names contain `ttu`.
- Treating iOS as Material with different colors.
- Treating Android as Cupertino grouped lists.
- Putting every setting in a single scroll view again.
- Hiding unsupported behavior without explanation.
- Updating reader settings without live refresh.
- Making Profile look global when a setting is profile-scoped.

## Open implementation decisions

1. Whether `SettingsItem` should be a sealed class hierarchy or a single class with nullable fields. Recommendation: sealed classes, because it prevents invalid combinations like a slider without min/max.
2. Whether Android wide settings should use a `NavigationRail` or a dense destination list. Recommendation: dense destination list inside the settings pane; app shell already uses navigation rail.
3. Whether settings search is needed. Recommendation: defer until after the six-destination model is implemented and tested.
4. Whether iOS/macOS should both be treated as Cupertino. Recommendation: yes for component grammar, with width-specific layout adjustments.

## Approval checkpoint

Implementation should start only after this document is reviewed and accepted. The first implementation plan should be component-first:

1. settings schema and context,
2. Material/Cupertino renderers,
3. settings home and destination shell,
4. destination-by-destination migration,
5. cleanup and verification.
