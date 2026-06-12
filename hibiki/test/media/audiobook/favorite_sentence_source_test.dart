import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-047 子项 A 守卫：FavoriteSentence 新增 source / dateKey 字段的契约 ——
/// 序列化往返、向后兼容（旧条目无 source → 默认 book、无 dateKey → null），
/// 以及四个来源常量值固定不漂移（统计/收藏夹按这些常量分桶）。
void main() {
  group('FavoriteSentence source / dateKey', () {
    test('来源常量值固定（统计分桶 & video 与 kStatSourceVideo 同值）', () {
      expect(kFavoriteSentenceSourceBook, 'book');
      expect(kFavoriteSentenceSourceVideo, 'video');
      expect(kFavoriteSentenceSourceAudiobook, 'audiobook');
      expect(kFavoriteSentenceSourceLyrics, 'lyrics');
    });

    test('构造默认 source=book、dateKey=null（书内既有行为不变）', () {
      final FavoriteSentence s = FavoriteSentence(
        text: '今日はいい天気です',
        bookTitle: 'テスト本',
        createdAt: DateTime(2026, 6, 10),
      );
      expect(s.source, kFavoriteSentenceSourceBook);
      expect(s.dateKey, isNull);
    });

    test('显式 video 来源 + dateKey 序列化往返保真', () {
      final FavoriteSentence s = FavoriteSentence(
        text: '映画の字幕',
        bookTitle: 'ビデオ',
        createdAt: DateTime(2026, 6, 10, 8, 30),
        bookKey: 'video-uid-123',
        sectionIndex: 7,
        normCharOffset: 123456,
        normCharLength: 2400,
        source: kFavoriteSentenceSourceVideo,
        dateKey: '2026-06-10',
      );
      final FavoriteSentence round = FavoriteSentence.fromJson(s.toJson());
      expect(round.source, kFavoriteSentenceSourceVideo);
      expect(round.dateKey, '2026-06-10');
      expect(round.bookKey, 'video-uid-123');
      expect(round.text, '映画の字幕');
      expect(
        round.sectionIndex,
        7,
        reason: '视频收藏句用 sectionIndex 兼容保存 playlist episode index',
      );
      expect(
        round.normCharOffset,
        123456,
        reason: '视频收藏句用 normCharOffset 兼容保存 cue.startMs',
      );
      expect(
        round.normCharLength,
        2400,
        reason: '视频收藏句用 normCharLength 兼容保存 cue durationMs',
      );
    });

    test('toJson 始终写 source；dateKey 为 null 时不写键', () {
      final FavoriteSentence noDate = FavoriteSentence(
        text: 'a',
        bookTitle: 'b',
        createdAt: DateTime(2026, 6, 10),
      );
      final Map<String, dynamic> json = noDate.toJson();
      expect(json['source'], kFavoriteSentenceSourceBook);
      expect(json.containsKey('dateKey'), isFalse);
    });

    test('向后兼容：旧 JSON（无 source / 无 dateKey）→ 默认 book / null', () {
      final FavoriteSentence legacy =
          FavoriteSentence.fromJson(<String, dynamic>{
        'id': 'hl_old',
        'text': '旧条目',
        'bookTitle': '旧本',
        'createdAt': DateTime(2025, 1, 1).toIso8601String(),
      });
      expect(legacy.source, kFavoriteSentenceSourceBook);
      expect(legacy.dateKey, isNull);
      expect(legacy.id, 'hl_old');
    });
  });
}
