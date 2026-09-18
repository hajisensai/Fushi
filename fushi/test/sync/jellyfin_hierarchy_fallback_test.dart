// BUG-2567 守卫：服务器忽略 `Recursive` / `IncludeItemTypes` 时的层级回退枚举。
//
// 原型是实测的公共服 `UHD Media Server 4.9.3.0`（Emby 兼容实现）：
// `/Users/{uid}/Items?ParentId=X` **永远只返回 X 的直接子级**，`Recursive=true`
// 与 `IncludeItemTypes` 一并被忽略——向电影库要 Episode 返回 Movie，向剧集库要
// Episode 返回 Series。于是剧集库只吐 `Series` 文件夹，全部通不过消费端的
// `isPlayableVideo`，整台服务器在影片页表现为「一个条目都没有」。
//
// 本文件把「修好了」钉成四条可执行断言：
//  [1] 忽略 Recursive 的服务器 → 自动走 `/Shows/{id}/Episodes` 把分集捞出来，
//      并按剧名折叠成合集（与原版 Jellyfin 的单集语义一字不差）；
//  [2] **守规矩的服务器一发都不多打**——回退只在「一个叶子都没有、却全是容器」
//      时触发，原版 Jellyfin / Emby 行为零变化；
//  [3] 预算闸 kMaxHierarchyRequests 真生效，且熔断要把 truncated 报出来
//      （静默给一半 = 「以为拉全了、其实没有」）；
//  [4] `/Shows/{id}/Episodes` 挂掉时回落列直接子级——**一次 404 不能把整个库
//      变成空**，那正是本 bug 的形状。
// 外加一条环路守卫：文件夹互相引用时枚举必须终止，不能无限循环。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/jellyfin_video_client.dart';

/// 中文库名/剧名必须走 bytes + utf8：`http.Response(String, …)` 按 latin-1 编码，
/// 非 ASCII 直接抛，而 `_getJson` 把它当网络失败吞掉——测试会静默走错分支而不是红。
http.Response _json(Map<String, Object?> body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

http.Response _page(List<Map<String, Object?>> items, int total) =>
    _json(<String, Object?>{'Items': items, 'TotalRecordCount': total});

Map<String, Object?> _series(String id, String name) => <String, Object?>{
      'Id': id,
      'Name': name,
      'Type': 'Series',
    };

Map<String, Object?> _episode(
  String id,
  String seriesName, {
  int season = 1,
  int episode = 1,
}) =>
    <String, Object?>{
      'Id': id,
      'Name': '第 $episode 集',
      'Type': 'Episode',
      'SeriesName': seriesName,
      'ParentIndexNumber': season,
      'IndexNumber': episode,
      'RunTimeTicks': 24 * 60 * 1000 * kTicksPerMs,
      'ImageTags': <String, Object?>{'Primary': 't$id'},
    };

Map<String, Object?> _movie(String id, String name) => <String, Object?>{
      'Id': id,
      'Name': name,
      'Type': 'Movie',
      'RunTimeTicks': 90 * 60 * 1000 * kTicksPerMs,
    };

/// 取分页窗口，模仿服务器对 StartIndex / Limit 的处理（实测该服两者均生效）。
List<Map<String, Object?>> _slice(
  List<Map<String, Object?>> all,
  Uri url,
) {
  final int start = int.tryParse(url.queryParameters['StartIndex'] ?? '') ?? 0;
  final int limit =
      int.tryParse(url.queryParameters['Limit'] ?? '') ?? all.length;
  if (start >= all.length) return const <Map<String, Object?>>[];
  return all.sublist(start, (start + limit).clamp(0, all.length));
}

/// 一台「忽略 Recursive/IncludeItemTypes」的 Emby 兼容服务器。
///
/// [children] 是「容器 id → 直接子级」，[episodes] 是「剧 id → 分集」。
/// 无论请求里写了什么 `Recursive` / `IncludeItemTypes`，`/Users/u1/Items` 一律
/// 返回 ParentId 的直接子级——这就是本 bug 的服务器侧事实。
MockClient _ignoringServer({
  required Map<String, List<Map<String, Object?>>> children,
  required Map<String, List<Map<String, Object?>>> episodes,
  required List<String> log,
  Set<String> failingSeries = const <String>{},
}) =>
    MockClient((http.Request req) async {
      final Uri url = req.url;
      log.add(url.path);
      if (url.path == '/Users/u1/Views') {
        return _json(<String, Object?>{
          'Items': <Object?>[
            <String, Object?>{
              'Id': 'lib1',
              'Name': '日韩新番',
              'CollectionType': 'tvshows',
            },
          ],
        });
      }
      if (url.path.startsWith('/Shows/') && url.path.endsWith('/Episodes')) {
        final String seriesId = url.path
            .substring('/Shows/'.length, url.path.length - '/Episodes'.length);
        if (failingSeries.contains(seriesId)) {
          return http.Response('not found', 404);
        }
        final List<Map<String, Object?>> all =
            episodes[seriesId] ?? const <Map<String, Object?>>[];
        return _page(_slice(all, url), all.length);
      }
      if (url.path == '/Users/u1/Items') {
        final String parent = url.queryParameters['ParentId'] ?? '';
        final List<Map<String, Object?>> all =
            children[parent] ?? const <Map<String, Object?>>[];
        return _page(_slice(all, url), all.length);
      }
      return http.Response('unexpected ${url.path}', 500);
    });

JellyfinVideoClient _clientFor(MockClient mock) => JellyfinVideoClient(
      api: JellyfinApi(
        serverUrl: 'http://nas:8096',
        accessToken: 'tok',
        client: mock,
      ),
      userId: 'u1',
    );

void main() {
  group('BUG-2567 层级回退枚举', () {
    test('[1] 忽略 Recursive 的服务器：剧集库不再为空，分集按剧名折叠成合集', () async {
      final List<String> log = <String>[];
      final MockClient mock = _ignoringServer(
        log: log,
        children: <String, List<Map<String, Object?>>>{
          'lib1': <Map<String, Object?>>[
            _series('s1', '孤独摇滚'),
            _series('s2', '葬送的芙莉莲'),
          ],
        },
        episodes: <String, List<Map<String, Object?>>>{
          's1': <Map<String, Object?>>[
            _episode('e1', '孤独摇滚', episode: 1),
            _episode('e2', '孤独摇滚', episode: 2),
          ],
          's2': <Map<String, Object?>>[_episode('e3', '葬送的芙莉莲')],
        },
      );

      final List<RemoteVideoInfo> videos =
          await _clientFor(mock).listRemoteVideos();

      // 修复前这里是 0——Series 全被 isPlayableVideo 滤掉，用户看到空库。
      expect(
          videos.map((RemoteVideoInfo v) => v.id), <String>['e1', 'e2', 'e3']);
      // 分集必须经 /Shows/{id}/Episodes 取得，不是靠继续分页硬撞。
      expect(log, contains('/Shows/s1/Episodes'));
      expect(log, contains('/Shows/s2/Episodes'));
      // 折叠语义与原版 Jellyfin 单集一致：按剧名归入 playlist 合集。
      expect(videos[0].collection?.collectionName, '孤独摇滚');
      expect(videos[0].collection?.collectionType, 'playlist');
      expect(videos[2].collection?.collectionName, '葬送的芙莉莲');
      // 季×10000+集 的组内序（[JellyfinVideoClient._collectionOf] 口径）。
      expect(videos[0].collection?.sortIndex, 10001);
      expect(videos[1].collection?.sortIndex, 10002);
    });

    test('[2] 守规矩的服务器一发都不多打：不碰 /Shows，行为零变化', () async {
      final List<String> log = <String>[];
      // 这台服务器认 Recursive：直接吐叶子。回退判据要求「一个叶子都没有」，
      // 所以它必须走原路径。
      final MockClient mock = MockClient((http.Request req) async {
        log.add(req.url.path);
        if (req.url.path == '/Users/u1/Views') {
          return _json(<String, Object?>{
            'Items': <Object?>[
              <String, Object?>{
                'Id': 'lib1',
                'Name': 'Movies',
                'CollectionType': 'movies',
              },
            ],
          });
        }
        final String type = req.url.queryParameters['IncludeItemTypes'] ?? '';
        final List<Map<String, Object?>> all = type == 'Movie'
            ? <Map<String, Object?>>[_movie('m1', 'Dune')]
            : <Map<String, Object?>>[_episode('e1', 'Show A')];
        return _page(_slice(all, req.url), all.length);
      });

      final List<RemoteVideoInfo> videos =
          await _clientFor(mock).listRemoteVideos();

      expect(videos.map((RemoteVideoInfo v) => v.id), <String>['m1', 'e1']);
      expect(
        log.where((String p) => p.startsWith('/Shows/')),
        isEmpty,
        reason: '原版 Jellyfin/Emby 绝不能因为本修复多付一发请求',
      );
    });

    test('[3] 预算闸 kMaxHierarchyRequests 生效，且熔断要报 truncated', () async {
      final List<String> log = <String>[];
      // 剧数远超预算：一部剧一发，必然撞上 kMaxHierarchyRequests。
      const int seriesCount = JellyfinApi.kMaxHierarchyRequests + 50;
      final Map<String, List<Map<String, Object?>>> episodes =
          <String, List<Map<String, Object?>>>{};
      final List<Map<String, Object?>> libChildren = <Map<String, Object?>>[];
      for (int i = 0; i < seriesCount; i++) {
        libChildren.add(_series('s$i', 'Show $i'));
        episodes['s$i'] = <Map<String, Object?>>[_episode('e$i', 'Show $i')];
      }

      final MockClient mock = _ignoringServer(
        log: log,
        children: <String, List<Map<String, Object?>>>{'lib1': libChildren},
        episodes: episodes,
      );
      final JellyfinRecursiveResult result = await JellyfinApi(
        serverUrl: 'http://nas:8096',
        accessToken: 'tok',
        client: mock,
      ).recursiveVideoItems(
        userId: 'u1',
        parentId: 'lib1',
        // 节流在真机是特性、在测试里是 60 秒的等待。
        pageInterval: Duration.zero,
      );

      expect(result.truncated, isTrue, reason: '截断必须报出来，不能静默给一半');
      expect(
        log.length,
        // +1 = 判定「这台服务器忽略 Recursive」那一发探测请求。它在回退开始**之前**
        // 就已发出，不属于层级预算；除它以外一发都不许超。
        lessThanOrEqualTo(JellyfinApi.kMaxHierarchyRequests + 1),
        reason: '预算是硬闸：超了就是几千发连续请求 = 爬虫特征',
      );
      // 撞闸不等于颗粒无收：闸之前捞到的分集照样要还给用户。
      expect(result.items, isNotEmpty);
      expect(result.items.every((JellyfinItem i) => i.isPlayableVideo), isTrue);
    });

    test('[4] /Shows/{id}/Episodes 挂掉 → 回落列子级，不会把整个库变成空', () async {
      final List<String> log = <String>[];
      final MockClient mock = _ignoringServer(
        log: log,
        // s1 的 Episodes 端点 404；它的季/集仍能经直接子级走到。
        failingSeries: <String>{'s1'},
        children: <String, List<Map<String, Object?>>>{
          'lib1': <Map<String, Object?>>[_series('s1', '孤独摇滚')],
          's1': <Map<String, Object?>>[
            <String, Object?>{'Id': 'sea1', 'Name': '第一季', 'Type': 'Season'},
          ],
          'sea1': <Map<String, Object?>>[_episode('e1', '孤独摇滚')],
        },
        episodes: const <String, List<Map<String, Object?>>>{},
      );

      final List<RemoteVideoInfo> videos =
          await _clientFor(mock).listRemoteVideos();

      expect(videos.map((RemoteVideoInfo v) => v.id), <String>['e1']);
    });

    test('[6] 单部剧彻底取不到 → 其余剧照常出来，不是整库为空', () async {
      final List<String> log = <String>[];
      // s1 的 Episodes 404，且它的 children 也 500——这部剧彻底没救。
      // 但 s2 必须照常枚举出来：这条回退要发几百发请求，一次瞬断就把整个远端库
      // 打成 failed（= 一个条目都不渲染）的话，等于把本 bug 换了个触发条件复现。
      final MockClient mock = MockClient((http.Request req) async {
        final Uri url = req.url;
        log.add(url.path);
        if (url.path == '/Users/u1/Views') {
          return _json(<String, Object?>{
            'Items': <Object?>[
              <String, Object?>{
                'Id': 'lib1',
                'Name': '番剧',
                'CollectionType': 'tvshows',
              },
            ],
          });
        }
        if (url.path == '/Shows/s2/Episodes') {
          final List<Map<String, Object?>> all = <Map<String, Object?>>[
            _episode('e2', '好剧'),
          ];
          return _page(_slice(all, url), all.length);
        }
        if (url.path == '/Shows/s1/Episodes') {
          return http.Response('nope', 404);
        }
        if (url.path == '/Users/u1/Items') {
          final String parent = url.queryParameters['ParentId'] ?? '';
          if (parent == 's1') return http.Response('boom', 500);
          if (parent == 'lib1') {
            final List<Map<String, Object?>> all = <Map<String, Object?>>[
              _series('s1', '坏剧'),
              _series('s2', '好剧'),
            ];
            return _page(_slice(all, url), all.length);
          }
        }
        return http.Response('unexpected ${url.path}', 500);
      });

      final List<RemoteVideoInfo> videos =
          await _clientFor(mock).listRemoteVideos();

      expect(videos.map((RemoteVideoInfo v) => v.id), <String>['e2']);
    });

    test('[5] 容器成环时枚举必须终止（否则无限循环 + 无限内存）', () async {
      final List<String> log = <String>[];
      // f1 与 f2 互相把对方列为子级——没有 visited 去重就永远跑不完。
      final MockClient mock = _ignoringServer(
        log: log,
        children: <String, List<Map<String, Object?>>>{
          'lib1': <Map<String, Object?>>[
            <String, Object?>{'Id': 'f1', 'Name': 'A', 'Type': 'Folder'},
          ],
          'f1': <Map<String, Object?>>[
            <String, Object?>{'Id': 'f2', 'Name': 'B', 'Type': 'Folder'},
          ],
          'f2': <Map<String, Object?>>[
            <String, Object?>{'Id': 'f1', 'Name': 'A', 'Type': 'Folder'},
            _movie('m1', 'Dune'),
          ],
        },
        episodes: const <String, List<Map<String, Object?>>>{},
      );

      final List<RemoteVideoInfo> videos =
          await _clientFor(mock).listRemoteVideos();

      expect(videos.map((RemoteVideoInfo v) => v.id), <String>['m1']);
      expect(log.length, lessThan(20), reason: '成环不能把预算烧光');
    });
  });
}
