import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;

/// 沉浸制卡片段音频的容器扩展名，按平台分（TODO-1217 / BUG-460）：
/// - iOS：`m4a`——AnkiMobile 只自动下载它识别为媒体的 localhost URL，`.aac` 裸流会被当成
///   可见文本不下载（da22cd42a）；iOS 端 ffmpeg-kit 自带 ipod muxer，能产出 `.m4a`。
/// - 桌面 / Android：`aac`（adts）——桌面捆绑的 ffmpeg-min
///   （`tool/ffmpeg-min/build-ffmpeg-min.sh` 的 MUXERS 白名单只有 adts，无 ipod/mp4/m4a）
///   写 `.m4a` 会自动选一个不存在的 ipod muxer → `Unable to choose output format` /
///   exit -22 → `extractAudioSegmentViaFfmpeg` 返 null → 音频丢（桌面网飞/YouTube/应用内
///   视频制卡有图无声，正是 da22cd42a 的桌面回归）；Android AnkiDroid 历来接受 `.aac`（BUG-460）。
///
/// 纯逻辑放在 [immersionMiningAudioExtensionFor]，便于对两分支单测（测试宿主上
/// `Platform.isIOS` 恒为 false，无法直接覆盖 iOS 分支）。
String immersionMiningAudioExtensionFor({required bool isIOS}) =>
    isIOS ? 'm4a' : 'aac';

/// 当前运行平台下沉浸制卡片段音频的容器扩展名（见 [immersionMiningAudioExtensionFor]）。
String immersionMiningAudioExtension() =>
    immersionMiningAudioExtensionFor(isIOS: Platform.isIOS);

/// 视频制卡的封面图片模式（用户在 Anki 设置里三选一，默认 [gif]=现状零破坏）：
/// - [gif]：字幕区间动图（现默认，`extractClipGifViaFfmpeg`）。抽取失败按旧阶梯降级为
///   静态帧，并弹「降级为静态帧」OSD。
/// - [currentFrame]：制卡那一刻的当前解码帧（`controller.screenshot`，点词已自动暂停）。
///   用户主动选的静态图，非降级 → 不弹降级 OSD。
/// - [subtitleStart]：当前字幕 cue 起始时间点的帧（`extractVideoFrameViaFfmpeg`，
///   `atSeconds = clipStartMs/1000`）。同为主动选择的静态图。
///
/// 持久化用 [wireName]（存进偏好的字符串），解析用 [fromWireName]（未知值回退 [gif]，
/// 向后兼容）。远端来源（Netflix providedCoverBytes / YouTube）请求不设本字段，保持 [gif]
/// 默认——它们直接给字节或走既有阶梯，不受影响。
enum VideoMiningImageMode {
  gif('gif'),
  currentFrame('current_frame'),
  subtitleStart('subtitle_start');

  const VideoMiningImageMode(this.wireName);

  /// 偏好持久化用的稳定字符串键（勿随枚举名改动）。
  final String wireName;

  /// 从偏好字符串解析；未知/null → [gif]（默认，向后兼容）。
  static VideoMiningImageMode fromWireName(String? name) {
    for (final VideoMiningImageMode mode in VideoMiningImageMode.values) {
      if (mode.wireName == name) return mode;
    }
    return VideoMiningImageMode.gif;
  }

  /// 是否为静态截图模式（用户主动选静态图，非 GIF 降级）。
  bool get isStill => this != VideoMiningImageMode.gif;
}

/// 统一沉浸制卡请求。任何来源（本地/YouTube/Netflix）都构造这个喂 [ImmersionMiningEngine]。
///
/// [mediaSource] 是 ffmpeg 的 inputPath——本地绝对路径 或 可 seek 的 http 流 URL。
/// 若 [mediaSource] 为 null（如 Netflix 前台无本地源），引擎只用 [stillFallback] /
/// [providedCoverBytes] / [providedAudioBytes] 组卡。
class ImmersionMiningRequest {
  const ImmersionMiningRequest({
    required this.fields,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.sentence,
    this.mediaSource,
    this.audioSource,
    this.cueSentence,
    this.documentTitle,
    this.audioStreamIndex,
    this.audioStreamCount,
    this.source = AnkiMiningSource.video,
    this.bookTitleTag,
    this.updateNoteId,
    this.stillFallback,
    this.providedCoverBytes,
    this.providedCoverName,
    this.providedAudioBytes,
    this.providedAudioName,
    this.requireAudio = true,
    this.imageMode = VideoMiningImageMode.gif,
    this.mediaSourceTlsPinSha256,
  });

  final Map<String, String> fields;
  final int clipStartMs;
  final int clipEndMs;
  final String sentence;
  final String? mediaSource;

  /// 音频段抽取源（ffmpeg inputPath）。null = 用 [mediaSource]（本地文件/muxed）。
  /// YouTube 分离流时 = audio-only 流 URL（视频流无音轨，音频得从这里裁）。
  final String? audioSource;
  final String? cueSentence;
  final String? documentTitle;
  final int? audioStreamIndex;
  final int? audioStreamCount;
  final AnkiMiningSource source;
  final String? bookTitleTag;

  /// 非 null = 覆盖现有卡（走 updateMinedNote，不计统计）。
  final int? updateNoteId;

  /// 当前解码帧兜底（本地路径链全失败时）。本地传 `controller.screenshot`。
  final Future<Uint8List?> Function()? stillFallback;

  /// 外部已抓好的封面/音频字节（Netflix 后台实例直接给字节，无本地文件）。
  final Uint8List? providedCoverBytes;
  final String? providedCoverName;
  final Uint8List? providedAudioBytes;
  final String? providedAudioName;

  /// true = 无音频则中止制卡（本地/YouTube 默认）；false = 允许无音频卡（Netflix 2A 截图卡）。
  final bool requireAudio;

  /// 视频制卡封面图片模式（见 [VideoMiningImageMode]）。默认 [VideoMiningImageMode.gif]
  /// = 现状。仅本地/有 range 的封面解析路径读取；providedCoverBytes 路径不受影响。
  final VideoMiningImageMode imageMode;

  /// BUG-891：[mediaSource]/[audioSource] 若是远端自签 Hibiki 主机的 https 流，这里带上
  /// 该 host 经 TOFU 钉扎的证书 SHA-256 指纹（`aa:bb:..`）。引擎把它透传给 ffmpeg 抽取器的
  /// `-tls_pin_sha256`，使自编 ffmpeg-kit（`--enable-gnutls` + pin 补丁）按指纹接受自签，
  /// 而非无条件放行。null = 本地源 / 公网有效证书源（YouTube 等），不钉扎、走 ffmpeg 默认。
  final String? mediaSourceTlsPinSha256;

  bool get hasRange => clipEndMs > clipStartMs;
}

/// 引擎产出。[outcome] 用 Object? 承 MineOutcome，避免此值对象文件依赖 anki_models 全量。
class ImmersionMiningResult {
  const ImmersionMiningResult({
    required this.aborted,
    this.outcome,
    this.degradedToStill = false,
    this.abortReason,
  });

  /// true = 因缺音频等前置条件中止，未调后端。
  final bool aborted;

  /// MineOutcome（成功路径）。
  final Object? outcome;
  final bool degradedToStill;

  /// TODO-1303：仅在 [aborted] 时非空——中止的人类可读原因（缺音频 / 空壳卡）。远端
  /// 制卡（浏览器扩展）据此把失败原因写进错误日志并随响应体回传，终结「制卡失败报成功
  /// + 诊断黑洞」。null（成功路径）时无诊断。
  final String? abortReason;
}
