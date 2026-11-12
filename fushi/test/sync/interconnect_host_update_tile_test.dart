import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_host_update_tile.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart'
    show HostUpdateAnswer, HostUpdateOtherHost;
import 'package:fushi/src/updates/host_self_update_service.dart'
    show kHostUpdateErrorCancelled;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 Pp8XPyve0N：client 侧「主机版本」行——版本 / 可更新 / 拒绝原因 / 触发后的
/// 进度、重启重连与新版本号。
class _FakeRemote implements HostUpdateRemote {
  /// 依次返回的 status 结果（HostUpdateStatus / null / Exception / [_From]）；用完后
  /// 重复最后一个。裸的状态 / null 算 [host] 这台答的；[_From] = 此刻会话连的是另一台。
  final List<Object?> statuses = <Object?>[];
  Object? triggerResult;
  final List<String> triggeredNonces = <String>[];
  final List<bool> refreshFlags = <bool>[];

  /// 默认答话的那台 host。
  String host = 'host-a';

  /// trigger 那一刻会话连着的 host；null = [host]。
  String? triggerHost;

  /// 每次调用带的 onlyHost（status 与 trigger 都记）。
  final List<String?> pins = <String?>[];

  /// 与生产实现同一契约：钉了 host 而会话连的是另一台 → 抛、不发请求。
  void _checkPin(String? onlyHost, String answering) {
    pins.add(onlyHost);
    if (onlyHost != null && onlyHost != answering) {
      throw HostUpdateOtherHost(expected: onlyHost, actual: answering);
    }
  }

  @override
  Future<HostUpdateAnswer> status({
    bool refresh = false,
    String? onlyHost,
  }) async {
    refreshFlags.add(refresh);
    final Object? next = statuses.length > 1
        ? statuses.removeAt(0)
        : statuses.first;
    if (next is Exception) throw next;
    if (next is _From) {
      _checkPin(onlyHost, next.host);
      return (host: next.host, status: next.status);
    }
    _checkPin(onlyHost, host);
    return (host: host, status: next as HostUpdateStatus?);
  }

  @override
  Future<HostUpdateStatus> trigger(
    String nonce, {
    required String onlyHost,
  }) async {
    _checkPin(onlyHost, triggerHost ?? host);
    triggeredNonces.add(nonce);
    final Object? result = triggerResult;
    if (result is Exception) throw result;
    return result! as HostUpdateStatus;
  }
}

/// 一次由另一台已配对 host 答的 status（会话换了 host）。
class _From {
  const _From(this.host, this.status);

  final String host;
  final HostUpdateStatus? status;
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
  Future<void> pumpTile(
    WidgetTester tester,
    _FakeRemote remote, {
    DateTime Function()? now,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: InterconnectHostUpdateTile(
            remote: remote,
            pollInterval: const Duration(seconds: 2),
            reconnectWindow: const Duration(seconds: 30),
            now: now,
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

  /// 确认对话框 → 「更新主机」，触发后跑两帧让 trigger 完成。
  Future<void> confirmTrigger(WidgetTester tester) async {
    await tester.tap(find.byType(FushiFilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.interconnect_host_update_action).last);
    await tester.pump();
    await tester.pump();
  }

  /// 推进一个轮询周期并让那次 status 调用落地。
  Future<void> pollOnce(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  }

  testWidgets(
    'PR #2100 review: reconnect window starts at the disconnect, not at the '
    'trigger — a download longer than the window does not time out at once',
    (WidgetTester tester) async {
      DateTime clock = DateTime(2026, 10, 13, 12);
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          _status(nonce: 'fresh'),
          // 之后一直重复这一条，直到测试把它换掉。
          _status(phase: HostUpdatePhase.downloading, progress: 0.9),
        ])
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote, now: () => clock);
      await confirmTrigger(tester);

      // 慢网：下载了 10 分钟（远超 30 秒的重连窗口）。
      clock = clock.add(const Duration(minutes: 10));
      await pollOnce(tester);
      expect(
        find.text(t.interconnect_host_update_downloading(percent: 90)),
        findsOneWidget,
      );

      // 安装器接班、host 退出：第一次连不上 = 正在重启，不能立刻判超时。
      remote.statuses[0] = const SocketException('host restarting');
      await pollOnce(tester);
      expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);
      expect(
        find.textContaining(t.interconnect_host_update_reconnect_timeout),
        findsNothing,
      );

      // 断线 20 秒：仍在窗口内。
      clock = clock.add(const Duration(seconds: 20));
      await pollOnce(tester);
      expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);

      // 断线超过 30 秒：这才超时、停止跟踪。
      clock = clock.add(const Duration(seconds: 15));
      await pollOnce(tester);
      expect(
        find.textContaining(t.interconnect_host_update_reconnect_timeout),
        findsOneWidget,
      );
      final int calls = remote.refreshFlags.length;
      await tester.pump(const Duration(seconds: 10));
      expect(remote.refreshFlags.length, calls, reason: '超时后不再轮询');
    },
  );

  testWidgets('PR #2100 review: a reconnect resets the disconnect clock', (
    WidgetTester tester,
  ) async {
    DateTime clock = DateTime(2026, 10, 13, 12);
    final _FakeRemote remote = _FakeRemote()
      ..statuses.addAll(<Object?>[
        _status(nonce: 'stale'),
        _status(nonce: 'fresh'),
        const SocketException('blip'),
      ])
      ..triggerResult = _status(
        phase: HostUpdatePhase.downloading,
        progress: 0,
      );
    await pumpTile(tester, remote, now: () => clock);
    await confirmTrigger(tester);

    await pollOnce(tester);
    expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);

    // 断了 25 秒后又问到了 host：断线时钟清零。
    clock = clock.add(const Duration(seconds: 25));
    remote.statuses[0] = _status(
      phase: HostUpdatePhase.downloading,
      progress: 0.5,
    );
    await pollOnce(tester);
    expect(
      find.text(t.interconnect_host_update_downloading(percent: 50)),
      findsOneWidget,
    );

    // 再断：从这次断线重新起算，25 + 10 秒不算超时。
    remote.statuses[0] = const SocketException('restarting');
    await pollOnce(tester);
    clock = clock.add(const Duration(seconds: 10));
    await pollOnce(tester);
    expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);
    expect(
      find.textContaining(t.interconnect_host_update_reconnect_timeout),
      findsNothing,
    );
  });

  testWidgets(
    'PR #2100 review: awaiting on-host confirmation stops polling and gives '
    'the action back so the install prompt can be raised again',
    (WidgetTester tester) async {
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          _status(nonce: 'fresh'),
          _status(phase: HostUpdatePhase.awaitingHostConfirmation),
        ])
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote);
      await confirmTrigger(tester);
      expect(remote.triggeredNonces, <String>['fresh']);

      await pollOnce(tester);
      expect(
        find.text(t.interconnect_host_update_awaiting_confirm),
        findsOneWidget,
      );
      // 不再定时问 host。
      final int calls = remote.refreshFlags.length;
      await tester.pump(const Duration(seconds: 10));
      expect(remote.refreshFlags.length, calls);
      // 按钮可点：没人点 / 取消了安装框时能再触发一次。
      expect(actionButton(tester).onPressed, isNotNull);

      await confirmTrigger(tester);
      expect(remote.triggeredNonces, hasLength(2), reason: '可以再触发一次');
    },
  );

  testWidgets(
    'BUG host-update-tracking-null-loops: host answering 404 mid-tracking '
    'ends tracking instead of polling every 2 s forever',
    (WidgetTester tester) async {
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          _status(nonce: 'fresh'),
          _status(phase: HostUpdatePhase.downloading, progress: 0.3),
          // host 回来了却不再认 /api/host/update（降级 / 换成无头服务端）：之后一直 404。
          null,
        ])
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote);
      await confirmTrigger(tester);

      await pollOnce(tester);
      expect(
        find.text(t.interconnect_host_update_downloading(percent: 30)),
        findsOneWidget,
      );

      await pollOnce(tester);
      await pollOnce(tester);
      final int calls = remote.refreshFlags.length;
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(remote.refreshFlags.length, calls, reason: '404 后不再轮询');
      expect(find.byType(FushiCircularProgressIndicator), findsNothing);
      expect(
        find.text(t.interconnect_host_update_reason_unavailable),
        findsOneWidget,
      );
    },
  );

  testWidgets('a download cancelled on the host is reported as such', (
    WidgetTester tester,
  ) async {
    final _FakeRemote remote = _FakeRemote()
      ..statuses.add(
        const HostUpdateStatus(
          currentVersion: '2.10.0',
          platform: 'windows',
          supported: true,
          remoteUpdateAllowed: true,
          latestVersion: '2.11.0',
          phase: HostUpdatePhase.failed,
          error: kHostUpdateErrorCancelled,
          nonce: 'n1',
        ),
      );
    await pumpTile(tester, remote);

    expect(find.text(t.interconnect_host_update_cancelled), findsOneWidget);
    expect(actionButton(tester).onPressed, isNotNull);
  });

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

  group('BUG-4457 残余：跟踪与触发只认被更新的那台 host', () {
    testWidgets('重启期间会话换到另一台 host：它的版本号不当成更新结果，原 host 回来才报完成', (
      WidgetTester tester,
    ) async {
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          _status(nonce: 'fresh'),
          _status(phase: HostUpdatePhase.downloading, progress: 0.4),
          // host-a 在重启；会话落到另一台也支持远程更新、版本不同的 host-b 上。
          _From('host-b', _status(current: '3.0.0', latest: null)),
          _From('host-b', _status(current: '3.0.0', latest: null)),
          _status(current: '2.11.0', latest: null),
        ])
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote);
      await confirmTrigger(tester);
      expect(remote.triggeredNonces, <String>['fresh']);
      expect(remote.pins, <String?>[
        null,
        'host-a',
        'host-a',
      ], reason: '打开时不钉；触发前现取与触发都钉在页面显示的那台上');

      await pollOnce(tester);
      expect(
        find.text(t.interconnect_host_update_downloading(percent: 40)),
        findsOneWidget,
      );

      // host-b 答话两拍：不是「已更新到 3.0.0」，而是 host-a 还没回来。
      await pollOnce(tester);
      expect(
        find.textContaining(t.interconnect_host_update_done(version: '3.0.0')),
        findsNothing,
      );
      expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);
      await pollOnce(tester);
      expect(
        find.textContaining(t.interconnect_host_update_done(version: '3.0.0')),
        findsNothing,
      );
      expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);
      expect(remote.pins.skip(3), everyElement('host-a'), reason: '跟踪期间每次都钉');

      // host-a 回来、版本变了：这一轮才结束。
      await pollOnce(tester);
      expect(
        find.textContaining(t.interconnect_host_update_done(version: '2.11.0')),
        findsOneWidget,
      );
      final int calls = remote.refreshFlags.length;
      await tester.pump(const Duration(seconds: 10));
      expect(remote.refreshFlags.length, calls, reason: '跟踪结束不再轮询');
    });

    testWidgets('被更新的 host 一直没回来、只有另一台在答：按重连超时收尾，不报已更新', (
      WidgetTester tester,
    ) async {
      DateTime clock = DateTime(2026, 11, 11, 12);
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          _status(nonce: 'fresh'),
          _From('host-b', _status(current: '3.0.0', latest: null)),
        ])
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote, now: () => clock);
      await confirmTrigger(tester);

      await pollOnce(tester);
      expect(find.text(t.interconnect_host_update_restarting), findsOneWidget);
      clock = clock.add(const Duration(seconds: 31));
      await pollOnce(tester);
      expect(
        find.textContaining(t.interconnect_host_update_reconnect_timeout),
        findsOneWidget,
      );
      expect(
        find.textContaining(t.interconnect_host_update_done(version: '3.0.0')),
        findsNothing,
      );
      final int calls = remote.refreshFlags.length;
      await tester.pump(const Duration(seconds: 10));
      expect(remote.refreshFlags.length, calls, reason: '超时后不再轮询');
    });

    testWidgets('确认框弹着时会话换到另一台 host：不触发，改显示现在连着的那台并说明', (
      WidgetTester tester,
    ) async {
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          // 触发前现取 nonce 时会话已在 host-b 上；之后重新加载也由它答。
          _From('host-b', _status(current: '3.0.0', latest: '3.1.0')),
        ])
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote);
      await confirmTrigger(tester);
      // 没有在跟踪（无定时器）：等确认框的退场动画走完，树里只剩这一行的按钮。
      await tester.pumpAndSettle();

      expect(remote.triggeredNonces, isEmpty, reason: '用户确认的是 host-a 的更新');
      expect(
        find.textContaining(t.interconnect_host_update_host_changed),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          t.interconnect_host_update_available(
            current: '3.0.0',
            latest: '3.1.0',
          ),
        ),
        findsOneWidget,
        reason: '这一行换成现在连着的那台的状态',
      );
      expect(actionButton(tester).onPressed, isNotNull, reason: '核对后可以再点');

      // 再点一次：这回确认的就是 host-b，钉的也是它。
      remote.host = 'host-b';
      remote.statuses
        ..clear()
        ..add(_status(current: '3.0.0', latest: '3.1.0', nonce: 'b1'));
      await confirmTrigger(tester);
      expect(remote.triggeredNonces, <String>['b1']);
      expect(remote.pins.last, 'host-b');
    });

    testWidgets('现取 nonce 之后、触发之前会话换了 host：触发请求不发', (
      WidgetTester tester,
    ) async {
      final _FakeRemote remote = _FakeRemote()
        ..statuses.addAll(<Object?>[
          _status(nonce: 'stale'),
          _status(nonce: 'fresh'),
          _From('host-b', _status(current: '3.0.0', latest: null)),
        ])
        ..triggerHost = 'host-b'
        ..triggerResult = _status(
          phase: HostUpdatePhase.downloading,
          progress: 0,
        );
      await pumpTile(tester, remote);
      await confirmTrigger(tester);
      await tester.pump();

      expect(remote.triggeredNonces, isEmpty);
      expect(
        find.textContaining(t.interconnect_host_update_host_changed),
        findsOneWidget,
      );
    });
  });
}
