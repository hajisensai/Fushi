import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：自动发音的解析/播放逻辑单一真相。WordAudioResolver 装配 +
/// resolveConfigured 只住在 lookup_audio_playback.dart；base_source_page 与
/// dictionary_page_mixin 的 _playAutoReadWord 都转调统一入口 autoReadWordUnified
/// （优先弹窗 <audio>、兜底 playLookupAudio），不再各自手抄一份 WordAudioResolver
/// 装配。防止两份发音逻辑漂移（任一处改了另一处漏改）。
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
        'base_source_page 的 _playAutoReadWord 转调统一入口 autoReadWordUnified 且不再自建 WordAudioResolver',
        () {
      expect(base, contains('autoReadWordUnified('),
          reason: 'base 应转调统一入口 autoReadWordUnified');
      expect(base.contains('WordAudioResolver('), isFalse,
          reason: 'base 不应再手抄一份 WordAudioResolver 装配');
    });

    test(
        'dictionary_page_mixin 的 _playAutoReadWord 转调统一入口 autoReadWordUnified 且不再自建 WordAudioResolver',
        () {
      expect(mixin, contains('autoReadWordUnified('),
          reason: 'mixin 应转调统一入口 autoReadWordUnified');
      expect(mixin.contains('WordAudioResolver('), isFalse,
          reason: 'mixin 不应再手抄一份 WordAudioResolver 装配');
    });
  });
}
