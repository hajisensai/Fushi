import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// BUG-908 LAN 同步服务器健壮性守卫。
///
/// (a) 音频查词 token POST 侧无 prune 无 cap → 内存膨胀（行为单测）。
/// (b) PROPFIND 逐项 stat 同步阻塞 → 改异步（源码扫描守卫）。
/// (d) WebDAV 并发写无互斥 → 按路径串行闸门（源码扫描守卫）。
class _FloodLookupService implements HibikiRemoteLookupService {
  _FloodLookupService(this._bytes);

  final Uint8List _bytes;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async =>
      RemoteAudioLookup(bytes: _bytes, contentType: 'audio/mpeg');

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      null;
}

/// 读取被测源文件（从 hibiki/ 包根运行）。
String _readServerSource() {
  final File f = File('lib/src/sync/hibiki_sync_server.dart');
  expect(f.existsSync(), isTrue, reason: 'run from the hibiki/ package root');
  return f.readAsStringSync();
}

/// 截取 [source] 中从 [startMarker] 到 [endMarker] 之间的方法体片段。
String _sliceMethod(String source, String startMarker, String endMarker) {
  final int start = source.indexOf(startMarker);
  expect(start, greaterThan(-1), reason: 'missing: $startMarker');
  final int end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, greaterThan(start),
      reason: 'missing end marker after $startMarker');
  return source.substring(start, end);
}

void main() {
  group('BUG-908(a) 音频 token 数量上限', () {
    late HibikiSyncServer server;
    late Directory tempDir;
    const String token = 'bug901-audio-cap';
    late String base;
    final DateTime clock = DateTime(2026, 1, 1, 12, 0, 0);

    String authHeader() =>
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('hbk_audio_cap');
      server = HibikiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: false,
        remoteLookupService:
            _FloodLookupService(Uint8List.fromList(utf8.encode('MP3'))),
        // 时钟固定：所有 token 都在 5 分钟 TTL 内，TTL prune 清不掉任何 token，
        // 故数量收束只能来自 cap 逐出——这才真正验证 cap 生效。
        now: () => clock,
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<void> mintOne(int i) async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.postUrl(Uri.parse('$base/api/lookup/audio'));
      req.headers.set('authorization', authHeader());
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(<String, String>{
        'expression': 'word-$i',
        'reading': 'r-$i',
      })));
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      await res.drain<void>();
      c.close();
    }

    test('狂发 POST 塞 token 时数量被上限约束（最旧被逐出）', () async {
      // 连发远超上限（128）的签发请求，全在 TTL 内（时钟不动）。
      for (int i = 0; i < 300; i++) {
        await mintOne(i);
      }
      // 不应无界增长：被上限 + 淘汰最旧者控制住。
      expect(server.remoteAudioTokenCount, lessThanOrEqualTo(128),
          reason: 'POST 侧必须在签发前 enforce cap，否则 _remoteAudioTokens 无界膨胀');
    });
  });

  group('BUG-908(b) PROPFIND 逐项 stat 异步化（源码守卫）', () {
    test('_handlePropfind 区间不再有 lengthSync / typeSync', () {
      final String src = _readServerSource();
      final String body = _sliceMethod(
        src,
        'Future<shelf.Response> _handlePropfind(',
        'Future<shelf.Response> _handleGet(',
      );
      expect(body.contains('lengthSync'), isFalse,
          reason: 'PROPFIND 文件长度必须用 await stat().size，不得同步阻塞');
      expect(body.contains('typeSync'), isFalse,
          reason: 'PROPFIND 类型判定必须用 await FileSystemEntity.type');
      // 正向：确实改成了异步 stat。
      expect(body.contains('await FileSystemEntity.type('), isTrue);
      expect(body.contains('.stat()).size'), isTrue);
    });
  });

  group('BUG-908(d) WebDAV 写操作串行闸门（源码守卫）', () {
    test('PUT / MKCOL / DELETE 分发都经过 _serializeDavWrite', () {
      final String src = _readServerSource();
      final String dispatch = _sliceMethod(
        src,
        "case 'PUT':",
        "case 'HEAD':",
      );
      expect(dispatch.contains('_serializeDavWrite(fsPath, () => _handlePut('),
          isTrue,
          reason: 'PUT 必须经串行闸门');
      expect(
          dispatch.contains('_serializeDavWrite(fsPath, () => _handleMkcol('),
          isTrue,
          reason: 'MKCOL 必须经串行闸门');
      expect(
          dispatch.contains('_serializeDavWrite(fsPath, () => _handleDelete('),
          isTrue,
          reason: 'DELETE 必须经串行闸门');
    });

    test('_serializeDavWrite 存在且是按路径链式串行实现', () {
      final String src = _readServerSource();
      expect(src.contains('Future<T> _serializeDavWrite<T>('), isTrue,
          reason: '串行闸门 helper 必须存在');
      final String body = _sliceMethod(
        src,
        'Future<T> _serializeDavWrite<T>(',
        'Future<shelf.Response> _handlePair(',
      );
      // 链式：取前驱 → 挂新链尾 → await 前驱 → 执行 → 收尾摘除。
      expect(body.contains('_davWriteChain[fsPath]'), isTrue);
      expect(body.contains('await prev'), isTrue);
      expect(body.contains('_davWriteChain.remove(fsPath)'), isTrue);
    });
  });
}
