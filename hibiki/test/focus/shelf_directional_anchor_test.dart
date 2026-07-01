import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

// TODO-1062 (BUG shelf-gamepad-nav) A2/B 守卫：书架页头图标行（导入 + 管理来源，右对齐）
// + 标签排序栏（整理 swap_vert 在最右）+ 书籍网格，同在一个 body FocusTraversalGroup。
// 用显式相对矩形（Positioned）复现两根因并验证方向锚点修复：
//  B）从最右「整理」按 Right，纯几何选中完全 clears 组织按钮右边缘的「管理来源」，越过
//     与之 x 部分重叠（未 clears）的「导入」——锚点让它落到导入。
//  A2）从「整理」按 Down 进入网格第一本书——锚点直接落第一本书。
// 锚点是「几何之前的可选短路」：未注册 / 目标不可聚焦时退化为纯几何（本文件先断言无锚点
// 的几何结果 = 越过导入到管理来源，再断言锚点修复 + 目标不可聚焦时退化不变）。
//
// 矩形布局（x 递增向右）：
//   导入 import   : x∈[560,600]  （与 organize x∈[600,640] 相接但不完全 clears）
//   管理 manage   : x∈[660,700]  （完全在 organize 右边缘 640 之后 -> clears）
//   整理 organize : x∈[600,640]  y=[60,100]（标签栏，最右）
//   书 A          : x∈[40,180]   y=[130,330]（网格第一本）
Widget _target(String id, Rect r) => Positioned(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: HibikiFocusTarget(
        id: HibikiFocusId(id),
        child: const SizedBox.expand(),
      ),
    );

Widget _shelf({required GlobalKey rootKey}) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    home: Scaffold(
      body: HibikiFocusRoot(
        child: FocusTraversalGroup(
          child: Stack(
            key: rootKey,
            children: <Widget>[
              // Header icon row (right-aligned): import then manage-source.
              _target(
                  'reader-shelf-import', const Rect.fromLTWH(560, 10, 40, 40)),
              _target(
                  'reader-shelf-manage', const Rect.fromLTWH(660, 10, 40, 40)),
              // Tag bar: organize (swap_vert) at the far right.
              _target('reader-shelf-tagbar-organize',
                  const Rect.fromLTWH(600, 60, 40, 40)),
              // Grid first cards.
              _target('reader-shelf-book-A',
                  const Rect.fromLTWH(40, 130, 140, 200)),
              _target('reader-shelf-book-B',
                  const Rect.fromLTWH(200, 130, 140, 200)),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  Future<HibikiFocusController> pump(
      WidgetTester tester, GlobalKey rootKey) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_shelf(rootKey: rootKey));
    await tester.pump();
    return HibikiFocusRoot.controllerOf(rootKey.currentContext!);
  }

  testWidgets(
      'baseline: Right from organize overshoots past import to manage-source',
      (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    final HibikiFocusController controller = await pump(tester, rootKey);

    expect(
      controller
          .requestById(const HibikiFocusId('reader-shelf-tagbar-organize')),
      isTrue,
    );
    await tester.pump();
    controller.move(HibikiFocusDirection.right);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('reader-shelf-manage'),
        reason: 'pure geometry picks the cleanly-clearing manage-source, '
            'overshooting import (the reported bug B)');
  });

  testWidgets('Right anchor lands on import, never manage-source (B fix)',
      (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    final HibikiFocusController controller = await pump(tester, rootKey);

    controller.registerDirectionalAnchor(
      const HibikiFocusId('reader-shelf-tagbar-organize'),
      HibikiFocusDirection.right,
      const HibikiFocusId('reader-shelf-import'),
    );
    expect(
      controller
          .requestById(const HibikiFocusId('reader-shelf-tagbar-organize')),
      isTrue,
    );
    await tester.pump();
    controller.move(HibikiFocusDirection.right);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('reader-shelf-import'));
    expect(
        controller.activeId, isNot(const HibikiFocusId('reader-shelf-manage')));
  });

  testWidgets('Down anchor from organize enters the grid first card (A2 fix)',
      (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    final HibikiFocusController controller = await pump(tester, rootKey);

    controller.registerDirectionalAnchor(
      const HibikiFocusId('reader-shelf-tagbar-organize'),
      HibikiFocusDirection.down,
      const HibikiFocusId('reader-shelf-book-A'),
    );
    expect(
      controller
          .requestById(const HibikiFocusId('reader-shelf-tagbar-organize')),
      isTrue,
    );
    await tester.pump();
    controller.move(HibikiFocusDirection.down);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('reader-shelf-book-A'),
        reason: 'Down from the tag bar must enter the grid first card');
  });

  testWidgets('anchor with a non-focusable target falls through to geometry',
      (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    final HibikiFocusController controller = await pump(tester, rootKey);

    controller.registerDirectionalAnchor(
      const HibikiFocusId('reader-shelf-tagbar-organize'),
      HibikiFocusDirection.right,
      const HibikiFocusId('does-not-exist'),
    );
    expect(
      controller
          .requestById(const HibikiFocusId('reader-shelf-tagbar-organize')),
      isTrue,
    );
    await tester.pump();
    controller.move(HibikiFocusDirection.right);
    await tester.pump();
    // Identical to the no-anchor baseline: geometry runs unchanged.
    expect(controller.activeId, const HibikiFocusId('reader-shelf-manage'));
  });

  testWidgets('unregisterDirectionalAnchor restores pure geometry',
      (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    final HibikiFocusController controller = await pump(tester, rootKey);

    controller.registerDirectionalAnchor(
      const HibikiFocusId('reader-shelf-tagbar-organize'),
      HibikiFocusDirection.right,
      const HibikiFocusId('reader-shelf-import'),
    );
    controller.unregisterDirectionalAnchor(
      const HibikiFocusId('reader-shelf-tagbar-organize'),
      HibikiFocusDirection.right,
      const HibikiFocusId('reader-shelf-import'),
    );
    expect(
      controller
          .requestById(const HibikiFocusId('reader-shelf-tagbar-organize')),
      isTrue,
    );
    await tester.pump();
    controller.move(HibikiFocusDirection.right);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('reader-shelf-manage'));
  });
}
