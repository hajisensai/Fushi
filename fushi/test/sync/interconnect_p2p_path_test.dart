import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_p2p_app.dart';
import 'package:fushi/src/sync/interconnect_p2p_path_badge.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart';

/// 「一直走中继」提示（docs/specs/2026-09-28-interconnect-remote-reach.md §9）：
/// iroh 建连先走中继、几秒内再升级直连，只有持续走中继才该提示。
void main() {
  FushiP2pConnStatus status(FushiP2pPathKind path, {bool connected = true}) =>
      FushiP2pConnStatus(
        connected: connected,
        path: path,
        rttMs: 42,
        directPaths: path == FushiP2pPathKind.direct ? 1 : 0,
        relayPaths: path == FushiP2pPathKind.relay ? 1 : 0,
      );

  group('InterconnectP2pPathTracker', () {
    final DateTime t0 = DateTime.utc(2026, 9, 28, 12);

    test('刚连上走中继不提示，持续满阈值才提示', () {
      final InterconnectP2pPathTracker tracker = InterconnectP2pPathTracker();
      expect(tracker.observe(status(FushiP2pPathKind.relay), t0), isFalse);
      expect(
        tracker.observe(
          status(FushiP2pPathKind.relay),
          t0.add(kInterconnectRelayOnlyAfter - const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(
        tracker.observe(
          status(FushiP2pPathKind.relay),
          t0.add(kInterconnectRelayOnlyAfter),
        ),
        isTrue,
      );
    });

    test('升级直连 / 断开 / 混合路径都重新计时', () {
      for (final FushiP2pConnStatus reset in <FushiP2pConnStatus>[
        status(FushiP2pPathKind.direct),
        status(FushiP2pPathKind.mixed),
        status(FushiP2pPathKind.relay, connected: false),
      ]) {
        final InterconnectP2pPathTracker tracker = InterconnectP2pPathTracker();
        tracker.observe(status(FushiP2pPathKind.relay), t0);
        expect(
          tracker.observe(reset, t0.add(const Duration(seconds: 5))),
          isFalse,
        );
        expect(
          tracker.observe(
            status(FushiP2pPathKind.relay),
            t0.add(kInterconnectRelayOnlyAfter + const Duration(seconds: 1)),
          ),
          isFalse,
          reason: '$reset 之后重新计时，不能沿用最早那次中继的起点',
        );
      }
    });
  });

  testWidgets('没有 P2P 运行时：徽标什么都不画、不起定时器', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: InterconnectP2pPathBadge(url: 'p2p://$_nodeHex')),
      ),
    );
    expect(find.byType(Text), findsNothing);
    // 定时器泄漏会让 testWidgets 在结束时报 pending timer。
    await tester.pumpWidget(const SizedBox());
  });

  group('parseInterconnectP2pUrl 按 iroh 口径校验 NodeId', () {
    test('不是 64 hex / 52 base32 的 NodeId → null', () {
      for (final String bad in <String>[
        'p2p://xyz',
        'p2p://not-a-node',
        'p2p://${'a' * 63}',
        'p2p://${'a' * 65}',
        'p2p://${'g' * 64}',
        'p2p://${'a' * 51}',
        'p2p://${'a' * 53}',
        'p2p://${'1' * 52}',
      ]) {
        expect(parseInterconnectP2pUrl(bad), isNull, reason: bad);
      }
    });

    test('64 hex 与 52 base32 都能解析；大写解析后为小写', () {
      expect(parseInterconnectP2pUrl('p2p://$_nodeHex')!.nodeId, _nodeHex);
      final String b32 = 'ab2c' * 13;
      expect(parseInterconnectP2pUrl('p2p://$b32?tls=1')!.nodeId, b32);
      expect(
        parseInterconnectP2pUrl('p2p://${b32.toUpperCase()}')!.nodeId,
        b32,
      );
      final String upperHex = '0123456789ABCDEF' * 4;
      expect(
        parseInterconnectP2pUrl('p2p://$upperHex')!.nodeId,
        upperHex.toLowerCase(),
        reason: '原生 hex 分支只认小写，传出去的必须已经是小写',
      );
    });
  });

  group('InterconnectP2pNode.status', () {
    test('节点已关闭 → null，不再碰原生端点', () async {
      final _StatusPort port = _StatusPort();
      final InterconnectP2pNode node = InterconnectP2pNode.forTesting(
        port,
        'self',
      );
      expect(node.status(_nodeHex)?.connected, isTrue);
      await node.close();
      expect(node.status(_nodeHex), isNull);
      expect(port.calls, 1);
    });
  });

  group('路径徽章的 FFI 异常边界', () {
    late _StatusPort port;
    late InterconnectP2pNode node;

    setUp(() async {
      await ErrorLogService.instance.clear();
      port = _StatusPort();
      node = InterconnectP2pNode.forTesting(port, 'self');
      bindInterconnectP2pClient(
        InterconnectP2pRuntime(
          loadSecret: () async => null,
          saveSecret: (String _) async {},
          loadRelayUrls: () async => const <String>[],
        )..debugInstall(node),
      );
    });

    tearDown(() async {
      debugResetAppInterconnectP2p();
      await ErrorLogService.instance.clear();
    });

    int badgeErrors() => ErrorLogService.instance.entries
        .where((ErrorLogEntry e) => e.source == 'P2pPathBadge')
        .length;

    Widget app(String url) => MaterialApp(
      home: Scaffold(body: InterconnectP2pPathBadge(url: url)),
    );

    testWidgets('status 抛 FFI 异常：本拍按无状态显示、继续轮询、同一错误只留痕一次', (
      WidgetTester tester,
    ) async {
      port.failure = const FushiP2pException('endpoint is closed');
      await tester.pumpWidget(app('p2p://$_nodeHex'));
      expect(tester.takeException(), isNull);
      expect(port.calls, 0, reason: 'initState 不同步碰 FFI');
      await tester.pump(Duration.zero);
      expect(tester.takeException(), isNull);
      expect(port.calls, 1, reason: '首拍在 Duration.zero 之后');
      for (int i = 2; i <= 3; i++) {
        await tester.pump(InterconnectP2pPathBadge.pollInterval);
        expect(tester.takeException(), isNull);
        expect(port.calls, i, reason: '出错后继续轮询（runtime 重启可自愈）');
      }
      expect(find.byType(Text), findsNothing);
      expect(badgeErrors(), 1, reason: '同一种错误连续出现只记一次');

      port.failure = null;
      await tester.pump(InterconnectP2pPathBadge.pollInterval);
      expect(tester.takeException(), isNull);
      expect(port.calls, 4);
      expect(find.byType(Text), findsOneWidget, reason: '恢复后徽章照常显示');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('NodeId 非法：从不调用 status，也不起定时器', (WidgetTester tester) async {
      await tester.pumpWidget(app('p2p://not-a-node'));
      await tester.pump(InterconnectP2pPathBadge.pollInterval * 3);
      expect(tester.takeException(), isNull);
      expect(port.calls, 0);
      expect(find.byType(Text), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

const String _nodeHex =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

final class _StatusPort implements InterconnectP2pEndpointPort {
  int calls = 0;
  FushiP2pException? failure;

  @override
  FushiP2pConnStatus status(String nodeId) {
    calls++;
    final FushiP2pException? f = failure;
    if (f != null) throw f;
    return const FushiP2pConnStatus(
      connected: true,
      path: FushiP2pPathKind.direct,
      rttMs: 12,
      directPaths: 1,
      relayPaths: 0,
    );
  }

  @override
  int clientForward(
    String nodeId, {
    List<String> directAddrs = const <String>[],
    String? relayUrl,
  }) => throw UnimplementedError();

  @override
  bool stopForward(int port) => true;

  @override
  FushiP2pInfo info() => throw UnimplementedError();

  @override
  void hostListen(int port) {}

  @override
  void hostStop() {}

  @override
  String? hostPeer(int port) => null;

  @override
  bool networkChange() => false;

  @override
  Future<void> closeAsync() async {}
}
