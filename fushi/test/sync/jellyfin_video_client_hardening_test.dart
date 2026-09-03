// PR#909 审查 7 条阻塞项的回归守卫。断言用到的关键字面量都写进注释，方便后人
// 一眼看出「改坏哪一行会红」：
//  [1] putRemoteVideoPosition 打 '/Sessions/Playing/Progress'（不是 Stopped），
//      并按 kPositionReportIntervalMs = 10000 节流；
//  [2] recursiveVideoItems 真分页（每轮传 'StartIndex' / 'Limit'，翻到
//      TotalRecordCount 为止），并按 kMaxRecursiveItems = 20000 熔断
//      （熔断现在还要把 truncated 报出来，BUG-1891）；
//  [3] 清单请求 Fields = 'ProductionYear'——**刻意不带 MediaSources**
//      （BUG-1891：它是全库枚举里最贵的一段），sizeBytes / subtitleFileName /
//      精确文本字幕轨改由 remoteVideoDetail 在单条目消费点按需补齐；
//  [4] kRequestTimeout = Duration(seconds: 15) 且真挂在请求上；
//  [5] remoteLibrarySourceId == 'jellyfin:<serverUrl>|<userId>'；
//  [6] UserData.LastPlayedDate -> lastPlayedAtMs -> positionUpdatedAtMs /
//      remoteVideoPosition().updatedAtMs；
//  [7] http.ClientException 里带 api_key 的 URL 在**异常构造侧**脱敏成
//      '<redacted>'（kRedactedPlaceholder）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/metadata/credential_redaction.dart'
    show kRedactedPlaceholder;
import 'package:fushi/src/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/jellyfin_video_client.dart';

/// 单集条目 JSON（带 MediaSources：默认源 id / 大小 / 字幕流）。
Map<String, Object?> _episodeJson({
  String id = 'ep1',
  int? positionTicks,
  String? lastPlayedDate,
  int? sizeBytes,
  bool? hasSubtitlesFlag,
  List<Map<String, Object?>> subtitleStreams = const <Map<String, Object?>>[],
}) =>
    <String, Object?>{
      'Id': id,
      'Name': 'The Pilot',
      'Type': 'Episode',
      'SeriesName': 'Show A',
      'ParentIndexNumber': 1,
      'IndexNumber': 2,
      'RunTimeTicks': 90 * 60 * 1000 * kTicksPerMs,
      'ImageTags': <String, Object?>{'Primary': 'tag'},
      if (hasSubtitlesFlag != null) 'HasSubtitles': hasSubtitlesFlag,
      'UserData': <String, Object?>{
        'PlaybackPositionTicks': positionTicks ?? 0,
        if (lastPlayedDate != null) 'LastPlayedDate': lastPlayedDate,
      },
      'MediaSources': <Object?>[
        <String, Object?>{
          'Id': 'src1',
          if (sizeBytes != null) 'Size': sizeBytes,
          'MediaStreams': <Object?>[
            <String, Object?>{'Type': 'Video', 'Index': 0},
            ...subtitleStreams,
          ],
        },
      ],
    };

/// 外挂日文 srt 轨。
const Map<String, Object?> _externalSrt = <String, Object?>{
  'Type': 'Subtitle',
  'Index': 3,
  'Codec': 'subrip',
  'Language': 'jpn',
  'IsExternal': true,
  'IsTextSubtitleStream': true,
};

/// 图形轨（PGS）：存在但下不了文本。
const Map<String, Object?> _graphicPgs = <String, Object?>{
  'Type': 'Subtitle',
  'Index': 4,
  'Codec': 'pgssub',
  'IsExternal': false,
  'IsTextSubtitleStream': false,
};

/// 熔断用的极简条目（只要能被 parseItem 解析即可，避免 2 万条的构造开销）。
Map<String, Object?> _tinyJson(String id) => <String, Object?>{
      'Id': id,
      'Name': id,
      'Type': 'Movie',
    };

JellyfinApi _api(MockClient client, {String token = 'tok'}) => JellyfinApi(
      serverUrl: 'http://nas:8096',
      accessToken: token,
      client: client,
    );

JellyfinVideoClient _client(
  MockClient client, {
  String userId = 'u1',
  List<String> libraryIds = const <String>[],
}) =>
    JellyfinVideoClient(
      api: _api(client),
      userId: userId,
      libraryIds: libraryIds,
    );

/// `/Users/{uid}/Views` 的响应。
///
/// 必须走 [http.Response.bytes] + utf8：库名是中文，`http.Response(String, …)`
/// 按 latin-1 编码，非 ASCII 直接抛 —— 而 `_getJson` 把它当网络失败吞掉，
/// 测试会「静默走进整库递归回退」而不是红。
http.Response _viewsResponse(List<List<String?>> idNameType) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(<String, Object?>{
        'Items': <Object?>[
          for (final List<String?> v in idNameType)
            <String, Object?>{
              'Id': v[0],
              'Name': v[1],
              if (v[2] != null) 'CollectionType': v[2],
            },
        ],
      })),
      200,
    );

void main() {
  group('[1] 断点上报走 Progress 并节流', () {
    test(
        'putRemoteVideoPosition 打 /Sessions/Playing/Progress 且带 IsPaused:false',
        () async {
      final List<http.Request> posts = <http.Request>[];
      final JellyfinVideoClient c =
          _client(MockClient((http.Request req) async {
        posts.add(req);
        return http.Response('', 204);
      }));

      await c.putRemoteVideoPosition('ep1', 90000, 1755000000000);

      expect(posts, hasLength(1));
      expect(posts.single.url.path, '/Sessions/Playing/Progress',
          reason: 'Stopped 会在接近片尾时标记已播放并清空 resume 位置，不能当心跳用');
      final Map<String, Object?> body =
          (jsonDecode(posts.single.body) as Map).cast<String, Object?>();
      expect(body['ItemId'], 'ep1');
      expect(body['PositionTicks'], 90000 * kTicksPerMs);
      expect(body['IsPaused'], false);
    });

    test('同一条目 10s 内的重复上报被节流掉（每秒回调不再刷爆服务器）', () async {
      int posts = 0;
      final JellyfinVideoClient c = _client(MockClient((_) async {
        posts++;
        return http.Response('', 204);
      }));

      await c.putRemoteVideoPosition('ep1', 1000, 1);
      await c.putRemoteVideoPosition('ep1', 2000, 2);
      await c.putRemoteVideoPosition('ep1', 3000, 3);

      expect(posts, 1, reason: 'kPositionReportIntervalMs = 10000：窗口内只放行第一发');
      expect(JellyfinVideoClient.kPositionReportIntervalMs, 10000);
    });

    test('换条目立刻重开窗口（切集后第一发不被上一集吃掉）', () async {
      final List<String> itemIds = <String>[];
      final JellyfinVideoClient c =
          _client(MockClient((http.Request req) async {
        itemIds.add(((jsonDecode(req.body) as Map)['ItemId'] as String?) ?? '');
        return http.Response('', 204);
      }));

      await c.putRemoteVideoPosition('ep1', 1000, 1);
      await c.putRemoteVideoPosition('ep2', 1000, 2);
      await c.putRemoteVideoPosition('ep2', 2000, 3);

      expect(itemIds, <String>['ep1', 'ep2']);
    });

    test('reportStopped 仍打 /Sessions/Playing/Stopped（真停止播放的入口保留）', () async {
      late http.Request seen;
      final JellyfinApi api = _api(MockClient((http.Request req) async {
        seen = req;
        return http.Response('', 204);
      }));
      await api.reportStopped(itemId: 'ep1', positionMs: 1234);
      expect(seen.url.path, '/Sessions/Playing/Stopped');
      expect(
          (jsonDecode(seen.body) as Map)['PositionTicks'], 1234 * kTicksPerMs);
    });
  });

  group('[2] 清单真分页', () {
    test('翻到 TotalRecordCount 为止：1200 条 / pageSize 500 = 3 轮，全部拿回', () async {
      const int total = 1200;
      final List<Map<String, String>> queries = <Map<String, String>>[];
      final JellyfinApi api = _api(MockClient((http.Request req) async {
        queries.add(req.url.queryParameters);
        final int start = int.parse(req.url.queryParameters['StartIndex']!);
        final int limit = int.parse(req.url.queryParameters['Limit']!);
        final int n = (total - start).clamp(0, limit);
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': <Object?>[
              for (int i = 0; i < n; i++) _tinyJson('ep${start + i}'),
            ],
            'TotalRecordCount': total,
          }),
          200,
        );
      }));

      final JellyfinRecursiveResult result = await api.recursiveVideoItems(
        userId: 'u1',
        pageInterval: Duration.zero,
      );
      final List<JellyfinItem> items = result.items;

      expect(result.truncated, isFalse);
      expect(items, hasLength(total),
          reason: '旧实现单发一次 + Limit=2000 不翻页，第 2001 条起永久不可见且无提示');
      expect(queries, hasLength(3));
      expect(
        queries.map((Map<String, String> q) => q['StartIndex']).toList(),
        <String>['0', '500', '1000'],
        reason: '旧实现根本没传 StartIndex，补上才叫分页',
      );
      expect(queries.first['Limit'], '500', reason: 'pageSize 默认 500');
      expect(items.first.id, 'ep0');
      expect(items.last.id, 'ep1199');
    });

    test('服务器谎报 TotalRecordCount 时按 kMaxRecursiveItems 熔断，不死循环', () async {
      int calls = 0;
      final JellyfinApi api = _api(MockClient((http.Request req) async {
        calls++;
        final int limit = int.parse(req.url.queryParameters['Limit']!);
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': <Object?>[
              for (int i = 0; i < limit; i++) _tinyJson('x$calls-$i'),
            ],
            // 永远大于已取到的数量：没有熔断这里就是无限循环 + 无限内存。
            'TotalRecordCount': 1 << 30,
          }),
          200,
        );
      }));

      final JellyfinRecursiveResult result = await api.recursiveVideoItems(
        userId: 'u1',
        pageSize: 1000,
        pageInterval: Duration.zero,
      );

      expect(JellyfinApi.kMaxRecursiveItems, 20000);
      expect(result.items, hasLength(JellyfinApi.kMaxRecursiveItems));
      expect(calls, 20);
      expect(result.truncated, isTrue,
          reason: 'BUG-1891：熔断此前是静默截断——用户拿到「前 20000 条」却以为拉全了');
    });

    test('分页之间有最小间隔：40 次重查询不再零间隔连发（BUG-1891）', () {
      fakeAsync((FakeAsync async) {
        int calls = 0;
        final JellyfinApi api = _api(MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'Items': <Object?>[
                for (int i = 0; i < 500; i++) _tinyJson('c$calls-$i'),
              ],
              'TotalRecordCount': 1500,
            }),
            200,
          );
        }));

        unawaited(api.recursiveVideoItems(userId: 'u1'));
        // 第一页不等（进页面的首屏不该被人为拖慢）。
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(calls, 1);

        // 第二页要等满 kPageInterval 才发。
        async.elapse(JellyfinApi.kPageInterval - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(calls, 1,
            reason: '零间隔连发正是 Emby/Jellyfin 滥用检测眼里的爬虫特征');

        async.elapse(const Duration(milliseconds: 2));
        async.flushMicrotasks();
        expect(calls, 2);
      });
      expect(JellyfinApi.kPageInterval, const Duration(milliseconds: 150));
    });

    test('某页返空即停（totalCount 偏大也不空转）', () async {
      int calls = 0;
      final JellyfinApi api = _api(MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': calls == 1
                ? <Object?>[_tinyJson('a'), _tinyJson('b')]
                : <Object?>[],
            'TotalRecordCount': 999,
          }),
          200,
        );
      }));

      final JellyfinRecursiveResult result = await api.recursiveVideoItems(
        userId: 'u1',
        pageInterval: Duration.zero,
      );
      expect(result.items, hasLength(2));
      expect(result.truncated, isFalse);
      expect(calls, 2);
    });
  });

  group('[3] 重字段不在清单里，由 remoteVideoDetail 按需补齐（BUG-1891）', () {
    test('清单 Fields = ProductionYear，全程没有一条请求要过 MediaSources', () async {
      final List<Uri> seen = <Uri>[];
      final JellyfinVideoClient c =
          _client(MockClient((http.Request req) async {
        seen.add(req.url);
        if (req.url.path == '/Users/u1/Views') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'Items': <Object?>[
                <String, Object?>{
                  'Id': 'lib-tv',
                  'Name': 'TV',
                  'CollectionType': 'tvshows',
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            // 服务器没被要 MediaSources 就不会下发它——桩必须照做，否则这条测试
            // 会拿着一份现实里不存在的响应体自我安慰。
            'Items': <Object?>[_episodeJson(hasSubtitlesFlag: true)
              ..remove('MediaSources')],
            'TotalRecordCount': 1,
          }),
          200,
        );
      }));

      final List<RemoteVideoInfo> list = await c.listRemoteVideos();

      final Uri itemsUri =
          seen.firstWhere((Uri u) => u.path == '/Users/u1/Items');
      expect(itemsUri.queryParameters['Fields'], 'ProductionYear',
          reason: 'Fields=MediaSources 会让服务器为每一条目展开媒体源'
              '（Emby 侧还含外挂字幕的磁盘探测），几十万条目的服务器上一进视频页'
              '就是几十上百个这种重查询连发——用户报的「一添加就开始刮削、卡死、'
              '封号」正是它');
      expect(
        seen.any((Uri u) => u.toString().contains('MediaSources')),
        isFalse,
        reason: '清单阶段一条都不许要 MediaSources',
      );

      final RemoteVideoInfo info = list.single;
      expect(info.hasSubtitle, isTrue,
          reason: '清单卡的字幕角标退回服务器的粗粒度 HasSubtitles（会把图形轨也算上）');
      expect(info.sizeBytes, isNull, reason: '重字段不在清单里');
      expect(info.subtitleFileName, isNull, reason: '重字段不在清单里');
    });

    test('remoteVideoDetail 打一次 /Items/{id} 把大小 / 精确字幕轨补回来', () async {
      final List<Uri> seen = <Uri>[];
      final JellyfinVideoClient c =
          _client(MockClient((http.Request req) async {
        seen.add(req.url);
        return http.Response(
          jsonEncode(_episodeJson(
            sizeBytes: 123456789,
            subtitleStreams: <Map<String, Object?>>[_externalSrt],
          )),
          200,
        );
      }));

      final RemoteVideoInfo detail = await c.remoteVideoDetail(
        const RemoteVideoInfo(id: 'ep1', title: 'Show A S01E02 The Pilot'),
      );

      expect(seen.single.path, '/Users/u1/Items/ep1');
      expect(detail.sizeBytes, 123456789);
      expect(detail.hasSubtitle, isTrue,
          reason:
              'home_video_page 的 if (!video.hasSubtitle) return 是下载外挂字幕的早返门');
      expect(detail.subtitleFileName, 'Show A S01E02 The Pilot.jpn.srt',
          reason: '文件名带着真实编码——为空时消费端按扩展名选解析器会恒落 srt，'
              'ASS 轨会被 srt 解析器解成 0 条 cue');
    });

    test('只有图形轨（PGS）时 remoteVideoDetail 把 hasSubtitle 纠回 false', () async {
      final JellyfinVideoClient c =
          _client(MockClient((_) async => http.Response(
                jsonEncode(_episodeJson(
                  // 服务器的 HasSubtitles 把图形轨也算 true——清单阶段只能信它，
                  // 所以真要下字幕之前必须补一次详情把它纠回来。
                  hasSubtitlesFlag: true,
                  subtitleStreams: <Map<String, Object?>>[_graphicPgs],
                )),
                200,
              )));

      final RemoteVideoInfo detail = await c.remoteVideoDetail(
        const RemoteVideoInfo(id: 'ep1', title: 'Show A S01E02 The Pilot'),
      );
      expect(detail.hasSubtitle, isFalse);
      expect(detail.subtitleFileName, isNull);
    });

    test('服务器没给流表时回落 HasSubtitles 旗子', () {
      final JellyfinItem item = JellyfinApi.parseItem(<String, Object?>{
        'Id': 'm1',
        'Name': 'Movie',
        'Type': 'Movie',
        'HasSubtitles': true,
      });
      expect(item.hasTextSubtitle, isTrue);
      expect(item.sizeBytes, isNull);
    });
  });

  group('[4] 请求超时', () {
    test('kRequestTimeout = 15s（与互联后端同口径）', () {
      expect(JellyfinApi.kRequestTimeout, const Duration(seconds: 15));
    });

    test('服务器只连不回时 _getJson 在 15s 抛 TimeoutException（不是永久转圈）', () {
      fakeAsync((FakeAsync async) {
        Object? err;
        final JellyfinApi api = _api(
          MockClient((_) => Completer<http.Response>().future),
        );
        unawaited(api.views('u1').then<void>(
              (List<JellyfinLibraryView> _) {},
              onError: (Object e, StackTrace _) => err = e,
            ));

        async.elapse(const Duration(seconds: 14));
        async.flushMicrotasks();
        expect(err, isNull, reason: '15s 之前不该提前放弃');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(err, isA<TimeoutException>(),
            reason: 'createAppHttpIoClient 只有连接超时，响应挂起必须由这层兜住');
      });
    });
  });

  group('[5] 缓存槽身份含 userId', () {
    test('remoteLibrarySourceId = jellyfin:<serverUrl>|<userId>', () {
      final JellyfinVideoClient c =
          _client(MockClient((_) async => http.Response('{}', 200)));
      expect(c.remoteLibrarySourceId, 'jellyfin:http://nas:8096|u1');
    });

    test('同机换账号必须换槽（否则 TTL 内把 A 的库清单渲染给 B）', () {
      final JellyfinVideoClient a =
          _client(MockClient((_) async => http.Response('{}', 200)));
      final JellyfinVideoClient b = _client(
        MockClient((_) async => http.Response('{}', 200)),
        userId: 'u2',
      );
      expect(a.remoteLibrarySourceId, isNot(b.remoteLibrarySourceId));
    });

    test('sourceIdFor 与实例属性同一真相（登出失效不会拼歪）', () {
      final JellyfinVideoClient a =
          _client(MockClient((_) async => http.Response('{}', 200)));
      expect(
        JellyfinVideoClient.sourceIdFor(
          serverUrl: 'http://nas:8096',
          userId: 'u1',
        ),
        a.remoteLibrarySourceId,
      );
    });
  });

  group('[6] 服务器断点带更新时刻（LastPlayedDate）', () {
    const String kLastPlayed = '2026-08-19T10:20:30.0000000Z';
    final int kLastPlayedMs =
        DateTime.parse(kLastPlayed).millisecondsSinceEpoch;

    test('parseItem 解 UserData.LastPlayedDate -> lastPlayedAtMs', () {
      final JellyfinItem item = JellyfinApi.parseItem(_episodeJson(
        positionTicks: 42000 * kTicksPerMs,
        lastPlayedDate: kLastPlayed,
      ));
      expect(item.positionMs, 42000);
      expect(item.lastPlayedAtMs, kLastPlayedMs);
    });

    test('没给 LastPlayedDate（从未播过）-> 0，退回旧行为', () {
      expect(JellyfinApi.parseItem(_episodeJson()).lastPlayedAtMs, 0);
    });

    test('remoteVideoPosition 报真实 updatedAtMs（恒 0 会让本地 LWW 恒胜）', () async {
      final JellyfinVideoClient c =
          _client(MockClient((_) async => http.Response(
              jsonEncode(_episodeJson(
                positionTicks: 42000 * kTicksPerMs,
                lastPlayedDate: kLastPlayed,
              )),
              200)));

      final ({int positionMs, int updatedAtMs}) pos =
          await c.remoteVideoPosition('ep1');
      expect(pos.positionMs, 42000);
      expect(pos.updatedAtMs, kLastPlayedMs,
          reason:
              'fushi_library_host_service 的 localUpdatedAtMs > remoteUpdatedAtMs '
              '在 remote 恒 0 时永远成立——「手机看一半回电脑接力」就是这么坏的');
    });

    test('清单条目也带 positionUpdatedAtMs', () async {
      final JellyfinVideoClient c =
          _client(MockClient((_) async => http.Response(
              jsonEncode(<String, Object?>{
                'Items': <Object?>[
                  _episodeJson(
                    positionTicks: 60000 * kTicksPerMs,
                    lastPlayedDate: kLastPlayed,
                  ),
                ],
                'TotalRecordCount': 1,
              }),
              200)));

      final RemoteVideoInfo info = (await c.listRemoteVideos()).single;
      expect(info.positionMs, 60000);
      expect(info.positionUpdatedAtMs, kLastPlayedMs);
    });
  });

  group('[7] 异常文本里的 api_key 脱敏', () {
    const String kToken = 'SUPERSECRETTOKEN';

    MockClient throwingClient() => MockClient((http.Request req) async {
          // package:http 的 IOClient 就是这么抛的：把 request.url 整个塞进异常，
          // 而 Jellyfin 的图片/流/字幕 URL 自带 api_key。
          throw http.ClientException('Connection reset by peer', req.url);
        });

    Future<Object> caught(Future<Object?> future) =>
        future.then<Object>((Object? _) => 'no throw',
            onError: (Object e, StackTrace _) => e);

    test('fetchBytes：封面失败的异常文本不含令牌', () async {
      final JellyfinApi api = _api(throwingClient(), token: kToken);
      final Object err = await caught(api.fetchBytes(api.imageUrl('ep1')));

      expect(err.toString(), isNot(contains(kToken)),
          reason: 'ErrorLogService 存的就是 error.toString()，无脱敏落盘并可一键上传');
      expect(err.toString(), contains('api_key=$kRedactedPlaceholder'));
    });

    test('downloadToFile：整片/字幕下载失败的异常文本不含令牌', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('jf_redact_test');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final JellyfinApi api = _api(throwingClient(), token: kToken);
      final Object err = await caught(api.downloadToFile(
        api.streamUrl('ep1'),
        File('${dir.path}/out.mp4'),
      ));

      expect(err.toString(), isNot(contains(kToken)));
      expect(err.toString(), contains('api_key=$kRedactedPlaceholder'));
    });

    test('脱敏只动凭据参数，其余排查信息保留', () async {
      final JellyfinApi api = _api(throwingClient(), token: kToken);
      final Object err = await caught(api.fetchBytes(
        '${api.imageUrl('ep1')}&maxWidth=300',
      ));
      expect(err.toString(), contains('maxWidth=300'));
      expect(err.toString(), contains('/Items/ep1/Images/Primary'));
    });
  });

  group('[8] 枚举面收窄到媒体库视图（BUG-1891）', () {
    test('默认（未点名库）只递归视频域媒体库：音乐/图书库不再被扫', () async {
      final List<Uri> seen = <Uri>[];
      final JellyfinVideoClient c =
          _client(MockClient((http.Request req) async {
        seen.add(req.url);
        if (req.url.path == '/Users/u1/Views') {
          return _viewsResponse(<List<String?>>[
            <String?>['lib-movies', '电影', 'movies'],
            <String?>['lib-music', '音乐', 'music'],
            <String?>['lib-books', '图书', 'books'],
            <String?>['lib-tv', '剧集', 'tvshows'],
            <String?>['lib-mixed', '混合', null],
          ]);
        }
        final String parent = req.url.queryParameters['ParentId']!;
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': <Object?>[_tinyJson('$parent-1')],
            'TotalRecordCount': 1,
          }),
          200,
        );
      }));

      final List<RemoteVideoInfo> list = await c.listRemoteVideos();

      expect(
        seen
            .where((Uri u) => u.path == '/Users/u1/Items')
            .map((Uri u) => u.queryParameters['ParentId'])
            .toList(),
        <String>['lib-movies', 'lib-tv', 'lib-mixed'],
        reason: '整台服务器递归（不带 ParentId）在几十万条目的公共 Emby 服上就是'
            '几十上百个重查询连发；音乐/图书/照片库更是白扫',
      );
      expect(list.map((RemoteVideoInfo v) => v.id).toList(),
          <String>['lib-movies-1', 'lib-tv-1', 'lib-mixed-1']);
    });

    test('用户点名了库 → 只递归这几个，连 Views 都不问', () async {
      final List<Uri> seen = <Uri>[];
      final JellyfinVideoClient c = _client(
        MockClient((http.Request req) async {
          seen.add(req.url);
          return http.Response(
            jsonEncode(<String, Object?>{
              'Items': <Object?>[
                _tinyJson('${req.url.queryParameters['ParentId']}-1'),
              ],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }),
        libraryIds: <String>['lib-anime'],
      );

      final List<RemoteVideoInfo> list = await c.listRemoteVideos();

      expect(seen.map((Uri u) => u.path).toSet(), <String>{'/Users/u1/Items'});
      expect(seen.single.queryParameters['ParentId'], 'lib-anime');
      expect(list.single.id, 'lib-anime-1');
    });

    test('Views 失败 → 退回整库递归（宁可多扫也不能让用户的库整个消失）', () async {
      final List<Uri> seen = <Uri>[];
      final JellyfinVideoClient c =
          _client(MockClient((http.Request req) async {
        seen.add(req.url);
        if (req.url.path == '/Users/u1/Views') {
          return http.Response('', 500);
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': <Object?>[_tinyJson('m1')],
            'TotalRecordCount': 1,
          }),
          200,
        );
      }));

      final List<RemoteVideoInfo> list = await c.listRemoteVideos();

      final Uri items =
          seen.firstWhere((Uri u) => u.path == '/Users/u1/Items');
      expect(items.queryParameters.containsKey('ParentId'), isFalse);
      expect(list.single.id, 'm1');
    });

    test('同一条目同时落在两个被点名的库里只出一张卡', () async {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => http.Response(
              jsonEncode(<String, Object?>{
                'Items': <Object?>[_tinyJson('dup')],
                'TotalRecordCount': 1,
              }),
              200,
            )),
        libraryIds: <String>['a', 'b'],
      );

      final List<RemoteVideoInfo> list = await c.listRemoteVideos();
      expect(list, hasLength(1));
    });
  });
}
