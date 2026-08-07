// TODO-1325 #6 制卡结果 MD3 toast 的 widget 守卫：FushiToast.showMine 按状态
// （added 绿 / duplicate 橙 / failed 红 / pending 蓝）着色并配 Material 图标，走
// 应用 navigator overlay 的自绘路径。这正是本次新增的、区别于弹窗内 mine 按钮图标
// 变化的、可见的桌面/移动统一制卡反馈通道。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/hibiki_toast.dart';

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

/// 找到 mine toast 那张着色卡片的 BoxDecoration 背景色。
Color _toastBg(WidgetTester tester) {
  final Iterable<Container> containers =
      tester.widgetList<Container>(find.byType(Container));
  for (final Container c in containers) {
    final Decoration? d = c.decoration;
    if (d is BoxDecoration && d.color != null && d.borderRadius != null) {
      return d.color!;
    }
  }
  fail('未找到制卡 toast 的着色卡片');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mineToastPalette 四态颜色/图标符合 added绿/duplicate橙/failed红/pending蓝',
      (WidgetTester tester) async {
    expect(mineToastPalette(MineToastStatus.added).background,
        const Color(0xFF2E7D32));
    expect(mineToastPalette(MineToastStatus.added).icon,
        Icons.check_circle_rounded);
    expect(mineToastPalette(MineToastStatus.duplicate).background,
        const Color(0xFFEF6C00));
    expect(mineToastPalette(MineToastStatus.failed).background,
        const Color(0xFFC62828));
    expect(mineToastPalette(MineToastStatus.failed).icon, Icons.error_rounded);
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

  testWidgets('added：toast 渲染绿色卡片 + check 图标 + 文案',
      (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '已添加到牌组', status: MineToastStatus.added);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('已添加到牌组'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(_toastBg(tester), const Color(0xFF2E7D32));

    await tester.pump(const Duration(seconds: 3)); // 跑完自动消失计时器
  });

  testWidgets('duplicate：橙色卡片 + 重复图标', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '重复卡片', status: MineToastStatus.duplicate);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(Icons.library_add_check_rounded), findsOneWidget);
    expect(_toastBg(tester), const Color(0xFFEF6C00));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('failed：红色卡片 + 错误图标', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '制卡失败', status: MineToastStatus.failed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    expect(_toastBg(tester), const Color(0xFFC62828));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('pending：蓝色卡片 + 同步图标，随后被结果 toast 顶替',
      (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(msg: '制卡中…', status: MineToastStatus.pending);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
    expect(_toastBg(tester), const Color(0xFF1565C0));

    // 结果 toast 顶替 pending：只剩一张 added 绿卡片。
    FushiToast.showMine(msg: '已添加', status: MineToastStatus.added);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byIcon(Icons.sync_rounded), findsNothing,
        reason: 'pending 应被结果 toast 顶替');
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(_toastBg(tester), const Color(0xFF2E7D32));

    await tester.pump(const Duration(seconds: 3));
  });
}
