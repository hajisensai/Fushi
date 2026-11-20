import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/baked_surface.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart';

/// 视频「系列」墙滚轮卡顿（应用内反馈 eBQtk9r7Z2）：每拨一档滚轮，根部 140 ms
/// 补间把网格停在亚像素位置，所有已烘焙的封面面（每张叠层合集卡 3 面）被打回
/// 实时绘制并**扔掉纹理**；补间落定后，同一帧末把整屏几十个面一口气
/// `toImageSync` 重烘一遍。而 Windows 一档 = 100 物理 px，落点与原烘焙位置像素
/// 等价，旧纹理本来可以原样贴回。
///
/// 真实 app 里还叠着一层整体「界面大小」缩放（首启按窗口算出的任意小数，反馈现场
/// 同类机器实测 1.0051），一档实际移动 100.51 物理 px，落点永远差个零头——所以滚轮
/// 落点要对齐物理像素格，纹理才贴得回去。
///
/// 守的是：一档滚完，留在视口里的面贴回原纹理、不重新离屏渲染；只有新滚进来的
/// 面才烘焙。整体缩放 1.0 与非整比例各跑一遍。
void main() {
  const double dpr = 1.75;

  Widget card(int i) => ShelfCoverFrame(
    stackedBehind: ColoredBox(color: Color(0xFF203040 + i * 0x010203)),
    stackedCovers: <Widget>[
      ColoredBox(color: Color(0xFF406080 - i * 0x010101)),
      ColoredBox(color: Color(0xFF805020 + i * 0x000102)),
    ],
    child: ColoredBox(color: Color(0xFF102030 + i * 0x030201)),
  );

  Widget wall(double uiScale) => MaterialApp(
    builder: (BuildContext context, Widget? child) => SmoothWheelScrollScope(
      child: FushiAppUiScale(scale: uiScale, child: child!),
    ),
    home: Scaffold(
      body: ShelfCoverMaterialScope(
        material: ShelfCoverMaterial.glossyPoster,
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid.builder(
                itemCount: 45,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 200 / 360,
                ),
                itemBuilder: (BuildContext context, int i) => Column(
                  children: <Widget>[
                    AspectRatio(aspectRatio: 2 / 3, child: card(i)),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Set<RenderBakedSurface> attached(WidgetTester tester) => tester
      .renderObjectList<RenderBakedSurface>(find.byType(BakedSurface))
      .toSet();

  Future<void> frames(WidgetTester tester, int n) async {
    for (int i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  for (final double uiScale in <double>[1.0, 1.0051]) {
    testWidgets('a wheel notch re-shows existing textures instead of re-baking '
        '(ui scale $uiScale)', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1336 * dpr, 851 * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wall(uiScale));
      await frames(tester, 10);
      final Set<RenderBakedSurface> before = attached(tester);
      expect(before.length, greaterThanOrEqualTo(30), reason: '前提：一屏几十个面');
      expect(
        before.where((RenderBakedSurface s) => !s.debugIsBaked),
        isEmpty,
        reason: '前提：静止时全部烘焙',
      );

      final Offset at = tester.getCenter(find.byType(CustomScrollView));
      for (int notch = 0; notch < 3; notch++) {
        final int bakes = RenderBakedSurface.debugBakeCount;
        final Set<RenderBakedSurface> start = attached(tester);
        // Windows 一档 = 100 物理 px；框架交给滚轮事件的是物理 px ÷ DPR。
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: at,
            scrollDelta: const Offset(0, 100 / dpr),
          ),
        );
        // 补间中途（亚像素位置）：留在视口里的面实时画。
        await frames(tester, 3);
        final Set<RenderBakedSurface> mid = attached(tester);
        expect(
          mid
              .intersection(start)
              .where((RenderBakedSurface s) => s.debugIsBaked),
          isEmpty,
          reason: '第 $notch 档补间中途是亚像素位置，必须实时画',
        );
        // 补间（140 ms）走完再落定两帧。
        await frames(tester, 12);
        final Set<RenderBakedSurface> end = attached(tester);
        final Set<RenderBakedSurface> stayed = end.intersection(start);
        final Set<RenderBakedSurface> entered = end.difference(start);
        expect(stayed.length, greaterThanOrEqualTo(25));
        expect(
          end.where((RenderBakedSurface s) => !s.debugIsBaked),
          isEmpty,
          reason: '第 $notch 档落定后全部回到贴纹理',
        );
        final int rebaked = RenderBakedSurface.debugBakeCount - bakes;
        expect(
          rebaked,
          lessThanOrEqualTo(entered.length),
          reason:
              '第 $notch 档：烘焙了 $rebaked 次，新滚进来的面只有 '
              '${entered.length} 个（留在视口里的 ${stayed.length} 个面应贴回原纹理）',
        );
      }
    });
  }
}
