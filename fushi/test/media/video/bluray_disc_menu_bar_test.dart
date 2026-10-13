import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/bluray_disc_menu_bar.dart';
import 'package:material_ui/material_ui.dart';

/// The disc menu chrome replaced a pinned black bar whose exit button never
/// hid. Its contract: it follows [BlurayDiscMenuChrome.visible], and while
/// hidden every click reaches the disc picture underneath.
void main() {
  late ValueNotifier<bool> visible;
  late List<String> events;

  setUp(() {
    visible = ValueNotifier<bool>(true);
    events = <String>[];
  });
  tearDown(() => visible.dispose());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => events.add('disc'),
            ),
          ),
          BlurayDiscMenuChrome(
            visible: visible,
            transitionDuration: const Duration(milliseconds: 150),
            slideEnabled: true,
            hiddenOffset: const Offset(0, -24),
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            onHoverChanged: (bool v) => events.add('hover:$v'),
            onFocusChanged: (bool v) => events.add('focus:$v'),
            child: Row(
              children: <Widget>[
                TextButton(
                  key: const ValueKey<String>('bluray-menu-exit'),
                  onPressed: () => events.add('exit'),
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  testWidgets('visible chrome owns its buttons', (WidgetTester tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('bluray-menu-exit')));
    expect(events, <String>['exit']);
  });

  testWidgets('hidden chrome fades out and clicks fall through to the disc', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pumpAndSettle();

    final AnimatedOpacity fade = tester.widget(find.byType(AnimatedOpacity));
    expect(fade.opacity, 0);
    await tester.tap(
      find.byKey(const ValueKey<String>('bluray-menu-exit')),
      warnIfMissed: false,
    );
    expect(events, <String>['disc']);

    visible.value = true;
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    await tester.tap(find.byKey(const ValueKey<String>('bluray-menu-exit')));
    expect(events, <String>['disc', 'exit']);
  });

  testWidgets('hover and focus on the chrome are reported to hold it open', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.pumpAndSettle();
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(600, 500));
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey<String>('bluray-menu-exit'))),
    );
    await tester.pump();
    await mouse.moveTo(const Offset(600, 500));
    await tester.pump();
    expect(events, <String>['hover:true', 'hover:false']);

    events.clear();
    final FocusNode node = Focus.of(tester.element(find.text('Back')));
    node.requestFocus();
    await tester.pump();
    node.unfocus();
    await tester.pump();
    expect(events, <String>['focus:true', 'focus:false']);
  });
}
