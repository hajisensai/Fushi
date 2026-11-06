// Apple（Cupertino）设计系统页面转场 × 系统「减弱动态效果」的行为守卫。
//
// 回归原样：Apple 分支六个平台直接挂裸 `CupertinoPageTransitionsBuilder`，它不认
// `MediaQuery.disableAnimations`——开了系统「减弱动态效果」的用户每次 push / pop
// 照样看 500ms 的右侧推入 + 旧页视差，违反「动效时长取 fushiMotionDuration，减弱
// 动态效果时归零」。MD3 桌面的 FushiSharedAxisTransition 在同样条件下早就退成
// 原地线性淡入。
//
// 这里测行为：真的推一页，在转场中途量新页 / 旧页的位置；并在 iOS 下确认减弱
// 动态效果时边缘侧滑返回仍然有效（iOS 没有系统返回键）。每条都有「动效开启」的
// 对照，证明断言不是恒绿。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:material_ui/material_ui.dart';

const String _kFirst = '第一页';
const String _kSecond = '第二页';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

ThemeData _appleTheme() => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959)),
  textTheme: const TextTheme(),
  glassDesign: true,
);

Widget _page(String label) => Scaffold(
  body: Align(alignment: Alignment.topLeft, child: Text(label)),
);

Future<void> _pumpApp(WidgetTester tester, {required bool reduceMotion}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: _navigatorKey,
      theme: _appleTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: _page(_kFirst),
    ),
  );
  await tester.pumpAndSettle();
}

/// 推第二页并停在转场中途（500ms 的 1/5 处）。
Future<void> _pushAndPumpMidway(WidgetTester tester) async {
  _navigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => _page(_kSecond)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// 把 body 跑在给定平台下（主题的 platform 取构造时的 defaultTargetPlatform，
/// 所以主题要在覆盖生效期间才构造）。
Future<void> _runOn(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.iOS,
  ]) {
    testWidgets('${platform.name}：减弱动态效果下原地淡入，无推入位移与旧页视差', (
      WidgetTester tester,
    ) async {
      await _runOn(platform, () async {
        await _pumpApp(tester, reduceMotion: true);
        await _pushAndPumpMidway(tester);
        expect(
          tester.getTopLeft(find.text(_kSecond)).dx,
          0.0,
          reason: '减弱动态效果下新页不得从右侧推入',
        );
        expect(
          tester.getTopLeft(find.text(_kFirst)).dx,
          0.0,
          reason: '减弱动态效果下旧页不得视差左移',
        );
        final Iterable<FadeTransition> fades = tester
            .widgetList<FadeTransition>(
              find.ancestor(
                of: find.text(_kSecond),
                matching: find.byType(FadeTransition),
              ),
            );
        expect(
          fades.any(
            (FadeTransition f) => f.opacity.value > 0 && f.opacity.value < 1,
          ),
          isTrue,
          reason: '转场中途新页应处于半透明的淡入过程',
        );
        await tester.pumpAndSettle();
        expect(find.text(_kSecond), findsOneWidget);
      });
    });

    testWidgets('${platform.name}：对照——动效开启时仍是 Cupertino 推入', (
      WidgetTester tester,
    ) async {
      await _runOn(platform, () async {
        await _pumpApp(tester, reduceMotion: false);
        await _pushAndPumpMidway(tester);
        expect(
          tester.getTopLeft(find.text(_kSecond)).dx,
          greaterThan(0.0),
          reason: '动效开启时新页从右侧推入；这条变红说明上面的用例不再有意义',
        );
        await tester.pumpAndSettle();
      });
    });
  }

  testWidgets('iOS：减弱动态效果下边缘侧滑返回仍有效', (WidgetTester tester) async {
    await _runOn(TargetPlatform.iOS, () async {
      await _pumpApp(tester, reduceMotion: true);
      _navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => _page(_kSecond)),
      );
      await tester.pumpAndSettle();
      expect(find.text(_kSecond), findsOneWidget);

      await tester.dragFrom(const Offset(3, 300), const Offset(500, 0));
      await tester.pumpAndSettle();

      expect(
        find.text(_kSecond),
        findsNothing,
        reason: 'iOS 没有系统返回键：减弱动态效果不能把侧滑返回手势一起拆掉',
      );
      expect(find.text(_kFirst), findsOneWidget);
    });
  });
}
