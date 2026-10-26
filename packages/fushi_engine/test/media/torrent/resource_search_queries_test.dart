// 资源搜索的多拼写查询生成（原内置 Nyaa provider 的 BUG-2794 / BUG-2818 契约，
// 行为逐字迁到 resource_search_queries.dart，供用户自配的 RSS 搜索站使用）。
import 'package:fushi_engine/media/torrent/resource_search_queries.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:test/test.dart';

/// TMDB 列表卡片的形状：只有中文展示名 + 日文原名。
VideoMediaReference _tmdbFrieren({
  Iterable<String> aliases = const <String>['葬送のフリーレン'],
}) => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '209867',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: '葬送的芙莉莲',
  originalTitle: '葬送のフリーレン',
  aliases: aliases,
  tmdbId: 209867,
);

/// 资源页补齐别名后的 TMDB 卡片：罗马字（TMDB JP 别名）→ 英文名，原名是日文。
VideoMediaReference _kurumi() => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '311842',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: 'FX战士胡桃酱',
  originalTitle: 'FX戦士くるみちゃん',
  aliases: const <String>[
    'FX Senshi KURUMICHAN',
    'FX Fighter Kurumi-chan',
    'FX戦士くるみちゃん',
  ],
  tmdbId: 311842,
);

void main() {
  group('resourceSearchQueries（BUG-2794）', () {
    test('预填的日文原名是已知标题：补查罗马字拼写', () {
      expect(
        resourceSearchQueries(
          VideoResourceSearchRequest(
            media: _tmdbFrieren(
              aliases: const <String>['Sousou no Frieren', '葬送のフリーレン'],
            ),
            query: '葬送のフリーレン',
          ),
        ),
        <String>['葬送のフリーレン', 'Sousou no Frieren'],
      );
    });

    test('用户手输中文译名（非拉丁）也补查作品拼写', () {
      expect(
        resourceSearchQueries(
          VideoResourceSearchRequest(
            media: _tmdbFrieren(
              aliases: const <String>['Sousou no Frieren', '葬送のフリーレン'],
            ),
            query: '芙莉莲 第二季',
          ),
        ),
        <String>['芙莉莲 第二季', 'Sousou no Frieren', '葬送のフリーレン'],
      );
    });

    test('用户手输的拉丁词是在收窄：只搜它', () {
      expect(
        resourceSearchQueries(
          VideoResourceSearchRequest(
            media: _tmdbFrieren(),
            query: 'Frieren S2 1080p',
          ),
        ),
        <String>['Frieren S2 1080p'],
      );
    });

    test('全角 / 大小写 / 空白差异仍认作同一个已知标题', () {
      expect(
        resourceSearchQueries(
          VideoResourceSearchRequest(
            media: _tmdbFrieren(aliases: const <String>['Sousou no Frieren']),
            query: 'ＳＯＵＳＯＵ  no frieren',
          ),
        ),
        <String>['ＳＯＵＳＯＵ  no frieren', '葬送のフリーレン'],
      );
    });

    test('没有作品身份（纯关键词）：只有显式词', () {
      expect(
        resourceSearchQueries(const VideoResourceSearchRequest(query: '芙莉莲')),
        <String>['芙莉莲'],
      );
    });
  });

  group('多拉丁拼写（BUG-2818）', () {
    test('预填的风格化罗马字是已知标题：英文名与日文原名都补查', () {
      expect(
        resourceSearchQueries(
          VideoResourceSearchRequest(
            media: _kurumi(),
            query: 'FX Senshi KURUMICHAN',
          ),
        ),
        <String>[
          'FX Senshi KURUMICHAN',
          'FX Fighter Kurumi-chan',
          'FX戦士くるみちゃん',
        ],
      );
    });

    test('无显式词也列出全部拉丁拼写', () {
      expect(
        resourceSearchQueries(VideoResourceSearchRequest(media: _kurumi())),
        <String>[
          'FX Senshi KURUMICHAN',
          'FX Fighter Kurumi-chan',
          'FX戦士くるみちゃん',
        ],
      );
    });

    test('首选词契约：罗马字与日文各一个；显式词原样一条', () {
      expect(
        preferredResourceSearchQueries(
          VideoResourceSearchRequest(media: _kurumi()),
        ),
        <String>['FX Senshi KURUMICHAN', 'FX戦士くるみちゃん'],
      );
      expect(
        preferredResourceSearchQueries(
          VideoResourceSearchRequest(media: _kurumi(), query: ' kurumi '),
        ),
        <String>['kurumi'],
      );
    });

    test('拉丁拼写至多查 kResourceMaxRomanizedQueries 个', () {
      final List<String> queries = resourceSearchQueries(
        VideoResourceSearchRequest(
          media: VideoMediaReference(
            providerId: 'tmdb',
            mediaId: '1',
            mediaKind: VideoMetadataMediaKind.tv,
            discoveryCategory: VideoDiscoveryCategory.anime,
            title: 'A',
            aliases: const <String>['B', 'C', 'D', 'E'],
          ),
        ),
      );
      expect(queries, hasLength(kResourceMaxRomanizedQueries));
      expect(queries, <String>['B', 'C', 'D']);
    });
  });
}
