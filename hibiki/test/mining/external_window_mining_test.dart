import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;
import 'package:hibiki/src/mining/external_window_mining.dart';

/// TODO-1162 外部窗口挖矿 M0：`buildExternalWindowRequest` 纯函数契约。
void main() {
  group('buildExternalWindowRequest', () {
    test('有截图字节 -> providedCoverBytes=截图，PNG 名，无音频不中止', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': '走る'},
        sentence: '彼は走る',
        screenshotBytes: Uint8List.fromList([1, 2, 3]),
        documentTitle: 'ある galgame',
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
      // 外部窗口挖矿归「视频/沉浸」来源标签。
      expect(req.source, AnkiMiningSource.video);
    });

    test('截图为 null（抓帧失败）-> providedCoverBytes=null 且无名（引擎将 fail-open 中止）', () {
      final req = buildExternalWindowRequest(
        fields: const {'expression': 'テスト'},
        sentence: 'これはテスト',
        screenshotBytes: null,
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
  });
}
