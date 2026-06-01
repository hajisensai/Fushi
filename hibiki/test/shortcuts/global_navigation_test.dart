import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

void main() {
  testWidgets('gameButtonB pops the top route', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('second')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('gameButtonB on root route does not crash',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('native gameButton keys dispatch GamepadButtonIntent',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    GamepadButton? received;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Scaffold(
        body: Actions(
          actions: <Type, Action<Intent>>{
            GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
              onInvoke: (GamepadButtonIntent intent) {
                received = intent.button;
                return true;
              },
            ),
          },
          child: const Focus(
            autofocus: true,
            child: Text('target'),
          ),
        ),
      ),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
    await tester.pump();

    expect(received, GamepadButton.x);
  });
}
