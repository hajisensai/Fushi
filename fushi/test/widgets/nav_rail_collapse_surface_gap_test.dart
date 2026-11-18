import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4853：侧栏展开 / 收起过渡中，rail 面板（镂空脊色块 / 色脊色块 / 悬浮
/// 面板）必须逐帧贴着内容区起始边一起动。旧实现把面板也按**目标宽**排版、只裁
/// 出当前宽：收起时色块瞬间缩到收起宽，占位宽（内容区起始边）还在弹簧当前值，
/// 二者之间露出一条页面底色的竖带，镂空脊的舞台圆角贴在竖带外侧。
///
/// 判据：面板外缘与内容区起始边之间的缝，在过渡的每一帧都等于静止时的缝
/// （镂空脊为 0，悬浮样式为固定留白）；同时面板宽确实逐帧在变（弹簧在动）。
/// 展开 / 收起由改 rail 的 `extended` 驱动，不点击。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];
  const Size surface = Size(1200, 800);
  const Key contentKey = ValueKey<String>('content');

  /// 面板（镂空脊色块 / 悬浮面板）——私有类型，按类型名找。
  final Finder panel = find.byWidgetPredicate((Widget widget) {
    final String name = widget.runtimeType.toString();
    return name == '_RailNotchSurface' || name == '_FloatingNavSurface';
  });

  Widget harness({
    required ValueNotifier<bool> extended,
    required ShellRailStyle style,
    required bool glass,
    required TextDirection direction,
  }) {
    return MaterialApp(
      theme: ThemeData(
        extensions: <ThemeExtension<dynamic>>[
          FushiShellTheme(railStyle: style),
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: glass),
        ],
      ),
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: NavRailContentSync(
            child: Row(
              children: <Widget>[
                ValueListenableBuilder<bool>(
                  valueListenable: extended,
                  builder: (BuildContext context, bool value, _) =>
                      adaptiveNavRail(
                        context: context,
                        currentIndex: 2,
                        onTap: (_) {},
                        items: items,
                        extended: value,
                        onToggleExtended: () =>
                            extended.value = !extended.value,
                      ),
                ),
                const Expanded(
                  child: NavRailStage(child: SizedBox.expand(key: contentKey)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 面板外缘到内容区起始边的距离（RTL 下镜像）。
  double gapOf(WidgetTester tester, TextDirection direction) {
    final Rect panelRect = tester.getRect(panel);
    final Rect content = tester.getRect(find.byKey(contentKey));
    return direction == TextDirection.rtl
        ? panelRect.left - content.right
        : content.left - panelRect.right;
  }

  for (final bool glass in <bool>[false, true]) {
    for (final ShellRailStyle style in ShellRailStyle.values) {
      // Apple 设计系统不走重设计侧栏，两种样式结果相同，只测一遍。
      if (glass && style != ShellRailStyle.values.first) continue;
      for (final TextDirection direction in TextDirection.values) {
        for (final bool startExtended in <bool>[true, false]) {
          final String label =
              '${glass ? 'Apple' : 'MD3 ${style.name}'} ${direction.name} '
              '${startExtended ? '收起' : '展开'}';
          testWidgets('$label：过渡每帧面板贴着内容区起始边', (WidgetTester tester) async {
            await tester.binding.setSurfaceSize(surface);
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final ValueNotifier<bool> extended = ValueNotifier<bool>(
              startExtended,
            );
            addTearDown(extended.dispose);
            await tester.pumpWidget(
              harness(
                extended: extended,
                style: style,
                glass: glass,
                direction: direction,
              ),
            );
            await tester.pumpAndSettle();
            expect(panel, findsOneWidget);
            final double restGap = gapOf(tester, direction);
            if (!glass && style == ShellRailStyle.notch) {
              expect(restGap, moreOrLessEquals(0, epsilon: 0.5));
            }
            final double restWidth = tester.getSize(panel).width;

            extended.value = !startExtended;
            final Set<int> widths = <int>{};
            for (int i = 0; i < 60; i++) {
              await tester.pump(const Duration(milliseconds: 16));
              widths.add(tester.getSize(panel).width.round());
              expect(
                gapOf(tester, direction),
                moreOrLessEquals(restGap, epsilon: 0.5),
                reason: '第 $i 帧面板与内容区之间的缝偏离静止值 $restGap',
              );
            }
            await tester.pumpAndSettle();
            expect(
              gapOf(tester, direction),
              moreOrLessEquals(restGap, epsilon: 0.5),
            );
            if (!glass) {
              // MD3：弹簧确实在逐帧动，面板宽不是一步跳到终值。
              expect(widths.length, greaterThan(5));
              expect(tester.getSize(panel).width, isNot(restWidth));
            }
          });
        }
      }
    }
  }
}
