import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_host_update_tile.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 Pp8XPyve0N：client 侧「主机版本」行——版本 / 可更新 / 拒绝原因 / 触发后的
/// 进度、重启重连与新版本号。
class _FakeRemote implements HostUpdateRemote {
  /// 依次返回的 status 结果（HostUpdateStatus / null / Exception）；用完后重复最后一个。
  final List<Object?> statuses = <Object?>[];
  Object? triggerResult;
  final List<String> triggeredNonces = <String>[];
  final List<bool> refreshFlags = <bool>[];

  @override
  Future<HostUpdateStatus?> status({bool refresh = false}) async {
    refreshFlags.add(refresh);
    final Object? next = statuses.length > 1
        ? statuses.removeAt(0)
        : statuses.first;
    if (next is Exception) throw next;
    return next as HostUpdateStatus?;
  }

  @override
  Future<HostUpdateStatus> trigger(String nonce) async {
    triggeredNonces.add(nonce);
    final Object? result = triggerResult;
    if (result is Exception) throw result;
    return result! as HostUpdateStatus;
  }
}

HostUpdateStatus _status({
  String current = '2.10.0',
  String? latest = '2.11.0',
  bool allowed = true,
  bool supported = true,
  HostUpdatePhase phase = HostUpdatePhase.idle,
  double? progress,
  String? nonce = 'n1',
}) => HostUpdateStatus(
  currentVersion: current,
  platform: 'windows',
  supported: supported,
  remoteUpdateAllowed: allowed,
  latestVersion: latest,
  phase: phase,
  progress: progress,
  nonce: nonce,
);

void main() {
  Future<void> pumpTile(WidgetTester tester, _FakeRemote remote) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: InterconnectHostUpdateTile(
            remote: remote,
            pollInterval: const Duration(seconds: 2),
            reconnectWindow: const Duration(seconds: 30),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  FushiFilledButton actionButton(WidgetTester tester) =>
      tester.widget<FushiFilledButton>(find.byType(FushiFilledButton));

  testWidgets('shows host version and an enabled update action', (
    WidgetTester tester,
  ) async {
    final _FakeRemote remote = _FakeRemote()..statuses.add(_status());
    await pumpTile(tester, remote);

    expect(remote.refreshFlags.first, isTrue, reason: '打开时让 host 去查一次更新源');
    expect(
      find.textContaining(
        t.interconnect_host_update_available(
          current: '2.10.0',
          latest: '2.11.0',
        ),
      ),
      findsOneWidget,
    );
    expect(actionButton(tester).onPressed, isNotNull);
  });

  testWidgets('host switch off disables the action and says why', (
    WidgetTester tester,
  ) async {
    final _FakeRemote remote = _FakeRemote()
      ..statuses.add(_status(allowed: false));
    await pumpTile(tester, remote);

    expect(
      find.textContaining(t.interconnect_host_update_reason_disabled),
      findsOneWidget,
    );
    expect(actionButton(tester).onPressed, isNull);
  });

  testWidgets('old host without the endpoint is explained', (
    WidgetTester tester,
  ) async {
    final _FakeRemote remote = _FakeRemote()..statuses.add(null);
    await pumpTile(tester, remote);

    expect(
      find.text(t.interconnect_host_update_reason_unavailable),
      findsOneWidget,
    );
    expect(actionButton(tester).onPressed, isNull);
  });

  testWidgets('up-to-date host offers no update', (WidgetTester tester) async {
    final _FakeRemote remote = _FakeRemote()
      ..statuses.add(_status(latest: null));
    await pumpTile(tester, remote);

    expect(
      find.text(t.interconnect_host_update_up_to_date(version: '2.10.0')),
      findsOneWidget,
    );
    expect(actionButton(tester).onPressed, isNull);
  });

  testWidgets(
    'confirm → trigger with a fresh nonce → progress → restart → new version',
    (WidgetTester tester) async {
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          _status(nonce: 'fresh'),
          _status(phase: HostUpdatePhase.downloading, progress: 0.4),
          const SocketException('host restarting'),
          _status(current: '2.11.0', latest: null),
        ])
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote);

      await tester.tap(find.byType(FushiFilledButton));
      await tester.pumpAndSettle();
      expect(
        find.text(t.interconnect_host_update_confirm_title),
        findsOneWidget,
      );
      await tester.tap(find.text(t.interconnect_host_update_action).last);
      await tester.pump();
      await tester.pump();

      expect(remote.triggeredNonces, <String>[
        'fresh',
      ], reason: '触发前现取 nonce，不用页面打开时那张');

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        find.text(t.interconnect_host_update_downloading(percent: 40)),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        find.textContaining(t.interconnect_host_update_done(version: '2.11.0')),
        findsOneWidget,
      );
      // 跟踪结束：不再轮询。
      final int calls = remote.refreshFlags.length;
      await tester.pump(const Duration(seconds: 10));
      expect(remote.refreshFlags.length, calls);
    },
  );

  testWidgets('trigger refused by the host shows the reason', (
    WidgetTester tester,
  ) async {
    final _FakeRemote remote = _FakeRemote()
      ..statuses.add(_status())
      ..triggerResult = const HostUpdateRejected(HostUpdateDenial.zone);
    await pumpTile(tester, remote);

    await tester.tap(find.byType(FushiFilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.interconnect_host_update_action).last);
    await tester.pumpAndSettle();

    expect(
      find.textContaining(t.interconnect_host_update_reason_zone),
      findsOneWidget,
    );
  });

  testWidgets('Android host waiting for on-device confirmation', (
    WidgetTester tester,
  ) async {
    final _FakeRemote remote = _FakeRemote()
      ..statuses.add(_status(phase: HostUpdatePhase.awaitingHostConfirmation));
    await pumpTile(tester, remote);

    expect(
      find.text(t.interconnect_host_update_awaiting_confirm),
      findsOneWidget,
    );
  });
}
