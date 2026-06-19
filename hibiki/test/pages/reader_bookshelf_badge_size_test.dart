import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart'
    show kShelfCoverBadgeDimension;
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// 书架书卡封面右上角类型徽章尺寸守卫（TODO-361 / TODO-552）。
///
/// 徽章内在尺寸是 22px（HibikiBadge：icon 14 + padding gap 8）。TODO-361 曾把方框收到
/// 16px + `BoxFit.contain`，把徽章硬缩到 16px，结果「太小看不清」（TODO-552 报回归）。
/// 修复把方框设为徽章内在尺寸 [kShelfCoverBadgeDimension]=22，配合 `BoxFit.contain`
/// 既不放大也不缩小，徽章按 22px 满尺寸（正常大小）渲染。
///
/// 这里用与生产代码同一个常量和同一种 FittedBox 配置渲染徽章，断言**视觉绘制尺寸**
/// （含 FittedBox 的 Transform.scale）确实是 22px，防止常量 / fit 被改回后悄悄缩小。
Size _visualSizeOf(WidgetTester tester, GlobalKey key) {
  final Size layoutSize = tester.getSize(find.byKey(key));
  final RenderBox box = key.currentContext!.findRenderObject()! as RenderBox;
  final Matrix4 transform = box.getTransformTo(null);
  final Offset topLeft = MatrixUtils.transformPoint(transform, Offset.zero);
  final Offset bottomRight = MatrixUtils.transformPoint(
    transform,
    Offset(layoutSize.width, layoutSize.height),
  );
  return Size(
    (bottomRight - topLeft).dx,
    (bottomRight - topLeft).dy,
  );
}

void main() {
  testWidgets(
      'cover badge dimension constant equals the badge intrinsic size (22px)',
      (tester) async {
    // The box equals the badge intrinsic size so BoxFit.contain renders the
    // badge at its full, normal size instead of shrinking it (TODO-552).
    expect(kShelfCoverBadgeDimension, equals(22.0));
  });

  testWidgets('cover type badge paints at its normal intrinsic 22px size',
      (tester) async {
    final GlobalKey badgeKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            // Mirror the production cover-overlay wrapper exactly.
            child: SizedBox.square(
              dimension: kShelfCoverBadgeDimension,
              child: FittedBox(
                fit: BoxFit.contain,
                child: HibikiBadge(
                  key: badgeKey,
                  icon: Icons.headphones_outlined,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // The badge lays out at its intrinsic 22px and FittedBox.contain neither
    // enlarges nor shrinks it, so the visual size stays at the normal 22px.
    expect(tester.getSize(find.byKey(badgeKey)), const Size(22.0, 22.0));
    final Size visual = _visualSizeOf(tester, badgeKey);
    expect(visual.width, moreOrLessEquals(22.0, epsilon: 0.01));
    expect(visual.height, moreOrLessEquals(22.0, epsilon: 0.01));
  });
}
