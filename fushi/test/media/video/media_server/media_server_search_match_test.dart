// 媒体服务器搜索的客户端把关（BUG-2608）：纯函数单测。
//
// 服务器 SearchTerm 语义三家不一：Jellyfin 子串、Emby 词首前缀 + 多词 AND、
// 兼容层按字模糊。把关只坚持「每个词都出现在标题或原名里」这一条对前两家无损
// 的下限；这里逐条钉住三家各自的命中形态都能过、模糊命中过不了。

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_search_match.dart';

MediaServerItem _movie(String id, String name, {String? originalTitle}) =>
    MediaServerItem(
      id: id,
      name: name,
      type: MediaServerItemType.movie,
      originalTitle: originalTitle,
    );

void main() {
  group('mediaServerSearchTokens', () {
    test('按空白切词、逐词归一化、丢空', () {
      expect(mediaServerSearchTokens('  Stranger  Things '), <String>[
        'stranger',
        'things',
      ]);
      expect(mediaServerSearchTokens('ＦＡＴＥ・ｓｔａｙ'), <String>['fatestay']);
      expect(mediaServerSearchTokens('   '), isEmpty);
      expect(mediaServerSearchTokens('「」…'), isEmpty, reason: '纯标点 = 没内容');
    });
  });

  group('mediaServerSearchMatches', () {
    final List<String> tokens = mediaServerSearchTokens('怪奇物语');

    test('Jellyfin 子串命中 / Emby 词首前缀命中都过', () {
      expect(mediaServerSearchMatches(tokens, _movie('a', '怪奇物语')), isTrue);
      expect(
        mediaServerSearchMatches(tokens, _movie('b', '最后的冒险：《怪奇物语》幕后')),
        isTrue,
      );
      expect(
        mediaServerSearchMatches(
          mediaServerSearchTokens('strang'),
          _movie('c', 'Stranger Things'),
        ),
        isTrue,
        reason: 'Emby 词首前缀',
      );
      expect(
        mediaServerSearchMatches(
          mediaServerSearchTokens('Things Making'),
          _movie('d', 'Stranger Things Making Of'),
        ),
        isTrue,
        reason: 'Emby 多词 AND、词序无关',
      );
    });

    test('兼容层的按字模糊命中过不了', () {
      for (final String junk in <String>[
        '怪形',
        '尘兔',
        '绿毛怪格林奇',
        '物怪',
        '佩小姐的奇幻城堡',
      ]) {
        expect(
          mediaServerSearchMatches(tokens, _movie(junk, junk)),
          isFalse,
          reason: junk,
        );
      }
    });

    test('原名也算：中文库按外文原题搜', () {
      expect(
        mediaServerSearchMatches(
          mediaServerSearchTokens('stranger things'),
          _movie('a', '怪奇物语', originalTitle: 'Stranger Things'),
        ),
        isTrue,
      );
    });

    test('归一化两侧同口径：全角 / 片假名 / 标点差异不挡命中', () {
      expect(
        mediaServerSearchMatches(
          mediaServerSearchTokens('fate stay'),
          _movie('a', 'Fate／stay night'),
        ),
        isTrue,
      );
      expect(
        mediaServerSearchMatches(
          mediaServerSearchTokens('ものの怪'),
          _movie('b', '劇場版モノノ怪 唐傘'),
        ),
        isTrue,
        reason: '片假名 → 平假名',
      );
    });

    test('空 tokens 恒 false（空查询该在上游短路）', () {
      expect(
        mediaServerSearchMatches(const <String>[], _movie('a', 'x')),
        isFalse,
      );
    });
  });

  group('rankMediaServerSearchHits', () {
    test('滤掉不命中；精确同名 > 以查询开头 > 其余保持服务器顺序', () {
      final List<MediaServerItem> ranked =
          rankMediaServerSearchHits('怪奇物语', <MediaServerItem>[
            _movie('making', '最后的冒险：《怪奇物语》第五季幕后'),
            _movie('junk1', '怪形'),
            _movie('beyond', '怪奇背后'),
            _movie('tales', '怪奇物语：1985故事集'),
            _movie('junk2', '尘兔'),
            _movie('st', '怪奇物语'),
            _movie('making2', '怪奇物语幕后 2'),
          ]);
      expect(ranked.map((MediaServerItem i) => i.id).toList(), <String>[
        'st',
        'tales',
        'making2',
        'making',
      ]);
    });

    test('查询无内容 → 空', () {
      expect(
        rankMediaServerSearchHits('  ', <MediaServerItem>[_movie('a', 'a')]),
        isEmpty,
      );
    });
  });
}
