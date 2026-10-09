// BUG-3198：Emby 媒体库「查看全部」列的是库路径对应的物理文件夹（一个库配两条路径就
// 是两个「动漫」文件夹），而不是剧。按库类型递归取作品：剧集库 Series、电影库 Movie；
// 混合库仍按文件夹树。协议层（MockClient）钉请求形态。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';

void main() {
  late List<Uri> seen;

  JellyfinVideoClient client() => JellyfinVideoClient(
    api: JellyfinApi(
      serverUrl: 'http://emby:8096',
      accessToken: 'tok',
      client: MockClient((http.Request req) async {
        seen.add(req.url);
        final bool recursive = req.url.queryParameters['Recursive'] == 'true';
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': recursive
                ? <Object?>[
                    <String, Object?>{
                      'Id': 's1',
                      'Name': '描绘直至生命尽头',
                      'Type': 'Series',
                    },
                  ]
                : <Object?>[
                    <String, Object?>{
                      'Id': 'f1',
                      'Name': '动漫',
                      'Type': 'Folder',
                      'IsFolder': true,
                    },
                  ],
            'TotalRecordCount': 1,
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    ),
    userId: 'u',
  );

  setUp(() => seen = <Uri>[]);

  test('剧集库：递归 + IncludeItemTypes=Series，返回剧而不是文件夹', () async {
    final MediaServerPage page = await client().listLibraryItems(
      library: const MediaServerLibrary(
        id: 'lib',
        name: '新番连载',
        kind: MediaServerLibraryKind.tvShows,
      ),
    );
    final Map<String, String> q = seen.single.queryParameters;
    expect(seen.single.path, '/Users/u/Items');
    expect(q['ParentId'], 'lib');
    expect(q['Recursive'], 'true');
    expect(q['IncludeItemTypes'], 'Series');
    expect(page.items.single.type, MediaServerItemType.series);
  });

  test('电影库：递归 + IncludeItemTypes=Movie', () async {
    await client().listLibraryItems(
      library: const MediaServerLibrary(
        id: 'm',
        name: '电影',
        kind: MediaServerLibraryKind.movies,
      ),
      sort: MediaServerSort.dateAdded,
    );
    final Map<String, String> q = seen.single.queryParameters;
    expect(q['Recursive'], 'true');
    expect(q['IncludeItemTypes'], 'Movie');
    expect(q['SortBy'], 'DateCreated');
  });

  test('混合库：没有单一作品类型，按文件夹树（直接子级）', () async {
    final MediaServerPage page = await client().listLibraryItems(
      library: const MediaServerLibrary(
        id: 'mix',
        name: '家庭视频',
        kind: MediaServerLibraryKind.mixed,
      ),
    );
    final Map<String, String> q = seen.single.queryParameters;
    expect(q.containsKey('Recursive'), isFalse);
    expect(q.containsKey('IncludeItemTypes'), isFalse);
    expect(page.items.single.type, MediaServerItemType.folder);
  });

  test('按文件夹浏览的入口保留：listChildren 仍列直接子级', () async {
    final MediaServerPage page = await client().listChildren(parentId: 'lib');
    expect(seen.single.queryParameters.containsKey('Recursive'), isFalse);
    expect(page.items.single.type, MediaServerItemType.folder);
  });
}
