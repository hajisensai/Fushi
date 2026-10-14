import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:material_ui/material_ui.dart';

/// 侧栏展开 / 收起掉帧：rail 宽度逐帧变化，右侧 `Expanded` 内容区（含 Offstage
/// 保活的全部 tab 页）每帧重排。[NavRailContentSync] 让内容区在过渡期间保持
/// 同一宽度，一次切换至多重排一次。探针是 [LayoutBuilder]：它的 builder 只在
/// 约束变化时重跑，跑的次数就是内容子树被重新布局的次数。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];

  Widget harness({
    required ValueNotifier<bool> extended,
    required List<double> contentWidths,
    required bool synced,
  }) {
    final Widget probe = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        contentWidths.add(constraints.maxWidth);
        return const SizedBox.expand();
      },
    );
    final Widget row = Row(
      children: <Widget>[
        ValueListenableBuilder<bool>(
          valueListenable: extended,
          builder: (BuildContext context, bool value, _) => adaptiveNavRail(
            context: context,
            currentIndex: 0,
            onTap: (_) {},
            items: items,
            extended: value,
            onToggleExtended: () => extended.value = !extended.value,
          ),
        ),
        Expanded(child: synced ? NavRailSyncedContent(child: probe) : probe),
      ],
    );
    return MaterialApp(
      home: Scaffold(body: synced ? NavRailContentSync(child: row) : row),
    );
  }

  /// 切换一次展开态并逐帧走完弹簧，返回过渡期间内容区被布局的宽度序列。
  Future<List<double>> toggleAndSettle(
    WidgetTester tester, {
    required bool startExtended,
    required bool synced,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ValueNotifier<bool> extended = ValueNotifier<bool>(startExtended);
    addTearDown(extended.dispose);
    final List<double> widths = <double>[];
    await tester.pumpWidget(
      harness(extended: extended, contentWidths: widths, synced: synced),
    );
    await tester.pumpAndSettle();
    widths.clear();

    extended.value = !startExtended;
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    return widths;
  }

  for (final bool startExtended in <bool>[false, true]) {
    final String direction = startExtended ? '收起' : '展开';

    testWidgets('rail $direction过渡中内容区至多重排一次', (WidgetTester tester) async {
      final List<double> widths = await toggleAndSettle(
        tester,
        startExtended: startExtended,
        synced: true,
      );
      expect(
        widths.length,
        lessThanOrEqualTo(1),
        reason: '内容区在过渡中被重新布局了 ${widths.length} 次：$widths',
      );
    });

    // 反向对照：不包 NavRailSyncedContent 时内容区确实逐帧重排——证明上一条
    // 测的是同步本身，弹簧也确实在逐帧动。
    testWidgets('对照：未同步时 rail $direction逐帧重排内容区', (WidgetTester tester) async {
      final List<double> widths = await toggleAndSettle(
        tester,
        startExtended: startExtended,
        synced: false,
      );
      expect(widths.length, greaterThan(5));
    });
  }

  testWidgets('静止后内容区宽度 = 窗口宽 − rail 占位宽', (WidgetTester tester) async {
    for (final bool startExtended in <bool>[false, true]) {
      final List<double> synced = await toggleAndSettle(
        tester,
        startExtended: startExtended,
        synced: true,
      );
      final List<double> plain = await toggleAndSettle(
        tester,
        startExtended: startExtended,
        synced: false,
      );
      // 收起时唯一一次重排发生在开头、展开时发生在结尾：两种情况下同步版
      // 最后一次布局的宽度都必须落在未同步版的最终宽度上。
      expect(synced, isNotEmpty);
      expect(synced.last, plain.last);
    }
  });
}
