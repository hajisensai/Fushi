import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1567 守卫：互联小型请求（清单 / 进度 / streamurl 等非流式端点）必须有整体
/// 超时。此前 host 接受 TCP 连接后停摆（挂起 / 断电前半死 / NAT 半开）时，
/// `req.close()` / body 读取的 future 永久悬挂——远端库页无限转圈且不自愈。
///
/// 三层守卫：
/// 1. 行为：真 socket 停摆（接受连接不回包 / 回头不回体）→ [TimeoutException]；
/// 2. 源码枚举：`await req.close()` 裸调用只允许出现在流式传输白名单里
///    （新小端点忘了走 `_sendBounded` 时变红）；
/// 3. 缓存自愈见 remote_library_cache_test.dart 的 in-flight TTL 组。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  group('BUG-1567 停摆 host 请求超时', () {
    late FushiDatabase db;
    late ServerSocket server;
    final List<Socket> accepted = <Socket>[];

    /// [onConnect] 决定停摆形态：null = 收连接后完全不回包；否则可先回响应头。
    Future<InterconnectSyncBackend> buildBackend({
      void Function(Socket socket)? onConnect,
    }) async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((Socket socket) {
        accepted.add(socket);
        // 消费入站字节但绝不回应（或只回 onConnect 给的半截响应）。
        socket.listen((_) {});
        onConnect?.call(socket);
      });
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: 'http://127.0.0.1:${server.port}'),
      ]);
      await repo.setFushiClientToken('tok');
      final InterconnectSyncBackend backend =
          InterconnectSyncBackend.withProbe((String u, String t) async => true);
      await backend.restoreAuth(repo);
      backend.requestTimeout = const Duration(milliseconds: 300);
      return backend;
    }

    setUp(() {
      db = _testDb();
    });

    tearDown(() async {
      for (final Socket s in accepted) {
        s.destroy();
      }
      accepted.clear();
      await server.close();
      await db.close();
    });

    test('接受连接后不回包：清单请求在超时窗内抛 TimeoutException', () async {
      final InterconnectSyncBackend backend = await buildBackend();
      final Stopwatch watch = Stopwatch()..start();
      await expectLater(
        backend.listRemoteBooks(),
        throwsA(isA<TimeoutException>()),
      );
      watch.stop();
      // 超时必须真的起作用（远小于旧行为的「永久悬挂」）；给调度余量到 5s。
      expect(watch.elapsedMilliseconds, lessThan(5000),
          reason: '停摆 host 必须按 requestTimeout 降级为失败，不得无限等待');
    });

    test('回了响应头但 body 断流：body 读取同样超时', () async {
      final InterconnectSyncBackend backend = await buildBackend(
        onConnect: (Socket socket) {
          // 合法响应头 + 声称 1000 字节 body，然后永远不发 body。
          socket.write('HTTP/1.1 200 OK\r\n'
              'Content-Type: application/json; charset=utf-8\r\n'
              'Content-Length: 1000\r\n'
              '\r\n');
        },
      );
      await expectLater(
        backend.listRemoteBooks(),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('进度端点（remoteBookProgress）同样被封顶', () async {
      final InterconnectSyncBackend backend = await buildBackend();
      await expectLater(
        backend.remoteBookProgress('book-1'),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('BUG-1567 源码枚举守卫', () {
    test('裸 await req.close() 只允许出现在流式传输白名单', () {
      final File f = File('lib/src/sync/interconnect_sync_backend.dart');
      expect(f.existsSync(), isTrue,
          reason: 'run from the fushi/ package root');
      final String src = f.readAsStringSync();
      // 白名单（7 处，全部有自己的超时/长传输语义）：
      // - downloadContentFile 的 open 回调 1 处（ResumableDownloader 的
      //   firstByteTimeout/bodyTimeout 负责停顿封顶）；
      // - 流式上传 6 处：putRemoteDictionary / putRemoteBook /
      //   putRemoteLocalAudio / putRemoteAudiobook / putRemoteVideo /
      //   putRemoteVideoSubtitle（body 发送时长与文件大小成正比、host 侧收尾
      //   可能分钟级，固定值封顶会砍断合法慢传输）。
      // 新增小型端点必须走 _sendBounded / _readBodyBounded；若合法新增流式端点，
      // 更新本计数并在上面白名单里记名。
      final int bareCloses = 'await req.close()'.allMatches(src).length;
      expect(bareCloses, 7,
          reason: '发现未封顶的 req.close() 裸调用（或白名单计数过期）——'
              '小型端点必须用 _sendBounded 包裹（BUG-1567）');
      // 正向：bounded 助手确实被广泛使用（防止有人整体删掉助手绕过守卫）。
      expect('_sendBounded(req)'.allMatches(src).length, greaterThan(15),
          reason: '小型端点应统一经 _sendBounded 发送');
      expect('_readBodyBounded(res)'.allMatches(src).length, greaterThan(8),
          reason: 'JSON 响应体读取应统一经 _readBodyBounded');
    });
  });
}
