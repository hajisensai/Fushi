// BUG-3199：Emby / Jellyfin 在线观看时界面标题是服务器的中文译名，搜字幕得自己输入
// 原名。条目自带 `OriginalTitle` 与 `ProviderIds`：字幕检索先按 ID / 原名搜。
// 协议层（MockClient）钉「集 → 剧」取身份与显式 Fields，再钉种子与搜索框备选。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

void main() {
  test('集：跳到所属剧取原名与外部 ID，请求显式带 Fields', () async {
    final List<Uri> seen = <Uri>[];
    final JellyfinVideoClient client = JellyfinVideoClient(
      api: JellyfinApi(
        serverUrl: 'http://emby:8096',
        accessToken: 'tok',
        client: MockClient((http.Request req) async {
          seen.add(req.url);
          final Map<String, Object?> body = req.url.path.endsWith('/ep1')
              ? <String, Object?>{
                  'Id': 'ep1',
                  'Name': '第1集',
                  'Type': 'Episode',
                  'SeriesId': 'sr',
                  'OriginalTitle': 'エピソード',
                  'ProviderIds': <String, Object?>{'Tvdb': '999'},
                }
              : <String, Object?>{
                  'Id': 'sr',
                  'Name': '葬送的芙莉莲',
                  'Type': 'Series',
                  'OriginalTitle': '葬送のフリーレン',
                  'ProviderIds': <String, Object?>{
                    'Tmdb': '209867',
                    'AniList': '154587',
                    'AniDB': '17617',
                    'Imdb': '',
                  },
                };
          return http.Response(
            jsonEncode(body),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      ),
      userId: 'u',
    );
    final RemoteVideoTitleIdentity? identity = await client
        .remoteVideoTitleIdentity('ep1');
    expect(seen.map((Uri u) => u.path), <String>[
      '/Users/u/Items/ep1',
      '/Users/u/Items/sr',
    ]);
    for (final Uri u in seen) {
      expect(u.queryParameters['Fields'], 'OriginalTitle,ProviderIds');
    }
    expect(identity!.originalTitle, '葬送のフリーレン');
    expect(identity.title, '葬送的芙莉莲');
    expect(identity.isMovie, isFalse);
    // 键转小写、空值丢掉。
    expect(identity.externalIds, <String, String>{
      'tmdb': '209867',
      'anilist': '154587',
      'anidb': '17617',
    });

    final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
      originalTitle: identity.originalTitle,
      metadataTitle: identity.title,
      displayTitle: '葬送的芙莉莲 S01E01',
      externalIds: identity.externalIds,
      isMovie: identity.isMovie,
    );
    expect(seed.anilistId, 154587, reason: 'Jimaku 按 AniList ID 直搜');
    expect(seed.tmdbId, 209867, reason: 'OpenSubtitles 按 TMDB ID 搜');
    expect(seed.primaryQuery, '葬送のフリーレン', reason: '搜索框默认填原名');
    expect(seed.queries, contains('葬送的芙莉莲'), reason: '能一键切回中文标题');
  });

  test('电影：直接用条目自身，isMovie 为真', () {
    final RemoteVideoTitleIdentity identity =
        JellyfinVideoClient.remoteTitleIdentityOf(
          JellyfinApi.parseItem(<String, Object?>{
            'Id': 'm',
            'Name': '你的名字。',
            'Type': 'Movie',
            'OriginalTitle': '君の名は。',
            'ProviderIds': <String, Object?>{'Tmdb': '372058'},
          }),
        );
    expect(identity.isMovie, isTrue);
    expect(identity.originalTitle, '君の名は。');
    expect(identity.externalIds['tmdb'], '372058');
  });
}
