// iOS 侧滑返回 × 墨水屏模式的行为守卫。
//
// 为什么这条守卫必须存在：
//
// * iOS **没有系统返回键**。隐藏了顶栏（无 AppBar / 无自绘返回按钮）的页面，
//   用户唯一的出口就是从左边缘往右的侧滑返回手势。
// * 这个手势不是 iOS 系统给的，是 Flutter 自己装的：只有 Cupertino 系的
//   `PageTransitionsBuilder`（`CupertinoRouteTransitionMixin.buildPageTransitions`）
//   才会在页面外面套上 `_CupertinoBackGestureDetector`。
// * 本 app 默认设计系统是 `auto`，`isCupertinoPlatform` 在 iOS 上返回 false，
//   于是 iOS 的每个页面都是普通的 `MaterialPageRoute`——它的返回手势 **100%**
//   来自 `ThemeData.pageTransitionsTheme` 里给 `TargetPlatform.iOS` 注册的那一项，
//   没有任何别的兜底。
//
// 回归原样：墨水屏分支曾给 iOS/macOS 注册 `EinkNoPageTransitionsBuilder`
// （`buildTransitions` 直接 `return child;`）。它不套手势检测器，于是「打开墨水屏
// 模式」= 整个 app 在 iOS 上丢掉侧滑返回，隐藏顶栏的页面永久出不去，而且没有任何
// 报错——只有用户发现「滑不回去了」。
//
// 修复是 `EinkCupertinoPageTransitionsBuilder`：委托给 Cupertino 的
// `buildPageTransitions` 保住手势检测器，同时在「没有拖动进行中」时喂
// `kAlwaysCompleteAnimation` / `kAlwaysDismissedAnimation`，让页面照旧单帧切换
// （墨水屏只刷一次，不拖影）。
//
// 所以这里测的是**行为**而不是类型：真的推一个页面，真的从左边缘拖一把，真的断言
// 回到了上一页。末尾另有一条反向对照（换回 `EinkNoPageTransitionsBuilder` 必须
// 滑不回去），用来证明这条测试测的是手势本身，不是一条恒绿的断言。
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';

const String _kFirstPageText = '第一页';
const String _kSecondPageText = '第二页';

void main() {
  late FushiDatabase db;
  late ThemeNotifier notifier;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, () => const TextTheme());
    // 直接喂偏好快照打开墨水屏，走的是产品代码真正的 eink 分支。
    notifier.loadFromPrefsSnapshot(<String, String>{
      'eink_mode': PrefCodec.encode(true),
    });
  });

  tearDown(() async {
    notifier.dispose();
    await db.close();
  });

  /// 把 body 跑在「当前平台是 iOS」下。
  ///
  /// 覆盖必须在 body 内设、body 内清：`flutter_test` 在测试体跑完、tearDown 之前就
  /// 校验 foundation 调试变量已复位，放进 tearDown 会直接抛
  /// 「The value of a foundation debug variable was changed by the test」。
  /// 同理 `ThemeData.platform` 取的是**构造时**的 defaultTargetPlatform，所以主题也
  /// 只能在覆盖生效期间才去取（`notifier.theme` 是每次现算的 getter）。
  Future<void> runAsIos(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// 只保留 `pageTransitionsTheme` 的最小主题，用来做反向对照。
  ThemeData themeWithIosBuilder(PageTransitionsBuilder iosBuilder) {
    return ThemeData(
      // 六个平台都得列全：`builders` 是全量替换而非合并，漏掉的平台会静默回落到
      // ZoomPageTransitionsBuilder。
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: const EinkNoPageTransitionsBuilder(),
          TargetPlatform.iOS: iosBuilder,
          TargetPlatform.macOS: iosBuilder,
          TargetPlatform.windows: const EinkNoPageTransitionsBuilder(),
          TargetPlatform.linux: const EinkNoPageTransitionsBuilder(),
          TargetPlatform.fuchsia: const EinkNoPageTransitionsBuilder(),
        },
      ),
    );
  }

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Widget pageWith(String label) {
    return Scaffold(
      // 顶栏故意不放：iOS 上这正是「只能靠侧滑出去」的那种页面。
      body: Align(alignment: Alignment.topLeft, child: Text(label)),
    );
  }

  Future<void> pumpApp(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: theme,
        home: pageWith(_kFirstPageText),
      ),
    );
    await tester.pumpAndSettle();
  }

  void pushSecondPage() {
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => pageWith(_kSecondPageText)),
    );
  }

  /// 从左边缘往右拖一把——模拟 iOS 侧滑返回。
  Future<void> swipeBack(WidgetTester tester) async {
    await tester.dragFrom(const Offset(3, 300), const Offset(500, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('墨水屏主题在 iOS 上仍装着 Cupertino 侧滑返回手势', (WidgetTester tester) async {
    await runAsIos(() async {
      expect(notifier.einkMode, isTrue, reason: '前置条件：测的必须是 eink 分支');
      final ThemeData theme = notifier.theme;
      expect(
        theme.platform,
        TargetPlatform.iOS,
        reason: 'MaterialPageRoute 按 ThemeData.platform 选 builder',
      );

      await pumpApp(tester, theme);
      expect(find.text(_kFirstPageText), findsOneWidget);

      pushSecondPage();
      await tester.pumpAndSettle();
      expect(find.text(_kSecondPageText), findsOneWidget);

      await swipeBack(tester);

      expect(
        find.text(_kSecondPageText),
        findsNothing,
        reason: '墨水屏模式下 iOS 丢了侧滑返回：iOS 没有系统返回键，隐藏顶栏的页面'
            '就此永久出不去。返回手势只能来自 pageTransitionsTheme 里 '
            'TargetPlatform.iOS 那一项，直接 `return child` 的 '
            'EinkNoPageTransitionsBuilder 不会装手势检测器',
      );
      expect(find.text(_kFirstPageText), findsOneWidget);
    });
  });

  testWidgets('反向对照：iOS 换回零转场 builder 就真的滑不回去', (WidgetTester tester) async {
    await runAsIos(() async {
      // 证明上面那条测的是手势本身而不是恒绿：同一套拖动，在
      // EinkNoPageTransitionsBuilder 下必须**留在**第二页。
      await pumpApp(
        tester,
        themeWithIosBuilder(const EinkNoPageTransitionsBuilder()),
      );

      pushSecondPage();
      await tester.pumpAndSettle();
      expect(find.text(_kSecondPageText), findsOneWidget);

      await swipeBack(tester);

      expect(
        find.text(_kSecondPageText),
        findsOneWidget,
        reason: '零转场 builder 不套 _CupertinoBackGestureDetector，拖动应当无效——'
            '这条一旦变红说明侧滑返回另有来源，上面那条正向用例就不再有意义',
      );
      expect(find.text(_kFirstPageText), findsNothing);
    });
  });

  testWidgets('修复没有破坏墨水屏的单帧切换：push 后无需等动画', (WidgetTester tester) async {
    await runAsIos(() async {
      // 墨水屏要的是「一次刷新换页」，不能因为接回 Cupertino 转场就变成滑动动画。
      await pumpApp(tester, notifier.theme);

      pushSecondPage();
      await tester.pump(); // 建路由
      await tester.pump(const Duration(milliseconds: 1)); // 起动画的第一帧

      expect(find.text(_kSecondPageText), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_kSecondPageText)).dx,
        0.0,
        reason: '喂了 kAlwaysCompleteAnimation，第二页第一帧就该完全落位；若开始逐帧'
            '横移说明墨水屏又变回有动画的转场',
      );
    });
  });

  test('eink 分支不得把 iOS/macOS 退回零转场 builder', () {
    // 类型级防回退：这两项一旦被改回 EinkNoPageTransitionsBuilder，整个 app 在
    // iOS 上就没有返回手势了。
    final Map<TargetPlatform, PageTransitionsBuilder> builders =
        notifier.theme.pageTransitionsTheme.builders;
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      expect(
        builders[platform],
        isA<EinkCupertinoPageTransitionsBuilder>(),
        reason: '$platform 的返回手势只能由 Cupertino 系 builder 装载',
      );
    }
    // 其余平台仍应保持零转场（墨水屏的本意），漏配会静默回落到 Zoom 转场。
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      expect(builders[platform], isA<EinkNoPageTransitionsBuilder>());
    }
  });
}
