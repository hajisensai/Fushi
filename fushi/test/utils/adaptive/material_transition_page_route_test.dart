// 小说阅读器路由：不论设计系统都按 Material 设计系统的转场进出（用户 2026-11-27
// 「Cupertino 会闪一下，以 Material 那种为准」）。
//
// 钉住三件事：Apple 主题下本页转场换成 Material 那套、被盖住的页不再按 Cupertino
// 视差左移、Material 主题下与普通 MaterialPageRoute 一致。
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransition;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_transitions_themes.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

ThemeData _theme({required bool apple, required TargetPlatform platform}) =>
    buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959)),
      textTheme: const TextTheme(),
      glassDesign: apple,
      eink: false,
    ).copyWith(platform: platform);

final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();

Future<void> _pumpHome(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: _nav,
      theme: theme,
      home: const Scaffold(body: Text('home')),
    ),
  );
}

Route<void> _readerRoute() => FushiMaterialTransitionPageRoute<void>(
  builder: (_) => const Scaffold(body: Text('reader')),
);

void main() {
  testWidgets('Apple 主题（Windows）：进出走 Material 共享轴转场，底页不视差左移', (
    WidgetTester tester,
  ) async {
    final ThemeData theme = _theme(
      apple: true,
      platform: TargetPlatform.windows,
    );
    expect(
      identical(theme.pageTransitionsTheme, fushiApplePageTransitionsTheme),
      isTrue,
    );
    await _pumpHome(tester, theme);
    final double homeX = tester.getTopLeft(find.text('home')).dx;

    final Route<void> route = _readerRoute();
    _nav.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      (route as TransitionRoute<void>).transitionDuration,
      FushiMotion.long,
    );
    final Finder reader = find.text('reader');
    expect(
      find.ancestor(
        of: reader,
        matching: find.byType(FushiSharedAxisTransition),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: reader, matching: find.byType(CupertinoPageTransition)),
      findsNothing,
    );
    expect(tester.getTopLeft(find.text('home')).dx, homeX);

    await tester.pumpAndSettle();
    _nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(find.text('home')).dx, homeX);
    expect(
      find.ancestor(of: reader, matching: find.byType(CupertinoPageTransition)),
      findsNothing,
    );
    await tester.pumpAndSettle();
    expect(reader, findsNothing);
  });

  testWidgets('对照：Apple 主题下普通页面路由仍是 Cupertino 推入（底页左移）', (
    WidgetTester tester,
  ) async {
    await _pumpHome(
      tester,
      _theme(apple: true, platform: TargetPlatform.windows),
    );
    final double homeX = tester.getTopLeft(find.text('home')).dx;
    _nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('other')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(find.text('home')).dx, lessThan(homeX));
    await tester.pumpAndSettle();
  });

  testWidgets('Apple 主题（Android）：本页不走 Cupertino 推入', (
    WidgetTester tester,
  ) async {
    await _pumpHome(
      tester,
      _theme(apple: true, platform: TargetPlatform.android),
    );
    _nav.currentState!.push(_readerRoute());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      find.ancestor(
        of: find.text('reader'),
        matching: find.byType(CupertinoPageTransition),
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('Material 主题：与普通 MaterialPageRoute 同一转场、同一委托', (
    WidgetTester tester,
  ) async {
    final ThemeData theme = _theme(
      apple: false,
      platform: TargetPlatform.windows,
    );
    expect(
      identical(theme.pageTransitionsTheme, fushiMaterialPageTransitionsTheme),
      isTrue,
    );
    await _pumpHome(tester, theme);
    final Route<void> route = _readerRoute();
    _nav.currentState!.push(route);
    await tester.pump();
    final MaterialPageRoute<void> plain = MaterialPageRoute<void>(
      builder: (_) => const SizedBox(),
    );
    expect(
      (route as MaterialPageRoute<void>).delegatedTransition,
      same(plain.delegatedTransition),
    );
    expect(route.transitionDuration, FushiMotion.long);
    await tester.pumpAndSettle();
  });
}
