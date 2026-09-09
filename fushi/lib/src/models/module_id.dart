/// 「功能模块」的唯一值域与可见性快照。
///
/// 设置 → 外观 → 功能模块 里的每个开关对应本文件的一个 [ModuleId]。此前这套东西
/// 是**七个散装 bool + 两处手写平台判据**：`home_page.dart` 的 `_activeTabs()` 抄
/// 一份、`main.dart` 的 macOS 侧栏抄第二份，两份已经漂移（macOS 那份漏了
/// `gamesEnabled`，注释还把漏写说成「macOS 恒 false」）。每加一个消费点就得再抄
/// 一遍七个参数 —— 少抄一个就静默漏一处门控。
///
/// 本文件把「pref 真值 + 平台判据 → 模块可见集合」收成**一次合成**
/// （[ModuleVisibility.resolve]）：平台判据只在 [ModuleId.availableOn] 里写一次，
/// 消费端一律只问 [ModuleVisibility.isEnabled]，不再各自判平台。
///
/// 刻意**不含**首页与设置：它们恒在（是全部模块关光后的安全回退面），没有开关，
/// 因此也不该出现在这个枚举里 —— 值域里没有它们，就没人写得出
/// `isEnabled(settings)` 这种脏状态。首页/设置属于 `HomeTab` 而非 `ModuleId`，
/// 两个值域的映射见 `module_registry.dart`。
library;

import 'package:flutter/foundation.dart';

/// 一个可被用户整体关闭的功能模块。
///
/// 顺序 = 设置页「功能模块」分区的展示顺序，也与底栏/侧栏的 tab 顺序同向
/// （库页 → 工具页 → 横切能力 → 设备数据）。
enum ModuleId {
  /// 书架（EPUB / 字幕书阅读）。
  books('module_books_enabled'),

  /// 漫画库（漫画阅读器 + OCR + 在线目录）。
  manga('module_manga_enabled'),

  /// 视频库（播放器 + 番剧刮削 + 发现）。
  video('module_video_enabled'),

  /// galgame 库与文本/语音捕获。**仅 Windows**（galgame hook 平台边界）。
  games('module_games_enabled'),

  /// 统一下载中心（torrent / 磁力 / 在线目录卷队列）。
  downloads('module_downloads_enabled'),

  /// 查词页与词典管理入口。
  ///
  /// 注意持久化键是历史名 `module_dictionaries_enabled`（**冻结不追改**）。
  /// 本模块关掉的是**页面入口**，不是查词能力：阅读器/视频/galgame 里的划词
  /// 弹窗、设置 → 查词 分类（词典导入管理、音频来源）一律保留。
  lookup('module_dictionaries_enabled'),

  /// 浏览器扩展管理页与本机扩展服务。**仅桌面**。
  browserExtension('module_browser_extension_enabled'),

  /// 听书：有声书播放/导入、语音转录（ASR）、悬浮歌词。
  listening('module_listening_enabled'),

  /// 制卡：Anki（AnkiConnect / AnkiDroid）与查词弹窗上的制卡入口。
  cardCreation('module_card_creation_enabled'),

  /// 在线服务与追踪：第三方 API / 索引器 / 媒体服务器凭据 + 媒体追踪。
  services('module_services_enabled'),

  /// 同步与备份 + Fushi 互联（设备直连、本机作为服务器）。
  sync('module_sync_enabled');

  const ModuleId(this.prefKey);

  /// 落 Drift `preferences` 表的键。**永不改变**（Never break userspace）——
  /// [lookup] 的键就是历史遗留的 `module_dictionaries_enabled`。
  ///
  /// 纪律：任何读写模块开关的地方只用本字段，绝不用 `.name` 拼键。
  final String prefKey;

  /// 本模块在当前平台上**是否存在**（与用户意愿无关）。
  ///
  /// 平台判据只在这里写一次。此前它散在 `home_page.dart`（games 判
  /// `Platform.isWindows`）、`main.dart`（browserExtension 判
  /// `DesktopLookupService.isDesktop`）与 `settings_schema_appearance.dart`
  /// （两个 `visible:` 回调）四处，正是漂移的来源。
  bool availableOn({required bool isWindows, required bool isDesktop}) =>
      switch (this) {
        // galgame hook 只做 Windows 端（见 CLAUDE.md「Galgame Hook 硬规则」）。
        ModuleId.games => isWindows,
        // 手机浏览器不支持加载未解压扩展，故按平台而非实验开关门控。
        ModuleId.browserExtension => isDesktop,
        ModuleId.books ||
        ModuleId.manga ||
        ModuleId.video ||
        ModuleId.downloads ||
        ModuleId.lookup ||
        ModuleId.listening ||
        ModuleId.cardCreation ||
        ModuleId.services ||
        ModuleId.sync => true,
      };

  /// 把持久化键解析回枚举；未知键返回 `null`（备份/同步可能带来旧键或对端新键，
  /// **绝不抛异常**）。
  static ModuleId? tryParsePrefKey(String? key) {
    for (final ModuleId id in ModuleId.values) {
      if (id.prefKey == key) return id;
    }
    return null;
  }

  /// 全部模块的持久化键集合。备份/Profile 的排除名单按它构造，避免再手抄一份。
  static Set<String> get allPrefKeys =>
      ModuleId.values.map((ModuleId id) => id.prefKey).toSet();
}

/// 「此刻哪些模块可见」的不可变快照：用户意愿（pref）与平台可用性的**唯一合成**。
///
/// 全 app 的门控一律读它，不再各自组合 pref + 平台。
@immutable
class ModuleVisibility {
  const ModuleVisibility(this.enabled);

  /// 当前可见的模块集合。
  final Set<ModuleId> enabled;

  /// 全部模块都可见（平台可用的那些）。仅供测试与默认值使用。
  factory ModuleVisibility.all({
    required bool isWindows,
    required bool isDesktop,
  }) => ModuleVisibility.resolve(
    prefOf: (ModuleId _) => true,
    isWindows: isWindows,
    isDesktop: isDesktop,
  );

  /// 把「每个模块的 pref 真值」与平台判据合成为可见集合。
  ///
  /// [prefOf] 只回答用户意愿（开关存的 bool）；平台可用性由
  /// [ModuleId.availableOn] 负责。调用方**不得**再自己叠平台条件 —— 那正是
  /// 旧实现里 `Platform.isWindows && appModel.moduleGamesEnabled` 抄两遍、
  /// 漏一遍的成因。
  factory ModuleVisibility.resolve({
    required bool Function(ModuleId id) prefOf,
    required bool isWindows,
    required bool isDesktop,
  }) {
    final Set<ModuleId> enabled = <ModuleId>{};
    for (final ModuleId id in ModuleId.values) {
      if (!id.availableOn(isWindows: isWindows, isDesktop: isDesktop)) continue;
      if (!prefOf(id)) continue;
      enabled.add(id);
    }
    return ModuleVisibility(enabled);
  }

  bool isEnabled(ModuleId id) => enabled.contains(id);

  /// `null` 视为「不属于任何模块」→ 恒可见。反向映射（`moduleOf*`）返回可空值，
  /// 消费端直接把结果喂进来即可，不必各自写 `?? true`。
  bool isEnabledOrUngated(ModuleId? id) => id == null || isEnabled(id);

  @override
  bool operator ==(Object other) =>
      other is ModuleVisibility && setEquals(other.enabled, enabled);

  @override
  int get hashCode => Object.hashAllUnordered(enabled);

  @override
  String toString() =>
      'ModuleVisibility(${enabled.map((ModuleId e) => e.name).join(', ')})';
}
