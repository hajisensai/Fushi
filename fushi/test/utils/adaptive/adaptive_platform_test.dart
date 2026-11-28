import 'dart:io' show File;

import 'package:material_ui/material_ui.dart';
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
}) async {
  final _RecordingNavigatorObserver observer = _RecordingNavigatorObserver();
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      navigatorObservers: <NavigatorObserver>[observer],
      theme: ThemeData(platform: platform),
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

  // Apple（玻璃）设计的推入转场由主题给（Cupertino 推入 + 页面背景层）；
  // CupertinoPageRoute 不读主题，推进来的页垫不上用户背景图片。
  testWidgets('glass design routes go through the theme transitions', (
    WidgetTester tester,
  ) async {
    final _RecordingNavigatorObserver observer = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: <NavigatorObserver>[observer],
        theme: ThemeData(
          platform: TargetPlatform.iOS,
          extensions: const <ThemeExtension<dynamic>>[
            FushiGlassTheme(FushiGlassMaterial.off, glassDesign: true),
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

    expect(observer.lastPushedRoute, isA<MaterialPageRoute<void>>());
  });

  testWidgets('MD3 routes stay Material on all five platform families', (
    WidgetTester tester,
  ) async {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final Route<dynamic>? route = await _pushAdaptiveRoute(
        tester,
        platform: platform,
      );
      expect(route, isA<MaterialPageRoute<void>>(), reason: '$platform');
    }
  });
}
