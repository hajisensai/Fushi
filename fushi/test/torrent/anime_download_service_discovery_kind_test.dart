import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/torrent/anime_download_fail_reason.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi_engine/media/torrent/qb_torrent_backend.dart';
import 'package:fushi_engine/media/torrent/qbittorrent_client.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';

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
      Future<DiscoveryImportOutcome?> Function(AnimeDownloadPlan, List<String>)?
          discoveryImporter,
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
          return const DiscoveryImportOutcome(importedCount: 1);
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
            const DiscoveryImportOutcome(),
      ).tick();

      final AnimeDownloadPlan plan = await singlePlan();
      expect(plan.status, AnimeDownloadPlan.statusFailed);
      expect(plan.failReason, isNotNull);
    });

    // 只有音频的有声书：入库移交给转录队列（0 条新增 + deferred）。下载本身
    // 成功，不能落成 import failed。
    test('kindAudiobook 入库移交转录(deferred) → imported,不是 failed', () async {
      await store.save(_plan(AnimeDownloadPlan.kindAudiobook));
      qb.torrents = <Map<String, dynamic>>[_completedTorrent()];
      await buildService(
        discoveryImporter: (AnimeDownloadPlan plan, List<String> paths) async =>
            const DiscoveryImportOutcome(summary: 'Book', deferred: true),
      ).tick();

      final AnimeDownloadPlan plan = await singlePlan();
      expect(plan.status, AnimeDownloadPlan.statusImported);
      expect(plan.failReason, isNull);
    });

    // BUG-2775：导入被挡下（这里是同名书已在库、音频没法自动附着）不能再落
    // 一句没头没脑的 import failed——落稳定原因码，任务行翻译成补救说明。
    test('discoveryImporter 被挡下 → failReason 是可翻译的原因码', () async {
      await store.save(_plan(AnimeDownloadPlan.kindAudiobook));
      qb.torrents = <Map<String, dynamic>>[_completedTorrent()];
      await buildService(
        discoveryImporter: (AnimeDownloadPlan plan, List<String> paths) async =>
            throw const DiscoveryImportBlockedException(
          DiscoveryImportBlocker.audiobookBookAlreadyInLibrary,
          'book.epub',
        ),
      ).tick();

      final AnimeDownloadPlan plan = await singlePlan();
      expect(plan.status, AnimeDownloadPlan.statusFailed);
      expect(
        parseAnimeDownloadBlockedFailReason(plan.failReason),
        DiscoveryImportBlocker.audiobookBookAlreadyInLibrary,
      );
      expect(
        describeAnimeDownloadFailReason(plan.failReason!),
        t.download_task_import_blocked_audiobook_book_exists,
      );
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

  group('describeAnimeDownloadFailReason', () {
    test('每个原因码都翻译成专门文案', () {
      for (final DiscoveryImportBlocker blocker
          in DiscoveryImportBlocker.values) {
        final String reason = animeDownloadBlockedFailReason(blocker);
        expect(parseAnimeDownloadBlockedFailReason(reason), blocker);
        final String text = describeAnimeDownloadFailReason(reason);
        expect(text, isNot(reason), reason: blocker.name);
        expect(text, isNotEmpty, reason: blocker.name);
      }
    });

    test('非原因码（旧任务/诊断文本）原样显示', () {
      expect(describeAnimeDownloadFailReason('torrent missing'),
          'torrent missing');
      expect(describeAnimeDownloadFailReason('blocked:noSuchBlocker'),
          'blocked:noSuchBlocker');
    });
  });
}
