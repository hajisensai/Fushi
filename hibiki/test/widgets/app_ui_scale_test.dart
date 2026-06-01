import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/spacing.dart';

void main() {
  testWidgets('app UI scale changes text scale and spacing', (
    WidgetTester tester,
  ) async {
    late double textScale;
    late double normalSpacing;

    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) {
          return HibikiAppUiScale(
            scale: 0.85,
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: Builder(
          builder: (BuildContext context) {
            textScale = MediaQuery.textScalerOf(context).scale(1);
            normalSpacing = Spacing.of(context).spaces.normal;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(textScale, 0.85);
    expect(normalSpacing, 8.5);
  });

  testWidgets('app UI scale preserves system text scaling', (
    WidgetTester tester,
  ) async {
    late double textScale;

    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.2),
            ),
            child: HibikiAppUiScale(
              scale: 0.85,
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
        home: Builder(
          builder: (BuildContext context) {
            textScale = MediaQuery.textScalerOf(context).scale(1);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(textScale, closeTo(1.02, 0.001));
  });
}
