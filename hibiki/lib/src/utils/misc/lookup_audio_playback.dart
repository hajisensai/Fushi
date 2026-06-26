import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/utils/misc/word_audio_resolver.dart';

/// Resolves and plays the audio for [expression] / [reading] exactly like Hoshi:
/// enabled sources only, no TTS fallback.
///
/// 单一真相：收口自 base_source_page._playAutoReadWord 与
/// dictionary_page_mixin._playAutoReadWord 两份逐行相同的实现。两者唯一差异是
/// AppModel 的取法（[appModel] 现作参数），装配/超时/解析/播放完全一致。
Future<void> playLookupAudio(
  AppModel appModel,
  String expression,
  String reading,
) async {
  final String? url =
      await resolveLookupAudioUrl(appModel, expression, reading);
  debugPrint('[hibiki-autoread] resolved url=$url');
  if (url == null || url.isEmpty) return;

  // Plays remote URLs and local file paths uniformly, including Windows
  // drive-letter paths (BUG-046).
  final bool ok = await TtsChannel.instance.playAudioRef(
    url,
    volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
  );
  debugPrint('[hibiki-autoread] play ok=$ok');
}

/// Resolves (but does not play) the configured-source audio URL/path for
/// [expression] / [reading] — enabled sources only, no TTS fallback. Single
/// source of truth shared by [playLookupAudio] and the global-lookup overlay's
/// two-step bridge (resolveWordAudio -> url, then playWordAudio -> play).
Future<String?> resolveLookupAudioUrl(
  AppModel appModel,
  String expression,
  String reading,
) async {
  final sources = appModel.enabledAudioSources;
  debugPrint(
      '[hibiki-autoread] "$expression" reading="$reading" sources=${sources.length}');
  final WordAudioResolver resolver = WordAudioResolver(
    queryLocalAudio: (expression, reading) async {
      try {
        return await TtsChannel.instance
            .queryLocalAudio(expression, reading)
            .timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        debugPrint(
            '[hibiki-autoread] queryLocalAudio timed out for "$expression"');
        return null;
      }
    },
    queryLocalAudioByDbIndex: (expression, reading, dbIndex) async {
      try {
        return await TtsChannel.instance
            .queryLocalAudio(expression, reading, dbIndex: dbIndex)
            .timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        debugPrint(
            '[hibiki-autoread] queryLocalAudio timed out for "$expression"');
        return null;
      }
    },
    extractLocalAudio: TtsChannel.instance.extractLocalAudio,
    queryRemoteAudio: (expression, reading) => appModel.lookupRemoteAudio(
      expression,
      reading,
    ),
  );
  return resolver.resolveConfigured(
    expression: expression,
    reading: reading,
    sources: appModel.audioSourceConfigs,
  );
}
