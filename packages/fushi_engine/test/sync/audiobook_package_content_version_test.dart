import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 有声书包端点的导出缓存按内容版本换代（[ExportPackageCache.obtain] 的 `version`，
/// host 用 [AudiobookContentRevisionHost] 给版本）：
///
/// - 版本不变：TTL 内的普通下载 / 续传命中同一份字节，导出器不重跑；
/// - 版本变了（host 上换过音频 / 字幕）：下一次普通下载（不带 `?fresh=1`）就重新打包；
/// - 正在发送的旧包照常发完、字节完整；它之后的续传带旧 ETag，收到 200 全量新包
///   （干净地从 0 重来），绝不 206 拼两代字节。
class _AudiobookHost
    implements FushiLibraryHostService, AudiobookContentRevisionHost {
  _AudiobookHost(this.size);

  final int size;
  String revision = 'r1-a';
  int exportCalls = 0;

  /// 第 N 代导出的字节：每个字节都是导出代数，拼错一眼可见。
  List<int> bytesOf(int generation) => List<int>.filled(size, generation);

  @override
  Future<String?> audiobookContentRevision(String identity) async =>
      identity == 'Neko' ? revision : null;

  @override
  Future<File> exportAudiobook(String identity) async {
    if (identity != 'Neko') throw StateError('audiobook not found');
    exportCalls++;
    final Directory tmp = Directory.systemTemp.createTempSync('ab_exp');
    final File f = File(p.join(tmp.path, '$identity.fushiaudio'));
    f.writeAsBytesSync(bytesOf(exportCalls));
    return f;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

typedef _Res = ({int status, Map<String, String> headers, List<int> body});

void main() {
  const String token = 'ab-version-token';
  const String path = '/api/library/audiobooks/Neko';
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  group('ExportPackageCache 内容版本', () {
    test('同版本命中、换版本重导出（不等 TTL）；不给版本的老调用照旧按 TTL', () async {
      final ExportPackageCache cache = ExportPackageCache();
      addTearDown(cache.dispose);
      int calls = 0;
      Future<File> export() async {
        calls++;
        final Directory d = Directory.systemTemp.createTempSync('cache_v');
        return File(p.join(d.path, 'x.bin'))..writeAsBytesSync(<int>[calls]);
      }

      final File a = await cache.obtain(
        'audiobook',
        'x',
        export,
        version: 'v1',
      );
      final File a2 = await cache.obtain(
        'audiobook',
        'x',
        export,
        version: 'v1',
      );
      expect(a2.path, a.path);
      expect(calls, 1);

      final String etagA = await ExportPackageCache.etagFor(a2);
      final File b = await cache.obtain(
        'audiobook',
        'x',
        export,
        version: 'v2',
      );
      expect(b.path, isNot(a.path));
      expect(calls, 2);
      expect(await b.readAsBytes(), <int>[2]);
      expect(await ExportPackageCache.etagFor(b), isNot(etagA));
      expect(a.existsSync(), isFalse, reason: '换代后旧缓存文件回收（没人在读）');

      final File c = await cache.obtain('dict', 'y', export);
      final File c2 = await cache.obtain('dict', 'y', export);
      expect(c2.path, c.path);
      expect(calls, 3);
    });

    test('并发：新版本请求不搭旧版本那次还没打完的导出', () async {
      final ExportPackageCache cache = ExportPackageCache();
      addTearDown(cache.dispose);
      final Completer<void> gate = Completer<void>();
      int calls = 0;
      Future<File> export() async {
        final int n = ++calls;
        if (n == 1) await gate.future;
        final Directory d = Directory.systemTemp.createTempSync('cache_v');
        return File(p.join(d.path, 'x.bin'))..writeAsBytesSync(<int>[n]);
      }

      final Future<File> old = cache.obtain(
        'audiobook',
        'x',
        export,
        version: 'v1',
      );
      final File fresh = await cache.obtain(
        'audiobook',
        'x',
        export,
        version: 'v2',
      );
      expect(await fresh.readAsBytes(), <int>[2]);
      gate.complete();
      expect(await (await old).readAsBytes(), <int>[1]);
      expect(calls, 2);
    });
  });

  group('有声书包端点', () {
    late FushiSyncServer server;
    late _AudiobookHost lib;
    late String base;

    setUp(() async {
      lib = _AudiobookHost(4 * 1024 * 1024);
      server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('ab_srv').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: lib,
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    Future<_Res> get({Map<String, String>? extra}) async {
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

    test('内容版本不变：第二次下载命中缓存；版本变了：普通下载就拿到新包', () async {
      final _Res first = await get();
      expect(first.status, 200);
      expect(first.body, lib.bytesOf(1));
      final _Res again = await get();
      expect(again.body, lib.bytesOf(1));
      expect(lib.exportCalls, 1);

      lib.revision = 'r1-b';
      final _Res changed = await get();
      expect(changed.status, 200);
      expect(changed.body, lib.bytesOf(2), reason: '不带 ?fresh=1 也不回 TTL 内的旧包');
      expect(changed.headers['etag'], isNot(first.headers['etag']));
      expect(lib.exportCalls, 2);
    });

    test('换代时正在发送的旧包照常发完且完整；它的续传收 200 全量新包', () async {
      // 旧包下载进行中：读到第一块就停住。
      final HttpClient slow = HttpClient();
      addTearDown(() => slow.close(force: true));
      final HttpClientRequest req = await slow.getUrl(Uri.parse('$base$path'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      final String oldEtag = res.headers.value('etag')!;
      final List<int> received = <int>[];
      final StreamIterator<List<int>> it = StreamIterator<List<int>>(res);
      expect(await it.moveNext(), isTrue);
      received.addAll(it.current);
      expect(received.length, lessThan(lib.size));

      // host 上内容换了：别的设备的普通下载拿到新包（旧缓存文件被换掉 / 尝试删除）。
      lib.revision = 'r1-b';
      final _Res other = await get();
      expect(other.body, lib.bytesOf(2));

      // 旧下载接着读完：仍是第 1 代的完整字节，没有混进第 2 代。
      while (await it.moveNext()) {
        received.addAll(it.current);
      }
      expect(received.length, lib.size);
      expect(received.every((int b) => b == 1), isTrue);

      // 假设旧下载在一半处断了：带旧 ETag 续传 → 200 全量新包，不是 206。
      final _Res resumed = await get(
        extra: <String, String>{
          'Range': 'bytes=${lib.size ~/ 2}-',
          'If-Range': oldEtag,
        },
      );
      expect(resumed.status, 200, reason: '验证器换代：从 0 重下新包，绝不拼两代字节');
      expect(resumed.body, lib.bytesOf(2));
      expect(lib.exportCalls, 2);
    });

    test('同版本内的续传仍是 206 同源字节（版本门不破坏断点续传）', () async {
      final _Res first = await get();
      final _Res resumed = await get(
        extra: <String, String>{
          'Range': 'bytes=100-',
          'If-Range': first.headers['etag']!,
        },
      );
      expect(resumed.status, 206);
      expect(resumed.body, first.body.sublist(100));
      expect(lib.exportCalls, 1);
    });
  });
}
