import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 互联包端点 Range 续传守卫（提速批次二）：
///
/// 1. 包 GET（epub/词典/有声书/本地音频同一代码路径，这里以词典为代表）带
///    `ETag` + `Accept-Ranges`；TTL 内续传（Range + 匹配的 If-Range）钉在**同一
///    份缓存字节**上（导出器不被重跑）→ 206 且字节与首次 200 完全同源。
/// 2. 验证器不匹配 / 缺 If-Range 的盲 Range 一律 200 全量——`export*` 重打包
///    字节不稳定，绝不允许两代字节拼接成损坏包。
/// 3. [ExportPackageCache] TTL 过期后重导出，ETag 必换代。
/// 4. 老 host 缺合集端点：`_syncCollectionsLive` 不再静默跳过，进
///    `report.errors`（错误日志 + 手动同步失败计数可见，BUG-938 次因）。
class _PkgService implements HibikiLibraryHostService {
  int exportCalls = 0;

  @override
  Future<File> exportDictionary(String name) async {
    if (name != 'JMdict') throw StateError('dictionary not found');
    exportCalls++;
    final Directory tmp = Directory.systemTemp.createTempSync('pkg_exp');
    final File f = File(p.join(tmp.path, '$name.hibikidict'));
    // 模拟 zip 重打包字节不稳定：首字节 = 导出代数，长度也随代数变化。
    f.writeAsBytesSync(<int>[
      exportCalls,
      for (int i = 1; i < 32 + exportCalls; i++) i & 0xff,
    ]);
    return f;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

typedef _Res = ({int status, Map<String, String> headers, List<int> body});

void main() {
  const String token = 'pkg-resume-token';
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  group('包端点 Range/If-Range', () {
    late HibikiSyncServer server;
    late _PkgService lib;
    late String base;

    setUp(() async {
      lib = _PkgService();
      server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('pkg_srv').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: lib,
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    Future<_Res> get(String path, {Map<String, String>? extra}) async {
      final HttpClient c = HttpClient();
      try {
        final HttpClientRequest req = await c.getUrl(Uri.parse('$base$path'));
        req.headers.set('authorization', authHeader());
        extra?.forEach(req.headers.set);
        final HttpClientResponse res = await req.close();
        final Map<String, String> headers = <String, String>{};
        res.headers.forEach((String name, List<String> values) {
          if (values.isNotEmpty) headers[name] = values.join(',');
        });
        final List<int> body = <int>[
          for (final List<int> chunk in await res.toList()) ...chunk,
        ];
        return (status: res.statusCode, headers: headers, body: body);
      } finally {
        c.close(force: true);
      }
    }

    test('200 带 ETag/Accept-Ranges；匹配 If-Range 的续传 206 且同源字节', () async {
      const String path = '/api/library/dictionaries/JMdict';
      final _Res first = await get(path);
      expect(first.status, 200);
      expect(first.headers['accept-ranges'], 'bytes');
      final String? etag = first.headers['etag'];
      expect(etag, isNotNull, reason: '包端点必须带强验证器供 If-Range 续传');
      expect(lib.exportCalls, 1);

      final _Res resumed = await get(path, extra: <String, String>{
        'Range': 'bytes=8-',
        'If-Range': etag!,
      });
      expect(resumed.status, 206);
      expect(resumed.headers['content-range'],
          'bytes 8-${first.body.length - 1}/${first.body.length}');
      expect(resumed.body, first.body.sublist(8),
          reason: '续传字节必须与首次 200 同源（同一份缓存文件）');
      expect(lib.exportCalls, 1, reason: 'TTL 内续传绝不重跑导出器——重打包字节不稳定，重跑即拼接损坏');
    });

    test('验证器不匹配或缺 If-Range 的 Range → 200 全量（防两代字节拼接）', () async {
      const String path = '/api/library/dictionaries/JMdict';
      final _Res first = await get(path);
      expect(first.status, 200);

      final _Res stale = await get(path, extra: <String, String>{
        'Range': 'bytes=8-',
        'If-Range': '"pkg-stale-mismatch"',
      });
      expect(stale.status, 200, reason: '验证器过期 → 整包重发');
      expect(stale.body, first.body);

      final _Res blind = await get(path, extra: <String, String>{
        'Range': 'bytes=8-',
      });
      expect(blind.status, 200, reason: '包字节可能换代，缺 If-Range 的盲 Range 必须拒绝续传');
      expect(blind.body, first.body);
    });

    test('未知词典仍 404', () async {
      final _Res res = await get('/api/library/dictionaries/Nope');
      expect(res.status, 404);
    });
  });

  group('ExportPackageCache', () {
    test('TTL 内命中同一文件；过期重导出且 ETag 换代', () async {
      final ExportPackageCache cache =
          ExportPackageCache(ttl: Duration.zero); // 立即过期
      addTearDown(cache.dispose);
      int gen = 0;
      Future<File> export() async {
        gen++;
        final Directory tmp = Directory.systemTemp.createTempSync('pkg_ttl');
        final File f = File(p.join(tmp.path, 'x.bin'));
        f.writeAsBytesSync(List<int>.filled(8 + gen, gen));
        return f;
      }

      final File a = await cache.obtain('dict', 'x', export);
      final String etagA = ExportPackageCache.etagFor(a);
      final File b = await cache.obtain('dict', 'x', export);
      expect(gen, 2, reason: 'ttl=0：第二次 obtain 必须重导出');
      expect(ExportPackageCache.etagFor(b), isNot(etagA),
          reason: '字节换代 ⇒ ETag 必变（否则旧 .part 会被误续传）');

      final ExportPackageCache fresh =
          ExportPackageCache(ttl: const Duration(minutes: 5));
      addTearDown(fresh.dispose);
      gen = 0;
      final File c1 = await fresh.obtain('dict', 'x', export);
      final File c2 = await fresh.obtain('dict', 'x', export);
      expect(gen, 1, reason: 'TTL 内第二次 obtain 命中缓存不重导出');
      expect(c2.path, c1.path);
    });
  });

  group('老 host 缺合集端点可见性（BUG-938 次因）', () {
    test('_syncCollectionsLive 不再静默跳过，错误可见', () async {
      // 老 host 模拟：不挂 libraryService → /api/library/collections 404。
      final HibikiSyncServer server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('old_host').path,
        port: 0,
        token: token,
        allowLan: false,
      );
      await server.start();
      addTearDown(server.stop);

      final HibikiDatabase clientDb =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(clientDb.close);
      final SyncRepository repo = SyncRepository(clientDb);
      await repo.setHibikiClientUrls(<HibikiClientUrl>[
        HibikiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
      ]);
      await repo.setHibikiClientToken(token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
          (String url, String tok) async => true);
      await backend.restoreAuth(repo);

      final SyncRunReport report = SyncRunReport();
      await SyncOrchestrator(
        db: clientDb,
        backend: backend,
        dictionaryResourceRoot: Directory.systemTemp,
        audioDatabaseRoot: Directory.systemTemp,
        tempDir: Directory.systemTemp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
        syncLocalAudio: false,
      ).syncCollectionsLiveForTest(report, backend);

      expect(
        report.errors.any((String e) => e.contains('no collections endpoint')),
        isTrue,
        reason: '老 host 缺合集端点必须留痕（错误日志 + 手动同步失败计数），'
            '不得静默跳过让用户只看见「合集没同步」',
      );
    });
  });
}
