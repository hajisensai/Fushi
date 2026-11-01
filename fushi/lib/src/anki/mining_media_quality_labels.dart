import 'package:fushi/utils.dart';

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
