import 'dart:math' as math;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-5308 夹具：400×400 页上一列绕 (200,200) 斜 [kBug5308Tilt] 的竖排三字
/// （每字 40×40，沿列方向排开），外加一个正立的横排块。
const double kBug5308Tilt = -20 * math.pi / 180;

MokuroImage bug5308Page() {
  const MokuroOrientedRect column = MokuroOrientedRect(
    center: MokuroPoint(200, 200),
    width: 40,
    height: 120,
    rotation: kBug5308Tilt,
  );
  final List<MangaOcrTextRegion> regions = <MangaOcrTextRegion>[
    for (int i = 0; i < 3; i++)
      () {
        final MokuroPoint c = column.toPage(0, -40.0 + 40.0 * i);
        return MangaOcrTextRegion(
          rectangle: MokuroRect.fromLTWH(c.dx - 20, c.dy - 20, 40, 40),
          utf16Start: i,
          utf16End: i + 1,
          rotation: kBug5308Tilt,
        );
      }(),
  ];
  return MokuroImage(
    url: 'p0.png',
    size: const MokuroSize(400, 400),
    blocks: <MokuroBlock>[
      MokuroBlock(
        rectangle: column.bounds,
        isVertical: true,
        fontSize: 40,
        zIndex: 0,
        lines: const <String>['一二三'],
        regions: regions,
      ),
      const MokuroBlock(
        rectangle: MokuroRect.fromLTWH(20, 340, 120, 40),
        isVertical: false,
        fontSize: 40,
        zIndex: 1,
        lines: <String>['四五六'],
      ),
    ],
  );
}
