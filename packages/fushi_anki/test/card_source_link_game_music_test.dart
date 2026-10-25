import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 「回到出处」L3：卡片来源链接补 game / music 两种出处（wire = `fushi://source`
/// 查询串，随 Anki 卡片跨设备 / 跨版本流转）。
///
/// 新旧互通的两条契约：
/// - 旧格式（book / manga / video）的 URL 逐字节不变、新版照常解析；
/// - 新 kind 的链接在不认识它的解析器那里是「无链接」而不是坏卡：旧版本的
///   `kind` 白名单只有三值，`tryParse` / `fromHtml` 返回空，卡面退化成纯文本标题。
const String _sourceId = '12345678-1234-4234-8234-123456789abc';

void main() {
  group('game', () {
    test('tryGame 只带游戏身份，往返一致', () {
      final CardSourceLink link = CardSourceLink.tryGame(
        gameId: '1700000000123456',
        sourceId: _sourceId,
      )!;
      expect(link.kind, CardSourceKind.game);
      final Uri uri = link.toUri();
      expect(uri.queryParameters['kind'], 'game');
      expect(uri.queryParameters.keys.toSet(), <String>{
        'v',
        'kind',
        'uid',
        'sourceId',
      });
      final CardSourceLink back = CardSourceLink.parse(uri.toString());
      expect(back.kind, CardSourceKind.game);
      expect(back.uid, '1700000000123456');
    });

    test('游戏链接不接受任何位置参数', () {
      expect(
        () => CardSourceLink(
          kind: CardSourceKind.game,
          uid: 'g1',
          sourceId: _sourceId,
          startMs: 0,
          endMs: 10,
        ),
        throwsFormatException,
      );
      expect(
        () => CardSourceLink(
          kind: CardSourceKind.game,
          uid: 'g1',
          sourceId: _sourceId,
          bookKey: 'title-key',
        ),
        throwsFormatException,
      );
    });

    test('路径形状的旧游戏 id 不可携带：tryGame 返回 null，不让制卡失败', () {
      expect(CardSourceLink.tryGame(gameId: r'C:\Games\a.exe'), isNull);
      expect(CardSourceLink.tryGame(gameId: '/opt/game'), isNull);
      expect(CardSourceLink.tryGame(gameId: ''), isNull);
    });
  });

  group('music', () {
    test('tryMusic 带曲目身份 + 歌词行时间窗，往返一致', () {
      final CardSourceLink link = CardSourceLink.tryMusic(
        trackUid: 'a1b2c3d4e5f6',
        startMs: 61000,
        endMs: 64500,
        sourceId: _sourceId,
      )!;
      final CardSourceLink back = CardSourceLink.fromHtml(
        link.toHtml(label: 'Song'),
      ).single;
      expect(back.kind, CardSourceKind.music);
      expect(back.uid, 'a1b2c3d4e5f6');
      expect(back.startMs, 61000);
      expect(back.endMs, 64500);
      expect(back.fingerprint, isNull, reason: '曲目 uid 即身份，不强制文件指纹');
    });

    test('音乐链接必须有成对时间窗、不接受书 / 漫画定位', () {
      expect(
        CardSourceLink.tryMusic(trackUid: 't', startMs: 10, endMs: 5),
        isNull,
      );
      expect(
        () => CardSourceLink(
          kind: CardSourceKind.music,
          uid: 't',
          sourceId: _sourceId,
        ),
        throwsFormatException,
      );
      expect(
        () => CardSourceLink(
          kind: CardSourceKind.music,
          uid: 't',
          sourceId: _sourceId,
          startMs: 0,
          endMs: 1,
          pageIndex: 3,
        ),
        throwsFormatException,
      );
    });
  });

  group('新旧格式互通', () {
    test('旧格式（v1 book / video）URL 逐字节不变且照常解析', () {
      const String legacyBook =
          'fushi://source?v=1&kind=book&uid=book_1&sourceId=$_sourceId'
          '&chapterIndex=2&charOffset=1234';
      final CardSourceLink book = CardSourceLink.parse(legacyBook);
      expect(book.toUri().toString(), legacyBook);

      const String legacyVideo =
          'fushi://source?v=1&kind=video&uid=video%2Fstream%2Fyt%3Aabc'
          '&sourceId=$_sourceId&episodeIndex=0&startMs=1000&endMs=2000';
      final CardSourceLink video = CardSourceLink.parse(legacyVideo);
      expect(video.kind, CardSourceKind.video);
      expect(video.uid, 'video/stream/yt:abc');
      expect(video.episodeIndex, 0);
      expect(video.startMs, 1000);
      expect(video.endMs, 2000);
      expect(
        CardSourceLink.parse(video.toUri().toString()).toUri(),
        video.toUri(),
      );
    });

    test('不认识的 kind 解析为「无链接」（旧版本看到 game / music 的行为）', () {
      const String future =
          '<a href="fushi://source?v=1&amp;kind=podcast&amp;uid=x'
          '&amp;sourceId=$_sourceId">Title</a>';
      expect(CardSourceLink.fromHtml(future), isEmpty);
      expect(
        CardSourceLink.tryParse(
          'fushi://source?v=1&kind=podcast&uid=x&sourceId=$_sourceId',
        ),
        isNull,
      );
    });
  });
}
