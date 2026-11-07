import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/series_shelf_card.dart';
import 'package:fushi/src/utils/components/baked_surface.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// BUG-4220（反馈 67oB1YAz76）：书库里多卷合集的扇形卡悬停时动画很卡，单本卡
/// 流畅。
///
/// 根因：扇形后面几本常驻旋转、悬停中的整摞带 3D 倾斜透视，而 [BakedSurface]
/// 此前只在「可 1:1 贴图」时才用纹理——这些面的层里留的是矢量绘制命令（模糊
/// 投影 + 圆角裁切 + 封面图 + 光泽）。层虽然被复用、Dart 侧不再 paint，桌面
/// Impeller 没有 raster cache、每帧整窗重画，GPU 每一帧都要把这 3–4 套命令重新
/// 栅格化一遍。所以这里守的是「每一帧都是贴纹理」，而不是 paint 调用次数（后者
/// 在修复前也不涨，测不出问题）。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget coverBox(String id, Color color) =>
      ColoredBox(key: ValueKey<String>('cover_$id'), color: color);

  Widget fanCard() => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 320,
            child: ShelfCoverMaterialScope(
              material: ShelfCoverMaterial.glossyBook,
              child: SeriesShelfCard(
                name: 'Fan',
                itemCount: 4,
                covers: <Widget>[
                  coverBox('v1', Colors.red),
                  coverBox('v2', Colors.green),
                  coverBox('v3', Colors.blue),
                  coverBox('v4', Colors.orange),
                ],
                slotAspectRatio: 160 / 260,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );

  List<RenderBakedSurface> surfacesOf(WidgetTester tester) => tester
      .renderObjectList<RenderBakedSurface>(find.byType(BakedSurface))
      .toList();

  Future<void> frames(WidgetTester tester, int n) async {
    for (int i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('resting fan: every member surface (rotated ones too) is baked', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(fanCard());
    await frames(tester, 10);
    final List<RenderBakedSurface> surfaces = surfacesOf(tester);
    expect(surfaces, hasLength(4), reason: '后层 3 本 + 最前 1 本');
    final List<int> live = <int>[
      for (int i = 0; i < surfaces.length; i++)
        if (!surfaces[i].debugIsBaked) i,
    ];
    expect(live, isEmpty, reason: '静止时没烘焙的面 $live：页面上任何动效出帧，它们都要整套重新栅格化');
  });

  testWidgets('hover tilt frames draw the whole pile from baked textures', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(fanCard());
    await frames(tester, 10);
    final Offset center = tester.getCenter(find.byType(SeriesShelfCard));
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(center);
    // 抬升 / 投影加深 / 扇形转开 / 扫光全部走完（最长的扫光是 long × 3）。
    await frames(tester, 120);

    final List<RenderBakedSurface> surfaces = surfacesOf(tester);
    expect(surfaces, hasLength(4));
    // 指针在卡上来回移动：3D 倾斜每帧都在变，持续出帧。每一帧、每一本都必须
    // 是贴纹理，而不是把矢量命令再栅格化一遍。
    const int movingFrames = 40;
    final List<int> liveFrames = List<int>.filled(surfaces.length, 0);
    for (int f = 0; f < movingFrames; f++) {
      final double dx = (f % 10 - 5) * 6.0;
      final double dy = (f % 7 - 3) * 8.0;
      await mouse.moveTo(center + Offset(dx, dy));
      await tester.pump(const Duration(milliseconds: 16));
      for (int i = 0; i < surfaces.length; i++) {
        if (!surfaces[i].debugIsBaked) liveFrames[i]++;
      }
    }
    expect(
      liveFrames,
      everyElement(0),
      reason: '倾斜 $movingFrames 帧里各本实时栅格化的帧数 $liveFrames（应全为 0）',
    );
    for (int i = 0; i < surfaces.length; i++) {
      // 纹理分辨率跟得上悬停放大（1.05 + 透视），不是把静止时的纹理放大糊掉。
      expect(
        surfaces[i].debugBakedPixelRatio,
        greaterThanOrEqualTo(tester.view.devicePixelRatio * 1.05),
        reason: '第 $i 本纹理分辨率',
      );
    }
  });
}
