/// 新手引导的纯数据模型：功能多选 → 步骤序列的映射。
///
/// 与 UI 解耦成顶层纯函数，便于单测「选了哪些功能就出现哪些步骤、顺序稳定」，
/// 不必实例化整个向导页面（模式同 `home_page.dart` 的 [homeActiveTabs]）。
library;

import 'package:fushi/src/models/module_id.dart';

/// 功能选择步骤里可勾选的项，分两类：
///
/// - **功能模块**（[ModuleId] 全部 11 个）：勾选状态在离开功能选择步骤时写进
///   `module_*_enabled` 偏好，未勾选的模块整套入口都不再露出（底栏/侧栏 tab、
///   设置一级分类、快捷键分区、首页聚合；设置 → 外观 → 功能模块 可随时改回）。
///   模块本身**不产生**引导步骤，但它是本模块名下配置步骤的总闸：模块都不要了，
///   向导就不该再拉着用户配它（扩展安装 / Anki / 备份 / 互联 / 应用外查词）。
/// - **配置能力**（资源准备/Anki/字体/备份/互联）：勾选只决定向导后续走哪些配置
///   步骤，不写任何持久化开关。
///
/// 两类的对应关系是**一张表**（[onboardingFeatureOfModule]），不是散在各处的
/// `if`：加模块时编译器强制在那张表里补齐，`kOnboardingModuleFeatures` 与反查
/// 都从它推导。
enum OnboardingFeature {
  /// 小说库页（模块）。
  books,

  /// 漫画库页（模块）。
  manga,

  /// 视频库页（模块）。
  video,

  /// galgame 游戏库页（模块，仅 Windows 提供勾选）。
  games,

  /// 下载中心（模块）。
  downloads,

  /// 查词页（模块）。注意关掉它只关**页面入口**，划词查词能力全留。
  lookup,

  /// 浏览器扩展 tab（模块，仅桌面提供勾选；同时门控扩展安装引导步骤）。
  browserExtension,

  /// 听书：有声书播放/导入、语音转录、悬浮歌词（模块）。
  listening,

  /// 制卡：Anki 集成（模块）。门控下面的 [anki] 配置步骤。
  cardCreation,

  /// 在线服务与媒体追踪（模块）。
  services,

  /// 同步备份 + 设备互联（模块）。门控下面的 [backup] / [interconnect] 步骤。
  sync,

  /// 官方推荐包：日语推荐词典 + 日/英发音音频库（Fushi 备份 zip，向导内直接
  /// 下载导入）。
  recommendedPack,

  /// 手动补充资源：导入词典，并按需导入有声书/配置发音来源；可与推荐包同时选。
  manualResources,

  /// Anki 制卡（AnkiConnect / AnkiDroid）。
  anki,

  /// 在线服务账号与 API 配置总览；默认不选，仅展示配置教程。
  onlineServices,

  /// 自定义字体（界面/正文/词典）。默认勾选；不勾则向导不出现字体步骤。
  fonts,

  /// 备份与同步（云端/自建后端 + 本地备份文件）。
  backup,

  /// 设备互联（局域网配对、共享书库/进度/查词）。
  interconnect,
}

/// 配置能力的默认教程选择；不控制服务启用，也不读取或修改已有账号。
const Set<OnboardingFeature> kOnboardingDefaultCapabilities =
    <OnboardingFeature>{
  OnboardingFeature.recommendedPack,
  OnboardingFeature.anki,
  OnboardingFeature.fonts,
};

/// [ModuleId] → 功能选择步骤里代表它的勾选项。**穷尽 switch**：加模块时编译器
/// 强制在这里补齐，向导的模块方格、写回 `module_*_enabled` 的循环与下面的步骤
/// 总闸全部从这一张表推导，不会再出现「加了模块但向导只认 5 个」的漂移。
OnboardingFeature onboardingFeatureOfModule(ModuleId module) =>
    switch (module) {
      ModuleId.books => OnboardingFeature.books,
      ModuleId.manga => OnboardingFeature.manga,
      ModuleId.video => OnboardingFeature.video,
      ModuleId.games => OnboardingFeature.games,
      ModuleId.downloads => OnboardingFeature.downloads,
      ModuleId.lookup => OnboardingFeature.lookup,
      ModuleId.browserExtension => OnboardingFeature.browserExtension,
      ModuleId.listening => OnboardingFeature.listening,
      ModuleId.cardCreation => OnboardingFeature.cardCreation,
      ModuleId.services => OnboardingFeature.services,
      ModuleId.sync => OnboardingFeature.sync,
    };

/// [onboardingFeatureOfModule] 的反查，**由它推导**而不是再手写一张表。
final Map<OnboardingFeature, ModuleId> _moduleOfFeature =
    <OnboardingFeature, ModuleId>{
      for (final ModuleId module in ModuleId.values)
        onboardingFeatureOfModule(module): module,
    };

/// 勾选项所属的功能模块；`null` = 纯配置能力（不写任何持久化开关）。
ModuleId? moduleOfOnboardingFeature(OnboardingFeature feature) =>
    _moduleOfFeature[feature];

/// 模块勾选项集合（勾选写 `module_*_enabled` 偏好；模块自身不产生引导步骤，但
/// 门控本模块名下的配置步骤）。从 [onboardingFeatureOfModule] 推导，不手抄。
final Set<OnboardingFeature> kOnboardingModuleFeatures = _moduleOfFeature.keys
    .toSet();

/// 能为查词教程提供词典资源的路径；两项独立多选，不互斥。
const Set<OnboardingFeature> kOnboardingResourceFeatures = <OnboardingFeature>{
  OnboardingFeature.recommendedPack,
  OnboardingFeature.manualResources,
};

/// 第一张 Anki 卡教程的真实就绪判据。仅有旧的非空选择 id 不够：本次必须连接
/// 成功，且两个 id 都仍存在于本次拉回的列表中。
bool onboardingAnkiSelectionReady({
  required bool connectionVerified,
  required int? selectedDeckId,
  required int? selectedNoteTypeId,
  required Iterable<int> availableDeckIds,
  required Iterable<int> availableNoteTypeIds,
}) {
  return connectionVerified &&
      selectedDeckId != null &&
      selectedNoteTypeId != null &&
      availableDeckIds.contains(selectedDeckId) &&
      availableNoteTypeIds.contains(selectedNoteTypeId);
}

/// 向导步骤身份（枚举身份而非整数索引，插入/裁剪步骤不会打乱路由判断）。
enum OnboardingStepId {
  /// 欢迎 + 界面语言/明暗主题（复用外观设置的行选择器）。
  welcome,

  /// 功能多选（库页模块 + 配置能力）。
  features,

  /// 推荐包下载与导入。
  recommendedPack,

  /// 手动导入词典、有声书与发音来源。
  manualResources,
  anki,
  onlineServices,
  backup,
  interconnect,

  /// 浏览器扩展安装引导（仅桌面）。
  browserExtension,

  /// 自定义字体配置（仅 [OnboardingFeature.fonts] 被勾选时）。
  fonts,

  /// 应用内点击文字查词的操作教程（全平台）。
  clickLookup,

  /// 应用外全局查词的操作教程（当前仅 Windows / Android 有完整入口）。
  globalLookup,

  /// 完成第一张 Anki 卡片（仅本次向导已验证连接并选好牌组/笔记类型时）。
  firstAnkiCard,
  finish,
}

/// 给定勾选集合与平台能力，返回向导要走的步骤序列。
///
/// 恒以 [OnboardingStepId.welcome]、[OnboardingStepId.features] 开头，
/// [OnboardingStepId.finish] 固定收尾；中间配置步骤按固定顺序（资源准备 → Anki →
/// 备份 → 互联 → 扩展 → 字体）出现：能力步骤（含字体）只保留被勾选的，
/// 浏览器扩展安装引导步骤 = [browserExtensionAvailable]（桌面平台）**且**扩展
/// 模块被勾选。模块勾选自身不产生步骤。
///
/// **模块是本模块名下配置步骤的总闸**（用户拍板的「关一个模块 = 关掉它的全部
/// 入口」在向导里的落法）：这里是这四条深链唯一的装配处，漏掉一条就等于用户在
/// 上一步刚把模块关掉、下一步向导又把它的配置页推到脸上。
/// - [OnboardingFeature.cardCreation] 关 → 不出 [OnboardingStepId.anki]，
///   也不出 [OnboardingStepId.firstAnkiCard]；
/// - [OnboardingFeature.sync] 关 → 不出 [OnboardingStepId.backup] /
///   [OnboardingStepId.interconnect]；
/// - [OnboardingFeature.browserExtension] 关 → 不出扩展安装引导（原有行为）；
/// - [OnboardingFeature.lookup] 关 → 不出 [OnboardingStepId.globalLookup]。
///   只砍**应用外**全局取词（它与 `ShortcutScope.globalExternal` 同属 lookup
///   模块，关掉时连系统热键都不该装）；[OnboardingStepId.clickLookup] 教的是
///   划词弹窗这一**能力**，按用户定的例外一律保留。
///
/// 点击/全局查词教程只有在两种资源准备路径至少选中一种时出现；全局查词还要求
/// [globalLookupAvailable]（当前 Windows / Android）。第一张 Anki 卡教程再加一道
/// [ankiReady] 门：本次向导真实连接成功，并且当前选择的牌组/笔记类型可用。
List<OnboardingStepId> onboardingStepSequence({
  required Set<OnboardingFeature> selected,
  required bool browserExtensionAvailable,
  required bool globalLookupAvailable,
  required bool ankiReady,
}) {
  final bool resourcesSelected = selected.any(
    kOnboardingResourceFeatures.contains,
  );
  // 配置能力 + 它所属模块，两道门都过才出步骤。
  final bool ankiSelected =
      selected.contains(OnboardingFeature.anki) &&
      selected.contains(OnboardingFeature.cardCreation);
  final bool syncModuleOn = selected.contains(OnboardingFeature.sync);
  return <OnboardingStepId>[
    OnboardingStepId.welcome,
    OnboardingStepId.features,
    if (selected.contains(OnboardingFeature.recommendedPack))
      OnboardingStepId.recommendedPack,
    if (selected.contains(OnboardingFeature.manualResources))
      OnboardingStepId.manualResources,
    if (ankiSelected) OnboardingStepId.anki,
    // 「在线服务」配置步骤同受它所属模块的总闸约束（与 anki/backup/interconnect
    // 同一范式）：模块都关了，向导不该再把它的配置页推到用户脸上。
    if (selected.contains(OnboardingFeature.services) &&
        selected.contains(OnboardingFeature.onlineServices))
      OnboardingStepId.onlineServices,
    if (syncModuleOn && selected.contains(OnboardingFeature.backup))
      OnboardingStepId.backup,
    if (syncModuleOn && selected.contains(OnboardingFeature.interconnect))
      OnboardingStepId.interconnect,
    if (browserExtensionAvailable &&
        selected.contains(OnboardingFeature.browserExtension))
      OnboardingStepId.browserExtension,
    if (selected.contains(OnboardingFeature.fonts)) OnboardingStepId.fonts,
    if (resourcesSelected) OnboardingStepId.clickLookup,
    if (resourcesSelected &&
        globalLookupAvailable &&
        selected.contains(OnboardingFeature.lookup))
      OnboardingStepId.globalLookup,
    if (resourcesSelected && ankiSelected && ankiReady)
      OnboardingStepId.firstAnkiCard,
    OnboardingStepId.finish,
  ];
}

/// Imported resources need only the operation tutorials, never setup preferences.
List<OnboardingStepId> onboardingTutorialStepSequence({
  required bool globalLookupAvailable,
}) =>
    <OnboardingStepId>[
      OnboardingStepId.clickLookup,
      if (globalLookupAvailable) OnboardingStepId.globalLookup,
      OnboardingStepId.finish,
    ];

/// Records explicit Next actions, not merely visiting a page or leaving via Skip.
class OnboardingTutorialProgress {
  final Set<OnboardingStepId> _completed = <OnboardingStepId>{};

  void completeStep(OnboardingStepId step) {
    if (_isTutorial(step)) _completed.add(step);
  }

  bool shouldMarkCompleted({
    required List<OnboardingStepId> steps,
    required bool finished,
  }) {
    final List<OnboardingStepId> tutorials = steps.where(_isTutorial).toList();
    return finished &&
        tutorials.isNotEmpty &&
        tutorials.every(_completed.contains);
  }

  static bool _isTutorial(OnboardingStepId step) =>
      step == OnboardingStepId.clickLookup ||
      step == OnboardingStepId.globalLookup ||
      step == OnboardingStepId.firstAnkiCard;
}
