import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Jimaku 真人剧的权威关联键接入（BUG-1849）。
///
/// AniList ID 是动画专属键，真人剧此前只剩「拿显示名去模糊搜」这一条路；而 Jimaku 的
/// entry 上本来就带 `tmdb_id`（`tv:<id>` / `movie:<id>`），只是解析器把它直接丢了。
///
/// 这里同时钉住一件事：**检索键与分类过滤是正交两轴**。分类过滤只有 [JimakuAnimeFilter]
/// 一个真相源（provider 侧由 `discoveryCategory` 决定），TMDB 只贡献检索键，不引入第二套
/// 范围枚举。
VideoMediaReference _media({
  required VideoDiscoveryCategory category,
  required VideoMetadataMediaKind kind,
  int? tmdbId,
  int? anilistId,
}) {
  return VideoMediaReference(
    providerId: 'tmdb',
    mediaId: '${tmdbId ?? 0}',
    mediaKind: kind,
    discoveryCategory: category,
    title: 'Saiai',
    tmdbId: tmdbId,
    anilistId: anilistId,
  );
}

void main() {
  group('JimakuVideoSubtitleProvider.tmdbIdFor', () {
    test('剧集编成 tv:<id>，电影编成 movie:<id>', () {
      expect(
        JimakuVideoSubtitleProvider.tmdbIdFor(_media(
          category: VideoDiscoveryCategory.tv,
          kind: VideoMetadataMediaKind.tv,
          tmdbId: 126991,
        )),
        'tv:126991',
      );
      expect(
        JimakuVideoSubtitleProvider.tmdbIdFor(_media(
          category: VideoDiscoveryCategory.movie,
          kind: VideoMetadataMediaKind.movie,
          tmdbId: 669204,
        )),
        'movie:669204',
      );
    });

    test('媒体种类决定前缀，不是发现分类——动画剧场版仍是 movie 号段', () {
      // TMDB 的电影与剧集是两个独立号段：只看 discoveryCategory 会把动画剧场版
      // 编成 tv:<id>，张冠李戴。
      expect(
        JimakuVideoSubtitleProvider.tmdbIdFor(_media(
          category: VideoDiscoveryCategory.anime,
          kind: VideoMetadataMediaKind.movie,
          tmdbId: 42,
        )),
        'movie:42',
      );
    });

    test('无 media / 无 tmdbId → null（不拼一个假键去查）', () {
      expect(JimakuVideoSubtitleProvider.tmdbIdFor(null), isNull);
      expect(
        JimakuVideoSubtitleProvider.tmdbIdFor(_media(
          category: VideoDiscoveryCategory.tv,
          kind: VideoMetadataMediaKind.tv,
        )),
        isNull,
      );
    });
  });

  group('provider.search 把 TMDB 键接上既有 anime 三态', () {
    test('真人剧：anime=false 单档 + tmdb_id 精确命中，不回退显示名', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        final Map<String, String> p = req.url.queryParameters;
        if (req.url.path.endsWith('/files')) {
          return http.Response.bytes(
            utf8.encode('[{"name":"Saiai E01.ja.srt","url":"http://x/1"}]'),
            200,
          );
        }
        if (p.containsKey('tmdb_id')) {
          calls.add('tmdb:${p['tmdb_id']}:${p['anime']}');
          return http.Response.bytes(
              utf8.encode('[{"id":4,"name":"最愛"}]'), 200);
        }
        calls.add('query:${p['query']}:${p['anime']}');
        return http.Response('[]', 200);
      });
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: client),
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await provider.search(VideoSubtitleSearchRequest(
        media: _media(
          category: VideoDiscoveryCategory.tv,
          kind: VideoMetadataMediaKind.tv,
          tmdbId: 126991,
        ),
        languages: <String>['ja'],
      ));

      expect(result.items.single.releaseName, '最愛');
      // 分类过滤仍由 discoveryCategory 单点决定（liveAction ⇒ 只发 anime=false），
      // TMDB 只是换了检索键；没有第二个「范围」参数参与分流。
      expect(calls, <String>['tmdb:tv:126991:false']);
    });

    test('动画且无 tmdbId：请求与本改动前一致（anilist_id + anime=true）', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        final Map<String, String> p = req.url.queryParameters;
        if (req.url.path.endsWith('/files')) return http.Response('[]', 200);
        expect(p.containsKey('tmdb_id'), isFalse,
            reason: '没有 TMDB id 就不该凭空多发一次请求');
        calls.add('${p.keys.where((String k) => k != 'anime').join(',')}'
            ':${p['anime']}');
        return http.Response('[{"id":9,"name":"anime hit"}]', 200);
      });
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: client),
      );

      await provider.search(VideoSubtitleSearchRequest(
        media: _media(
          category: VideoDiscoveryCategory.anime,
          kind: VideoMetadataMediaKind.tv,
          anilistId: 21,
        ),
      ));

      expect(calls, <String>['anilist_id:true']);
    });
  });
}
