import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_p2p_path_badge.dart';
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
        home: Scaffold(body: InterconnectP2pPathBadge(url: 'p2p://abc')),
      ),
    );
    expect(find.byType(Text), findsNothing);
    // 定时器泄漏会让 testWidgets 在结束时报 pending timer。
    await tester.pumpWidget(const SizedBox());
  });
}
