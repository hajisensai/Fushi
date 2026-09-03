import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi/src/media/torrent/qb_torrent_backend.dart';
import 'package:fushi/src/media/torrent/qbittorrent_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';

const String _kHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

const QbConnectionConfig _kConfig = QbConnectionConfig(
  baseUrl: 'http://127.0.0.1:8080',
  username: 'admin',
  password: 'secret',
);

/// 最小 qb 假后端（形状同 anime_download_service_test.dart 的 _FakeQb）。
class _FakeQb {
  List<Map<String, dynamic>> torrents = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> files = <Map<String, dynamic>>[];

  late final MockClient mock = MockClient((http.Request request) async {
    final String path = request.url.path;
    if (path == '/api/v2/auth/login') {
      return http.Response(
        'Ok.',
        200,
        headers: <String, String>{'set-cookie': 'SID=fake123; path=/'},
      );
    }
    if (path == '/api/v2/torrents/info') {
      return http.Response(jsonEncode(torrents), 200);
    }
    if (path == '/api/v2/torrents/files') {
      return http.Response(jsonEncode(files), 200);
    }
    return http.Response('not found', 404);
  });

  TorrentBackend newBackend(QbConnectionConfig config) {
    return QbTorrentBackend(
      QBittorrentClient(
        baseUrl: config.baseUrl,
        username: config.username,
        password: config.password,
        client: mock,
      ),
    );
  }
}

AnimeDownloadPlan _plan(String contentKind) {
  return AnimeDownloadPlan(
    id: _kHash,
    createdAtMs: DateTime.now().millisecondsSinceEpoch,
    seriesTitle: 'Pack',
    torrentTitle: 'Pack Torrent',
    magnet: 'magnet:?xt=urn:btih:$_kHash',
    qbCategory: 'hibiki',
    contentKind: contentKind,
  );
}

Map<String, dynamic> _completedTorrent() => <String, dynamic>{
      'hash': _kHash,
      'name': 'torrent',
      'progress': 1.0,
      'state': 'stalledUP',
      'save_path': '/dl',
      'content_path': '/dl/Pack',
      'amount_left': 0,
    };

void main() {
  group('resolveAllAbsolutePaths', () {
    test('全文件 join savePath，不按扩展名过滤', () {
      const TorrentSnapshot info = TorrentSnapshot(
        hash: _kHash,
        name: 'torrent',
        progress: 1,
        state: 'stalledUP',
        savePath: '/dl',
        contentPath: '/dl/Pack',
        amountLeft: 0,
      );
      final List<String> all =
          resolveAllAbsolutePaths(info, const <TorrentFileEntry>[
        TorrentFileEntry(name: 'Pack/game.exe', size: 1, progress: 1, index: 0),
        TorrentFileEntry(name: 'Pack/data.xp3', size: 1, progress: 1, index: 1),
      ]);
      expect(all, <String>[
        p.join('/dl', 'Pack/game.exe'),
        p.join('/dl', 'Pack/data.xp3'),
      ]);
    });

    test('files 为空退化用 contentPath', () {
      const TorrentSnapshot info = TorrentSnapshot(
        hash: _kHash,
        name: 'torrent',
        progress: 1,
        state: 'stalledUP',
        savePath: '/dl',
        contentPath: '/dl/single.rar',
        amountLeft: 0,
      );
      expect(
        resolveAllAbsolutePaths(info, const <TorrentFileEntry>[]),
        <String>['/dl/single.rar'],
      );
    });
  });

  group('发现页内容类型（audiobook/game）的收尾', () {
    late Directory tempDir;
    late AnimeDownloadPlanStore store;
    late _FakeQb qb;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('anime_dl_discovery_test');
      store = AnimeDownloadPlanStore(
        baseDir: Directory(p.join(tempDir.path, 'anime_downloads')),
      );
      qb = _FakeQb();
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    AnimeDownloadService buildService({
      Future<int?> Function(AnimeDownloadPlan, List<String>)? discoveryImporter,
    }) {
      return AnimeDownloadService(
        store: store,
        configProvider: () => _kConfig,
        importer: (AnimeDownloadPlan plan, List<String> videos) async {
          fail('video importer must not run for discovery kinds');
        },
        bookImporter: (AnimeDownloadPlan plan, List<String> books) async {
          fail('book importer must not run for discovery kinds');
        },
        discoveryImporter: discoveryImporter,
        backendFactory: qb.newBackend,
      );
    }

    Future<AnimeDownloadPlan> singlePlan() async =>
        (await store.loadAll()).single;

    test('kindGame 完成 → 整包路径交给 discoveryImporter → imported', () async {
      await store.save(_plan(AnimeDownloadPlan.kindGame));
      qb.torrents = <Map<String, dynamic>>[_completedTorrent()];
      qb.files = <Map<String, dynamic>>[
        <String, dynamic>{'name': 'Pack/game.exe', 'size': 10, 'progress': 1.0},
        <String, dynamic>{'name': 'Pack/data.xp3', 'size': 99, 'progress': 1.0},
      ];
      final List<(String, List<String>)> calls = <(String, List<String>)>[];
      await buildService(
        discoveryImporter: (AnimeDownloadPlan plan, List<String> paths) async {
          calls.add((plan.contentKind, paths));
          return 1;
        },
      ).tick();

      expect(calls.single.$1, AnimeDownloadPlan.kindGame);
      expect(calls.single.$2, hasLength(2));
      expect(
        (await singlePlan()).status,
        AnimeDownloadPlan.statusImported,
      );
    });

    test('kindAudiobook 导入 0 条 → failed 带原因', () async {
      await store.save(_plan(AnimeDownloadPlan.kindAudiobook));
      qb.torrents = <Map<String, dynamic>>[_completedTorrent()];
      await buildService(
        discoveryImporter: (AnimeDownloadPlan plan, List<String> paths) async =>
            0,
      ).tick();

      final AnimeDownloadPlan plan = await singlePlan();
      expect(plan.status, AnimeDownloadPlan.statusFailed);
      expect(plan.failReason, isNotNull);
    });

    test('discoveryImporter 抛异常 → failed 收进 failReason', () async {
      await store.save(_plan(AnimeDownloadPlan.kindGame));
      qb.torrents = <Map<String, dynamic>>[_completedTorrent()];
      await buildService(
        discoveryImporter: (AnimeDownloadPlan plan, List<String> paths) async =>
            throw StateError('boom'),
      ).tick();

      final AnimeDownloadPlan plan = await singlePlan();
      expect(plan.status, AnimeDownloadPlan.statusFailed);
      expect(plan.failReason, contains('boom'));
    });

    test('未注入 discoveryImporter → failed unsupported', () async {
      await store.save(_plan(AnimeDownloadPlan.kindGame));
      qb.torrents = <Map<String, dynamic>>[_completedTorrent()];
      await buildService().tick();

      final AnimeDownloadPlan plan = await singlePlan();
      expect(plan.status, AnimeDownloadPlan.statusFailed);
      expect(plan.failReason, contains('unsupported'));
    });
  });
}
