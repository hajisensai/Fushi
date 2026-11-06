import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:path/path.dart' as p;

// BUG-3743：互联文件箱书阶段一次树列举取代逐本 PROPFIND。
//
// 真 FushiSyncServer + 真 InterconnectSyncBackend，中间夹一层计数代理（数清每个
// PROPFIND 的 Depth）。同一份远端 / 本地种子各起一套，一套走快照、一套走逐本，比对
// 同步方向与同步后远端文件树——只断言「结果对」不够，两条路各自算错成同一个值也会过。
//
// 代理的 legacy 模式模拟老 host：capabilities 不带 `webdav` 分组，且把
// `Depth: infinity` 改写成 `0`（老 host 对非 1 的 Depth 一律只回根自身）。

/// 远端种子：书文件夹名（sanitize 后）→ progress 的 (时间戳, 进度)；null = 文件夹在、
/// 没有 progress。不在表里 = 远端没有这本书的文件夹。
final Map<String, (int, double)?> _remote = <String, (int, double)?>{
  'Same': (1000, 0.5),
  'LocalNewer': (1000, 0.5),
  'RemoteNewer': (9000, 0.9),
  'RemoteMissing': null,
  sanitizeTtuFilename('Re:ゼロ'): (9000, 0.9),
  sanitizeTtuFilename('本 #2'): (1000, 0.5),
};

/// 本地种子：(标题, 本地进度时间戳, 共同祖先)。
const List<(String, int, int?)> _local = <(String, int, int?)>[
  ('Same', 1000, 1000),
  ('LocalNewer', 2000, 1000),
  ('RemoteNewer', 1000, 1000),
  ('RemoteMissing', 1000, null),
  ('NoFolder', 1000, null),
  ('Re:ゼロ', 1000, 1000),
  ('本 #2', 1000, 1000),
];

class _Rig {
  _Rig._(this.tmp, this.server, this.proxy, this.backend, this.db);

  final Directory tmp;
  final FushiSyncServer server;
  final HttpServer proxy;
  final InterconnectSyncBackend backend;
  final FushiDatabase db;

  /// 经代理的每个 PROPFIND 的 Depth 头（原样，改写前）。
  final List<String> propfindDepths = <String>[];

  String get fileBoxRoot => p.join(tmp.path, 'sync-data', 'fushi-data');

  static Future<_Rig> start({bool legacyHost = false}) async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'ic_tree_listing_',
    );
    final String token = FushiSyncServer.generateToken();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: token,
    );
    await server.start();

    final HttpServer proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${proxy.port}'),
    ]);
    await repo.setFushiClientToken(token);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String url, String token) async => true,
    );
    final _Rig rig = _Rig._(tmp, server, proxy, backend, db);
    rig._serveProxy(legacyHost: legacyHost);
    expect(await backend.restoreAuth(repo), isTrue);
    await rig._seed();
    return rig;
  }

  void _serveProxy({required bool legacyHost}) {
    final HttpClient upstream = HttpClient();
    proxy.listen((HttpRequest inbound) async {
      final String? depth = inbound.headers.value('depth');
      if (inbound.method == 'PROPFIND') propfindDepths.add(depth ?? '');
      final HttpClientRequest out = await upstream.openUrl(
        inbound.method,
        Uri.parse('http://127.0.0.1:${server.port}${inbound.uri.path}'),
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
      if (legacyHost && depth != null && depth != '1') {
        out.headers.set('Depth', '0');
      }
      await out.addStream(inbound);
      final HttpClientResponse res = await out.close();
      List<int> body = await res.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      if (legacyHost && inbound.uri.path == '/api/capabilities') {
        final Map<String, dynamic> caps =
            jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        caps.remove('webdav');
        body = utf8.encode(jsonEncode(caps));
      }
      inbound.response.statusCode = res.statusCode;
      final String? contentType = res.headers.value('content-type');
      if (contentType != null) {
        inbound.response.headers.set('Content-Type', contentType);
      }
      inbound.response.add(body);
      await inbound.response.close();
    });
  }

  Future<void> _seed() async {
    for (final MapEntry<String, (int, double)?> e in _remote.entries) {
      final Directory dir = Directory(p.join(fileBoxRoot, e.key))
        ..createSync(recursive: true);
      // 每本书一个无关文件：三件套必须靠前缀认出来。
      File(p.join(dir.path, 'cover_1_6.png')).writeAsBytesSync(<int>[1, 2, 3]);
      final (int, double)? prog = e.value;
      if (prog != null) {
        final (int at, double fraction) = prog;
        File(
          p.join(dir.path, 'progress_1_6_${at}_$fraction.json'),
        ).writeAsStringSync(
          jsonEncode(
            TtuProgress(
              dataId: 0,
              exploredCharCount: (fraction * 1000).round(),
              progress: fraction,
              lastBookmarkModified: at,
            ).toJson(),
          ),
        );
      }
    }
    // 根下 spill 残留与保留命名空间：不属于任何书，不得被归给某本书。
    File(p.join(fileBoxRoot, 'progress_1_6_99999_1.0.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    Directory(p.join(fileBoxRoot, '__collections__')).createSync();

    for (final (String title, int updatedAt, int? baseline) in _local) {
      final String key = sanitizeTtuFilename(title);
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: title,
          epubPath: '/tmp/$key.epub',
          extractDir: '/tmp/$key',
          chapterCount: 1,
          chaptersJson: '[{"title":"c1","characters":1000}]',
          importedAt: 1,
        ),
      );
      final String uid = (await db.resolveEpubBookUid(key))!;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(uid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(5000),
          updatedAt: Value<int>(updatedAt),
        ),
      );
      if (baseline != null) {
        // 互联通道的进度基线按通道分槽（BUG-2621），种在全局 'progress' 上会被当成
        // 「无基线」——文件箱只有 client 自己写，于是一律按导出兜底。
        await db.setSyncBaseline(
          key,
          progressBaselineDimensionOf(backend),
          baseline,
        );
      }
    }
  }

  /// 书阶段一轮：先问快照（[useSnapshot]），再逐本同步。
  Future<({List<SyncResult> directions, RemoteListingSnapshot? snapshot})>
  runBookPhase({required bool useSnapshot}) async {
    final String root = await backend.findOrCreateRootFolder();
    final RemoteListingSnapshot? snapshot = useSnapshot
        ? await backend.snapshotListing(root)
        : null;
    final List<SyncBookResult> results =
        await SyncManager(db: db, backend: backend).syncAllBooks(
          syncStats: false,
          statsSyncMode: StatisticsSyncMode.merge,
          syncAudioBook: false,
          listing: snapshot,
        );
    return (
      directions: results.map((SyncBookResult r) => r.direction).toList(),
      snapshot: snapshot,
    );
  }

  /// 同步后远端文件箱的全貌（相对路径集合），用来比两条路写出的结果。
  Set<String> remoteTree() => <String>{
    for (final FileSystemEntity e in Directory(
      fileBoxRoot,
    ).listSync(recursive: true))
      if (e is File)
        p.relative(e.path, from: fileBoxRoot).replaceAll(r'\', '/'),
  };

  Future<void> dispose() async {
    await db.close();
    await proxy.close(force: true);
    await server.stop();
    await tmp.delete(recursive: true);
  }
}

int _listingPropfinds(List<String> depths) =>
    depths.where((String d) => d == '1' || d == 'infinity').length;

void main() {
  test('快照路与逐本路方向、远端结果逐一相同；列举请求从 O(书数) 降到 1', () async {
    final _Rig viaSnapshot = await _Rig.start();
    addTearDown(viaSnapshot.dispose);
    final _Rig viaPerBook = await _Rig.start();
    addTearDown(viaPerBook.dispose);

    viaSnapshot.propfindDepths.clear();
    viaPerBook.propfindDepths.clear();
    final a = await viaSnapshot.runBookPhase(useSnapshot: true);
    final b = await viaPerBook.runBookPhase(useSnapshot: false);

    expect(a.snapshot, isNotNull, reason: '新 host 公布了树列举能力');
    expect(a.directions, b.directions);
    expect(a.directions, <SyncResult>[
      SyncResult.synced, // Same
      SyncResult.exported, // LocalNewer
      SyncResult.imported, // RemoteNewer
      SyncResult.exported, // RemoteMissing
      SyncResult.exported, // NoFolder
      SyncResult.imported, // Re:ゼロ（含 sanitize 出的 %3A）
      SyncResult.synced, // 本 #2（含空格与 #）
    ]);
    expect(viaSnapshot.remoteTree(), viaPerBook.remoteTree());

    // 冷缓存首轮：逐本路每本书一次 Depth 1；快照路一次 infinity，外加快照里没有
    // 文件夹的那一本（NoFolder，刚建出）回落逐本问一次。
    expect(_listingPropfinds(viaPerBook.propfindDepths), _local.length);
    expect(viaSnapshot.propfindDepths.where((String d) => d == 'infinity'), [
      'infinity',
    ]);
    expect(_listingPropfinds(viaSnapshot.propfindDepths), 2);

    // 稳态（同一会话第二轮，文件夹缓存已热）：快照路整个书阶段只剩一次 PROPFIND。
    viaSnapshot.propfindDepths.clear();
    viaPerBook.propfindDepths.clear();
    final a2 = await viaSnapshot.runBookPhase(useSnapshot: true);
    final b2 = await viaPerBook.runBookPhase(useSnapshot: false);
    expect(a2.directions, b2.directions);
    expect(viaSnapshot.propfindDepths, <String>['infinity']);
    expect(viaPerBook.propfindDepths, List<String>.filled(_local.length, '1'));
    expect(viaSnapshot.remoteTree(), viaPerBook.remoteTree());
  });

  test('快照与逐本 listSyncFiles 给出逐字相同的三件套 id', () async {
    final _Rig rig = await _Rig.start();
    addTearDown(rig.dispose);
    final String root = await rig.backend.findOrCreateRootFolder();
    final RemoteListingSnapshot snapshot = (await rig.backend.snapshotListing(
      root,
    ))!;
    for (final String folder in _remote.keys) {
      final String folderId = await rig.backend.ensureBookFolder(
        bookTitle: unsanitizeTtuFilename(folder),
        rootFolderId: root,
      );
      final SyncFileTrio perBook = await rig.backend.listSyncFiles(folderId);
      final SyncFileTrio fromSnapshot = snapshot.trioFor(folder);
      expect(snapshot.hasFolder(folder), isTrue, reason: folder);
      expect(fromSnapshot.progress?.id, perBook.progress?.id, reason: folder);
      expect(fromSnapshot.progress?.name, perBook.progress?.name);
      expect(fromSnapshot.statistics?.id, perBook.statistics?.id);
      expect(fromSnapshot.audioBook?.id, perBook.audioBook?.id);
    }
    expect(snapshot.hasFolder('__collections__'), isTrue);
    expect(snapshot.hasFolder('progress_1_6_99999_1.0.json'), isFalse);
  });

  test('老 host（未公布能力）：不发 infinity，快照为 null，逐本结果不变', () async {
    final _Rig legacy = await _Rig.start(legacyHost: true);
    addTearDown(legacy.dispose);
    final _Rig reference = await _Rig.start();
    addTearDown(reference.dispose);

    legacy.propfindDepths.clear();
    final a = await legacy.runBookPhase(useSnapshot: true);
    final b = await reference.runBookPhase(useSnapshot: false);

    expect(a.snapshot, isNull);
    expect(legacy.propfindDepths, isNot(contains('infinity')));
    expect(_listingPropfinds(legacy.propfindDepths), _local.length);
    expect(a.directions, b.directions);
    expect(legacy.remoteTree(), reference.remoteTree());
  });

  test('快照漏列书文件夹（如 host 只回根自身）时回落逐本，不会把书判成「远端为空」', () async {
    // 纵深防御：能力判据之外，快照里查不到某本书的文件夹时 SyncManager 回落逐本
    // 列举。这里用「声明支持、实际只回根」的 host 验证这条兜底。
    final _Rig rig = await _Rig.start();
    addTearDown(rig.dispose);
    final _Rig reference = await _Rig.start();
    addTearDown(reference.dispose);

    final RemoteListingSnapshot rootOnly = RemoteListingBuilder().build();
    final List<SyncBookResult> results =
        await SyncManager(db: rig.db, backend: rig.backend).syncAllBooks(
          syncStats: false,
          statsSyncMode: StatisticsSyncMode.merge,
          syncAudioBook: false,
          listing: rootOnly,
        );
    final b = await reference.runBookPhase(useSnapshot: false);
    expect(
      results.map((SyncBookResult r) => r.direction).toList(),
      b.directions,
    );
    expect(rig.remoteTree(), reference.remoteTree());
  });
}
