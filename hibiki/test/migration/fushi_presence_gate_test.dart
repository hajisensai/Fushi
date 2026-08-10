import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/migration/fushi_presence_gate.dart';
import 'package:hibiki/src/migration/migration_target_channel.dart';

/// 可翻转的探包替身：模拟「用户在系统设置里把 Fushi 卸了」。
class _FakeChannel extends MigrationTargetChannel {
  const _FakeChannel(this.state);

  final _State state;

  @override
  Future<bool> isFushiInstalled() async => state.installed;
}

class _State {
  bool installed = false;
  int probes = 0;
}

class _CountingChannel extends MigrationTargetChannel {
  const _CountingChannel(this.state);

  final _State state;

  @override
  Future<bool> isFushiInstalled() async {
    state.probes++;
    return state.installed;
  }
}

Widget _host(MigrationTargetChannel channel) => MaterialApp(
      home: Scaffold(
        body: FushiPresenceGate(
          channel: channel,
          builder: (BuildContext context, bool installed) =>
              Text(installed ? 'OPEN' : 'DOWNLOAD'),
        ),
      ),
    );

void main() {
  group('BUG-1501 「打开 Fushi」必须跟随 Fushi 的真实安装状态', () {
    testWidgets('没装 Fushi 时不给「打开」入口', (WidgetTester tester) async {
      final _State state = _State()..installed = false;
      await tester.pumpWidget(_host(_FakeChannel(state)));
      await tester.pumpAndSettle();

      expect(find.text('DOWNLOAD'), findsOneWidget);
      expect(find.text('OPEN'), findsNothing);
    });

    testWidgets('首帧未探完时 fail-closed：先按「没装」渲染，绝不先给死按钮',
        (WidgetTester tester) async {
      final _State state = _State()..installed = true;
      await tester.pumpWidget(_host(_FakeChannel(state)));
      // 只 pump 一帧，探包 future 还没回来。
      expect(find.text('DOWNLOAD'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('OPEN'), findsOneWidget);
    });

    testWidgets('装着 → 用户去系统里卸掉 → 回到前台：入口必须翻回「下载」', (WidgetTester tester) async {
      final _State state = _State()..installed = true;
      await tester.pumpWidget(_host(_FakeChannel(state)));
      await tester.pumpAndSettle();
      expect(find.text('OPEN'), findsOneWidget);

      // 卸载发生在别的界面，本进程只有回到前台这一刻能重新确认。
      state.installed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('DOWNLOAD'), findsOneWidget,
          reason: '这正是用户报的症状：Fushi 已删，老版仍常驻一个点了没反应的「打开 Fushi」');
      expect(find.text('OPEN'), findsNothing);
    });

    testWidgets('每次 resume 都重新探包，不是只在 initState 探一次',
        (WidgetTester tester) async {
      final _State state = _State()..installed = false;
      await tester.pumpWidget(_host(_CountingChannel(state)));
      await tester.pumpAndSettle();
      expect(state.probes, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(state.probes, 2);
    });
  });

  group('BUG-1501 两个调用点都接到闸门上', () {
    test('首屏只读横幅用 FushiPresenceGate 决定入口，而不是只看只读偏好', () {
      final String source =
          File('lib/src/pages/implementations/home_dashboard_page.dart')
              .readAsStringSync();
      final int bannerIndex = source.indexOf('class _MigrationReadonlyBanner');
      expect(bannerIndex, isNot(-1));
      final String banner = source.substring(bannerIndex);
      expect(banner, contains('FushiPresenceGate'),
          reason: '只读态是持久偏好，不能拿它代替「Fushi 当下装着吗」');
      expect(banner.indexOf('migration_download_fushi'),
          lessThan(banner.indexOf('migration_open_fushi')),
          reason: '未安装分支必须在前，安装分支在后（if (!installed) 先返回下载入口）');
    });

    test('迁移页 resume 不再因 done 跳过探包，且「打开」按钮看真值', () {
      final String source =
          File('lib/src/pages/implementations/migration_page.dart')
              .readAsStringSync();
      expect(source, isNot(contains('resumed && _step != _Step.done')),
          reason: 'done 态正是「导出完后把 Fushi 卸了」的路径，跳过探包就永远刷不新');
      expect(source, contains('if (!_fushiInstalled) ...<Widget>['),
          reason: 'done 分支必须按真实安装状态分流');
      expect(source, contains('unawaited(_openFushi())'),
          reason: 'launchFushi 的失败不能再被丢弃（静默无反应）');
    });
  });
}
