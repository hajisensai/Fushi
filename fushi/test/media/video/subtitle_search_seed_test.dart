import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';

/// BUG-1842：在线字幕检索的身份种子。
///
/// 真实故障：库里《Re:Zero》第四季的显示名是中文「Re：从零开始的异世界生活 第四季
/// 丧失篇」，Jimaku 的条目名只有罗马音/英文/日文，AniList 也匹配不上这种长串（实测
/// 只有「从零开始的异世界生活」能命中，整串 0 结果）——于是搜索必然空手而归，尽管这个
/// 视频刮削过、库里存着它的 AniList ID 和日文原名。
void main() {
  group('buildSubtitleSearchSeed', () {
    test('日文原名排在最前，其次刮削名、显示名、合集名', () {
      final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
        originalTitle: 'Re:ゼロから始める異世界生活',
        metadataTitle: 'Re:Zero kara Hajimeru Isekai Seikatsu',
        displayTitle: 'Re：从零开始的异世界生活 第四季 丧失篇',
        collectionTitle: 'Re:Zero',
      );
      expect(seed.queries, <String>[
        'Re:ゼロから始める異世界生活',
        'Re:Zero kara Hajimeru Isekai Seikatsu',
        'Re：从零开始的异世界生活 第四季 丧失篇',
        'Re:Zero',
      ]);
      // 预填框用第一条；其余作为主词搜空后的备选。
      expect(seed.primaryQuery, 'Re:ゼロから始める異世界生活');
      expect(
        seed.fallbackQueries.first,
        'Re:Zero kara Hajimeru Isekai Seikatsu',
      );
    });

    test('去空白、去重、跳过空值', () {
      final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
        originalTitle: '  ',
        metadataTitle: 'Bocchi the Rock!',
        displayTitle: 'Bocchi the Rock!',
        collectionTitle: null,
      );
      expect(seed.queries, <String>['Bocchi the Rock!']);
      expect(seed.fallbackQueries, isEmpty);
    });

    test('AniList / TMDB 外部 ID 被解析成强身份', () {
      final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
        displayTitle: '最愛',
        externalIds: const <String, String>{
          'anilist': '21355',
          'tmdb': '126991',
        },
      );
      expect(seed.anilistId, 21355);
      expect(seed.tmdbId, 126991);
      expect(seed.isMovie, isFalse);
      expect(seed.hasStrongIdentity, isTrue);
    });

    test('电影身份带 isMovie 标记（TMDB 的 movie / tv 是两个互不相通的号段）', () {
      final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
        displayTitle: 'x',
        externalIds: const <String, String>{'tmdb': '669204'},
        isMovie: true,
      );
      expect(seed.tmdbId, 669204);
      expect(seed.isMovie, isTrue);
    });

    test('没有元数据时退化成纯文本种子（= 旧行为）', () {
      final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
        displayTitle: 'Some Anime',
      );
      expect(seed.hasStrongIdentity, isFalse);
      expect(seed.anilistId, isNull);
      expect(seed.tmdbId, isNull);
      expect(seed.primaryQuery, 'Some Anime');
    });

    test('外部 ID 不是正整数时当作没有，不硬塞给 API', () {
      final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
        displayTitle: 'x',
        externalIds: const <String, String>{'anilist': 'abc', 'tmdb': ''},
      );
      expect(seed.anilistId, isNull);
      expect(seed.tmdbId, isNull);
      expect(seed.hasStrongIdentity, isFalse);
    });

    test('provider 名大小写不影响识别（调用方已归一，这里锁住小写键约定）', () {
      final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
        displayTitle: 'x',
        externalIds: const <String, String>{'anilist': '  21355  '},
      );
      expect(seed.anilistId, 21355);
    });

    test('空种子（缺省构造）不带任何检索键', () {
      const SubtitleSearchSeed seed = SubtitleSearchSeed();
      expect(seed.primaryQuery, '');
      expect(seed.fallbackQueries, isEmpty);
      expect(seed.hasStrongIdentity, isFalse);
    });
  });
}
