import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-1120：收藏句来源枚举 [SentenceSourceKind] 的解析契约。
/// - dbValue 与 kFavoriteSentenceSource* 落库字符串逐字节一致（wire 契约不变）；
/// - tryParse 严格四值匹配，未知 → null；
/// - sentenceSourceKindOf 宽松解析，未知/null/空串回退 book（与
///   FavoriteSentence.fromJson 旧条目缺 source 的默认一致）。
void main() {
  group('SentenceSourceKind.dbValue', () {
    test('与落库字符串常量逐字节一致', () {
      expect(SentenceSourceKind.book.dbValue, kFavoriteSentenceSourceBook);
      expect(SentenceSourceKind.video.dbValue, kFavoriteSentenceSourceVideo);
      expect(
        SentenceSourceKind.audiobook.dbValue,
        kFavoriteSentenceSourceAudiobook,
      );
      expect(SentenceSourceKind.lyrics.dbValue, kFavoriteSentenceSourceLyrics);
    });
  });

  group('SentenceSourceKind.tryParse', () {
    test('四个落库值精确映射', () {
      expect(SentenceSourceKind.tryParse('book'), SentenceSourceKind.book);
      expect(SentenceSourceKind.tryParse('video'), SentenceSourceKind.video);
      expect(
        SentenceSourceKind.tryParse('audiobook'),
        SentenceSourceKind.audiobook,
      );
      expect(SentenceSourceKind.tryParse('lyrics'), SentenceSourceKind.lyrics);
    });

    test('未知/null/空串/大小写不匹配 → null', () {
      expect(SentenceSourceKind.tryParse(null), isNull);
      expect(SentenceSourceKind.tryParse(''), isNull);
      expect(SentenceSourceKind.tryParse('unknown'), isNull);
      expect(SentenceSourceKind.tryParse('Video'), isNull);
      expect(SentenceSourceKind.tryParse(' video'), isNull);
    });
  });

  group('sentenceSourceKindOf', () {
    test('四个落库值精确映射', () {
      expect(sentenceSourceKindOf('book'), SentenceSourceKind.book);
      expect(sentenceSourceKindOf('video'), SentenceSourceKind.video);
      expect(sentenceSourceKindOf('audiobook'), SentenceSourceKind.audiobook);
      expect(sentenceSourceKindOf('lyrics'), SentenceSourceKind.lyrics);
    });

    test('未知串/null/空串一律回退 book（向后兼容默认）', () {
      expect(sentenceSourceKindOf(null), SentenceSourceKind.book);
      expect(sentenceSourceKindOf(''), SentenceSourceKind.book);
      expect(sentenceSourceKindOf('unknown'), SentenceSourceKind.book);
      expect(sentenceSourceKindOf('anki'), SentenceSourceKind.book);
    });

    test('FavoriteSentence 旧条目缺 source 的默认与回退一致', () {
      final FavoriteSentence legacy =
          FavoriteSentence.fromJson(<String, dynamic>{
        'text': 'テスト文',
        'bookTitle': 'テスト本',
        'createdAt': '2026-07-26T00:00:00.000',
      });
      expect(sentenceSourceKindOf(legacy.source), SentenceSourceKind.book);
    });
  });
}
