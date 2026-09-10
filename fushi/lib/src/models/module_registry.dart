/// [ModuleId] 与各域值域之间的**显式映射表**。
///
/// 本仓有多套互不通用的值域：底栏 tab [HomeTab]、设置一级分类
/// [SettingsDestinationId]、快捷键作用域 [ShortcutScope]、书架/合集媒体种类
/// [MediaKind]。「功能模块」要门控它们全部，但值域**不合并**（`HomeTab.home` /
/// `SettingsDestinationId.appearance` 这类恒在项根本没有对应模块）。
///
/// 这里把换算收成**穷尽 switch 的纯函数**：加模块时编译器强制补齐每张映射，
/// 漏一张就编译不过。体例照抄
/// `packages/fushi_core/lib/src/database/media_kind_mappings.dart`。
///
/// 反向映射一律返回**可空**值，`null` = 「不属于任何模块」= 恒可见。省掉的那个
/// 默认分支正是安全方向：新加的 destination 默认恒在，忘写映射不会把它藏掉。
library;

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart' show HomeTab;
import 'package:fushi/src/settings/settings_destination.dart'
    show SettingsDestinationId;
import 'package:fushi/src/shortcuts/shortcut_action.dart' show ShortcutScope;
import 'package:fushi_core/fushi_core.dart' show MediaKind;

// ── HomeTab ────────────────────────────────────────────────────────────────

/// 顶层 tab → 所属模块。`home` / `settings` 恒在（全部模块关光后的安全回退面），
/// 故返回 `null`。
ModuleId? moduleOfHomeTab(HomeTab tab) => switch (tab) {
  HomeTab.home => null,
  HomeTab.settings => null,
  HomeTab.books => ModuleId.books,
  HomeTab.manga => ModuleId.manga,
  HomeTab.video => ModuleId.video,
  HomeTab.downloads => ModuleId.downloads,
  HomeTab.dictionaries => ModuleId.lookup,
  HomeTab.games => ModuleId.games,
  HomeTab.browserExtension => ModuleId.browserExtension,
};

/// 某个顶层 tab 此刻是否可达。`_selectTab` / 任何「点了要跳过去」的入口渲染判据
/// 都用它，别自己拼 `isEnabled(moduleOfHomeTab(t)!)`——恒在 tab 会在那个 `!` 上崩。
bool isHomeTabVisible(HomeTab tab, ModuleVisibility visibility) =>
    visibility.isEnabledOrUngated(moduleOfHomeTab(tab));

/// 模块 → 它的顶层 tab。四个横切模块（听书/制卡/在线服务/同步）**没有 tab**，
/// 返回 `null`——它们只有设置分类与散落在各页的入口。
HomeTab? homeTabOfModule(ModuleId module) => switch (module) {
  ModuleId.books => HomeTab.books,
  ModuleId.manga => HomeTab.manga,
  ModuleId.video => HomeTab.video,
  ModuleId.downloads => HomeTab.downloads,
  ModuleId.lookup => HomeTab.dictionaries,
  ModuleId.games => HomeTab.games,
  ModuleId.browserExtension => HomeTab.browserExtension,
  ModuleId.listening ||
  ModuleId.cardCreation ||
  ModuleId.services ||
  ModuleId.sync => null,
};

// ── SettingsDestinationId ──────────────────────────────────────────────────

/// 设置一级分类 → 所属模块（`null` = 恒在）。
///
/// 几个刻意判 `null` 的：
/// - `reading`：books 与 manga **共用**的阅读偏好（漫画库页内嵌的设置分区引的
///   正是它，见 `manga_library_page.dart`），挂 books 会在「books 关 + manga 开」
///   这个合法组合下把漫画库的设置分区一起连坐。
/// - `lookup`：用户明确要求「关掉查词模块只关页面入口、查词能力全留」——词典
///   导入管理与音频来源是阅读器划词弹窗的配置面，藏了等于把弹窗锁死成空壳。
/// - `storage` / `system` / `appearance` / `profiles`：设备级，不属任何模块
///   （storage 正文里按模块分的**条目**另行过滤，见 `storage_usage_view.dart`）。
/// - 四个 synthetic 分类（`readerQuickSettings` / `appIcon` /
///   `videoQuickSettings` / `shortcuts`）不是设置主页上的一级分类，藏它们只会
///   让对应的合成面板整个消失。
ModuleId? moduleOfSettingsDestination(SettingsDestinationId id) => switch (id) {
  SettingsDestinationId.appearance => null,
  SettingsDestinationId.profiles => null,
  SettingsDestinationId.reading => null,
  SettingsDestinationId.lookup => null,
  SettingsDestinationId.storage => null,
  SettingsDestinationId.system => null,
  SettingsDestinationId.readerQuickSettings => null,
  SettingsDestinationId.appIcon => null,
  SettingsDestinationId.videoQuickSettings => null,
  SettingsDestinationId.shortcuts => null,
  SettingsDestinationId.manga => ModuleId.manga,
  SettingsDestinationId.video => ModuleId.video,
  SettingsDestinationId.cardCreation => ModuleId.cardCreation,
  SettingsDestinationId.downloads => ModuleId.downloads,
  SettingsDestinationId.game => ModuleId.games,
  // 在线服务与媒体追踪同属「第三方服务」一个开关：追踪本就是靠在线服务的
  // 凭据跑的，分成两个开关只会让用户关了一半还留着另一半。
  SettingsDestinationId.services => ModuleId.services,
  SettingsDestinationId.mediaTracking => ModuleId.services,
  // 互联是从同步备份拆出去的一级分类，共享同一套后端与私有状态，同一个开关。
  SettingsDestinationId.syncBackup => ModuleId.sync,
  SettingsDestinationId.interconnect => ModuleId.sync,
};

/// 某个设置一级分类此刻是否该出现。挂给 `SettingsDestination.visible` 即可同时
/// 满足「列表看不见 + 搜索搜不到 + 主从详情不可选」——三条渲染路径共用
/// `isVisible`。
bool isSettingsDestinationVisible(
  SettingsDestinationId id,
  ModuleVisibility visibility,
) => visibility.isEnabledOrUngated(moduleOfSettingsDestination(id));

// ── ShortcutScope ──────────────────────────────────────────────────────────

/// 快捷键作用域 → 所属模块（`null` = 恒在）。
///
/// `dictionaryPopup`（划词弹窗内部导航）判 `null`：它跨全部弹窗宿主常驻，属于
/// 查词**能力**而非查词页面，与 lookup 模块开关无关。
/// `globalExternal`（app 外系统级取词热键）判 lookup：它是把用户送进查词界面的
/// 外部入口，模块关掉时不该还能装系统钩子。
ModuleId? moduleOfShortcutScope(ShortcutScope scope) => switch (scope) {
  ShortcutScope.global => null,
  ShortcutScope.universal => null,
  ShortcutScope.home => null,
  ShortcutScope.gamepad => null,
  ShortcutScope.dictionaryPopup => null,
  ShortcutScope.globalExternal => ModuleId.lookup,
  ShortcutScope.reader => ModuleId.books,
  ShortcutScope.audiobook => ModuleId.listening,
  ShortcutScope.manga => ModuleId.manga,
  ShortcutScope.video => ModuleId.video,
};

bool isShortcutScopeVisible(ShortcutScope scope, ModuleVisibility visibility) =>
    visibility.isEnabledOrUngated(moduleOfShortcutScope(scope));

// ── MediaKind ──────────────────────────────────────────────────────────────

/// 书架/合集媒体种类 → 所属模块。
///
/// ⚠️ **漫画盖不住**：[MediaKind] 没有 `manga` 值——漫画是 `EpubBooks.format ==
/// 'manga'` 派生出来的，落在 `epub` 桶里。按本映射过滤只能把漫画跟着 books 一起
/// 处理；需要区分漫画的地方（首页「继续」/「最近添加」）必须另带派生判据，不能
/// 给 [MediaKind] 加值（`dbValue` 是持久化契约，加值会波及合集/统计/同步全链）。
ModuleId moduleOfMediaKind(MediaKind kind) => switch (kind) {
  MediaKind.epub || MediaKind.srt => ModuleId.books,
  MediaKind.video => ModuleId.video,
  MediaKind.game => ModuleId.games,
};

/// 此刻该出现在首页聚合列表里的媒体种类。
Set<MediaKind> visibleMediaKinds(ModuleVisibility visibility) => MediaKind
    .values
    .where((MediaKind k) => visibility.isEnabled(moduleOfMediaKind(k)))
    .toSet();
