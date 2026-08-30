/// 新手引导的纯数据模型：功能多选 → 步骤序列的映射。
///
/// 与 UI 解耦成顶层纯函数，便于单测「选了哪些功能就出现哪些步骤、顺序稳定」，
/// 不必实例化整个向导页面（模式同 `home_page.dart` 的 [homeActiveTabs]）。
library;

/// 功能选择步骤里可勾选的项，分两类：
///
/// - **库页模块**（小说/漫画/视频/游戏/浏览器扩展）：勾选状态在离开功能选择
///   步骤时写进 `module_*_enabled` 偏好，未勾选的从底栏/侧栏隐藏（设置 → 外观 →
///   功能模块 可随时改回）。模块不产生引导步骤——唯一例外是浏览器扩展：它同时
///   门控「扩展安装引导」这一步（模块都不要了自然不必引导安装）。
/// - **配置能力**（资源准备/Anki/备份/互联）：勾选只决定向导后续走哪些配置步骤，
///   不写任何持久化开关。
enum OnboardingFeature {
  /// 小说库页（模块）。
  books,

  /// 漫画库页（模块）。
  manga,

  /// 视频库页（模块）。
  video,

  /// galgame 游戏库页（模块，仅 Windows 提供勾选）。
  games,

  /// 浏览器扩展 tab（模块，仅桌面提供勾选；同时门控扩展安装引导步骤）。
  browserExtension,

  /// 官方推荐包：日语推荐词典 + 日/英发音音频库（Fushi 备份 zip，向导内直接
  /// 下载导入）。
  recommendedPack,

  /// 不下载推荐包：手动导入词典，并按需导入有声书/配置发音来源。
  manualResources,

  /// Anki 制卡（AnkiConnect / AnkiDroid）。
  anki,

  /// 备份与同步（云端/自建后端 + 本地备份文件）。
  backup,

  /// 设备互联（局域网配对、共享书库/进度/查词）。
  interconnect,
}

/// 库页模块集合（勾选写 tab 显隐偏好；除 browserExtension 外不产生引导步骤）。
const Set<OnboardingFeature> kOnboardingModuleFeatures = <OnboardingFeature>{
  OnboardingFeature.books,
  OnboardingFeature.manga,
  OnboardingFeature.video,
  OnboardingFeature.games,
  OnboardingFeature.browserExtension,
};

/// 查词前的资源准备二选一：官方推荐包，或手动准备词典/音频。
const Set<OnboardingFeature> kOnboardingResourceFeatures = <OnboardingFeature>{
  OnboardingFeature.recommendedPack,
  OnboardingFeature.manualResources,
};

/// 功能选择页的一次点击。资源准备两项是单选，其余项维持普通多选。
Set<OnboardingFeature> toggleOnboardingFeature({
  required Set<OnboardingFeature> selected,
  required OnboardingFeature feature,
}) {
  final Set<OnboardingFeature> next = Set<OnboardingFeature>.of(selected);
  if (kOnboardingResourceFeatures.contains(feature)) {
    return next
      ..removeAll(kOnboardingResourceFeatures)
      ..add(feature);
  }
  if (!next.remove(feature)) next.add(feature);
  return next;
}

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
  backup,
  interconnect,

  /// 浏览器扩展安装引导（仅桌面）。
  browserExtension,

  /// 阅读字体配置。
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
/// [OnboardingStepId.fonts] 和 [OnboardingStepId.finish] 固定收尾；中间配置步骤按
/// 固定顺序（资源准备 → Anki → 备份 → 互联 → 扩展）出现：能力步骤只保留被
/// 勾选的，
/// 浏览器扩展安装引导步骤 = [browserExtensionAvailable]（桌面平台）**且**扩展
/// 模块被勾选。其余库页模块勾选不产生步骤。
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
  return <OnboardingStepId>[
    OnboardingStepId.welcome,
    OnboardingStepId.features,
    if (selected.contains(OnboardingFeature.recommendedPack))
      OnboardingStepId.recommendedPack,
    if (selected.contains(OnboardingFeature.manualResources))
      OnboardingStepId.manualResources,
    if (selected.contains(OnboardingFeature.anki)) OnboardingStepId.anki,
    if (selected.contains(OnboardingFeature.backup)) OnboardingStepId.backup,
    if (selected.contains(OnboardingFeature.interconnect))
      OnboardingStepId.interconnect,
    if (browserExtensionAvailable &&
        selected.contains(OnboardingFeature.browserExtension))
      OnboardingStepId.browserExtension,
    OnboardingStepId.fonts,
    if (resourcesSelected) OnboardingStepId.clickLookup,
    if (resourcesSelected && globalLookupAvailable)
      OnboardingStepId.globalLookup,
    if (resourcesSelected &&
        selected.contains(OnboardingFeature.anki) &&
        ankiReady)
      OnboardingStepId.firstAnkiCard,
    OnboardingStepId.finish,
  ];
}
