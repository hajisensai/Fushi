import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/youtube_range_relay.dart';
import 'package:fushi/src/sync/cloud_video_stream_relay.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi/src/utils/net/loopback_relay_slot.dart';

/// 反馈 TUA4_h7d6a：iPad 上看完本地片再开 Jellyfin 片，mpv 每次都
/// `tcp://127.0.0.1:<同一端口> Connection refused`，只能重启 app。缓存的应用内
/// 中继监听 socket 已被系统回收，但 `isRunning` 仍为 true，于是被一直复用。
class _FakeRelay implements LoopbackRelay {
  _FakeRelay(this.port);

  @override
  final int port;

  int closeCalls = 0;

  @override
  bool get isRunning => true; // 模拟「监听 socket 被回收，Dart 侧没收到任何事件」。

  @override
  Future<void> close() async => closeCalls++;
}

void main() {
  late Future<bool> Function(int port) originalProbe;

  setUp(() => originalProbe = loopbackRelayProbe);
  tearDown(() => loopbackRelayProbe = originalProbe);

  test('loopbackListenerAccepts 区分在 accept 的端口与已关闭的端口', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final StreamSubscription<Socket> sub = server.listen(
      (Socket s) => s.destroy(),
    );
    final int port = server.port;
    expect(await loopbackListenerAccepts(port), isTrue);
    await sub.cancel();
    await server.close();
    expect(await loopbackListenerAccepts(port), isFalse);
  });

  test('自报 isRunning 但端口不再 accept 的中继会被关掉并换新', () async {
    int nextPort = 40000;
    final List<_FakeRelay> started = <_FakeRelay>[];
    final Set<int> deadPorts = <int>{};
    loopbackRelayProbe = (int port) async => !deadPorts.contains(port);
    final LoopbackRelaySlot<_FakeRelay> slot = LoopbackRelaySlot<_FakeRelay>(
      start: () async {
        final _FakeRelay relay = _FakeRelay(nextPort++);
        started.add(relay);
        return relay;
      },
      log: (_) {},
    );

    final _FakeRelay first = await slot.acquire();
    expect(await slot.acquire(), same(first), reason: '活着就复用');

    deadPorts.add(first.port); // iOS 回收了监听 socket。
    final _FakeRelay second = await slot.acquire();
    expect(second, isNot(same(first)));
    expect(first.closeCalls, 1, reason: '死中继要释放');
    expect(await slot.acquire(), same(second));
    expect(started, hasLength(2));
  });

  test('并发 acquire 只起一个中继；起失败的 Future 不缓存', () async {
    int starts = 0;
    bool fail = true;
    final LoopbackRelaySlot<_FakeRelay> slot = LoopbackRelaySlot<_FakeRelay>(
      start: () async {
        starts++;
        if (fail) throw const SocketException('bind failed');
        return _FakeRelay(41000 + starts);
      },
      log: (_) {},
    );
    loopbackRelayProbe = (int _) async => true;

    await expectLater(slot.acquire(), throwsA(isA<SocketException>()));
    fail = false;
    final List<_FakeRelay> got = await Future.wait(<Future<_FakeRelay>>[
      slot.acquire(),
      slot.acquire(),
      slot.acquire(),
    ]);
    expect(got.toSet(), hasLength(1));
    expect(starts, 2);
  });

  test('应用内网络中继端口被回收后 ensureAppNativeProxyEndpoint 换新端口', () async {
    final AppNativeProxy first = await ensureAppNativeProxy();
    expect(await ensureAppNativeProxy(), same(first));
    expect(first.isRunning, isTrue);

    final int deadPort = first.port;
    loopbackRelayProbe = (int port) async =>
        port != deadPort && await loopbackListenerAccepts(port);
    final Uri endpoint = await ensureAppNativeProxyEndpoint();
    expect(endpoint.port, isNot(deadPort));
    expect(await loopbackListenerAccepts(endpoint.port), isTrue);
    await pumpEventQueue();
    expect(first.isRunning, isFalse, reason: '旧中继被关闭释放');
  });

  test('YouTube / 云盘中继单例同样按真连探测换新', () async {
    final YoutubeRangeRelay yt = await YoutubeRangeRelay.instance();
    final CloudVideoStreamRelay cloud = await CloudVideoStreamRelay.instance();
    final Set<int> dead = <int>{yt.port, cloud.port};
    loopbackRelayProbe = (int port) async =>
        !dead.contains(port) && await loopbackListenerAccepts(port);

    final YoutubeRangeRelay yt2 = await YoutubeRangeRelay.instance();
    final CloudVideoStreamRelay cloud2 = await CloudVideoStreamRelay.instance();
    expect(yt2, isNot(same(yt)));
    expect(cloud2, isNot(same(cloud)));
    expect(await loopbackListenerAccepts(yt2.port), isTrue);
    expect(await loopbackListenerAccepts(cloud2.port), isTrue);
    await yt2.close();
    await cloud2.close();
  });
}
