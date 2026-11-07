/// 反馈 kM-Gb_Xnu-：互联同步的网络往返计数回归。
///
/// 真 FushiSyncServer（带真 LocalLibraryHostService）+ 真 InterconnectSyncBackend，
/// 中间夹一层计数代理，数清 client 发出的每个请求。钉住三件事：
/// 1. 全量 sweep 不再经 WebDAV 文件箱跑书阶段（host 从不读回那份文件箱）；书进度
///    一次 `GET /api/library/book-progress` 取齐，不再每本书一次 GET；稳态请求数与
///    书数无关。老 host（无批量端点）回落逐本 GET，结果一致。
/// 2. 书进度阶段排在有声书 / 视频文件上传之前。
/// 3. 退出书的单本同步对互联直接走 live：进度真的落进 host DB，不碰文件箱。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _token = 'round-trip-count-token';

/// 一次请求在计数表里的类别：同一端点的逐书路径折成一类，WebDAV 文件箱按方法计。
String _category(String method, String path) {
  if (path.startsWith('/api/library/books/') && path.endsWith('/progress')) {
    return '$method /api/library/books/*/progress';
  }
  if (path.startsWith('/api/')) return '$method $path';
  if (path.startsWith('/$kSyncRootFolderName')) return '$method <file box>';
  return '$method $path';
}

class _Rig {
  _Rig._(this.work, this.server, this.proxy, this.hostDb);

  final Directory work;
  final FushiSyncServer server;
  final HttpServer proxy;
  final FushiDatabase hostDb;

  /// 代理看到的每个请求的类别（按到达顺序）。
  final List<String> requests = <String>[];

  void reset() => requests.clear();

  int count(String category) =>
      requests.where((String r) => r == category).length;

  int countWhere(bool Function(String r) test) => requests.where(test).length;

  Map<String, int> summary() {
    final Map<String, int> out = <String, int>{};
    for (final String r in requests) {
      out[r] = (out[r] ?? 0) + 1;
    }
    return Map<String, int>.fromEntries(
      out.entries.toList()..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            a.key.compareTo(b.key),
      ),
    );
  }

  static Future<_Rig> start({bool legacyHost = false}) async {
    final Directory work = await Directory.systemTemp.createTemp(
      'ic_round_trips_',
    );
    final FushiDatabase hostDb = _memDb();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: _token,
      allowLan: false,
      libraryService: LocalLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      ),
    );
    await server.start();
    final HttpServer proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _Rig rig = _Rig._(work, server, proxy, hostDb);
    rig._serve(legacyHost: legacyHost);
    return rig;
  }

  void _serve({required bool legacyHost}) {
    final HttpClient upstream = HttpClient();
    proxy.listen((HttpRequest inbound) async {
      final String path = inbound.uri.path;
      requests.add(_category(inbound.method, path));
      // 老 host 模拟：没有批量进度端点（老 host 把它落进 WebDAV 文件分支回 404）。
      if (legacyHost && path == kBookProgressBatchPath) {
        await inbound.drain<void>();
        inbound.response.statusCode = 404;
        await inbound.response.close();
        return;
      }
      final HttpClientRequest out = await upstream.openUrl(
        inbound.method,
        Uri.parse('http://127.0.0.1:${server.port}${inbound.uri}'),
      );
      inbound.headers.forEach((String name, List<String> values) {
        final String lower = name.toLowerCase();
        if (const <String>{
          'host',
          'accept-encoding',
          'transfer-encoding',
          'connection',
        }.contains(lower)) {
          return;
        }
        for (final String v in values) {
          out.headers.add(name, v);
        }
      });
      await out.addStream(inbound);
      final HttpClientResponse res = await out.close();
      final List<int> body = await res.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      inbound.response.statusCode = res.statusCode;
      final String? contentType = res.headers.value('content-type');
      if (contentType != null) {
        inbound.response.headers.set('Content-Type', contentType);
      }
      inbound.response.add(body);
      await inbound.response.close();
    });
  }

  Future<InterconnectSyncBackend> client(FushiDatabase db) async {
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${proxy.port}', enabled: true),
    ]);
    await repo.setFushiClientToken(_token);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    expect(await backend.restoreAuth(repo), isTrue);
    return backend;
  }

  Future<void> stop() async {
    await proxy.close(force: true);
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  }
}

Future<void> _seedBook(FushiDatabase db, String key) => db.insertEpubBook(
  EpubBooksCompanion.insert(
    bookKey: key,
    title: key,
    epubPath: '/tmp/$key.epub',
    extractDir: '/tmp/$key',
    chapterCount: 1,
    chaptersJson: '["ch1"]',
    importedAt: 0,
  ),
);

Future<void> _setPosition(
  FushiDatabase db,
  String key, {
  required int section,
  required int at,
}) async {
  final String uid = (await db.resolveEpubBookUid(key))!;
  await db.upsertReaderPosition(
    ReaderPositionsCompanion(
      bookUid: Value(uid),
      sectionIndex: Value(section),
      normCharOffset: Value(section * 100),
      charOffset: Value(section),
      updatedAt: Value(at),
    ),
  );
}

Future<ReaderPositionRow?> _positionOf(FushiDatabase db, String key) async {
  final String? uid = await db.resolveEpubBookUid(key);
  return uid == null ? null : db.getReaderPosition(uid);
}

SyncOrchestrator _orchestrator(
  FushiDatabase db,
  InterconnectSyncBackend backend,
  Directory tmp,
) => SyncOrchestrator(
  db: db,
  backend: backend,
  dictionaryResourceRoot: tmp,
  audioDatabaseRoot: tmp,
  tempDir: tmp,
  // 统计 / 有声书断点开着：旧实现正是在这两项开着时往文件箱多写。
  syncStats: true,
  syncAudioBookPosition: true,
  syncContent: false,
  syncMangaContent: false,
  syncAudioBookFiles: false,
  syncDictionary: false,
);

/// 两端各 [n] 本同名书；本端都读过（第 1 节），host 都没有进度。
Future<void> _seedLibrary(_Rig rig, FushiDatabase local, int n) async {
  for (int i = 0; i < n; i++) {
    final String key = 'Book$i';
    await _seedBook(rig.hostDb, key);
    await _seedBook(local, key);
    await _setPosition(local, key, section: 1, at: 1000 + i);
  }
}

/// 冷启动一轮 + 稳态一轮 + 读了一本之后一轮，返回三轮各自的请求清单。
Future<List<Map<String, int>>> _runThreeRounds(
  _Rig rig,
  FushiDatabase local,
  Directory tmp,
) async {
  final InterconnectSyncBackend backend = await rig.client(local);
  final List<Map<String, int>> rounds = <Map<String, int>>[];
  Future<SyncRunReport> round() async {
    rig.reset();
    final SyncRunReport report = await _orchestrator(local, backend, tmp).run();
    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(report.conflicts, isEmpty);
    rounds.add(rig.summary());
    return report;
  }

  await round(); // 冷启动：本端进度推给 host。
  await round(); // 稳态：两端一致。
  await _setPosition(local, 'Book0', section: 7, at: 50000);
  await round(); // 读了一本。
  return rounds;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ic_round_trips_tmp_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  for (final bool legacyHost in <bool>[false, true]) {
    final String label = legacyHost ? '老 host（无批量端点）' : '新 host';
    test('$label：全量 sweep 不经文件箱、书进度结果正确、稳态请求数与书数无关', () async {
      final Map<int, List<Map<String, int>>> byN =
          <int, List<Map<String, int>>>{};
      for (final int n in <int>[3, 12]) {
        final _Rig rig = await _Rig.start(legacyHost: legacyHost);
        final FushiDatabase local = _memDb();
        try {
          await _seedLibrary(rig, local, n);
          final List<Map<String, int>> rounds = await _runThreeRounds(
            rig,
            local,
            tmp,
          );
          byN[n] = rounds;
          // ignore: avoid_print
          print(
            'ROUNDTRIPS legacy=$legacyHost n=$n '
            'cold=${_total(rounds[0])} steady=${_total(rounds[1])} '
            'oneChanged=${_total(rounds[2])}\n'
            '  cold:   ${rounds[0]}\n'
            '  steady: ${rounds[1]}\n'
            '  oneChanged: ${rounds[2]}',
          );

          // 结果：每本书的进度都落进了 host DB，读过的那本是新位置。
          for (int i = 0; i < n; i++) {
            final ReaderPositionRow? host = await _positionOf(
              rig.hostDb,
              'Book$i',
            );
            expect(host, isNotNull, reason: 'Book$i');
            expect(host!.sectionIndex, i == 0 ? 7 : 1, reason: 'Book$i');
          }
          for (final Map<String, int> r in rounds) {
            // 文件箱里的书阶段整段没有了：不建书文件夹、不列、不写三件套。
            expect(r['MKCOL <file box>'] ?? 0, lessThanOrEqualTo(1));
            expect(r['PUT <file box>'] ?? 0, 0, reason: '$r');
            expect(r['DELETE <file box>'] ?? 0, 0, reason: '$r');
            expect(
              r['GET /api/library/books/*/progress'] ?? 0,
              legacyHost ? n : 0,
              reason: '$r',
            );
            expect(r['GET $kBookProgressBatchPath'] ?? 0, 1, reason: '$r');
          }
          // 读了一本：只给那一本发一次 PUT。
          expect(rounds[2]['PUT /api/library/books/*/progress'], 1);
          expect(rounds[1]['PUT /api/library/books/*/progress'] ?? 0, 0);
        } finally {
          await local.close();
          await rig.stop();
        }
      }
      if (!legacyHost) {
        // 稳态一轮的请求数与书数无关（旧实现每本书至少一次 GET /progress）。
        expect(_total(byN[12]![1]), _total(byN[3]![1]));
      }
    });
  }

  test('书进度阶段排在有声书 / 视频文件上传之前，互联不再有文件箱书阶段', () async {
    final _Rig rig = await _Rig.start();
    final FushiDatabase local = _memDb();
    try {
      await _seedLibrary(rig, local, 2);
      final InterconnectSyncBackend backend = await rig.client(local);
      final SyncRunReport report = await _orchestrator(
        local,
        backend,
        tmp,
      ).run();
      expect(report.errors, isEmpty, reason: '${report.errors}');
      final List<String> phases = report.phaseMs.keys.toList();
      expect(phases, isNot(contains('readingData')));
      expect(
        phases.indexOf('bookProgressLive'),
        lessThan(phases.indexOf('audiobook+videoFiles')),
        reason: '$phases',
      );
    } finally {
      await local.close();
      await rig.stop();
    }
  });

  group('退出书的单本同步（互联）', () {
    test('进度直接落进 host DB，不碰文件箱', () async {
      final _Rig rig = await _Rig.start();
      final FushiDatabase local = _memDb();
      try {
        await _seedLibrary(rig, local, 1);
        final InterconnectSyncBackend backend = await rig.client(local);
        rig.reset();
        final SyncConflict? conflict = await syncExitedBookOnChannel(
          db: local,
          repo: SyncRepository(local),
          backend: backend,
          book: (await local.getEpubBook('Book0'))!,
        );
        expect(conflict, isNull);
        final ReaderPositionRow? host = await _positionOf(rig.hostDb, 'Book0');
        expect(host, isNotNull);
        expect(host!.sectionIndex, 1);
        expect(host.updatedAt, 1000);
        // ignore: avoid_print
        print('ROUNDTRIPS bookExit: ${rig.summary()}');
        expect(rig.countWhere((String r) => r.endsWith('<file box>')), 0);
        expect(rig.count('GET /api/library/books/*/progress'), 1);
        expect(rig.count('PUT /api/library/books/*/progress'), 1);
      } finally {
        await local.close();
        await rig.stop();
      }
    });

    test('两端都偏离基线 → 返回 live 维度的冲突，谁都不覆盖', () async {
      final _Rig rig = await _Rig.start();
      final FushiDatabase local = _memDb();
      try {
        await _seedLibrary(rig, local, 1);
        final EpubBookRow book = (await local.getEpubBook('Book0'))!;
        await local.setSyncBaseline(
          'Book0',
          kInterconnectBookProgressDimension,
          const BookProgressBaseline(
            sectionIndex: 0,
            normCharOffset: 0,
          ).encode(),
        );
        await _setPosition(rig.hostDb, 'Book0', section: 5, at: 3000);
        final InterconnectSyncBackend backend = await rig.client(local);
        final SyncConflict? conflict = await syncExitedBookOnChannel(
          db: local,
          repo: SyncRepository(local),
          backend: backend,
          book: book,
        );
        expect(conflict, isNotNull);
        expect(conflict!.dimension, kInterconnectBookProgressDimension);
        expect(conflict.localVersion, 1000);
        expect(conflict.remoteVersion, 3000);
        expect((await _positionOf(rig.hostDb, 'Book0'))!.sectionIndex, 5);
        expect((await _positionOf(local, 'Book0'))!.sectionIndex, 1);
      } finally {
        await local.close();
        await rig.stop();
      }
    });
  });

  test('批量端点与逐本端点同口径：无进度 / 不在库的书不出现', () async {
    final _Rig rig = await _Rig.start();
    final FushiDatabase local = _memDb();
    try {
      await _seedBook(rig.hostDb, 'Read');
      await _seedBook(rig.hostDb, 'Unread');
      await _setPosition(rig.hostDb, 'Read', section: 4, at: 777);
      final InterconnectSyncBackend backend = await rig.client(local);
      final Map<String, RemoteBookProgress>? all = await backend
          .remoteBookProgressSnapshot();
      expect(all, isNotNull);
      expect(all!.keys, <String>['Read']);
      final RemoteBookProgress one = await backend.remoteBookProgress('Read');
      expect(all['Read']!.toJson(), one.toJson());
      expect(
        (await backend.remoteBookProgress('Unread')).toJson(),
        RemoteBookProgress.empty.toJson(),
      );
    } finally {
      await local.close();
      await rig.stop();
    }
  });
}

int _total(Map<String, int> m) =>
    m.values.fold<int>(0, (int a, int b) => a + b);
