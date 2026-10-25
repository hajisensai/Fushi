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
/// 刻意**不含**设置：它恒在（是全部模块关光后的安全回退面），没有开关，因此也
/// 不该出现在这个枚举里 —— 值域里没有它，就没人写得出 `isEnabled(settings)` 这种
/// 脏状态。设置属于 `HomeTab` 而非 `ModuleId`，两个值域的映射见
/// `module_registry.dart`。
///
/// 首页（dashboard）此前也恒在；2026-10-09 起它是可关的 [ModuleId.home]（用户反馈
/// 「首页没什么用但偏偏不给关」）。关掉后落地页改为第一个启用的 tab，首页工具栏
/// 上的入口迁到 设置 → 系统（见 `settings_schema_system.dart`）。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/models/store_compliance.dart';

/// 一个可被用户整体关闭的功能模块。
///
/// 顺序 = 设置页「功能模块」分区的展示顺序，也与底栏/侧栏的 tab 顺序同向
/// （库页 → 工具页 → 横切能力 → 设备数据）。
enum ModuleId {
  /// 首页 dashboard（继续 / 学习统计 / 活动 / 更新提醒）。可关：关掉后落地页改为
  /// 第一个启用的 tab；导航 tab 至少要留一个（见 `isLastNavigationModule`）。
  home('module_home_enabled'),

  /// 书架（EPUB / 字幕书阅读）。
  books('module_books_enabled'),

  /// 漫画库（漫画阅读器 + OCR + 在线目录）。
  manga('module_manga_enabled'),

  /// 视频库（播放器 + 番剧刮削 + 发现）。
  video('module_video_enabled'),

  /// 音乐库（曲库 / 专辑 / 播放 / 歌词，docs/specs/2026-10-23-music-module-design.md）。
  /// 独立底栏模块（设计 D1），与只管有声书的 [listening] 不合并；五端都有，不新增
  /// App Store 受限能力。
  music('module_music_enabled'),

  /// 游戏。Windows 上是本机 galgame 库与文本/语音捕获（galgame hook 平台边界）；
  /// Android / iOS / macOS / Linux 上是串流接收端的远端游戏库（从已配对 Windows
  /// 主机启动并串流）。iOS 上只有串流这一种形态，不属于 App Store 受限能力。
  /// 两种形态见 [GamesModuleForm]。
  games('module_games_enabled'),

  /// 浏览（Mihon 式 Browse）：三域在线来源、扩展目录、四域发现页与统一下载中心
  /// （torrent / 磁力 / 在线目录卷队列）。
  ///
  /// 2026-09-27 由「下载」改名而来：持久化键仍是历史名 `module_downloads_enabled`
  /// （**冻结不追改**）。
  browse('module_downloads_enabled'),

  /// 查词页与词典管理入口。
  ///
  /// 注意持久化键是历史名 `module_dictionaries_enabled`（**冻结不追改**）。
  /// 本模块关掉的是**页面入口**，不是查词能力：阅读器/视频/galgame 里的划词
  /// 弹窗、设置 → 查词 分类（词典导入管理、音频来源）一律保留。
  lookup('module_dictionaries_enabled'),

  /// 复习（Fushi 内置 SRS，FSRS-7 排程）：牌组、复习、笔记编辑与浏览。
  ///
  /// **出厂默认开**（[defaultEnabled]，所有者 2026-10-16「默认就是 fushi srs」，取代
  /// 10-14 的默认关）。升级上来的老用户由 `PreferencesRepository
  /// .settleSrsMiningTargetInstallDefault` 一次性显式写成关（老用户不提醒：自己去设置
  /// 打开才看得到）。新手引导不提供它的方格，由「复习方式」一步写入（选 Fushi 复习 =
  /// 开，见 `onboarding_steps.dart` 的 `OnboardingReviewMethod`）。
  srs('module_srs_enabled'),

  /// 浏览器：app 内浏览网站（通用浏览、网页视频站点、网页漫画）+ 浏览器扩展管理页
  /// 与本机扩展服务。**五端都有**；子页各自再按平台门控（见 `WebHubSection`，
  /// 浏览器扩展只在桌面，见 [browserExtensionSupportedOn]）。
  ///
  /// 2026-10-19 由「浏览器扩展」模块升级而来（用户：app 内浏览取代扩展成为主路径，
  /// 扩展降为次级子页；「改名成浏览器，这样就能重置一下这个开关」）：持久化键
  /// **刻意换新** `module_web_enabled`，旧键 `module_browser_extension_enabled`
  /// 不再读取——老用户关过扩展模块的，升级后这个新模块按出厂默认开。
  web('module_web_enabled'),

  /// 听书：有声书播放/导入、语音转录（ASR）、悬浮歌词。
  listening('module_listening_enabled'),

  /// 制卡：Anki（AnkiConnect / AnkiDroid）与查词弹窗上的制卡入口。
  cardCreation('module_card_creation_enabled'),

  /// 在线服务与追踪：第三方 API / 索引器 / 媒体服务器凭据 + 媒体追踪。
  services('module_services_enabled'),

  /// AI：用户自配的大模型提供商与全部 AI 辅助功能（AI 下载、刮削 AI 识别、
  /// 词典 / Lapis / 主题样式生成、galgame 文本处理规则生成、漫画 OCR 大模型
  /// 重读）。2026-10-13 起独立成模块（用户反馈「AI 用不着，想像首页那样整块
  /// 关掉」）；此前 AI 设置挂在 [services] 下、功能入口没有总开关。
  ///
  /// 关掉 = 「设置 › AI」整类不渲染 + 各页 AI 入口不渲染（UI 判据
  /// `isAiModuleEnabled`，见 `module_registry.dart`）+ 运行时每个
  /// `AiFeature` 都解析不到提供商（`PreferencesRepository.aiFeatureAssignments`
  /// 投影成空），行为与「从没配过 AI」完全一致，不发任何 AI 请求。已配的提供商与
  /// 指派原样保留，重新打开即恢复。
  ai('module_ai_enabled'),

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
  ///
  /// [isIOS] 单列而不是靠 `!isDesktop && !isAndroid` 推：它承载的不是「这个平台
  /// 做不做得到」，而是 App Store 的合规边界（见 [StoreRestrictedCapability]），
  /// 两者会在同一个平台上给出相反的答案——下载中心在 iOS 上技术可行（外接
  /// qBittorrent 是纯 HTTP），但不允许上架。
  ///
  /// [isAndroid] 目前没有模块按它区分（串流接收端已覆盖全部平台，见
  /// [GamesModuleForm]）；保留它让调用方始终给出完整的平台元组。
  bool availableOn({
    required bool isWindows,
    required bool isDesktop,
    required bool isIOS,
    required bool isAndroid,
  }) => switch (this) {
    // 每个平台都有 games 模块，只是形态不同（见 [GamesModuleForm.on]）。
    ModuleId.games => true,
    // 「浏览」装的是发现页、三域在线扩展源与通用 torrent / 磁力下载器，都不能进
    // App Store。判据不在这里写死，委托给合规边界的唯一真相源；各页签内的每个域
    // 仍各自再问对应的 [StoreRestrictedCapability]，两处若各判各的就会分头漂移。
    ModuleId.browse => StoreRestrictedCapability.downloads.availableOn(
      isIOS: isIOS,
    ),
    // 通用 app 内浏览器不属于 App Store 受限能力（受限的在线漫画源动作由子页自己问
    // [StoreRestrictedCapability.onlineMangaSource]）；浏览器扩展子页另按
    // [browserExtensionSupportedOn] 只在桌面出现。
    ModuleId.web => true,
    ModuleId.home ||
    ModuleId.books ||
    ModuleId.manga ||
    ModuleId.video ||
    ModuleId.music ||
    ModuleId.lookup ||
    // 复习不是 App Store 受限能力（纯本地数据 + 用户自己的同步后端），五端都有。
    ModuleId.srs ||
    ModuleId.listening ||
    ModuleId.cardCreation ||
    ModuleId.services ||
    ModuleId.ai ||
    ModuleId.sync => true,
  };

  /// 偏好里还没有这个键时的取值（出厂默认）。
  ///
  /// 全部默认开（[srs] 自 2026-10-16 起也默认开：新装默认就用 Fushi 复习；老用户的
  /// 「默认关」由一次性迁移显式写入，见 [srs] 的说明）。读取端
  /// （`PreferencesRepository.moduleEnabled`、偏好未就绪时的 `AppModel.moduleEnabled`）
  /// 与设置开关的 `defaultValue` 一律取这里，不各写一份。
  bool get defaultEnabled => switch (this) {
    ModuleId.srs ||
    ModuleId.home ||
    ModuleId.books ||
    ModuleId.manga ||
    ModuleId.video ||
    ModuleId.music ||
    ModuleId.games ||
    ModuleId.browse ||
    ModuleId.lookup ||
    ModuleId.web ||
    ModuleId.listening ||
    ModuleId.cardCreation ||
    ModuleId.services ||
    ModuleId.ai ||
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

  /// 用户排过的模块顺序（设置 → 外观 → 功能模块 里拖拽排序；底栏 / 侧栏 tab
  /// 按它排）。值是逗号分隔的 [prefKey]——用冻结的持久化键而不是 `.name`，枚举
  /// 改名（如 downloads → browse）不会把用户排好的顺序打乱。
  static const String orderPrefKey = 'module_nav_order';

  /// 启动页：打开 app 时落在哪个模块的 tab（设置 → 系统 → 启动页）。值是该模块的
  /// [prefKey]（与 [orderPrefKey] 同理用冻结键而非 `.name`），空串 = 默认（底栏
  /// 第一个可见页）。所选模块被关掉或平台上不存在时回退到默认，见 `homeInitialTab`。
  ///
  /// 取代旧开关 `startup_default_dictionary_tab`（「启动时打开查词」）：本键从未写过
  /// 时沿用旧开关（开着 = 查词），见 `PreferencesRepository.startupModule`。
  static const String startupPrefKey = 'startup_module';

  /// 「功能模块」全部设备本地键：开关 + 顺序 + 启动页。与开关同理，顺序与启动页描述
  /// 的是**这台设备**的入口布局，不随 Profile 走、不进备份（见 `profile_keys.dart`
  /// 与 `backup_service.dart` 的排除名单）。
  static Set<String> get devicePrefKeys => <String>{
    ...allPrefKeys,
    orderPrefKey,
    startupPrefKey,
  };

  /// 解析 [orderPrefKey] 的存储值。未知键（对端新模块 / 已删模块）与重复项直接
  /// 跳过，**绝不抛异常**；结果只是用户意愿，补全见 [orderModules]。
  static List<ModuleId> parseOrder(String? stored) {
    if (stored == null || stored.isEmpty) return const <ModuleId>[];
    final List<ModuleId> out = <ModuleId>[];
    for (final String key in stored.split(',')) {
      final ModuleId? id = tryParsePrefKey(key.trim());
      if (id != null && !out.contains(id)) out.add(id);
    }
    return out;
  }

  /// [orderPrefKey] 里「设置」tab 的位置标记（反馈 TqJ_xq3UlO：设置也要能拖）。
  /// 设置不是 [ModuleId]（它恒在、不可关），所以它在顺序里只是一个标记：不是任何
  /// 模块的 [prefKey]，旧版本的 [parseOrder] 把它当未知键跳过，设置回到最后。
  static const String settingsOrderToken = 'settings';

  /// [orderPrefKey] 存储值里「设置」排在第几个模块之前（= 它前面有几个能解析的
  /// 模块）；没有标记 = null（设置在最后）。与 [parseOrder] 同口径跳过未知键与重复项。
  static int? parseSettingsSlot(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    final List<ModuleId> seen = <ModuleId>[];
    for (final String raw in stored.split(',')) {
      final String key = raw.trim();
      if (key == settingsOrderToken) return seen.length;
      final ModuleId? id = tryParsePrefKey(key);
      if (id != null && !seen.contains(id)) seen.add(id);
    }
    return null;
  }

  /// [parseOrder] / [parseSettingsSlot] 的逆。[settingsSlot] 为 null 或不小于
  /// 模块数时不写标记（设置在最后，与没排过一样）。
  static String encodeOrder(Iterable<ModuleId> order, {int? settingsSlot}) {
    final List<String> keys = <String>[
      for (final ModuleId id in order) id.prefKey,
    ];
    if (settingsSlot != null &&
        settingsSlot >= 0 &&
        settingsSlot < keys.length) {
      keys.insert(settingsSlot, settingsOrderToken);
    }
    return keys.join(',');
  }
}

/// 把用户排过的顺序补全成**覆盖全部 [ModuleId] 的完整序列**：[preferred] 去重后
/// 打头，没排过的模块（新加的模块、旧版从没排过）按枚举顺序接在后面。空列表 =
/// 纯枚举顺序，即排序功能上线前的底栏顺序。
List<ModuleId> orderModules(Iterable<ModuleId> preferred) {
  final List<ModuleId> out = <ModuleId>[];
  for (final ModuleId id in preferred) {
    if (!out.contains(id)) out.add(id);
  }
  for (final ModuleId id in ModuleId.values) {
    if (!out.contains(id)) out.add(id);
  }
  return out;
}

/// [ModuleId.games] 在当前平台上的形态。
///
/// 同一个模块开关、同一个底栏 tab，两种截然不同的页面：Windows 是本机 galgame
/// 库（hook 注入、捕获工作台、兼容性诊断，另有「串流」子区接别的主机），其余平台
/// 是串流接收端（列出已配对 Windows 主机的游戏库，远程启动后直接串流）。平台判据
/// 只在 [on] 写一次，消费端问 [AppModel.gamesModuleForm]，不各自判平台。
enum GamesModuleForm {
  /// Windows：本机 galgame 库 + 文本/语音捕获。
  localLibrary,

  /// Android / iOS / macOS / Linux：远端主机游戏库 + 远程启动 + 串流接收。
  streamClient;

  /// 本平台上 games 模块的形态。galgame hook 与画面采集只做 Windows（见
  /// CLAUDE.md「Galgame Hook 硬规则」），其余平台只能当串流接收端。
  static GamesModuleForm on({required bool isWindows}) =>
      isWindows ? GamesModuleForm.localLibrary : GamesModuleForm.streamClient;
}

/// 「此刻哪些模块可见」的不可变快照：用户意愿（pref）与平台可用性的**唯一合成**。
///
/// 全 app 的门控一律读它，不再各自组合 pref + 平台。
@immutable
class ModuleVisibility {
  const ModuleVisibility(
    this.enabled, {
    this.order = const <ModuleId>[],
    this.settingsSlot,
  });

  /// 当前可见的模块集合。
  final Set<ModuleId> enabled;

  /// 用户排过的模块顺序（只是意愿：可含平台上不存在或被关掉的模块，也可不全）。
  /// 消费端读补全后的 [ordered]，不直接读本字段。
  final List<ModuleId> order;

  /// 全部模块的展示顺序（[order] 打头，余下按枚举顺序），底栏 / 侧栏 tab 顺序由
  /// 它导出（`homeActiveTabs`）。
  List<ModuleId> get ordered => orderModules(order);

  /// 「设置」tab 排在 [ordered] 的第几项之前；null = 最后（默认）。位置按**全部**
  /// 模块（含被关掉、平台上不存在的）计，开关模块不会让设置跳位。
  final int? settingsSlot;

  /// 导航 tab 的完整顺序：[ordered] 里插入一个 `null` 代表设置（恒在、恰好一次）。
  List<ModuleId?> get navOrder {
    final List<ModuleId?> out = <ModuleId?>[...ordered];
    final int? slot = settingsSlot;
    if (slot == null || slot < 0 || slot >= out.length) {
      out.add(null);
    } else {
      out.insert(slot, null);
    }
    return out;
  }

  /// 全部模块都可见（平台可用的那些）。仅供测试与默认值使用。
  factory ModuleVisibility.all({
    required bool isWindows,
    required bool isDesktop,
    required bool isIOS,
    required bool isAndroid,
  }) => ModuleVisibility.resolve(
    prefOf: (ModuleId _) => true,
    isWindows: isWindows,
    isDesktop: isDesktop,
    isIOS: isIOS,
    isAndroid: isAndroid,
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
    required bool isIOS,
    required bool isAndroid,
    List<ModuleId> order = const <ModuleId>[],
    int? settingsSlot,
  }) {
    final Set<ModuleId> enabled = <ModuleId>{};
    for (final ModuleId id in ModuleId.values) {
      if (!id.availableOn(
        isWindows: isWindows,
        isDesktop: isDesktop,
        isIOS: isIOS,
        isAndroid: isAndroid,
      )) {
        continue;
      }
      if (!prefOf(id)) continue;
      enabled.add(id);
    }
    return ModuleVisibility(enabled, order: order, settingsSlot: settingsSlot);
  }

  bool isEnabled(ModuleId id) => enabled.contains(id);

  /// `null` 视为「不属于任何模块」→ 恒可见。反向映射（`moduleOf*`）返回可空值，
  /// 消费端直接把结果喂进来即可，不必各自写 `?? true`。
  bool isEnabledOrUngated(ModuleId? id) => id == null || isEnabled(id);

  @override
  bool operator ==(Object other) =>
      other is ModuleVisibility &&
      setEquals(other.enabled, enabled) &&
      listEquals(other.navOrder, navOrder);

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(enabled), Object.hashAll(navOrder));

  @override
  String toString() =>
      'ModuleVisibility(${enabled.map((ModuleId e) => e.name).join(', ')})';
}

/// 浏览器扩展（「浏览器」模块的次级子页、扩展安装引导、扩展副本刷新）在本平台是否
/// 存在：手机浏览器不支持加载未解压扩展，故只在桌面。
///
/// 2026-10-19 前这条判据就是整个模块的 `availableOn`；模块改为五端都有后，扩展
/// 相关的消费端一律问这里，不各自写 `isDesktop`。
bool browserExtensionSupportedOn({required bool isDesktop}) => isDesktop;
