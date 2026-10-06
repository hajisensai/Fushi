import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

void main() {
  for (final double width in <double>[320, 360]) {
    for (final double textScale in <double>[1, 2]) {
      testWidgets(
        'modified picker fits $width px at UI 2 and text $textScale',
        (WidgetTester tester) async {
          await tester.binding.setSurfaceSize(Size(width, 1200));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          int selected = 1;
          int resets = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: FushiAppUiScale(
                  scale: 2,
                  child: Builder(
                    builder: (BuildContext context) {
                      final FushiDesignTokens tokens = FushiDesignTokens.of(
                        context,
                      );
                      return MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.linear(textScale)),
                        child: SingleChildScrollView(
                          padding: EdgeInsets.symmetric(
                            horizontal:
                                tokens.spacing.page + tokens.spacing.gap,
                          ),
                          child: StatefulBuilder(
                            builder:
                                (BuildContext context, StateSetter setState) =>
                                    SettingsModifiedRow(
                                      modified: selected != 0,
                                      onReset: () => setState(() {
                                        selected = 0;
                                        resets++;
                                      }),
                                      child: AdaptiveSettingsPickerRow<int>(
                                        title: 'Immersive mode',
                                        icon: FushiIcons.undo,
                                        showIcon: true,
                                        selected: selected,
                                        options:
                                            const <
                                              AdaptiveSettingsPickerOption<int>
                                            >[
                                              AdaptiveSettingsPickerOption(
                                                value: 0,
                                                label: 'Shortcut and lookup',
                                              ),
                                              AdaptiveSettingsPickerOption(
                                                value: 1,
                                                label: 'Lookup only',
                                              ),
                                            ],
                                        onChanged: (int value) =>
                                            setState(() => selected = value),
                                      ),
                                    ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final Finder picker = find.byType(AdaptiveSettingsPickerRow<int>);
          final Element originalPicker = tester.element(picker);
          final Finder reset = find.byKey(
            const ValueKey<String>('settings-reset-default'),
          );
          final Rect resetRect = tester.getRect(reset);
          expect(
            resetRect.top,
            greaterThanOrEqualTo(tester.getRect(picker).bottom),
          );
          expect(
            resetRect.width,
            greaterThanOrEqualTo(2 * kMinInteractiveDimension),
          );
          expect(resetRect.right, lessThanOrEqualTo(width));
          await tester.ensureVisible(reset);
          await tester.tap(reset);
          await tester.pumpAndSettle();
          expect(resets, 1);
          expect(selected, 0);
          expect(reset, findsNothing);
          expect(tester.element(picker), same(originalPicker));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('wide modified row keeps reset beside its content', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 500,
              child: SettingsModifiedRow(
                modified: true,
                onReset: () {},
                child: const SizedBox(
                  key: ValueKey<String>('wide-settings-content'),
                  height: 120,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect content = tester.getRect(
      find.byKey(const ValueKey<String>('wide-settings-content')),
    );
    final Rect reset = tester.getRect(
      find.byKey(const ValueKey<String>('settings-reset-default')),
    );
    expect(reset.left, greaterThanOrEqualTo(content.right));
    expect(reset.center.dy, closeTo(content.center.dy, 0.01));
    expect(tester.takeException(), isNull);
  });
  for (final double width in <double>[104, 500]) {
    testWidgets(
      'bounded $width px host keeps the modified row content height',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  height: 600,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SettingsModifiedRow(
                      key: const ValueKey<String>('bounded-modified-row'),
                      modified: true,
                      onReset: () {},
                      child: const SizedBox(height: 120),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final Size row = tester.getSize(
          find.byKey(const ValueKey<String>('bounded-modified-row')),
        );
        expect(row.height, 120 + (width == 104 ? kMinInteractiveDimension : 0));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
