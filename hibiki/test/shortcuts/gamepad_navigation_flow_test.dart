import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';

/// End-to-end check that the universal navigation layer composes: a directional
/// key moves focus, gameButtonA activates the focused control (pushing a route),
/// and gameButtonB pops back — all without any pointer tap. This is the
/// device-independent proof of the "gamepad operates everything" mechanism;
/// the integration test exercises the same flow on a real device.
void main() {
  // TODO-700 T1：B 经注册表 globalBack 解析（可改键）；默认表已把 B 绑到 globalBack。
  HibikiShortcutRegistry windowsRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  Widget appWithLayer(Widget home, GlobalKey<NavigatorState> navKey) {
    return MaterialApp(
      navigatorKey: navKey,
      home: home,
      builder: (context, child) => HibikiFocusRing(
        child: wrapWithGlobalNavigation(
          navigatorKey: navKey,
          registry: windowsRegistry(),
          child: child!,
        ),
      ),
    );
  }

  testWidgets('DPAD moves focus, A activates, B pops — no taps',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode first = FocusNode(debugLabel: 'first');
    final FocusNode second = FocusNode(debugLabel: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(appWithLayer(
      Scaffold(
        body: Column(
          children: <Widget>[
            ElevatedButton(
              focusNode: first,
              autofocus: true,
              onPressed: () {},
              child: const Text('one'),
            ),
            ElevatedButton(
              focusNode: second,
              onPressed: () {
                navKey.currentState!.push(MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('detail')),
                ));
              },
              child: const Text('two'),
            ),
          ],
        ),
      ),
      navKey,
    ));
    await tester.pump();
    expect(first.hasPrimaryFocus, isTrue, reason: 'first autofocuses');

    // D-pad down -> focus moves to the second button.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(second.hasPrimaryFocus, isTrue,
        reason: 'directional focus moves to the next control');

    // gameButtonA -> activates the focused button -> pushes the detail route.
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget,
        reason: 'gameButtonA activates the focused control');

    // gameButtonB -> global back -> pops the detail route.
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsNothing,
        reason: 'gameButtonB pops the route');
    expect(find.text('one'), findsOneWidget);
  });
}
