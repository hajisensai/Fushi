// TODO-1325 #6 制卡结果 MD3 toast 的 widget 守卫：FushiToast.showMine 按状态
// 配 Material 图标并给图标上语义色（浮条底色恒为主题 inverseSurface），走
// 应用 navigator overlay 的自绘路径。这正是本次新增的、区别于弹窗内 mine 按钮图标
// 变化的、可见的桌面/移动统一制卡反馈通道。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

Future<void> _pumpToastHost(WidgetTester tester) async {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  FushiToast.navigatorKey = navKey;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
}

/// toast 浮条的底色：MD3 下恒为主题 inverseSurface，不再按状态整块着色。
Color _toastBg(WidgetTester tester) {
  final Iterable<Container> containers =
      tester.widgetList<Container>(find.byType(Container));
  for (final Container c in containers) {
    final Decoration? d = c.decoration;
    if (d is BoxDecoration && d.color != null && d.borderRadius != null) {
      return d.color!;
    }
  }
  fail('未找到制卡 toast 的浮条');
}

/// 状态图标的颜色（语义只落在前置图标上）。
Color? _iconColor(WidgetTester tester, IconData icon) =>
    tester.widget<Icon>(find.byIcon(icon)).color;

/// 默认浅色主题下 inverseSurface 是深底，语义色取 MD3 tone 80 一档。
Color _inverseSurface(WidgetTester tester) => Theme.of(
      tester.element(find.byType(Scaffold)),
    ).colorScheme.inverseSurface;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mineToastPalette 四态颜色/图标符合 added绿/duplicate橙/failed红/pending蓝',
      (WidgetTester tester) async {
    expect(mineToastPalette(MineToastStatus.added).background,
        const Color(0xFF2E7D32));
    expect(mineToastPalette(MineToastStatus.added).icon,
        FushiIcons.filled(FushiIcons.success));
    expect(mineToastPalette(MineToastStatus.duplicate).background,
        const Color(0xFFEF6C00));
    expect(mineToastPalette(MineToastStatus.failed).background,
        const Color(0xFFC62828));
    expect(mineToastPalette(MineToastStatus.failed).icon,
        FushiIcons.filled(FushiIcons.error));
    expect(mineToastPalette(MineToastStatus.pending).background,
        const Color(0xFF1565C0));
    // orange 800 配白字只有 3.08:1；duplicate/warning 用黑字达到 6.81:1。
    expect(mineToastPalette(MineToastStatus.duplicate).foreground, Colors.black);
    expect(toastSeverityPalette(ToastSeverity.warning)?.foreground,
        Colors.black);
    for (final MineToastStatus s in <MineToastStatus>[
      MineToastStatus.added,
      MineToastStatus.failed,
      MineToastStatus.pending,
    ]) {
      expect(mineToastPalette(s).foreground, Colors.white);
    }
  });

  testWidgets('added：toast 渲染绿色 check 图标 + 文案',
      (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '已添加到牌组', status: MineToastStatus.added);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('已添加到牌组'), findsOneWidget);
    expect(find.byIcon(FushiIcons.filled(FushiIcons.success)), findsOneWidget);
    expect(_toastBg(tester), _inverseSurface(tester),
        reason: '底色是主题浮条色，不整块铺状态色');
    expect(_iconColor(tester, FushiIcons.filled(FushiIcons.success)),
        const Color(0xFF7DDC8C));

    await tester.pump(const Duration(seconds: 3)); // 跑完自动消失计时器
  });

  testWidgets('duplicate：橙色重复图标', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '重复卡片', status: MineToastStatus.duplicate);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(FushiIcons.filled(FushiIcons.libraryAdd)), findsOneWidget);
    expect(_toastBg(tester), _inverseSurface(tester));
    expect(_iconColor(tester, FushiIcons.filled(FushiIcons.libraryAdd)),
        const Color(0xFFFFB870));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('failed：红色错误图标', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '制卡失败', status: MineToastStatus.failed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(FushiIcons.filled(FushiIcons.error)), findsOneWidget);
    expect(_toastBg(tester), _inverseSurface(tester));
    expect(_iconColor(tester, FushiIcons.filled(FushiIcons.error)), const Color(0xFFFFB4AB));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('pending：同步图标，随后被结果 toast 顶替',
      (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '制卡中…', status: MineToastStatus.pending);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(FushiIcons.sync), findsOneWidget);
    expect(_toastBg(tester), _inverseSurface(tester));

    // 结果 toast 顶替 pending：只剩一张 added 绿卡片。
    FushiToast.showMine(msg: '已添加', status: MineToastStatus.added);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byIcon(FushiIcons.sync), findsNothing,
        reason: 'pending 应被结果 toast 顶替');
    expect(find.byIcon(FushiIcons.filled(FushiIcons.success)), findsOneWidget);
    expect(_iconColor(tester, FushiIcons.filled(FushiIcons.success)),
        const Color(0xFF7DDC8C));

    await tester.pump(const Duration(seconds: 3));
  });
}
