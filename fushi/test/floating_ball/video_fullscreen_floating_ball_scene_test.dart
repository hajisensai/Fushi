import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

/// BUG-2846：视频全屏后悬浮球退回「其它页面」那组按钮（关闭 / 查词 / 剪贴板）。
///
/// 全屏是推到根导航器上的独立整页路由，视频页那份场景登记所在路由不再是当前
/// 路由，宿主只认当前路由上的场景。修法是全屏路由里再登记一份视频场景。
void main() {
  setUp(FloatingBallSceneRegistry.instance.debugReset);

  ReaderHeaderAction action(String id) =>
      ReaderHeaderAction(icon: Icons.add, label: id, onPressed: () {});

  Widget videoScene() => FloatingBallScene(
    scope: FloatingBallScope.video,
    actions: <String, ReaderHeaderAction>{'play_pause': action('play_pause')},
  );

  testWidgets('全屏路由里重登记的视频场景压过「其它页面」', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    final FloatingBallSceneRegistry registry =
        FloatingBallSceneRegistry.instance;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: <NavigatorObserver>[floatingBallRouteObserver],
        home: videoScene(),
      ),
    );
    await tester.pump();
    expect(registry.current.scope, FloatingBallScope.video);

    // 同全屏实现：PageRouteBuilder 压到根导航器，内容外包一份视频场景。
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => FloatingBallScene(
          scope: FloatingBallScope.video,
          actions: <String, ReaderHeaderAction>{
            'play_pause': action('play_pause'),
          },
          child: const SizedBox.expand(),
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    await tester.pumpAndSettle();
    expect(registry.current.scope, FloatingBallScope.video);
    expect(registry.current.actions.keys, <String>['play_pause']);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(registry.current.scope, FloatingBallScope.video);
  });

  test('源码守卫：视频全屏路由内容包在视频悬浮球场景里', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int route = src.indexOf('PageRouteBuilder<void>(');
    expect(route, isNonNegative);
    final int builder = src.indexOf('pageBuilder:', route);
    expect(
      src.substring(builder, builder + 160),
      contains('_buildVideoFloatingBallScene('),
      reason: '全屏路由不登记视频场景，悬浮球在全屏下只剩「其它页面」按钮',
    );
  });
}
