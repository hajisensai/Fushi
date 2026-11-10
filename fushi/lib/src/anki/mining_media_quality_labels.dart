import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show MiningClipFormat;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// 制卡图片 / GIF 清晰度各档的名字（下标 = 档位，低 → 高）。
List<String> miningImageQualityTierNames() => <String>[
  t.mining_image_quality_thrift,
  t.mining_image_quality_standard,
  t.mining_image_quality_hd,
  // BUG-1039：满档叫「最高」，只承诺是滑块顶格（GIF 仍封顶），不承诺保真度。
  t.mining_image_quality_max,
];

/// 制卡音频质量各档的名字（下标 = 档位，低 → 高）。
List<String> miningAudioQualityTierNames() => <String>[
  t.mining_audio_quality_standard,
  t.mining_audio_quality_high,
  // BUG-1039：192k 立体声是有损重编码，不叫「原片」。
  t.mining_audio_quality_max,
];

/// 把图片档位翻成用户看得懂的具体参数：截图长边上限、GIF 宽度与帧率。
///
/// 数值直接读 [MiningMediaCompression.imageTiers]（顶格档的 GIF 封顶读
/// [MiningMediaCompression.gifMaxTierWidth] / [MiningMediaCompression.gifMaxTierFps]），
/// 编码参数改了说明跟着变，不会说一套做一套。
String miningImageQualityTierDetail(int tier) {
  final int i = tier.clamp(0, MiningMediaCompression.imageTierMax);
  if (i == MiningMediaCompression.imageTierMax) {
    return t.mining_image_quality_detail_max(
      gifWidth: MiningMediaCompression.gifMaxTierWidth,
      gifFps: MiningMediaCompression.gifMaxTierFps,
    );
  }
  final ({int gifFps, int gifWidth, int maxLongEdge, int quality}) spec =
      MiningMediaCompression.imageTiers[i];
  return t.mining_image_quality_detail(
    longEdge: spec.maxLongEdge,
    gifWidth: spec.gifWidth,
    gifFps: spec.gifFps,
  );
}

/// 把音频档位翻成具体参数：单声道 / 立体声 + 比特率（kbps）。
String miningAudioQualityTierDetail(int tier) {
  final int i = tier.clamp(0, MiningMediaCompression.audioTierCount - 1);
  final ({int channels, String bitrate}) spec =
      MiningMediaCompression.audioTiers[i];
  final String kbps = spec.bitrate.replaceAll(RegExp('[kK]\$'), '');
  return spec.channels <= 1
      ? t.mining_audio_quality_detail_mono(kbps: kbps)
      : t.mining_audio_quality_detail_stereo(kbps: kbps);
}

/// 片段格式选项的文案。五端随包的统一 FFmpeg（tool/ffmpeg-unified）都带 libvpx-vp9 +
/// SVT-AV1 + libopus，三档在各端都编得出；[MiningClipFormat.encodeAttempts] 的降级只给
/// 用户自带的外部 ffmpeg 兜底。
///
/// 全局设置页与游戏详情页「本游戏制卡设置」共用（放在这个不依赖 AppModel 的叶子
/// 文件里，详情页那一节才不必为一个文案函数 import 整个设置页）。
String miningClipFormatLabel(MiningClipFormat format) => switch (format) {
  MiningClipFormat.webmVp9 => t.mining_clip_format_webm_vp9,
  MiningClipFormat.webmAv1 => t.mining_clip_format_webm_av1,
  MiningClipFormat.mp4H264 => t.mining_clip_format_mp4_h264,
};
