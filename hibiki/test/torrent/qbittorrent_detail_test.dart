/// TODO-2482：外接 qBittorrent 后端「任务详情」能力的单测——
/// 拆分统计字段解析、peers/trackers/transfer/pieceStates/filePrio 各纯
/// parse 函数，以及 [QbTorrentBackend] 对 [TorrentDetailBackend] 的转发。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/qb_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 造一个「登录永远成功」的 MockClient，非登录请求交给 [handler]
/// （与 qbittorrent_client_test.dart 同款，helper 是文件私有只能复制）。
MockClient _mockWithLogin(
  Future<http.Response> Function(http.Request request) handler,
) {
  return MockClient((http.Request request) async {
    if (request.url.path == '/api/v2/auth/login') {
      return http.Response(
        'Ok.',
        200,
        headers: <String, String>{'set-cookie': 'SID=tok1; path=/'},
      );
    }
    return handler(request);
  });
}

/// 构造走 [mock] 的 qb 客户端（账密固定，测试不关心）。
QBittorrentClient _client(MockClient mock) => QBittorrentClient(
      baseUrl: 'http://qb.local:8080',
      username: 'admin',
      password: 'secret',
      client: mock,
    );

void main() {
  group('parseQbTorrentInfos 拆分统计字段（TODO-2482）', () {
    test('带全部新字段的样例 → 各拆分字段正确，numPeers 保持合并语义', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'hash': 'h1',
          'state': 'downloading',
          'num_seeds': 3,
          'num_leechs': 2,
          'num_complete': 120,
          'num_incomplete': 45,
          'time_active': 3600,
          'seeding_time': 600,
        },
      ]);
      final TorrentSnapshot info = parseQbTorrentInfos(body).single;
      expect(info.numSeeds, 3);
      expect(info.numLeechs, 2);
      expect(info.swarmSeeds, 120);
      expect(info.swarmLeechs, 45);
      expect(info.activeDurationSeconds, 3600);
      expect(info.seedingDurationSeconds, 600);
      // 旧语义回归：numPeers = num_seeds + num_leechs，不迁移。
      expect(info.numPeers, 5);
    });

    test('缺字段 / 非 int → 拆分字段全 -1，numPeers 缺省仍是 0', () {
      final TorrentSnapshot bare = parseQbTorrentInfos(
        '[{"hash":"h2","num_complete":"not-int"}]',
      ).single;
      expect(bare.numSeeds, -1);
      expect(bare.numLeechs, -1);
      expect(bare.swarmSeeds, -1);
      expect(bare.swarmLeechs, -1);
      expect(bare.activeDurationSeconds, -1);
      expect(bare.seedingDurationSeconds, -1);
      expect(bare.numPeers, 0);
    });
  });

  group('parseQbTorrentPeers', () {
    test('正常样例：字段一一映射（含 flags 原样保留）', () {
      final String body = jsonEncode(<String, dynamic>{
        'rid': 1,
        'peers': <String, dynamic>{
          '1.2.3.4:6881': <String, dynamic>{
            'ip': '1.2.3.4',
            'port': 6881,
            'client': 'qBittorrent/4.6.5',
            'progress': 0.75,
            'dl_speed': 1024,
            'up_speed': 2048,
            'downloaded': 100,
            'uploaded': 200,
            'flags': 'D U K',
          },
        },
      });
      final TorrentPeerDetail peer = parseQbTorrentPeers(body).single;
      expect(peer.address, '1.2.3.4');
      expect(peer.port, 6881);
      expect(peer.client, 'qBittorrent/4.6.5');
      expect(peer.progress, 0.75);
      expect(peer.downSpeedBps, 1024);
      expect(peer.upSpeedBps, 2048);
      expect(peer.downloadedBytes, 100);
      expect(peer.uploadedBytes, 200);
      expect(peer.flags, 'D U K');
    });

    test('ip 缺失时从 map key 拆地址与端口（含 IPv6 key）', () {
      final String body = jsonEncode(<String, dynamic>{
        'peers': <String, dynamic>{
          '5.6.7.8:51413': <String, dynamic>{'client': 'x'},
          '[::1]:6881': <String, dynamic>{'client': 'y'},
        },
      });
      final List<TorrentPeerDetail> peers = parseQbTorrentPeers(body);
      expect(peers, hasLength(2));
      expect(peers[0].address, '5.6.7.8');
      expect(peers[0].port, 51413);
      // IPv6 key 按最后一个 `:` 拆，地址保留括号原样。
      expect(peers[1].address, '[::1]');
      expect(peers[1].port, 6881);
    });

    test('坏 JSON / peers 非 Map / 条目非 Map → 空表或跳过', () {
      expect(parseQbTorrentPeers('not json'), isEmpty);
      expect(parseQbTorrentPeers('[]'), isEmpty);
      expect(parseQbTorrentPeers('{"peers":[1,2]}'), isEmpty);
      final List<TorrentPeerDetail> peers = parseQbTorrentPeers(
        '{"peers":{"1.2.3.4:1":"bad","2.3.4.5:2":{"port":2}}}',
      );
      expect(peers, hasLength(1));
      expect(peers.single.address, '2.3.4.5');
    });
  });

  group('parseQbTrackers', () {
    test('正常条目：status 映射 + scrape 数与 msg', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'url': 'http://tracker.example/announce',
          'tier': 1,
          'status': 2,
          'num_seeds': 10,
          'num_leeches': 5,
          'num_downloaded': 99,
          'msg': 'ok',
        },
      ]);
      final TorrentTrackerDetail t = parseQbTrackers(body).single;
      expect(t.url, 'http://tracker.example/announce');
      expect(t.tier, 1);
      expect(t.status, TorrentTrackerStatus.working);
      expect(t.seeds, 10);
      expect(t.leeches, 5);
      expect(t.downloaded, 99);
      expect(t.message, 'ok');
    });

    test('DHT 伪条目保留导出：tier -1 归 0 且 status=disabled', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'url': '** [DHT] **', 'tier': -1, 'status': 2},
        <String, dynamic>{
          'url': 'http://t/announce',
          'tier': 0,
          'status': 4,
          'msg': 'timed out',
        },
      ]);
      final List<TorrentTrackerDetail> trackers = parseQbTrackers(body);
      expect(trackers, hasLength(2), reason: '伪条目留给 UI 决定显示与否，解析层不丢');
      expect(trackers[0].url, '** [DHT] **');
      expect(trackers[0].tier, 0);
      expect(trackers[0].status, TorrentTrackerStatus.disabled);
      expect(trackers[1].status, TorrentTrackerStatus.notWorking);
      expect(trackers[1].message, 'timed out');
    });

    test('未知 status / 缺 scrape 字段 → notContacted 与 -1', () {
      final TorrentTrackerDetail t = parseQbTrackers(
        '[{"url":"http://t/announce","status":42}]',
      ).single;
      expect(t.status, TorrentTrackerStatus.notContacted);
      expect(t.seeds, -1);
      expect(t.leeches, -1);
      expect(t.downloaded, -1);
      expect(t.message, '');
    });

    test('坏 JSON / 非数组 / 缺 url → 空表或跳过', () {
      expect(parseQbTrackers('not json'), isEmpty);
      expect(parseQbTrackers('{"a":1}'), isEmpty);
      expect(parseQbTrackers('[{"tier":0},1]'), isEmpty);
    });
  });

  group('parseQbTransferInfo', () {
    test('解析速率与 DHT 节点数；开关字段留 null 待组合', () {
      final TorrentSessionStatusInfo info = parseQbTransferInfo(
        '{"dl_info_speed":1000,"up_info_speed":2000,"dht_nodes":386}',
      )!;
      expect(info.downRateBps, 1000);
      expect(info.upRateBps, 2000);
      expect(info.dhtNodes, 386);
      expect(info.dhtEnabled, isNull);
      expect(info.lsdEnabled, isNull);
      expect(info.pexEnabled, isNull);
      expect(info.portMappings, isEmpty);
    });

    test('缺字段 → -1；坏 JSON / 非 Map → null', () {
      final TorrentSessionStatusInfo info = parseQbTransferInfo('{}')!;
      expect(info.downRateBps, -1);
      expect(info.upRateBps, -1);
      expect(info.dhtNodes, -1);
      expect(parseQbTransferInfo('not json'), isNull);
      expect(parseQbTransferInfo('[1,2]'), isNull);
    });
  });

  group('parseQbPieceStates', () {
    test('int 数组正常解析，haveCount 只数 2', () {
      final TorrentPieceStates states = parseQbPieceStates('[0,1,2,2,0]')!;
      expect(states.states, <int>[0, 1, 2, 2, 0]);
      expect(states.numPieces, 5);
      expect(states.haveCount, 2);
    });

    test('非数组 → null；非 int 条目按 0（缺）处理', () {
      expect(parseQbPieceStates('not json'), isNull);
      expect(parseQbPieceStates('{"a":1}'), isNull);
      expect(parseQbPieceStates('[2,"x",null,1]')!.states, <int>[2, 0, 0, 1]);
    });
  });

  group('parseQbFilePriorities', () {
    test('乱序 index 按位落座；0/1/4/5/6/7 全值域映射', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'index': 3, 'priority': 7},
        <String, dynamic>{'index': 0, 'priority': 0},
        <String, dynamic>{'index': 2, 'priority': 6},
        <String, dynamic>{'index': 1, 'priority': 4},
        <String, dynamic>{'index': 4, 'priority': 1},
        <String, dynamic>{'index': 5, 'priority': 5},
      ]);
      expect(parseQbFilePriorities(body), <TorrentFilePriority>[
        TorrentFilePriority.skip, // index 0 <- priority 0
        TorrentFilePriority.normal, // index 1 <- priority 4
        TorrentFilePriority.high, // index 2 <- priority 6
        TorrentFilePriority.high, // index 3 <- priority 7
        TorrentFilePriority.normal, // index 4 <- priority 1
        TorrentFilePriority.normal, // index 5 <- priority 5
      ]);
    });

    test('index 缺失按出现序；坏条目 → 该条 normal', () {
      final List<TorrentFilePriority> out = parseQbFilePriorities(
        '[{"priority":0},{"priority":"bad"},1]',
      )!;
      expect(out, <TorrentFilePriority>[
        TorrentFilePriority.skip,
        TorrentFilePriority.normal,
        TorrentFilePriority.normal,
      ]);
    });

    test('坏 JSON / 非数组 → null（区别于空种子的空表）', () {
      expect(parseQbFilePriorities('not json'), isNull);
      expect(parseQbFilePriorities('{"a":1}'), isNull);
      expect(parseQbFilePriorities('[]'), isEmpty);
    });
  });

  group('fetchSessionStatus（组合 transfer/info + preferences）', () {
    test('两个端点都成功 → 完整组合', () async {
      final QBittorrentClient client = _client(
        _mockWithLogin((http.Request request) async {
          if (request.url.path == '/api/v2/transfer/info') {
            return http.Response(
              '{"dl_info_speed":111,"up_info_speed":222,"dht_nodes":333}',
              200,
            );
          }
          expect(request.url.path, '/api/v2/app/preferences');
          return http.Response(
            '{"dht":true,"lsd":false,"pex":true,"listen_port":51413,'
            '"upnp":true}',
            200,
          );
        }),
      );
      final TorrentSessionStatusInfo info =
          (await client.fetchSessionStatus())!;
      expect(info.downRateBps, 111);
      expect(info.upRateBps, 222);
      expect(info.dhtNodes, 333);
      expect(info.dhtEnabled, isTrue);
      expect(info.lsdEnabled, isFalse);
      expect(info.pexEnabled, isTrue);
      expect(info.listenPort, 51413);
      // qb API 拿不到端口映射结果，upnp 开关不伪造成一条成功映射。
      expect(info.portMappings, isEmpty);
      client.close();
    });

    test('preferences 失败 → 降级返回 transfer 侧部分数据（开关 null）', () async {
      final QBittorrentClient client = _client(
        _mockWithLogin((http.Request request) async {
          if (request.url.path == '/api/v2/transfer/info') {
            return http.Response('{"dl_info_speed":10,"dht_nodes":7}', 200);
          }
          return http.Response('', 500);
        }),
      );
      final TorrentSessionStatusInfo info =
          (await client.fetchSessionStatus())!;
      expect(info.downRateBps, 10);
      expect(info.dhtNodes, 7);
      expect(info.dhtEnabled, isNull);
      expect(info.lsdEnabled, isNull);
      expect(info.pexEnabled, isNull);
      expect(info.listenPort, 0);
      client.close();
    });

    test('两个端点都失败 → null', () async {
      final QBittorrentClient client = _client(
        _mockWithLogin((http.Request request) async => http.Response('', 500)),
      );
      expect(await client.fetchSessionStatus(), isNull);
      client.close();
    });
  });

  group('detail 端点方法（请求形状 + 失败返 null）', () {
    test('fetchTorrentPeers 带 hash 与 rid=0；非 200 → null', () async {
      late http.Request seen;
      int status = 200;
      final QBittorrentClient client = _client(
        _mockWithLogin((http.Request request) async {
          seen = request;
          return http.Response('{"peers":{}}', status);
        }),
      );
      expect(await client.fetchTorrentPeers('abc'), isEmpty);
      expect(seen.url.path, '/api/v2/sync/torrentPeers');
      expect(seen.url.queryParameters,
          <String, String>{'hash': 'abc', 'rid': '0'});
      status = 404;
      expect(await client.fetchTorrentPeers('abc'), isNull);
      expect(await client.fetchTorrentPeers(''), isNull);
      client.close();
    });

    test('fetchTrackers / fetchFilePriorities / fetchPieceStates 路径正确',
        () async {
      final List<String> paths = <String>[];
      final QBittorrentClient client = _client(
        _mockWithLogin((http.Request request) async {
          paths.add(request.url.path);
          expect(request.url.queryParameters['hash'], 'abc');
          return http.Response('[]', 200);
        }),
      );
      expect(await client.fetchTrackers('abc'), isEmpty);
      expect(await client.fetchFilePriorities('abc'), isEmpty);
      expect(await client.fetchPieceStates('abc'), isNotNull);
      expect(paths, <String>[
        '/api/v2/torrents/trackers',
        '/api/v2/torrents/files',
        '/api/v2/torrents/pieceStates',
      ]);
      expect(await client.fetchTrackers(''), isNull);
      expect(await client.fetchFilePriorities(''), isNull);
      expect(await client.fetchPieceStates(''), isNull);
      client.close();
    });
  });

  group('QbTorrentBackend（TorrentDetailBackend 转发）', () {
    test('实现 TorrentDetailBackend 且能力恒可用', () {
      final QbTorrentBackend backend = QbTorrentBackend(
        _client(_mockWithLogin(
            (http.Request request) async => http.Response('', 500))),
      );
      expect(backend, isA<TorrentDetailBackend>());
      expect(backend.detailAvailable, isTrue);
      backend.close();
    });

    test('setFilePriority：form 参数 hash/id/priority 且枚举映射 0/1/6', () async {
      final List<Map<String, String>> forms = <Map<String, String>>[];
      final QbTorrentBackend backend = QbTorrentBackend(
        _client(_mockWithLogin((http.Request request) async {
          expect(request.url.path, '/api/v2/torrents/filePrio');
          forms.add(request.bodyFields);
          return http.Response('', 200);
        })),
      );
      expect(
        await backend.setFilePriority('abc', 2, TorrentFilePriority.skip),
        isTrue,
      );
      expect(
        await backend.setFilePriority('abc', 3, TorrentFilePriority.normal),
        isTrue,
      );
      expect(
        await backend.setFilePriority('abc', 4, TorrentFilePriority.high),
        isTrue,
      );
      expect(forms, <Map<String, String>>[
        <String, String>{'hash': 'abc', 'id': '2', 'priority': '0'},
        <String, String>{'hash': 'abc', 'id': '3', 'priority': '1'},
        <String, String>{'hash': 'abc', 'id': '4', 'priority': '6'},
      ]);
      backend.close();
    });

    test('listPeers / listTrackers / sessionStatus / pieceStates 纯转发',
        () async {
      final List<String> paths = <String>[];
      final QbTorrentBackend backend = QbTorrentBackend(
        _client(_mockWithLogin((http.Request request) async {
          paths.add(request.url.path);
          if (request.url.path == '/api/v2/sync/torrentPeers') {
            return http.Response('{"peers":{}}', 200);
          }
          if (request.url.path == '/api/v2/transfer/info') {
            return http.Response('{"dl_info_speed":1}', 200);
          }
          if (request.url.path == '/api/v2/app/preferences') {
            return http.Response('{"dht":true}', 200);
          }
          return http.Response('[]', 200);
        })),
      );
      expect(await backend.listPeers('abc'), isEmpty);
      expect(await backend.listTrackers('abc'), isEmpty);
      expect(await backend.filePriorities('abc'), isEmpty);
      expect((await backend.sessionStatus())!.downRateBps, 1);
      expect((await backend.pieceStates('abc'))!.numPieces, 0);
      expect(paths, <String>[
        '/api/v2/sync/torrentPeers',
        '/api/v2/torrents/trackers',
        '/api/v2/torrents/files',
        '/api/v2/transfer/info',
        '/api/v2/app/preferences',
        '/api/v2/torrents/pieceStates',
      ]);
      backend.close();
    });
  });
}
