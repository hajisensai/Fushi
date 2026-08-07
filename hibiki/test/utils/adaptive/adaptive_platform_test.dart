import 'dart:io' show File, Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';

class _RecordingNavigatorObserver extends NavigatorObserver {
  Route<dynamic>? lastPushedRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    lastPushedRoute = route;
  }
}

Future<Route<dynamic>?> _pushAdaptiveRoute(
  WidgetTester tester, {
  required TargetPlatform platform,
  required HibikiDesignSystem? designSystem,
}) async {
  final _RecordingNavigatorObserver observer = _RecordingNavigatorObserver();
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      navigatorObservers: <NavigatorObserver>[observer],
      theme: ThemeData(
        platform: platform,
        extensions: designSystem == null
            ? const <ThemeExtension<dynamic>>[]
            : <ThemeExtension<dynamic>>[
                HibikiDesignSystemTheme(designSystem),
              ],
      ),
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () {
            Navigator.of(context).push<void>(
              adaptivePageRoute<void>(
                context: context,
                builder: (_) => const SizedBox.shrink(),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  observer.lastPushedRoute = null;

  await tester.tap(find.text('open'));
  await tester.pump();

  return observer.lastPushedRoute;
}

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

  test('adaptive route API requires the active BuildContext', () {
    final String source = File(
      'lib/src/utils/adaptive/adaptive_widgets.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        'Route<T> adaptivePageRoute<T>({\n'
        '  required BuildContext context,',
      ),
    );
    expect(source, isNot(contains('BuildContext? context')));
    expect(source, isNot(contains('context != null')));
  });

  testWidgets('explicit Cupertino route is pushed through a real Navigator', (
    WidgetTester tester,
  ) async {
    final Route<dynamic>? route = await _pushAdaptiveRoute(
      tester,
      platform: TargetPlatform.iOS,
      designSystem: HibikiDesignSystem.cupertino,
    );

    expect(route, isA<CupertinoPageRoute<void>>());
  });

  testWidgets('auto and missing extension routes stay Material everywhere', (
    WidgetTester tester,
  ) async {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final Route<dynamic>? autoRoute = await _pushAdaptiveRoute(
        tester,
        platform: platform,
        designSystem: HibikiDesignSystem.auto,
      );
      expect(autoRoute, isA<MaterialPageRoute<void>>(),
          reason: '$platform auto');

      final Route<dynamic>? missingRoute = await _pushAdaptiveRoute(
        tester,
        platform: platform,
        designSystem: null,
      );
      expect(
        missingRoute,
        isA<MaterialPageRoute<void>>(),
        reason: '$platform missing',
      );
    }
  });
}
