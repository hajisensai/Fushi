import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart'
    show kShelfCoverBadgeDimension;
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// 书架书卡封面右上角类型徽章尺寸守卫（TODO-361）。
///
/// 徽章内在尺寸是 22px（HibikiBadge：icon 14 + padding gap 8）。早期它夹在封面下方
/// footer 里读作小角标；TODO-355 移到封面图后旧的 `gap*5(=40) + BoxFit.scaleDown`
/// 永远不缩小 22px 徽章，于是封面上显得「大了一圈」。修复把方框收到
/// [kShelfCoverBadgeDimension]=16 并改 `BoxFit.contain`，让徽章等比缩到 16px。
///
/// 这里用与生产代码同一个常量和同一种 FittedBox 配置渲染徽章，断言**视觉绘制尺寸**
/// （含 FittedBox 的 Transform.scale）确实是 16px，防止常量 / fit 被改回后悄悄漂大。
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
      'cover badge dimension constant is smaller than the badge intrinsic size',
      (tester) async {
    // If the box were >= 22, BoxFit.contain would never shrink the badge and we
    // would be back to the oversized cover badge.
    expect(kShelfCoverBadgeDimension, equals(16.0));
    expect(kShelfCoverBadgeDimension, lessThan(22.0));
  });

  testWidgets('cover type badge paints at the restored 16px corner size',
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

    // The badge still lays out at its intrinsic 22px, but FittedBox.contain
    // visually scales it down to fill the 16px box.
    expect(tester.getSize(find.byKey(badgeKey)), const Size(22.0, 22.0));
    final Size visual = _visualSizeOf(tester, badgeKey);
    expect(visual.width, moreOrLessEquals(16.0, epsilon: 0.01));
    expect(visual.height, moreOrLessEquals(16.0, epsilon: 0.01));
  });
}
