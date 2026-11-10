/// gal 制卡设置枚举 → 界面文案。全局设置页、操作目录与游戏详情页「本游戏制卡设置」
/// 共用这一份，免得同一个选项在三处各写一份、翻译漂开。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/gal_mining_settings.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';

String galMiningAudioModeLabel(GalMiningAudioMode mode) => switch (mode) {
  GalMiningAudioMode.auto => t.gal_mining_audio_mode_auto,
  GalMiningAudioMode.maxLength => t.gal_mining_audio_mode_max_length,
  GalMiningAudioMode.fixedLength => t.gal_mining_audio_mode_fixed_length,
  GalMiningAudioMode.off => t.gal_mining_audio_mode_off,
};

/// galgame 封面模式三档（[galMiningImageModeChoices]）的文案；与全局设置页同一组 key。
String galMiningImageModeLabel(VideoMiningImageMode mode) => mode.isVideoClip
    ? t.gal_mining_image_mode_video_clip
    : mode.isStill
    ? t.gal_mining_image_mode_screenshot
    : t.video_mining_image_mode_gif;

String galMiningAnimatedFormatLabel(MiningAnimatedFormat format) =>
    switch (format) {
      MiningAnimatedFormat.avif => t.mining_animated_format_avif,
      MiningAnimatedFormat.webp => t.mining_animated_format_webp,
      MiningAnimatedFormat.gif => t.mining_animated_format_gif,
    };

String galMiningStillFormatLabel(MiningStillFormat format) => switch (format) {
  MiningStillFormat.jpg => t.mining_still_format_jpg,
  MiningStillFormat.png => t.mining_still_format_png,
};
