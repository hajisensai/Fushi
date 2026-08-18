/// 新手引导的纯数据模型：功能多选 → 步骤序列的映射。
///
/// 与 UI 解耦成顶层纯函数，便于单测「选了哪些功能就出现哪些步骤、顺序稳定」，
/// 不必实例化整个向导页面（模式同 `home_page.dart` 的 [homeActiveTabs]）。
library;

/// 功能选择步骤里可勾选的项，分两类：
///
/// - **库页模块**（[isModule] == true，漫画/视频/游戏）：勾选状态在离开功能选择
///   步骤时写进 `module_*_enabled` 偏好，未勾选的从底栏/侧栏隐藏（设置 → 系统 →
///   功能模块 可随时改回）。模块不产生引导步骤。
/// - **配置能力**（推荐包/Anki/备份/互联）：勾选只决定向导后续走哪些配置步骤，
///   不写任何持久化开关。
enum OnboardingFeature {
  /// 漫画库页（模块）。
  manga,

  /// 视频库页（模块）。
  video,

  /// galgame 游戏库页（模块，仅 Windows 提供勾选）。
  games,

  /// 官方推荐包：日语推荐词典 + 日/英发音音频库（Fushi 备份 zip，向导内直接
  /// 下载导入）。
  recommendedPack,

  /// Anki 制卡（AnkiConnect / AnkiDroid）。
  anki,

  /// 备份与同步（云端/自建后端 + 本地备份文件）。
  backup,

  /// 设备互联（局域网配对、共享书库/进度/查词）。
  interconnect,
}

/// 库页模块集合（勾选写 tab 显隐偏好，不产生引导步骤）。
const Set<OnboardingFeature> kOnboardingModuleFeatures = <OnboardingFeature>{
  OnboardingFeature.manga,
  OnboardingFeature.video,
  OnboardingFeature.games,
};

/// 向导步骤身份（枚举身份而非整数索引，插入/裁剪步骤不会打乱路由判断）。
enum OnboardingStepId {
  /// 欢迎 + 界面语言/明暗主题（复用外观设置的行选择器）。
  welcome,

  /// 功能多选（库页模块 + 配置能力）。
  features,

  /// 推荐包下载与导入。
  recommendedPack,
  anki,
  backup,
  interconnect,

  /// 浏览器扩展安装引导（仅桌面）。
  browserExtension,

  /// 阅读字体配置。
  fonts,
  finish,
}

/// 给定勾选集合与平台能力，返回向导要走的步骤序列。
///
/// 恒以 [OnboardingStepId.welcome]、[OnboardingStepId.features] 开头，
/// [OnboardingStepId.fonts]、[OnboardingStepId.finish] 结尾；中间配置步骤按固定
/// 顺序（推荐包 → Anki → 备份 → 互联 → 扩展）出现：能力步骤只保留被勾选的，
/// 浏览器扩展步骤由 [browserExtensionAvailable]（桌面平台）门控。库页模块勾选
/// 不产生步骤。
List<OnboardingStepId> onboardingStepSequence({
  required Set<OnboardingFeature> selected,
  required bool browserExtensionAvailable,
}) {
  return <OnboardingStepId>[
    OnboardingStepId.welcome,
    OnboardingStepId.features,
    if (selected.contains(OnboardingFeature.recommendedPack))
      OnboardingStepId.recommendedPack,
    if (selected.contains(OnboardingFeature.anki)) OnboardingStepId.anki,
    if (selected.contains(OnboardingFeature.backup)) OnboardingStepId.backup,
    if (selected.contains(OnboardingFeature.interconnect))
      OnboardingStepId.interconnect,
    if (browserExtensionAvailable) OnboardingStepId.browserExtension,
    OnboardingStepId.fonts,
    OnboardingStepId.finish,
  ];
}
