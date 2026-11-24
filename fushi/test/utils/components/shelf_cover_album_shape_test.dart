import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// 专辑材质在 Cupertino 下是按尺寸取半径的连续曲率圆角（用户 2026-11-24 拍板：
/// 满尺寸 12，小缩略图等比缩小、下限 4）；M3E 保持 8 圆弧角不变。
void main() {
  Widget harness({
    required bool apple,
    required double extent,
    ShelfCoverDensity density = ShelfCoverDensity.regular,
  }) => MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.standard, glassDesign: apple),
      ],
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox.square(
          dimension: extent,
          child: ShelfCoverMaterialScope(
            material: ShelfCoverMaterial.glossyAlbum,
            child: ShelfCoverSelection(
              selectionMode: false,
              selected: true,
              child: ShelfCoverFrame(
                density: density,
                child: const ColoredBox(color: Color(0xFF336699)),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Finder inSurface(Type type) => find.descendant(
    of: find.byType(ShelfMaterialSurface),
    matching: find.byType(type),
  );

  /// 封面主体裁切（ShelfMaterialSurface 下第一个连续曲率裁切）的实际半径。
  Radius bodyClipRadius(WidgetTester tester) {
    final Finder clip = inSurface(ClipRSuperellipse).first;
    final ClipRSuperellipse widget = tester.widget<ClipRSuperellipse>(clip);
    final RSuperellipse r = widget.clipper!.getClip(tester.getSize(clip));
    return Radius.elliptical(r.tlRadiusX, r.tlRadiusY);
  }

  test('半径曲线：≥160 满 12，以下等比缩小，下限 4', () {
    expect(shelfAppleAlbumRadius(320), kShelfAppleAlbumRadius);
    expect(shelfAppleAlbumRadius(160), 12);
    expect(shelfAppleAlbumRadius(80), closeTo(6, 1e-9));
    expect(shelfAppleAlbumRadius(64), closeTo(4.8, 1e-9));
    expect(shelfAppleAlbumRadius(40), kShelfAppleAlbumMinRadius);
    expect(shelfAppleAlbumRadius(double.infinity), 12);
  });

  testWidgets('Apple 大封面：连续曲率 12，投影 / 光泽 / 扫光 / 高光 / 选中罩同一外形', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(apple: true, extent: 320));

    expect(inSurface(ClipRRect), findsNothing, reason: '不该再有圆弧角裁切');
    expect(bodyClipRadius(tester), const Radius.circular(12));

    const ShelfCoverShape expected = ShelfCoverShape(
      material: ShelfCoverMaterial.glossyAlbum,
      continuous: true,
    );
    // 投影：同一个超椭圆的 ShapeDecoration。
    final AnimatedContainer shadow = tester.widget<AnimatedContainer>(
      inSurface(AnimatedContainer).first,
    );
    final ShapeDecoration deco = shadow.decoration! as ShapeDecoration;
    expect((deco.shape as ShelfCoverBorder).shape, expected);
    expect(deco.shadows, isNotEmpty);

    // 扫光 / 倾斜高光：按外形裁，不再给圆弧角半径。
    final ShelfCoverSheen sheen = tester.widget<ShelfCoverSheen>(
      find.byType(ShelfCoverSheen),
    );
    expect(sheen.clipRadius, isNull);
    expect((sheen.clipShape! as ShelfCoverBorder).shape, expected);
    final FushiTiltGlare glare = tester.widget<FushiTiltGlare>(
      find.byType(FushiTiltGlare),
    );
    expect(glare.clipRadius, isNull);
    expect((glare.clipShape! as ShelfCoverBorder).shape, expected);

    // 外形边框解析出来就是 12 的 RoundedSuperellipseBorder。
    final Path outer = expected.border().getOuterPath(
      const Rect.fromLTWH(0, 0, 320, 320),
    );
    final Path reference = const RoundedSuperellipseBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ).getOuterPath(const Rect.fromLTWH(0, 0, 320, 320));
    expect(outer.getBounds(), reference.getBounds());
    for (final Offset p in const <Offset>[
      Offset(1, 1),
      Offset(2.5, 2.5),
      Offset(4, 1),
      Offset(1, 6),
    ]) {
      expect(outer.contains(p), reference.contains(p), reason: '$p');
    }

    // 选中罩：同一外形的 ShapeDecoration。
    final DecoratedBox overlay = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(ShelfSelectedOverlay),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      ((overlay.decoration as ShapeDecoration).shape as ShelfCoverBorder).shape,
      expected,
    );
  });

  testWidgets('Apple 小缩略图（64）：连续曲率，半径按短边等比缩小到 4.8', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(apple: true, extent: 64, density: ShelfCoverDensity.compact),
    );
    expect(inSurface(ClipRRect), findsNothing);
    final Radius r = bodyClipRadius(tester);
    expect(r.x, closeTo(4.8, 1e-6));
    expect(r.y, closeTo(4.8, 1e-6));
  });

  testWidgets('Apple 40px 缩略图：半径落在下限 4', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(apple: true, extent: 40, density: ShelfCoverDensity.compact),
    );
    expect(bodyClipRadius(tester), const Radius.circular(4));
  });

  testWidgets('M3E：专辑仍是 8 圆弧角，无连续曲率', (WidgetTester tester) async {
    await tester.pumpWidget(harness(apple: false, extent: 320));
    expect(inSurface(ClipRSuperellipse), findsNothing);
    final ClipRRect clip = tester.widget<ClipRRect>(inSurface(ClipRRect).first);
    expect(clip.borderRadius, const BorderRadius.all(Radius.circular(8)));
    final AnimatedContainer shadow = tester.widget<AnimatedContainer>(
      inSurface(AnimatedContainer).first,
    );
    expect(
      (shadow.decoration! as BoxDecoration).borderRadius,
      const BorderRadius.all(Radius.circular(8)),
    );
    expect(
      tester.widget<ShelfCoverSheen>(find.byType(ShelfCoverSheen)).clipShape,
      isNull,
    );
    expect(
      tester.widget<FushiTiltGlare>(find.byType(FushiTiltGlare)).clipRadius,
      const BorderRadius.all(Radius.circular(8)),
    );
    final BuildContext ctx = tester.element(find.byType(ShelfMaterialSurface));
    expect(shelfCoverRadius(ctx), const BorderRadius.all(Radius.circular(8)));
  });
}
