import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：自动发音的 WordAudioResolver 装配 + resolveConfigured + playAudioRef
/// 逻辑只有一份（顶层 playLookupAudio），base_source_page 与 dictionary_page_mixin
/// 的 _playAutoReadWord 都转调它，不再各自手抄一份 WordAudioResolver 装配。
/// 防止两份发音逻辑漂移（任一处改了另一处漏改）。
void main() {
  final playback = File(
    'lib/src/utils/misc/lookup_audio_playback.dart',
  ).readAsStringSync();
  final base = File(
    'lib/src/pages/base_source_page.dart',
  ).readAsStringSync();
  final mixin = File(
    'lib/src/pages/implementations/dictionary_page_mixin.dart',
  ).readAsStringSync();

  group('自动发音逻辑单一真相 playLookupAudio', () {
    test('顶层 playLookupAudio 定义存在且收 AppModel', () {
      expect(
        playback,
        contains('Future<void> playLookupAudio('),
        reason: 'playLookupAudio 顶层函数应定义在 lookup_audio_playback.dart',
      );
      expect(playback, contains('WordAudioResolver('),
          reason: 'WordAudioResolver 装配应只住在 playLookupAudio 这一处');
      expect(playback, contains('playAudioRef('));
    });

    test(
        'base_source_page 的 _playAutoReadWord 转调 playLookupAudio 且不再自建 WordAudioResolver',
        () {
      expect(base, contains('playLookupAudio('),
          reason: 'base 应转调 playLookupAudio');
      expect(base.contains('WordAudioResolver('), isFalse,
          reason: 'base 不应再手抄一份 WordAudioResolver 装配');
    });

    test(
        'dictionary_page_mixin 的 _playAutoReadWord 转调 playLookupAudio 且不再自建 WordAudioResolver',
        () {
      expect(mixin, contains('playLookupAudio('),
          reason: 'mixin 应转调 playLookupAudio');
      expect(mixin.contains('WordAudioResolver('), isFalse,
          reason: 'mixin 不应再手抄一份 WordAudioResolver 装配');
    });
  });
}
