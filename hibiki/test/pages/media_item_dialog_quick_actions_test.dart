import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

/// TODO-293 redesign (supersedes the BUG-223 equal-width guard): the long-press
/// dialog actions are now translucent capsule buttons layered over the cover,
/// laid out in a wrapping bar. The intrinsic-width parity that BUG-223 fixed no
/// longer applies — but the actions must still render their labels without
/// overflow and lay out without exceptions on both wide and narrow dialogs.
void main() {
  // Three Japanese labels of differing length, the real
  // view_illustrations / audiobook_import / tag_label set.
  final List<DialogQuickAction> threeActions = <DialogQuickAction>[
    DialogQuickAction(
      label: '査看插画',
      icon: Icons.image_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '导入有声书',
      icon: Icons.headphones_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '标签',
      icon: Icons.sell_outlined,
      onPressed: () {},
    ),
  ];

  Future<void> pumpFrame(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaItemDialogFrame(
              cover: const SizedBox(width: 260, height: 200),
              title: 'こころ',
              launchLabel: 'Read',
              onLaunch: () {},
              quickActions: threeActions,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders every quick-action label as a button',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester);

    expect(find.text('査看插画'), findsOneWidget);
    expect(find.text('导入有声书'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow dialog wraps the action chips without overflowing',
      (WidgetTester tester) async {
    // Narrow enough that all three chips cannot sit on a single row; the
    // wrapping bar must lay them out without throwing or clipping.
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester);

    expect(find.text('査看插画'), findsOneWidget);
    expect(find.text('导入有声书'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    // No render-overflow exceptions on the narrow layout.
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a quick-action fires its callback',
      (WidgetTester tester) async {
    int tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaItemDialogFrame(
            cover: const SizedBox(width: 260, height: 200),
            title: 'こころ',
            launchLabel: 'Read',
            onLaunch: () {},
            quickActions: <DialogQuickAction>[
              DialogQuickAction(
                label: 'Tag',
                icon: Icons.sell_outlined,
                onPressed: () => tapped++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tag'));
    await tester.pump();
    expect(tapped, 1);
    expect(tester.takeException(), isNull);
  });
}
