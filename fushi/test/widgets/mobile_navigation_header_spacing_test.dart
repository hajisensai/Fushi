import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

void main() {
  const Key tabsKey = ValueKey<String>('navigation-tabs');

  Future<void> pumpHeader(
    WidgetTester tester, {
    double width = 393,
    double scale = 1,
    double inset = 47,
    EdgeInsets? padding,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 852),
            padding: EdgeInsets.only(top: inset),
            viewPadding: EdgeInsets.only(top: inset),
          ),
          child: FushiAppUiScale(
            scale: scale,
            child: Scaffold(
              body: SafeArea(
                child: Column(
                  children: <Widget>[
                    FushiPageHeader.customTitle(
                      padding: padding,
                      title: const SizedBox(
                        key: tabsKey,
                        height: 48,
                        child: Text('书架　发现　导入　设置'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final double scale in <double>[0.6, 1, 1.3]) {
    testWidgets('phone navigation starts at safe area at UI scale $scale', (
      WidgetTester tester,
    ) async {
      await pumpHeader(tester, scale: scale);
      expect(tester.getTopLeft(find.byKey(tabsKey)).dy, closeTo(47, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('zero inset does not leave an empty title band', (
    WidgetTester tester,
  ) async {
    await pumpHeader(tester, inset: 0);
    expect(tester.getTopLeft(find.byKey(tabsKey)).dy, 0);
  });

  // A tab row owns its own touch height, and the shell above the header already
  // yields the seam (SafeArea on phones, the 32px caption row on desktop), so
  // the title margin is redundant at every width -- not just on phones. Desktop
  // used to take `page + 8` here and showed a visibly empty band under the
  // window caption.
  testWidgets('wide header drops the title margin too', (
    WidgetTester tester,
  ) async {
    await pumpHeader(tester, width: 900);
    expect(tester.getTopLeft(find.byKey(tabsKey)).dy, closeTo(47, 0.01));
  });

  testWidgets('wide header keeps the title margin for a plain text title', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(900, 852),
            padding: EdgeInsets.only(top: 47),
            viewPadding: EdgeInsets.only(top: 47),
          ),
          child: FushiAppUiScale(
            scale: 1,
            child: Scaffold(
              body: SafeArea(
                child: Column(
                  children: <Widget>[
                    FushiPageHeader(title: '书架'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // spacing.page + 8 == 28, unchanged: a text title still needs its band.
    expect(tester.getTopLeft(find.text('书架')).dy, closeTo(47 + 28, 0.01));
  });

  testWidgets('explicit header padding still takes precedence', (
    WidgetTester tester,
  ) async {
    await pumpHeader(tester, padding: const EdgeInsets.only(top: 12));
    expect(tester.getTopLeft(find.byKey(tabsKey)).dy, 59);
  });
}
