import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

/// 设计系统：分页只剩 Apple 胶囊在用（MD3 分页样式 2026-10-25 删除）。
enum _Design { apple }

// 2026-10-15 底栏「分页滑动」：胶囊里每页 5 个（查词留在右下角固定钮）；
// 底栏横滑翻页（跟手、过 1/4 页或甩一下就翻）；按住约 0.3 秒进入拖选，手指
// 罩着哪一格就选哪一格，拖到边缘停一下自动翻页，松手切过去。
//
// 2026-10-16 用户「手机上没看见分页啊。而且 apple 也要分页」：Apple 胶囊此前
// 不读 barStyle、恒按平铺画（9 个目的地全挤进一枚胶囊）。
//
// 2026-10-25 用户砍掉了 MD3 的「分页滑动」样式（设置里不再有这一项）；分页
// 只剩 Apple 胶囊用来画没接 Apple 的原型样式（含出厂默认的相机模式条），
// 所以下面只跑 Apple；几何按真手机（390×844 逻辑像素、DPR 3、出厂纯图标）。
void main() {
  const Size phone = Size(390, 844);
  const double dpr = 3;

  List<AdaptiveNavItem> itemsOf(int n) => <AdaptiveNavItem>[
    for (int i = 0; i < n; i++)
      AdaptiveNavItem(icon: Icons.circle_outlined, label: 'Tab$i'),
  ];

  Widget app(_Design design, Widget Function(BuildContext) bar) {
    final bool apple = design == _Design.apple;
    return MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        // Apple 组件悬浮面实色（glassMaterialTier 钉成 off，2026-10-13 拍板）。
        glass: FushiGlassMaterial.off,
        glassDesign: apple,
      ),
      themeAnimationDuration: Duration.zero,
      home: FushiGlassScope(
        child: FushiFocusRoot(
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: Builder(builder: bar),
          ),
        ),
      ),
    );
  }

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = phone * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpBar(
    WidgetTester tester,
    _Design design, {
    int count = 9,
    int currentIndex = 0,
    ValueChanged<int>? onTap,
    ValueChanged<int>? onDragSelect,
    AdaptiveNavBarStyle style = AdaptiveNavBarStyle.modeStrip,
    int? searchIndex,
  }) async {
    usePhone(tester);
    await tester.pumpWidget(
      app(
        design,
        (BuildContext context) => adaptiveBottomBar(
          context: context,
          currentIndex: currentIndex,
          onTap: onTap ?? (_) {},
          onDragSelect: onDragSelect,
          items: itemsOf(count),
          barStyle: style,
          // 真机出厂纯图标（`nav_bar_labels_visible` 默认关）。
          showLabels: false,
          glassSearchIndex: searchIndex,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 第 [i] 个目的地此刻在栏上看得见、点得到（别页的格被裁掉且不接指针）。
  Finder shown(int i) => find
      .byWidgetPredicate(
        (Widget w) =>
            w is FushiFocusTarget && w.id == FushiFocusId('nav-bar-$i'),
      )
      .hitTestable();

  List<int> bar() => <int>[
    for (int i = 0; i < 9; i++)
      if (shown(i).evaluate().isNotEmpty) i,
  ];

  Finder more() => find
      .byWidgetPredicate(
        (Widget w) =>
            w is FushiFocusTarget && w.id == const FushiFocusId('nav-bar-more'),
      )
      .hitTestable();

  double barY(WidgetTester tester) => tester.getCenter(shown(bar().first)).dy;

  Future<void> swipeBar(WidgetTester tester, double dx) async {
    final double y = barY(tester);
    await tester.dragFrom(Offset(phone.width / 2 - dx / 2, y), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  for (final _Design design in <_Design>[_Design.apple]) {
    group('${design.name} 翻页', () {
      testWidgets(
        '手机尺寸：一页 5 个，左滑翻到下一页，点第二页的项照常切；首页再右滑不动',
        (WidgetTester tester) async {
          final List<int> taps = <int>[];
          await pumpBar(tester, design, onTap: taps.add);
          expect(bar(), <int>[0, 1, 2, 3, 4]);
          expect(more(), findsNothing, reason: '分页样式没有「更多」');
          await swipeBar(tester, -220);
          expect(bar(), <int>[5, 6, 7, 8]);
          await tester.tap(shown(6));
          await tester.pumpAndSettle();
          expect(taps, <int>[6]);
          await swipeBar(tester, 220);
          expect(bar().first, 0);
          await swipeBar(tester, 220);
          expect(bar().first, 0);
        },
        variant: const TargetPlatformVariant(<TargetPlatform>{
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );

      // 真 app 实测：慢拖不到半页（没有甩速）曾被吸回原页，窄胶囊上手感发涩。
      testWidgets('慢拖约 1/3 页宽、不甩也翻页；只蹭约 1/6 弹回', (WidgetTester tester) async {
        await pumpBar(tester, design);
        final double y = barY(tester);
        await tester.timedDragFrom(
          Offset(300, y),
          const Offset(-120, 0),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        expect(bar(), <int>[5, 6, 7, 8]);
        await tester.timedDragFrom(
          Offset(100, y),
          const Offset(55, 0),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        expect(bar(), <int>[5, 6, 7, 8]);
      });

      testWidgets('当前项在第二页时直接停在第二页', (WidgetTester tester) async {
        await pumpBar(tester, design, currentIndex: 7);
        expect(bar(), <int>[5, 6, 7, 8]);
      });

      // 真 app 实测（原型期切样式时）：分组变了还沿用旧页号，会停在不该停的页。
      testWidgets('分组变了（开关模块）落回当前项所在页，不沿用旧页号', (WidgetTester tester) async {
        final ValueNotifier<int> count = ValueNotifier<int>(9);
        addTearDown(count.dispose);
        usePhone(tester);
        await tester.pumpWidget(
          app(
            design,
            (BuildContext context) => ValueListenableBuilder<int>(
              valueListenable: count,
              builder: (BuildContext context, int n, Widget? _) =>
                  adaptiveBottomBar(
                    context: context,
                    currentIndex: 1,
                    onTap: (_) {},
                    items: itemsOf(n),
                    showLabels: false,
                    barStyle: AdaptiveNavBarStyle.modeStrip,
                  ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await swipeBar(tester, -220);
        expect(bar(), <int>[5, 6, 7, 8]);
        count.value = 8;
        await tester.pumpAndSettle();
        expect(bar(), <int>[0, 1, 2, 3, 4]);
      });

      testWidgets('不多于 5 个入口时不分页', (WidgetTester tester) async {
        await pumpBar(tester, design, count: 5);
        expect(bar(), <int>[0, 1, 2, 3, 4]);
        await swipeBar(tester, -220);
        expect(bar(), <int>[0, 1, 2, 3, 4]);
      });

      // 2026-10-17 用户「底部左边要分页右下角是查词」：查词不进分页，翻到
      // 哪一页都钉在右侧（MD3 FAB / Apple 圆钮）。
      testWidgets('查词固定在右侧，其余目的地分页', (WidgetTester tester) async {
        await pumpBar(tester, design, searchIndex: 6);
        final Finder lookup = design == _Design.apple
            ? shown(6)
            : find
                  .byWidgetPredicate(
                    (Widget w) =>
                        w is FushiFocusTarget &&
                        w.id == const FushiFocusId('nav-bar-fab'),
                  )
                  .hitTestable();
        expect(lookup, findsOneWidget);
        expect(bar().where((int i) => i != 6), <int>[0, 1, 2, 3, 4]);
        final double lookupX = tester.getCenter(lookup).dx;
        expect(lookupX, greaterThan(tester.getCenter(shown(4)).dx));
        // 右侧让给查词钮，横滑要从胶囊里起手。
        await tester.dragFrom(
          tester.getCenter(shown(3)),
          const Offset(-220, 0),
        );
        await tester.pumpAndSettle();
        expect(bar().where((int i) => i != 6), <int>[5, 7, 8]);
        expect(lookup, findsOneWidget);
        expect(tester.getCenter(lookup).dx, lookupX);
      });

      testWidgets('平铺样式下不分页（9 个目的地不会只剩 5 个）', (WidgetTester tester) async {
        await pumpBar(tester, design, style: AdaptiveNavBarStyle.flat);
        await swipeBar(tester, -220);
        expect(
          bar().length + (more().evaluate().isEmpty ? 0 : 1),
          greaterThan(5),
        );
      });
    });

    group('${design.name} 按住拖选', () {
      testWidgets('按住 0.3 秒后拖到别的格松手：切过去', (WidgetTester tester) async {
        final List<int> taps = <int>[];
        final List<int> drags = <int>[];
        await pumpBar(tester, design, onTap: taps.add, onDragSelect: drags.add);
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(shown(0)),
        );
        await tester.pump(const Duration(milliseconds: 350));
        // 来回拖：先到 4，再回到 3 松手，以最后罩着的为准。
        await gesture.moveTo(tester.getCenter(shown(4)));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(shown(3)));
        await tester.pump();
        // 拖选中整排不跟着翻页。
        expect(bar(), <int>[0, 1, 2, 3, 4]);
        await gesture.up();
        await tester.pumpAndSettle();
        // Apple 保持 iOS 的点按切换语义，落地走 onTap。
        expect(taps, <int>[3]);
        expect(drags, isEmpty);
      });

      testWidgets('拖回当前项上松手 = 取消', (WidgetTester tester) async {
        final List<int> taps = <int>[];
        final List<int> drags = <int>[];
        await pumpBar(tester, design, onTap: taps.add, onDragSelect: drags.add);
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(shown(0)),
        );
        await tester.pump(const Duration(milliseconds: 350));
        await gesture.moveTo(tester.getCenter(shown(3)));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(shown(0)));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(drags, isEmpty);
        expect(taps, isEmpty);
      });

      testWidgets('没按够 0.3 秒就横拖 = 翻页，不是拖选', (WidgetTester tester) async {
        final List<int> taps = <int>[];
        final List<int> drags = <int>[];
        await pumpBar(tester, design, onTap: taps.add, onDragSelect: drags.add);
        await swipeBar(tester, -220);
        expect(drags, isEmpty);
        expect(taps, isEmpty);
        expect(bar(), <int>[5, 6, 7, 8]);
      });

      testWidgets('拖到右边缘停一下自动翻页，接着选第二页的项', (WidgetTester tester) async {
        final List<int> taps = <int>[];
        final List<int> drags = <int>[];
        await pumpBar(tester, design, onTap: taps.add, onDragSelect: drags.add);
        final Offset tab1 = tester.getCenter(shown(1));
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(shown(3)),
        );
        await tester.pump(const Duration(milliseconds: 350));
        // 拖出胶囊右缘外停住。
        await gesture.moveTo(Offset(phone.width - 2, tab1.dy));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(bar(), <int>[5, 6, 7, 8]);
        // 第二页第 2 格（原 1 的位置）是 6。
        await gesture.moveTo(tab1);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(<int>[...drags, ...taps], <int>[6]);
      });
    });

    group('${design.name} 方向键 / 手柄', () {
      // 分页是出厂默认（2026-10-16）：键盘 / 手柄用户只能靠焦点在栏上走，
      // 别页的目的地必须够得着（此前别页整页 ExcludeFocus，焦点停在第 5 格
      // 再往右就走不动，第 6~9 个目的地对键盘 / 手柄永远不可达）。
      testWidgets('从第一页走到最后一个目的地再走回来，焦点所在页随之翻过去', (WidgetTester tester) async {
        await pumpBar(tester, design);
        final FushiFocusController focus = FushiFocusRoot.controllerOf(
          tester.element(shown(0)),
        );
        expect(focus.requestById(const FushiFocusId('nav-bar-0')), isTrue);
        await tester.pumpAndSettle();
        String? primary() => FocusManager.instance.primaryFocus?.debugLabel;
        for (int i = 1; i < 9; i++) {
          expect(focus.move(FushiFocusDirection.right), isTrue);
          await tester.pumpAndSettle();
          expect(primary(), 'nav-bar-$i');
          // 焦点格一定在胶囊里看得见。
          expect(bar(), contains(i));
        }
        expect(bar(), <int>[5, 6, 7, 8]);
        expect(
          focus.move(FushiFocusDirection.right),
          isFalse,
          reason: '最后一个目的地往右没有下一格',
        );
        for (int i = 7; i >= 0; i--) {
          expect(focus.move(FushiFocusDirection.left), isTrue);
          await tester.pumpAndSettle();
          expect(primary(), 'nav-bar-$i');
          expect(bar(), contains(i));
        }
        expect(bar(), <int>[0, 1, 2, 3, 4]);
      });
    });
  }
}
