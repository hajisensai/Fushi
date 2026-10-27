/// 新手引导的纯数据模型：功能多选 → 步骤序列的映射。
///
/// 与 UI 解耦成顶层纯函数，便于单测「选了哪些功能就出现哪些步骤、顺序稳定」，
/// 不必实例化整个向导页面（模式同 `home_page.dart` 的 [homeActiveTabs]）。
library;

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';

/// 功能选择步骤里可勾选的项，分两类：
///
/// - **功能模块**（[ModuleId] 中除首页外的 11 个）：勾选状态在离开功能选择步骤时写进
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

  /// 浏览（模块）：在线来源 / 扩展 / 发现 / 下载。
  browse,

  /// 查词页（模块）。注意关掉它只关**页面入口**，划词查词能力全留。
  lookup,

  /// 浏览器扩展 tab（模块，仅桌面提供勾选；同时门控扩展安装引导步骤）。
  web,

  /// 听书：有声书播放/导入、语音转录、悬浮歌词（模块）。
  listening,

  /// 制卡（模块）。门控下面的 [anki] 配置能力（复习方式 + Anki 配置步骤）。
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

  /// 制卡与复习：先选复习方式（[OnboardingReviewMethod]），选 Anki 再出 Anki 配置步骤。
  /// 枚举名沿用 `anki`（只活在内存里，不持久化）。
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
///
/// 首页（[ModuleId.home]）与 AI（[ModuleId.ai]）返回 `null`：它们不是向导里「要不
/// 要这项功能」的选择，向导不出方格、也不改写它们（只在 设置 → 外观 → 功能模块
/// 里关）。
OnboardingFeature? onboardingFeatureOfModule(ModuleId module) =>
    switch (module) {
      ModuleId.home => null,
      ModuleId.books => OnboardingFeature.books,
      ModuleId.manga => OnboardingFeature.manga,
      ModuleId.video => OnboardingFeature.video,
      // 音乐（2026-10 新模块）向导暂不出方格：默认开，关在 设置 → 外观 → 功能模块。
      ModuleId.music => null,
      ModuleId.games => OnboardingFeature.games,
      ModuleId.browse => OnboardingFeature.browse,
      ModuleId.lookup => OnboardingFeature.lookup,
      // 复习不出方格：开关由「复习方式」一步写入（选 Fushi 复习 = 开、选 Anki = 关，
      // 见 [OnboardingReviewMethod]），不让用户在两个地方回答同一个问题。
      ModuleId.srs => null,
      ModuleId.web => OnboardingFeature.web,
      ModuleId.listening => OnboardingFeature.listening,
      ModuleId.cardCreation => OnboardingFeature.cardCreation,
      ModuleId.services => OnboardingFeature.services,
      // AI 默认开、向导不问：新装用户还没配任何提供商，AI 入口点了只引导去配置，
      // 「要不要 AI」不是首启该回答的问题。关 AI 在 设置 → 外观 → 功能模块。
      ModuleId.ai => null,
      ModuleId.sync => OnboardingFeature.sync,
    };

/// [onboardingFeatureOfModule] 的反查，**由它推导**而不是再手写一张表。
final Map<OnboardingFeature, ModuleId> _moduleOfFeature =
    <OnboardingFeature, ModuleId>{
      for (final ModuleId module in ModuleId.values)
        if (onboardingFeatureOfModule(module) case final OnboardingFeature f)
          f: module,
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

/// 欢迎步里的「用 Fushi 做什么」：不是人人都学外语，只看书 / 看番 / 听书的用户用不上
/// 查词、制卡、复习这一整条链路。它只是下一步功能方格的**预设**，选完仍可逐项改。
enum OnboardingUsagePurpose {
  /// 学外语：查词 → 制卡 → 复习整条链路照常（出厂形态）。
  languageLearning,

  /// 只看书、看番、听书：预先取消 [kOnboardingLanguageLearningFeatures]，并关复习模块
  /// （见 [onboardingSrsModuleOverride]）。
  mediaOnly,
}

/// 只服务于学外语的勾选项：查词页、制卡两个模块 + 词典资源与制卡复习两项配置。
/// 复习模块（`ModuleId.srs`）不出方格，单独由 [onboardingSrsModuleOverride] 处理。
const Set<OnboardingFeature> kOnboardingLanguageLearningFeatures =
    <OnboardingFeature>{
      OnboardingFeature.lookup,
      OnboardingFeature.cardCreation,
      OnboardingFeature.recommendedPack,
      OnboardingFeature.manualResources,
      OnboardingFeature.anki,
    };

/// 选了 [purpose] 之后的勾选集。只动学外语那几项，其余（库页、字体、同步……）保留
/// 用户已有的选择：
/// - [OnboardingUsagePurpose.mediaOnly]：去掉 [kOnboardingLanguageLearningFeatures]；
/// - [OnboardingUsagePurpose.languageLearning]：补回查词 / 制卡模块与出厂默认的
///   配置能力（推荐包 + 制卡与复习），手动资源保持原样（它本来就默认不勾）。
Set<OnboardingFeature> onboardingSelectionForPurpose(
  OnboardingUsagePurpose purpose,
  Set<OnboardingFeature> current,
) => switch (purpose) {
  OnboardingUsagePurpose.mediaOnly => current.difference(
    kOnboardingLanguageLearningFeatures,
  ),
  OnboardingUsagePurpose.languageLearning => <OnboardingFeature>{
    ...current,
    OnboardingFeature.lookup,
    OnboardingFeature.cardCreation,
    ...kOnboardingDefaultCapabilities.intersection(
      kOnboardingLanguageLearningFeatures,
    ),
  },
};

/// 用途的初值 = 用户此刻的状态：查词页和制卡两个模块**都关着**才算只看媒体（从设置
/// 重开向导的老用户看到的是自己上次的选择）；全新安装两者默认开 → 学外语。
OnboardingUsagePurpose onboardingUsagePurposeOf({
  required bool lookupModuleEnabled,
  required bool cardCreationModuleEnabled,
}) => !lookupModuleEnabled && !cardCreationModuleEnabled
    ? OnboardingUsagePurpose.mediaOnly
    : OnboardingUsagePurpose.languageLearning;

/// 复习模块在离开功能选择步骤时要不要被改写：只看媒体且制卡没勾 → `false`（关）；
/// 其余返回 `null` = 不碰，交给「复习方式」一步（制卡勾着时它会出现并写入）。
bool? onboardingSrsModuleOverride({
  required OnboardingUsagePurpose purpose,
  required Set<OnboardingFeature> selected,
}) =>
    purpose == OnboardingUsagePurpose.mediaOnly &&
        !selected.contains(OnboardingFeature.cardCreation)
    ? false
    : null;

/// 新手引导里「制卡后自动按词频重排」开关的初值：**开**。Fushi 复习路径（复习方式
/// 一步）与 Anki 路径（Anki 步）各摆一颗，共用这一个初值与同一个设置
/// （所有者 2026-10-20：「走新手教程那步的时候默认开启」）。
///
/// 设置本身（`AnkiSettings.autoRepositionEnabled`）默认关，因为它会在用户没点
/// 任何按钮时改新卡顺序，不能是升级送的；但引导里用户看得见这颗开关，
/// 照着默认走下一步就是显式选择。新卡按常见词优先学是绝大多数人想要的顺序，
/// 而手机端用户此前几乎不会知道有这个功能。
const bool kOnboardingAutoRepositionDefault = true;

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

/// 「复习方式」：查词制出的卡在哪里复习（所有者 2026-10-16）。
///
/// [fushi] 是主路径、默认选中、直接呈现；[anki] 收在「改用 Anki」折叠里（所有者：
/// 「anki 放到折叠里面，或者次级显示」）。两者不加「推荐」之类的比较用语。
enum OnboardingReviewMethod {
  /// Fushi 内置复习：开复习模块、挖词目标 = Fushi 复习、笔记类型用默认（Fushi 卡片）。
  /// 不出任何 Anki 专属步骤。
  fushi,

  /// 发往 Anki：沿用原有的 Anki 配置步骤（连接 / 牌组 / 笔记类型 / Lapis / FSRS 教程）
  /// 与「第一张 Anki 卡」教程。
  anki,
}

/// 「复习方式」一步的初值：**恒为 Fushi 复习**（所有者 2026-10-20：「新手教程从默认
/// anki 改成默认 fushi 复习」）。此前按用户此刻的状态推断，老用户重开向导看到的是
/// Anki；现在一律从 Fushi 起步，要用 Anki 的展开折叠点选。初值不在进页时写入：离开
/// 这一步（按下一步）或点选时才写（见 [applyOnboardingReviewMethod]）。
const OnboardingReviewMethod kOnboardingDefaultReviewMethod =
    OnboardingReviewMethod.fushi;

/// 「复习方式」的写入：用户点选时立即写（跳过向导也不丢），离开这一步时按当前选择再
/// 写一次（照着默认直接按下一步的用户也算显式选择）。
///
/// - [OnboardingReviewMethod.fushi]：开复习模块、挖词目标 = Fushi 复习，再调
///   [adoptFushiCard] 把制卡笔记类型落到内置 Fushi 卡片（生产实现只把旧默认 Lapis 换掉，
///   用户自建的笔记类型不动）。
/// - [OnboardingReviewMethod.anki]：挖词目标 = Anki、关复习模块（与升级上来的老用户
///   同一形态：只在设置里能找到 Fushi 复习）。
///
/// 写入经回调（生产是 `AppModel.setModuleEnabled` / `AppModel.setSrsMiningTarget`），
/// 便于单测断言不起整个 AppModel。
Future<void> applyOnboardingReviewMethod(
  OnboardingReviewMethod method, {
  required Future<void> Function(ModuleId module, bool enabled)
  setModuleEnabled,
  required Future<void> Function(SrsMiningTarget target) setMiningTarget,
  Future<void> Function()? adoptFushiCard,
}) async {
  switch (method) {
    case OnboardingReviewMethod.fushi:
      await setMiningTarget(SrsMiningTarget.srs);
      await setModuleEnabled(ModuleId.srs, true);
      if (adoptFushiCard != null) await adoptFushiCard();
    case OnboardingReviewMethod.anki:
      await setMiningTarget(SrsMiningTarget.anki);
      await setModuleEnabled(ModuleId.srs, false);
  }
}

/// 向导步骤身份（枚举身份而非整数索引，插入/裁剪步骤不会打乱路由判断）。
enum OnboardingStepId {
  /// 欢迎 + 界面语言/明暗主题（复用外观设置的行选择器）。
  welcome,

  /// 功能多选（库页模块 + 配置能力）。
  features,

  /// 系统权限（仅 Android）：通知 / 悬浮窗 / 所有文件访问，安卓默认关着其中几项。
  permissions,

  /// 推荐包下载与导入。
  recommendedPack,

  /// 手动导入词典、有声书与发音来源。
  manualResources,

  /// 复习方式（Fushi 复习 / Anki），制卡相关步骤的第一步。
  reviewMethod,

  /// Anki 配置（仅复习方式选了 Anki）。
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

  /// Fushi 内置复习（SRS）介绍：复习方式选了 Fushi 复习时出现；没走复习方式一步
  /// （制卡没勾）时，复习模块已经开着也出现。
  srs,
  finish,
}

/// 给定勾选集合与平台能力，返回向导要走的步骤序列。
///
/// 恒以 [OnboardingStepId.welcome]、[OnboardingStepId.features] 开头，
/// [OnboardingStepId.finish] 固定收尾；中间配置步骤按固定顺序（资源准备 → 复习方式 / Anki →
/// 备份 → 互联 → 扩展 → 字体）出现：能力步骤（含字体）只保留被勾选的，
/// 浏览器扩展安装引导步骤 = [browserExtensionAvailable]（桌面平台）**且**扩展
/// 模块被勾选。模块勾选自身不产生步骤。
///
/// **模块是本模块名下配置步骤的总闸**（用户拍板的「关一个模块 = 关掉它的全部
/// 入口」在向导里的落法）：这里是这四条深链唯一的装配处，漏掉一条就等于用户在
/// 上一步刚把模块关掉、下一步向导又把它的配置页推到脸上。
/// - [OnboardingFeature.cardCreation] 关 → 不出 [OnboardingStepId.reviewMethod] /
///   [OnboardingStepId.anki]，
///   也不出 [OnboardingStepId.firstAnkiCard]；
/// - [OnboardingFeature.sync] 关 → 不出 [OnboardingStepId.backup] /
///   [OnboardingStepId.interconnect]；
/// - [OnboardingFeature.web] 关 → 不出扩展安装引导（原有行为）；
/// - [OnboardingFeature.lookup] 关 → 不出 [OnboardingStepId.globalLookup]。
///   只砍**应用外**全局取词（它与 `ShortcutScope.globalExternal` 同属 lookup
///   模块，关掉时连系统热键都不该装）；[OnboardingStepId.clickLookup] 教的是
///   划词弹窗这一**能力**，按用户定的例外一律保留。
///
/// 点击/全局查词教程只有在两种资源准备路径至少选中一种时出现；全局查词还要求
/// [globalLookupAvailable]（当前 Windows / Android）。第一张 Anki 卡教程再加一道
/// [ankiReady] 门：本次向导真实连接成功，并且当前选择的牌组/笔记类型可用。
///
/// **复习方式**（[reviewMethod]）：制卡相关步骤以 [OnboardingStepId.reviewMethod] 开头。
/// 选 [OnboardingReviewMethod.fushi] 时**跳过全部 Anki 专属步骤**——
/// [OnboardingStepId.anki]（后端 / AnkiConnect 插件 / AnkiDroid 权限与安装 / 牌组与
/// 笔记类型 / Lapis / 词频重排 / Anki 里开 FSRS 的教程）和
/// [OnboardingStepId.firstAnkiCard]——改出 [OnboardingStepId.srs] 介绍；两边通用的
/// 点击查词教程（含「点 + 制卡」）照常保留。选 [OnboardingReviewMethod.anki] 则与原
/// 流程逐步一致。
///
/// [srsEnabled]：复习模块（`ModuleId.srs`）此刻是否开着。只在**没有**复习方式一步时
/// （制卡模块或制卡能力没勾）决定要不要出 [OnboardingStepId.srs] 介绍。
///
/// [systemPermissionsAvailable]：本平台有需要用户手动开的系统权限（当前仅 Android，
/// 用户 2026-10-21：「有些权限比如通知是默认关闭的」）。紧跟功能选择出现——后面
/// 推荐包下载的进度通知就要用到通知权限。
List<OnboardingStepId> onboardingStepSequence({
  required Set<OnboardingFeature> selected,
  required bool browserExtensionAvailable,
  required bool globalLookupAvailable,
  required bool ankiReady,
  OnboardingReviewMethod reviewMethod = OnboardingReviewMethod.fushi,
  bool srsEnabled = false,
  bool systemPermissionsAvailable = false,
}) {
  final bool resourcesSelected = selected.any(
    kOnboardingResourceFeatures.contains,
  );
  // 配置能力 + 它所属模块，两道门都过才出步骤。
  final bool cardReviewSelected =
      selected.contains(OnboardingFeature.anki) &&
      selected.contains(OnboardingFeature.cardCreation);
  final bool ankiSelected =
      cardReviewSelected && reviewMethod == OnboardingReviewMethod.anki;
  final bool srsIntro = cardReviewSelected
      ? reviewMethod == OnboardingReviewMethod.fushi
      : srsEnabled;
  final bool syncModuleOn = selected.contains(OnboardingFeature.sync);
  return <OnboardingStepId>[
    OnboardingStepId.welcome,
    OnboardingStepId.features,
    if (systemPermissionsAvailable) OnboardingStepId.permissions,
    if (selected.contains(OnboardingFeature.recommendedPack))
      OnboardingStepId.recommendedPack,
    if (selected.contains(OnboardingFeature.manualResources))
      OnboardingStepId.manualResources,
    if (cardReviewSelected) OnboardingStepId.reviewMethod,
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
    if (browserExtensionAvailable && selected.contains(OnboardingFeature.web))
      OnboardingStepId.browserExtension,
    if (selected.contains(OnboardingFeature.fonts)) OnboardingStepId.fonts,
    if (resourcesSelected) OnboardingStepId.clickLookup,
    if (resourcesSelected &&
        globalLookupAvailable &&
        selected.contains(OnboardingFeature.lookup))
      OnboardingStepId.globalLookup,
    if (resourcesSelected && ankiSelected && ankiReady)
      OnboardingStepId.firstAnkiCard,
    if (srsIntro) OnboardingStepId.srs,
    OnboardingStepId.finish,
  ];
}

/// Imported resources need only the operation tutorials, never setup preferences.
List<OnboardingStepId> onboardingTutorialStepSequence({
  required bool globalLookupAvailable,
}) => <OnboardingStepId>[
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
