import 'dart:io';

import 'package:fushi/src/media/video/video_shader_downloader.dart';

/// 视频画质增强「档位」：把用户面前的「无/低/中/高/极高」五档，投影到底层两套**正交**
/// 机制的组合——① mpv 内置缩放（[VideoMpvConfig.highQuality]，开=ewa_lanczossharp）
/// ② GLSL 着色器启用集（[mpvShaderDirectory] 里勾选的 `.glsl` 文件名）。
///
/// **设计原则（消除特殊情况）**：档位不是第三套独立持久化状态。它只是上面两套现有状态
/// 的一个**派生枚举投影**——选档=按映射写这两套状态；回读=反查当前两套状态命中哪一档
/// （都不命中=用户手工自定义勾选，返回 null）。这样不引入「档位 vs 实际状态」不一致的
/// 边界，老用户手动勾的着色器仍原样工作（显示「自定义」），TODO-018/026 的既有行为零破坏。
///
/// 映射（全 MIT，无 GPL 传染；见 .codex-test/todo-041-shader-tier-research.md 方案甲'）：
/// - [off]   = 关闭：内置缩放 off（bilinear）+ 无 GLSL。
/// - [low]   = 低：内置缩放 on（ewa_lanczossharp，零下载）+ 无 GLSL。
/// - [medium]= 中：内置缩放 on + Anime4K Fast（Mode A Fast，中低端 GPU 可跑）。
/// - [high]  = 高：内置缩放 on + Anime4K HQ（Mode A HQ，需较强 GPU）。
/// - [ultra] = 极高：内置缩放 on + Anime4K Mode A VL + 额外去模糊修复（高档 VL 链再叠一个
///   Restore_CNN_Soft_VL 去模糊/降噪 pass，MIT，需较强 GPU；BUG-836：UL 大 pass 越过 ANGLE
///   的 GL_MAX_VERTEX_ATTRIBS=16 会黑屏，故极高用 VL 类文件而非 UL）。
enum VideoShaderTier {
  off,
  low,
  medium,
  high,
  ultra,
}

/// 一个档位的完整定义：稳定 id + 是否开内置缩放 + 该档对应的 GLSL 预设（null=不用 GLSL）。
class VideoShaderTierSpec {
  const VideoShaderTierSpec({
    required this.tier,
    required this.id,
    required this.highQuality,
    required this.preset,
  });

  /// 档位枚举值。
  final VideoShaderTier tier;

  /// 稳定 id（持久化无关，仅 i18n/测试用）：`off` / `low` / `medium` / `high` / `ultra`。
  final String id;

  /// 是否启用 mpv 内置高画质缩放（写入 [VideoMpvConfig.highQuality]）。
  final bool highQuality;

  /// 该档使用的 GLSL 着色器预设（null = 不叠加任何 GLSL，仅靠内置缩放）。
  final Anime4kPreset? preset;

  /// 该档需要落盘 + 启用的 GLSL 文件名（按叠加顺序；无 GLSL 档返回空表）。
  List<String> get shaderFileNames =>
      preset == null ? const <String>[] : preset!.fileNames;
}

/// **桌面**五档的权威定义表（顺序即 UI 从左到右 无→极高）。移动端另有一张
/// [kMobileVideoShaderTiers]，取哪张一律经 [shaderTiersFor] 投影，别直接引用本表。
final List<VideoShaderTierSpec> kVideoShaderTiers = <VideoShaderTierSpec>[
  VideoShaderTierSpec(
    tier: VideoShaderTier.off,
    id: 'off',
    highQuality: false,
    preset: null,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.low,
    id: 'low',
    highQuality: true,
    preset: null,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.medium,
    id: 'medium',
    highQuality: true,
    preset: kAnime4kFastPreset,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.high,
    id: 'high',
    highQuality: true,
    preset: kAnime4kHqPreset,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.ultra,
    id: 'ultra',
    highQuality: true,
    preset: kAnime4kUltraDeblurPreset,
  ),
];

/// **移动端**五档定义表。与桌面表**同语义、不同投影**：档位含义（无→极高，越高越强）
/// 一字不变，变的只是每档映射到哪条 GLSL 链。
///
/// 无/低 与桌面完全相同（低=纯 mpv 内置缩放，移动端回落 spline36，见
/// `resolveScaleProperties`，零 GLSL）。中/高/极高 换成**只修复、不放大**的链
/// （[kAnime4kMobileRestoreSPreset] 等三个常量，理由见其 doc）：桌面链的开销主体是两个
/// `Upscale_CNN_x2` + 两个 `AutoDownscalePre`，而手机屏幕不比片源更大，放大收益被显示
/// 分辨率截断、代价却全额付；GPU 占满时连带 Flutter raster 一起卡（用户实测：手机上选
/// 高于「低」的任意档，播放和整个 app 一起卡）。
///
/// 这与 `resolveScaleProperties` 早就为移动端做的降级（EWA polar → spline36，TODO-1196）
/// 是同一条判断——那次只做了「内置缩放」这一半，GLSL 这一半一直漏着，本表补上。
final List<VideoShaderTierSpec> kMobileVideoShaderTiers = <VideoShaderTierSpec>[
  VideoShaderTierSpec(
    tier: VideoShaderTier.off,
    id: 'off',
    highQuality: false,
    preset: null,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.low,
    id: 'low',
    highQuality: true,
    preset: null,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.medium,
    id: 'medium',
    highQuality: true,
    preset: kAnime4kMobileRestoreSPreset,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.high,
    id: 'high',
    highQuality: true,
    preset: kAnime4kMobileRestoreMPreset,
  ),
  VideoShaderTierSpec(
    tier: VideoShaderTier.ultra,
    id: 'ultra',
    highQuality: true,
    preset: kAnime4kMobileRestoreMSoftPreset,
  ),
];

/// **纯函数**：取本平台该用的档位表（[kVideoShaderTiers] / [kMobileVideoShaderTiers]）。
///
/// 与 `resolveScaleProperties` 同签名范式：[isMobile] 显式传入便于单测两端都断言，不传
/// 则按运行平台判定。**本文件所有档位查询都经这里取表**，保证「选档写入」与「反查回读」
/// 用的是同一张表——两边取不同表会让刚选的档立刻显示成「自定义」。
List<VideoShaderTierSpec> shaderTiersFor({bool? isMobile}) {
  final bool mobile = isMobile ?? (Platform.isAndroid || Platform.isIOS);
  return mobile ? kMobileVideoShaderTiers : kVideoShaderTiers;
}

/// 取某档的规格。纯函数。
VideoShaderTierSpec shaderTierSpec(VideoShaderTier tier, {bool? isMobile}) =>
    shaderTiersFor(isMobile: isMobile)
        .firstWhere((VideoShaderTierSpec s) => s.tier == tier);

/// 该档需要的 GLSL 文件名集合（落盘 + 启用）。纯函数。
List<String> shaderFilesForTier(VideoShaderTier tier, {bool? isMobile}) =>
    shaderTierSpec(tier, isMobile: isMobile).shaderFileNames;

/// **纯函数**：从当前底层状态（内置缩放开关 [highQuality] + 已启用 GLSL 文件名集
/// [enabledShaders]）反查命中的档位；都不命中（用户手工勾了非标准集）返回 null=自定义。
///
/// 判据：内置缩放开关必须等于该档定义，且**已启用 GLSL 集恰好等于**该档的着色器集
/// （顺序无关、按集合相等）。空集 vs 空集相等，故 off/low 仅靠 highQuality 区分。
VideoShaderTier? tierFromState({
  required bool highQuality,
  required List<String> enabledShaders,
  bool? isMobile,
}) {
  final Set<String> enabled = enabledShaders.toSet();
  for (final VideoShaderTierSpec spec in shaderTiersFor(isMobile: isMobile)) {
    if (spec.highQuality != highQuality) continue;
    final Set<String> want = spec.shaderFileNames.toSet();
    if (_setEquals(enabled, want)) return spec.tier;
  }
  return null;
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// 选某档后应当**启用并按序排列**的 GLSL 文件名（按 [present] 实际已落盘的文件取交集，
/// 保持该档预设里的叠加顺序）。纯函数。
///
/// 调用方先把该档预设下载到着色器目录，再用本函数从「目录现有文件」过滤出有序启用集，
/// 写进持久化的启用集 + 应用到播放器。这样即便个别文件下载失败，也只启用真正存在的，
/// 不会让 libmpv 加载缺失路径。
List<String> orderedEnabledForTier(
  VideoShaderTier tier,
  Set<String> presentFiles, {
  bool? isMobile,
}) {
  return <String>[
    for (final String name in shaderFilesForTier(tier, isMobile: isMobile))
      if (presentFiles.contains(name)) name,
  ];
}
