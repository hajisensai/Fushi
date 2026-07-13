import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';

void main() {
  Future<({bool cupertino, bool macos})> resolve(
    WidgetTester tester, {
    required TargetPlatform platform,
    required HibikiDesignSystem designSystem,
  }) async {
    late ({bool cupertino, bool macos}) result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: platform,
          extensions: <ThemeExtension<dynamic>>[
            HibikiDesignSystemTheme(designSystem),
          ],
        ),
        home: Builder(
          builder: (BuildContext context) {
            result = (
              cupertino: isCupertinoPlatform(context),
              macos: isMacosPlatform(context),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('auto resolves to MD3 on all five platform families', (
    WidgetTester tester,
  ) async {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final result = await resolve(
        tester,
        platform: platform,
        designSystem: HibikiDesignSystem.auto,
      );
      expect(result.cupertino, isFalse, reason: '$platform');
      expect(result.macos, isFalse, reason: '$platform');
    }
  });

  testWidgets('explicit Apple modes remain internally available', (
    WidgetTester tester,
  ) async {
    final cupertino = await resolve(
      tester,
      platform: TargetPlatform.iOS,
      designSystem: HibikiDesignSystem.cupertino,
    );
    expect(cupertino.cupertino, isTrue);
    final macos = await resolve(
      tester,
      platform: TargetPlatform.macOS,
      designSystem: HibikiDesignSystem.macos,
    );
    expect(macos.macos, Platform.isMacOS);
  });

  testWidgets('missing design extension follows auto and stays MD3', (
    WidgetTester tester,
  ) async {
    late bool cupertino;
    late bool macos;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (BuildContext context) {
            cupertino = isCupertinoPlatform(context);
            macos = isMacosPlatform(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cupertino, isFalse);
    expect(macos, isFalse);
  });

  test('context-free adaptive route defaults to Material', () {
    final route = adaptivePageRoute<void>(
      builder: (_) => const SizedBox.shrink(),
    );
    expect(route, isA<MaterialPageRoute<void>>());
  });
}
