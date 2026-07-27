import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;
import 'package:hibiki/src/mining/external_window_mining.dart';

/// TODO-1162 外部窗口挖矿 M0：`buildExternalWindowRequest` 纯函数契约。
/// BUG-1137：`source` 已改必填（曾默认 video 把 gal 卡误标成视频标签），
/// 各用例显式声明来源并断言原样透传。
void main() {
  group('buildExternalWindowRequest', () {
    test('有截图字节 -> providedCoverBytes=截图，PNG 名，无音频不中止', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': '走る'},
        sentence: '彼は走る',
        screenshotBytes: Uint8List.fromList([1, 2, 3]),
        documentTitle: 'ある galgame',
        source: AnkiMiningSource.game,
      );
      expect(req.providedCoverBytes, [1, 2, 3]);
      expect(req.providedCoverName, 'external_window.png');
      expect(req.sentence, '彼は走る');
      expect(req.documentTitle, 'ある galgame');
      // M0 无音频：不因缺音频中止，无 GIF/无本地媒体源。
      expect(req.requireAudio, false);
      expect(req.mediaSource, isNull);
      expect(req.audioSource, isNull);
      expect(req.providedAudioBytes, isNull);
      expect(req.clipStartMs, 0);
      expect(req.clipEndMs, 0);
      expect(req.hasRange, false);
      // BUG-1137：gal Hook 场景卡归「游戏」来源标签，不再吃 video 默认值。
      expect(req.source, AnkiMiningSource.game);
    });

    test('截图为 null（抓帧失败）-> providedCoverBytes=null 且无名（引擎将 fail-open 中止）', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': 'テスト'},
        sentence: 'これはテスト',
        screenshotBytes: null,
        source: AnkiMiningSource.game,
      );
      expect(req.providedCoverBytes, isNull);
      expect(req.providedCoverName, isNull);
      // 无 cover + 无 audio + 无 mediaSource -> 引擎中止（no cover and no audio produced）。
      expect(req.requireAudio, false);
      expect(req.mediaSource, isNull);
    });

    test('透传 fields / cueSentence / updateNoteId / bookTitleTag', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': '本', 'reading': 'ほん'},
        sentence: '本を読む',
        cueSentence: '本を読む。',
        bookTitleTag: 'game-title',
        updateNoteId: 42,
        source: AnkiMiningSource.book,
      );
      expect(req.fields, {'expression': '本', 'reading': 'ほん'});
      expect(req.cueSentence, '本を読む。');
      expect(req.bookTitleTag, 'game-title');
      expect(req.updateNoteId, 42);
      expect(req.source, AnkiMiningSource.book);
    });

    // galgame 一键制卡（docs/specs/galgame-mining）：audioBytes 接线。
    test('有音频字节 -> providedAudioBytes 透传，requireAudio 开，默认名带扩展', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': '声'},
        sentence: '君の声',
        screenshotBytes: Uint8List.fromList([9, 9]),
        audioBytes: Uint8List.fromList([1, 2, 3, 4]),
        source: AnkiMiningSource.game,
      );
      expect(req.providedAudioBytes, [1, 2, 3, 4]);
      // 桌面/Android 默认 aac；iOS m4a。两种都以 galgame_audio. 前缀。
      expect(req.providedAudioName, startsWith('galgame_audio.'));
      // 本应有音频 -> 守卫开（最终丢音=失败，不静默出无声卡）。
      expect(req.requireAudio, true);
    });

    test('自定义 audioName 覆盖默认名', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': '声'},
        sentence: '君の声',
        audioBytes: Uint8List.fromList([1, 2]),
        audioName: 'custom_voice.m4a',
        source: AnkiMiningSource.game,
      );
      expect(req.providedAudioName, 'custom_voice.m4a');
    });

    test('空音频字节 -> 当作无音频（requireAudio false，纯截图卡不被误当失败）', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': '声'},
        sentence: '君の声',
        screenshotBytes: Uint8List.fromList([9]),
        audioBytes: Uint8List(0),
        source: AnkiMiningSource.game,
      );
      expect(req.providedAudioBytes, isNull);
      expect(req.providedAudioName, isNull);
      expect(req.requireAudio, false);
    });
  });
}
