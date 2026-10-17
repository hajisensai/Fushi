import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:material_ui/material_ui.dart';

final class _Run {
  _Run(this.visible, this.hidden, this.visibleRightEdges);
  final List<double> visible;
  final List<double> hidden;
  final List<double> visibleRightEdges;
}

/// 侧栏展开 / 收起：rail 宽度逐帧变化，右侧 `Expanded` 内容区（含 Offstage
/// 保活的全部 tab 页）随之重排。[NavRailContentSync] 只让**藏起的**保活子树
/// 在过渡期间保持同一宽度（一次切换至多重排一次）；可见内容必须逐帧跟随 rail，
/// 否则右侧贴边的内容整段过渡被裁掉、结束时再弹回（BUG-3447）。探针是
/// [LayoutBuilder]：它的 builder 只在约束变化时重跑，跑的次数就是子树被重新
/// 布局的次数；可见探针同时记下自己在屏幕上的右缘。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];
  const Size surface = Size(1200, 800);
  const Key visibleKey = ValueKey<String>('visible-probe');

  Widget harness({
    required ValueNotifier<bool> extended,
    required List<double> visibleWidths,
    required List<double> hiddenWidths,
  }) {
    Widget probe(List<double> sink, {Key? key}) => LayoutBuilder(
      key: key,
      builder: (BuildContext context, BoxConstraints constraints) {
        sink.add(constraints.maxWidth);
        return const SizedBox.expand();
      },
    );
    return MaterialApp(
      home: Scaffold(
        body: NavRailContentSync(
          child: Row(
            children: <Widget>[
              ValueListenableBuilder<bool>(
                valueListenable: extended,
                builder: (BuildContext context, bool value, _) =>
                    adaptiveNavRail(
                      context: context,
                      currentIndex: 0,
                      onTap: (_) {},
                      items: items,
                      extended: value,
                      onToggleExtended: () => extended.value = !extended.value,
                    ),
              ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Offstage(
                      child: NavRailSyncedContent(
                        hidden: true,
                        child: probe(hiddenWidths),
                      ),
                    ),
                    Offstage(
                      offstage: false,
                      child: NavRailSyncedContent(
                        hidden: false,
                        child: probe(visibleWidths, key: visibleKey),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 切换一次展开态并逐帧走完弹簧，返回过渡期间两个探针被布局的宽度序列与
  /// 可见探针每帧的屏幕右缘。
  Future<_Run> toggleAndSettle(
    WidgetTester tester, {
    required bool startExtended,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ValueNotifier<bool> extended = ValueNotifier<bool>(startExtended);
    addTearDown(extended.dispose);
    final List<double> visible = <double>[];
    final List<double> hidden = <double>[];
    final List<double> rightEdges = <double>[];
    await tester.pumpWidget(
      harness(extended: extended, visibleWidths: visible, hiddenWidths: hidden),
    );
    await tester.pumpAndSettle();
    visible.clear();
    hidden.clear();

    extended.value = !startExtended;
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      rightEdges.add(tester.getRect(find.byKey(visibleKey)).right);
    }
    await tester.pumpAndSettle();
    return _Run(visible, hidden, rightEdges);
  }

  for (final bool startExtended in <bool>[false, true]) {
    final String direction = startExtended ? '收起' : '展开';

    testWidgets('rail $direction过渡中藏起的保活子树至多重排一次', (WidgetTester tester) async {
      final _Run run = await toggleAndSettle(
        tester,
        startExtended: startExtended,
      );
      expect(
        run.hidden.length,
        lessThanOrEqualTo(1),
        reason: '藏起的子树在过渡中被重新布局了 ${run.hidden.length} 次：${run.hidden}',
      );
    });

    testWidgets('rail $direction过渡中可见内容逐帧跟随且右缘始终贴窗口右缘', (
      WidgetTester tester,
    ) async {
      final _Run run = await toggleAndSettle(
        tester,
        startExtended: startExtended,
      );
      // BUG-3447：钉宽方案下可见内容按较宽一端排版、随 rail 边缘平移，右缘
      // 整段过渡越出窗口被裁掉，结束时才重排弹回——用户看到的「右边闪烁」。
      for (final double right in run.visibleRightEdges) {
        expect(right, moreOrLessEquals(surface.width, epsilon: 0.5));
      }
      // 弹簧确实在逐帧动，可见内容逐帧重排而不是钉在某一端的宽度上。
      expect(run.visible.length, greaterThan(5));
    });
  }

  testWidgets('静止后两个探针宽度一致 = 窗口宽 − rail 占位宽', (WidgetTester tester) async {
    for (final bool startExtended in <bool>[false, true]) {
      final _Run run = await toggleAndSettle(
        tester,
        startExtended: startExtended,
      );
      // 收起时藏起子树唯一一次重排发生在开头、展开时发生在结尾：两种情况下
      // 它最后一次布局的宽度都必须落在可见内容的最终宽度上。
      expect(run.hidden, isNotEmpty);
      expect(run.visible, isNotEmpty);
      expect(run.hidden.last, run.visible.last);
    }
  });
}
