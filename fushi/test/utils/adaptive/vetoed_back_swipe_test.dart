// 页面用 `PopScope(canPop: false)` 拦返回时，iOS / macOS 边缘侧滑不能毫无反应：
// Flutter 原生 Cupertino 返回手势在这种情况下整个关掉（popGestureEnabled 为假），
// 用户右滑以为卡住了（拍板台 left3533，牌组设置页有改动时）。三套 Cupertino 转场
// builder（Material 主题 iOS/macOS、Apple 设计系统、墨水屏）都必须把这次侧滑转成
// `maybePop()`，落到页面自己的 onPopInvokedWithResult（didPop = false）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:material_ui/material_ui.dart';

const Map<String, PageTransitionsBuilder> _builders =
    <String, PageTransitionsBuilder>{
      'material-ios': FushiNativeCupertinoPageTransitionsBuilder(),
      'apple': FushiCupertinoPageTransitionsBuilder(),
      'eink': EinkCupertinoPageTransitionsBuilder(),
    };

final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

Widget _app(PageTransitionsBuilder builder, Widget home) => MaterialApp(
  navigatorKey: _navKey,
  theme: ThemeData(
    platform: TargetPlatform.iOS,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.iOS: builder,
      },
    ),
  ),
  home: home,
);

Widget _guarded({required bool canPop, required List<bool> log}) =>
    PopScope<Object?>(
      canPop: canPop,
      onPopInvokedWithResult: (bool didPop, Object? _) => log.add(didPop),
      child: const Scaffold(body: Center(child: Text('guarded'))),
    );

Future<void> _pushGuarded(
  WidgetTester tester, {
  required bool canPop,
  required List<bool> log,
}) async {
  _navKey.currentState!.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _guarded(canPop: canPop, log: log),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('guarded'), findsOneWidget);
}

void main() {
  for (final MapEntry<String, PageTransitionsBuilder> entry
      in _builders.entries) {
    group(entry.key, () {
      testWidgets('被否决时边缘侧滑走 maybePop，页面留着', (WidgetTester tester) async {
        final List<bool> log = <bool>[];
        await tester.pumpWidget(
          _app(entry.value, const Scaffold(body: Text('home'))),
        );
        await _pushGuarded(tester, canPop: false, log: log);

        await tester.dragFrom(const Offset(5, 300), const Offset(300, 0));
        await tester.pumpAndSettle();

        expect(log, <bool>[false]);
        expect(find.text('guarded'), findsOneWidget);
      });

      testWidgets('慢拖不够远不触发', (WidgetTester tester) async {
        final List<bool> log = <bool>[];
        await tester.pumpWidget(
          _app(entry.value, const Scaffold(body: Text('home'))),
        );
        await _pushGuarded(tester, canPop: false, log: log);

        await tester.timedDragFrom(
          const Offset(5, 300),
          const Offset(60, 0),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();

        expect(log, isEmpty);
        expect(find.text('guarded'), findsOneWidget);
      });

      testWidgets('不在边缘起手不触发', (WidgetTester tester) async {
        final List<bool> log = <bool>[];
        await tester.pumpWidget(
          _app(entry.value, const Scaffold(body: Text('home'))),
        );
        await _pushGuarded(tester, canPop: false, log: log);

        await tester.dragFrom(const Offset(100, 300), const Offset(300, 0));
        await tester.pumpAndSettle();

        expect(log, isEmpty);
      });

      testWidgets('没被否决时仍是原生侧滑返回', (WidgetTester tester) async {
        final List<bool> log = <bool>[];
        await tester.pumpWidget(
          _app(entry.value, const Scaffold(body: Text('home'))),
        );
        await _pushGuarded(tester, canPop: true, log: log);

        await tester.dragFrom(const Offset(5, 300), const Offset(500, 0));
        await tester.pumpAndSettle();

        expect(find.text('guarded'), findsNothing);
        expect(find.text('home'), findsOneWidget);
        expect(log, <bool>[true]);
      });

      testWidgets('首页被否决不接侧滑', (WidgetTester tester) async {
        final List<bool> log = <bool>[];
        await tester.pumpWidget(
          _app(entry.value, _guarded(canPop: false, log: log)),
        );
        await tester.pumpAndSettle();

        await tester.dragFrom(const Offset(5, 300), const Offset(300, 0));
        await tester.pumpAndSettle();

        expect(log, isEmpty);
      });
    });
  }
}
