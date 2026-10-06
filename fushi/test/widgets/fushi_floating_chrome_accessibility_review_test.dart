import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';

Widget _app(
  Widget child, {
  double textScale = 1,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: ThemeData(splashFactory: NoSplash.splashFactory),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: child!,
    ),
    home: child,
  );
}

Future<void> _selectBrowse(WidgetTester tester) async {
  final FushiSectionTabBar<MediaLibraryViewKind> strip = tester.widget(
    find.byType(FushiSectionTabBar<MediaLibraryViewKind>),
  );
  strip.onChanged!(MediaLibraryViewKind.browse);
  await tester.pumpAndSettle();
}

Widget _libraryShell(Widget library) => Scaffold(
  body: MediaLibraryShell(
    focusIdPrefix: 'accessibility-review-library',
    views: <MediaLibraryViewSpec>[
      MediaLibraryViewSpec(
        kind: MediaLibraryViewKind.library,
        label: 'Library',
        builder: (BuildContext context, Widget navigation) => library,
      ),
      MediaLibraryViewSpec(
        kind: MediaLibraryViewKind.browse,
        label: 'Browse',
        builder: (BuildContext context, Widget navigation) =>
            const Center(child: Text('Visible browse content')),
      ),
    ],
  ),
);

void main() {
  // Exercise the actual scaffold/header constraints used by AI acquisition
  // (executor subtitle) and statistics (profile subtitle), not an isolated Column.
  for (final double scale in <double>[1, 1.3, 2]) {
    testWidgets('HBK-AUDIT-007: scaffold subtitle fits at text scale $scale', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const FushiPageScaffold(
            title: 'Video acquisition',
            subtitle: 'Remote executor: living room',
            leading: BackButton(),
            body: SizedBox.expand(),
          ),
          textScale: scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Scaled text must not overflow',
      );

      final Finder title = find.byType(FushiPageChromeTitle);
      expect(title, findsOneWidget);
      final Rect capsule = tester.getRect(title);
      // The capsule height is fixed (BUG-2977); when both scaled lines no
      // longer fit, the subtitle is demoted to the title's tooltip instead of
      // overflowing (b3e5d2d7531). Whatever is laid out must sit inside.
      const String subtitle = 'Remote executor: living room';
      final bool subtitleShown = find.text(subtitle).evaluate().isNotEmpty;
      if (!subtitleShown) {
        final Tooltip tooltip = tester.widget<Tooltip>(
          find.descendant(of: title, matching: find.byType(Tooltip)),
        );
        expect(tooltip.message, subtitle);
      }
      for (final String label in <String>[
        'Video acquisition',
        if (subtitleShown) subtitle,
      ]) {
        final Rect line = tester.getRect(find.text(label));
        expect(line.top, greaterThanOrEqualTo(capsule.top - 0.01));
        expect(line.bottom, lessThanOrEqualTo(capsule.bottom + 0.01));
      }
    });
  }

  testWidgets('HBK-AUDIT-017: hidden library does not receive keyboard input', (
    WidgetTester tester,
  ) async {
    final FocusNode hiddenNode = FocusNode(debugLabel: 'library action');
    int hiddenKeyEvents = 0;
    try {
      await tester.pumpWidget(
        _app(
          _libraryShell(
            Focus(
              focusNode: hiddenNode,
              onKeyEvent: (FocusNode node, KeyEvent event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.keyA) {
                  hiddenKeyEvents++;
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: const Text('Library action'),
            ),
          ),
        ),
      );
      hiddenNode.requestFocus();
      await tester.pump();
      expect(hiddenNode.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(
        hiddenKeyEvents,
        1,
        reason: 'Control: visible library receives keys',
      );

      await _selectBrowse(tester);
      expect(find.text('Library action'), findsNothing);
      expect(find.text('Visible browse content'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(
        hiddenKeyEvents,
        1,
        reason: 'Offstage library must stop receiving keys',
      );
      expect(hiddenNode.hasFocus, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      hiddenNode.dispose();
    }
  });

  testWidgets('HBK-AUDIT-017: hidden selection PopScope cannot consume back', (
    WidgetTester tester,
  ) async {
    int hiddenSelectionExits = 0;
    await tester.pumpWidget(_app(const Scaffold(body: Text('Landing route'))));
    final NavigatorState navigator = tester.state(find.byType(Navigator));
    // This is the same SectionPopScope contract used by the reader/video
    // multi-select pages. The real shell, Offstage, ModalRoute and back
    // dispatch are exercised.
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _libraryShell(
          SectionPopScope(
            intercepting: true,
            onIntercept: () => hiddenSelectionExits++,
            child: const Text('Selected library items'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectBrowse(tester);
    expect(find.text('Selected library items'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      hiddenSelectionExits,
      0,
      reason: 'Hidden multi-select must not consume back',
    );
    expect(find.text('Landing route'), findsOneWidget);
    expect(find.text('Visible browse content'), findsNothing);
  });

  for (final bool reducedMotion in <bool>[false, true]) {
    testWidgets(
      'nested floating chrome keeps finite bounds, reduced motion $reducedMotion',
      (WidgetTester tester) async {
        final FushiFloatingChromeController controller =
            FushiFloatingChromeController();
        ValueListenable<double>? visibleExtent;
        double inset = 0;
        const Key bodyKey = ValueKey<String>('stable-body');
        try {
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: FushiFloatingChromeScope(
                  controller: controller,
                  child: FushiFloatingChromeOverlay(
                    chrome: const SizedBox(height: 48),
                    child: FushiFloatingChromeOverlay(
                      chrome: const SizedBox(height: 48),
                      child: Builder(
                        builder: (BuildContext context) {
                          visibleExtent =
                              FushiFloatingChromeVisibleExtent.maybeOf(context);
                          inset = FushiFloatingChromeInset.of(context);
                          return const SizedBox.expand(key: bodyKey);
                        },
                      ),
                    ),
                  ),
                ),
              ),
              disableAnimations: reducedMotion,
            ),
          );
          await tester.pumpAndSettle();
          final Rect bodyRect = tester.getRect(find.byKey(bodyKey));
          expect(inset, greaterThan(96));
          expect(visibleExtent!.value, closeTo(inset, 0.01));
          // Reverse before settling to retain velocity and exercise spring overshoot.
          for (final bool show in <bool>[false, true, false, true]) {
            show ? controller.show() : controller.hide();
            await tester.pump();
            if (reducedMotion) {
              expect(visibleExtent!.value, closeTo(show ? inset : 0, 0.01));
            }
            for (int frame = 0; frame < 24; frame++) {
              await tester.pump(const Duration(milliseconds: 4));
              expect(visibleExtent!.value.isFinite, isTrue);
              expect(visibleExtent!.value, inInclusiveRange(0, inset));
              expect(tester.getRect(find.byKey(bodyKey)), bodyRect);
              expect(tester.takeException(), isNull);
            }
          }
          await tester.pumpAndSettle();
          expect(visibleExtent!.value, closeTo(inset, 0.01));
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        }
      },
    );
  }
}
