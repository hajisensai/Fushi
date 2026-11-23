/// 便利店街角（folia `scenes/konbini/`）：前面、右面两条路在前右角相交；便利店占后左象限，
/// 前面和右面前段是落地玻璃（店内货架、天花灯、段落开头开一下的自动门）；店招带绕前面
/// 与右面一圈（前面写曲名当店名，右面是 LED 跑马灯滚下一句）；屋顶上的三面广告塔是逐字
/// 点亮当前行的歌词屏。街边有贩卖机、立柱灯箱、电线杆、路灯、曲面镜、停止牌、自行车、
/// のぼり旗。尺寸按 folia 的 layout.ts（米，原点在底座中心）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_props.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_render.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_screen.dart';

/// 屋顶广告塔一面的尺寸（米）。
const double machiKonbiniScreenW = 5.6;
const double machiKonbiniScreenH = 2.3;

// 店身。
const double _x0 = -5.4;
const double _x1 = 0.8;
const double _z0 = -5.4;
const double _z1 = 0.4;
const double _floor = 0.12;
const double _roof = 3.42;
const double _parapet = 3.62;
const double _glassBottom = 0.24;
const double _glassTop = 2.5;
const double _fasciaY0 = 2.6;
const double _fasciaY1 = 3.28;
const double _doorX0 = -1.3;
const double _doorX1 = 0.5;
const double _rightGlassEnd = -2.6;
const double _frontPillarEnd = -4.6;

// 广告塔。
const double _boardCx = -2.2;
const double _boardCz = -2.65;
const double _boardY0 = 4.0;
const double _boardAz = 45 * machiDeg;

// 路。
const double _roadInner = 2.2;
const double _roadOuter = 5.5;

const List<String> _noboriWords = <String>['おでん', '肉まん', 'からあげ', '新発売', 'コーヒー'];

MachiSceneModel buildMachiKonbini(
  MachiPalette p,
  int seed,
  MachiLyricScreen screen,
) {
  final Color wall = machiHex(0xe9e5dc);
  final Color trim = machiHex(0x3b4250);
  final Color roofColor = machiHex(0x59606b);
  final List<MachiItem> items = <MachiItem>[];
  final List<MachiLamp> lamps = <MachiLamp>[];

  // —— 地面 ——————————————————————————————————————————————
  void roadPaint(Canvas c, Size s, MachiFrame f, {required bool alongX}) {
    final Color paint = f.lighting.shade(MachiPalette.roadPaint, MachiV3.up);
    final Paint dash = Paint()..color = paint.withValues(alpha: 0.85);
    if (alongX) {
      final double mid = s.height / 2;
      for (double x = 0; x < s.width; x += 120) {
        c.drawRect(Rect.fromLTWH(x, mid - 5, 60, 10), dash);
      }
      c.drawRect(Rect.fromLTWH(0, 24, s.width, 6), dash);
      c.drawRect(Rect.fromLTWH(0, s.height - 30, s.width, 6), dash);
    } else {
      final double mid = s.width / 2;
      for (double z = 0; z < s.height; z += 120) {
        c.drawRect(Rect.fromLTWH(mid - 5, z, 10, 60), dash);
      }
      c.drawRect(Rect.fromLTWH(24, 0, 6, s.height), dash);
      c.drawRect(Rect.fromLTWH(s.width - 30, 0, 6, s.height), dash);
    }
    // 水洼：按 seed 放几处，湿的时候映天光。
    final double wet = f.env.wetness;
    if (wet > 0.05) {
      final Paint puddle = Paint()
        ..color = machiMix(
          p.skyBottom,
          p.skyBottomDay,
          f.env.daylight,
        ).withValues(alpha: 0.22 * wet);
      for (int i = 0; i < 4; i++) {
        final double px = machiHash01(seed, i, alongX ? 0x91 : 0x92) * s.width;
        final double pz = machiHash01(seed, i, alongX ? 0x93 : 0x94) * s.height;
        c.drawOval(
          Rect.fromCenter(center: Offset(px, pz), width: 120, height: 60),
          puddle,
        );
      }
    }
  }

  void crosswalk(Canvas c, Size s, MachiFrame f) {
    final Paint w = Paint()
      ..color = f.lighting
          .shade(MachiPalette.roadPaint, MachiV3.up)
          .withValues(alpha: 0.8);
    for (double x = 10; x < s.width - 10; x += 45) {
      c.drawRect(Rect.fromLTWH(x, 10, 24, s.height - 20), w);
    }
  }

  void tiles(Canvas c, Size s, MachiFrame f) {
    final Paint line = Paint()
      ..color = f.lighting.shade(machiScale(p.concrete, 0.82), MachiV3.up)
      ..strokeWidth = 2;
    for (double x = 0; x < s.width; x += 60) {
      c.drawLine(Offset(x, 0), Offset(x, s.height), line);
    }
    for (double z = 0; z < s.height; z += 60) {
      c.drawLine(Offset(0, z), Offset(s.width, z), line);
    }
  }

  final List<MachiGround> ground = <MachiGround>[
    machiGroundRect(
      -6,
      _roadInner,
      6,
      _roadOuter,
      0,
      p.asphalt,
      decal: (Canvas c, Size s, MachiFrame f) =>
          roadPaint(c, s, f, alongX: true),
    ),
    machiGroundRect(
      _roadInner,
      -6,
      _roadOuter,
      _roadInner,
      0,
      p.asphalt,
      decal: (Canvas c, Size s, MachiFrame f) =>
          roadPaint(c, s, f, alongX: false),
    ),
    machiGroundRect(
      -1.0,
      _roadInner + 0.2,
      1.8,
      _roadOuter - 0.2,
      0.005,
      p.asphalt,
      decal: crosswalk,
    ),
    // 路缘的立面。
    MachiGround(
      MachiFaceFrame(
        const MachiV3(-6, _floor, _roadInner),
        const MachiV3(1, 0, 0),
        MachiV3.down,
        6 + _roadInner,
        _floor,
      ),
      MachiPalette.curb,
      wet: false,
    ),
    MachiGround(
      MachiFaceFrame(
        const MachiV3(_roadInner, _floor, _roadInner),
        const MachiV3(0, 0, -1),
        MachiV3.down,
        6 + _roadInner,
        _floor,
      ),
      MachiPalette.curb,
      wet: false,
    ),
    machiGroundRect(
      -6,
      -6,
      _roadInner,
      _roadInner,
      _floor,
      p.concrete,
      decal: tiles,
    ),
    machiGroundRect(-6, _roadOuter, 6, 6, _floor, p.concrete),
    machiGroundRect(_roadOuter, -6, 6, _roadOuter, _floor, p.concrete),
    machiGroundRect(
      -6,
      _roadInner - 0.16,
      _roadInner,
      _roadInner,
      _floor + 0.002,
      MachiPalette.curb,
      wet: false,
    ),
    machiGroundRect(
      _roadInner - 0.16,
      -6,
      _roadInner,
      _roadInner,
      _floor + 0.002,
      MachiPalette.curb,
      wet: false,
    ),
  ];

  // —— 店 ——————————————————————————————————————————————
  /// 玻璃里的店内：天花灯、货架与商品、竖框；[x0]..[x1] 是局部 x（像素），[door] 是门的范围。
  void interior(
    Canvas c,
    double x0,
    double x1,
    double y0,
    double y1,
    MachiFrame f, {
    (double, double)? door,
  }) {
    final Rect glass = Rect.fromLTRB(x0, y0, x1, y1);
    final double night = 1 - f.env.daylight;
    final Color inside = f.emissive(p.interiorLight, 0.85 * f.beat.warm);
    final Color sky = machiMix(p.skyBottom, p.skyBottomDay, f.env.daylight);
    c.drawRect(
      glass,
      Paint()
        ..color = machiMix(
          machiScale(inside, 0.75),
          sky,
          0.35 * f.env.daylight,
        ),
    );
    // 天花灯。
    final Paint ceil = Paint()
      ..color = f.emissive(machiHex(0xffffff), 0.6 + 0.4 * night);
    for (double x = x0 + 30; x < x1 - 30; x += 90) {
      c.drawRect(Rect.fromLTWH(x, y0 + 6, 50, 5), ceil);
    }
    // 货架（三层）与商品。
    final Paint shelf = Paint()
      ..color = machiScale(machiHex(0xd9dde3), 0.55 + 0.35 * night);
    final Paint item = Paint();
    final double h = y1 - y0;
    for (int row = 0; row < 3; row++) {
      final double sy = y0 + h * (0.42 + row * 0.18);
      c.drawRect(Rect.fromLTWH(x0, sy, x1 - x0, 4), shelf);
      for (double x = x0 + 6; x < x1 - 10; x += 13) {
        final int k = ((x * 7 + row * 13).floor() + seed) % p.products.length;
        item.color = machiScale(p.products[k], 0.55 + 0.4 * night);
        c.drawRect(Rect.fromLTWH(x, sy - 16, 9, 15), item);
      }
    }
    // 门：两扇对开，开着时露出更亮的门洞。
    if (door != null) {
      final double open = f.doorOpen;
      final double dw = door.$2 - door.$1;
      final Paint panel = Paint()
        ..color = Color.fromRGBO(255, 255, 255, 0.12)
        ..style = PaintingStyle.fill;
      final Paint frame = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = f.lighting.shade(trim, const MachiV3(0, 0, 1));
      final double half = dw / 2;
      final double slide = half * 0.94 * open;
      final Rect left = Rect.fromLTWH(
        door.$1 - slide,
        y0 + h * 0.02,
        half,
        h * 0.98,
      );
      final Rect right = Rect.fromLTWH(
        door.$1 + half + slide,
        y0 + h * 0.02,
        half,
        h * 0.98,
      );
      if (open > 0.02) {
        c.drawRect(
          Rect.fromLTWH(door.$1 + half - slide, y0, slide * 2, h),
          Paint()..color = f.emissive(p.interiorLight, 1.05),
        );
      }
      c.drawRect(left, panel);
      c.drawRect(right, panel);
      c.drawRect(left, frame);
      c.drawRect(right, frame);
    }
    // 竖框。
    final Paint mullion = Paint()
      ..color = f.lighting.shade(trim, const MachiV3(0, 0, 1))
      ..strokeWidth = 5;
    for (double x = x0; x <= x1 + 1; x += 100) {
      c.drawLine(Offset(x, y0), Offset(x, y1), mullion);
    }
    // 玻璃反光。
    c.drawRect(
      glass,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          glass.topLeft,
          glass.bottomRight,
          <Color>[
            const Color(0x00FFFFFF),
            Color.fromRGBO(255, 255, 255, 0.05 + 0.08 * f.env.daylight),
            const Color(0x00FFFFFF),
          ],
          const <double>[0.3, 0.45, 0.6],
        ),
    );
  }

  /// 店招带：品牌条 + 白底；前面写曲名（店名）带圆章，右面中间是 LED 跑马灯。
  void fascia(Canvas c, Size s, MachiFrame f, {required bool ticker}) {
    const double top = (_roof - _fasciaY1) * machiLocalPxPerMeter;
    const double bottom = (_roof - _fasciaY0) * machiLocalPxPerMeter;
    final Rect band = Rect.fromLTRB(0, top, s.width, bottom);
    final double lift = f.beat.lightbox(0);
    c.drawRect(band, Paint()..color = f.emissive(p.brand[1], lift));
    machiPaintBrandStripes(
      c,
      Rect.fromLTWH(0, bottom - 16, s.width, 16),
      f,
      k: lift,
    );
    if (ticker) {
      final Rect strip = Rect.fromLTRB(
        s.width * 0.08,
        top + 10,
        s.width * 0.92,
        bottom - 22,
      );
      c.save();
      c.translate(strip.left, strip.top);
      machiPaintTicker(c, strip.size, f);
      c.restore();
    } else {
      final Rect logo = Rect.fromLTWH(
        s.width * 0.04 + 80,
        top + 6,
        40,
        bottom - top - 26,
      );
      machiPaintLogo(c, logo, f, f.title);
      f.text.drawFitted(
        c,
        f.title.isEmpty ? 'MACHI MART' : f.title,
        Rect.fromLTRB(logo.right + 14, top + 6, s.width - 30, bottom - 22),
        f.emissive(p.signText, lift),
        fill: 0.72,
        align: Alignment.centerLeft,
      );
    }
  }

  void storeFront(Canvas c, Size s, MachiFrame f) {
    const double k = machiLocalPxPerMeter;
    interior(
      c,
      (_frontPillarEnd - _x0) * k,
      (_x1 - _x0) * k,
      (_roof - _glassTop) * k,
      (_roof - _glassBottom) * k,
      f,
      door: ((_doorX0 - _x0) * k, (_doorX1 - _x0) * k),
    );
    // 窗内霓虹（OPEN），第 1 组。
    machiPaintNeonText(
      c,
      'OPEN',
      Rect.fromLTWH(
        (_frontPillarEnd - _x0) * k + 30,
        (_roof - _glassTop) * k + 40,
        90,
        34,
      ),
      p.neon,
      f,
      intensity: f.flicker * f.beat.group(1) * (0.6 + 0.4 * f.artificial),
    );
    // 玻璃海报：歌手、专辑。
    final Rect poster = Rect.fromLTWH(
      (_frontPillarEnd - _x0) * k + 150,
      (_roof - _glassTop) * k + 30,
      70,
      100,
    );
    c.drawRect(
      poster,
      Paint()..color = f.lighting.shade(p.brand[2], const MachiV3(0, 0, 1)),
    );
    f.text.drawFitted(
      c,
      f.artist,
      poster.deflate(6).topLeft & Size(poster.width - 12, 40),
      f.lighting.shade(machiHex(0xffffff), const MachiV3(0, 0, 1)),
      fill: 0.6,
    );
    f.text.drawFitted(
      c,
      f.album,
      Rect.fromLTWH(poster.left + 6, poster.bottom - 34, poster.width - 12, 26),
      f.lighting.shade(machiHex(0xffffff), const MachiV3(0, 0, 1)),
      fill: 0.6,
    );
    fascia(c, s, f, ticker: false);
  }

  void storeRight(Canvas c, Size s, MachiFrame f) {
    const double k = machiLocalPxPerMeter;
    interior(
      c,
      0,
      (_z1 - _rightGlassEnd) * k,
      (_roof - _glassTop) * k,
      (_roof - _glassBottom) * k,
      f,
    );
    fascia(c, s, f, ticker: true);
  }

  items.add(
    machiBox(
      _x0,
      _floor,
      _z0,
      _x1,
      _roof,
      _z1,
      wall,
      top: roofColor,
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: storeFront,
        MachiSide.right: storeRight,
      },
    ),
  );
  // 女儿墙。
  items.add(
    machiBox(
      _x0 - 0.12,
      _roof,
      _z0 - 0.12,
      _x1 + 0.12,
      _parapet,
      _z1 + 0.12,
      trim,
      top: roofColor,
    ),
  );
  // 屋顶空调。
  for (final (double x, double z) in <(double, double)>[
    (-0.1, -4.75),
    (-4.85, -0.35),
  ]) {
    items.add(
      machiBox(
        x - 0.4,
        _parapet,
        z - 0.3,
        x + 0.4,
        _parapet + 0.55,
        z + 0.3,
        machiHex(0xc8ccd2),
      ),
    );
  }
  // 墙边地上的空调外机。
  for (final double z in <double>[-2.0, -3.1]) {
    items.add(
      machiBox(
        -5.95,
        _floor,
        z - 0.35,
        -5.45,
        _floor + 0.6,
        z + 0.35,
        machiHex(0xc8ccd2),
      ),
    );
  }

  // —— 屋顶三面广告塔 ————————————————————————————————————
  final double faceR = machiKonbiniScreenW / (2 * math.sqrt(3));
  final List<MachiFace> prism = <MachiFace>[];
  List<MachiV3> screenFace = const <MachiV3>[];
  final List<MachiV3> lid = <MachiV3>[];
  for (int k = 0; k < 3; k++) {
    final double a = _boardAz + k * 2 * math.pi / 3;
    final MachiV3 n = machiAzimuthDir(a);
    final MachiV3 u = MachiV3(math.cos(a), 0, -math.sin(a));
    final MachiV3 center =
        MachiV3(_boardCx, _boardY0 + machiKonbiniScreenH / 2, _boardCz) +
        n * faceR;
    final MachiV3 origin =
        center -
        u * (machiKonbiniScreenW / 2) +
        const MachiV3(0, machiKonbiniScreenH / 2, 0);
    if (k == 0) {
      screenFace = MachiFaceFrame(
        origin,
        u,
        MachiV3.down,
        machiKonbiniScreenW,
        machiKonbiniScreenH,
      ).corners;
    }
    prism.add(
      MachiFace.panel(
        MachiFaceFrame(
          origin,
          u,
          MachiV3.down,
          machiKonbiniScreenW,
          machiKonbiniScreenH,
        ),
        p.boardBase,
        emissive: true,
        decal: screen.paint,
      ),
    );
    lid.add(
      MachiV3(_boardCx, _boardY0 + machiKonbiniScreenH, _boardCz) +
          machiAzimuthDir(a + math.pi / 3) * (faceR * 2),
    );
  }
  prism.add(
    MachiFace(corners: lid, normal: MachiV3.up, color: MachiPalette.darkMetal),
  );
  const MachiV3 towerCenter = MachiV3(
    _boardCx,
    _boardY0 + machiKonbiniScreenH / 2,
    _boardCz,
  );
  // 塔脚。
  for (int k = 0; k < 3; k++) {
    final MachiV3 at =
        towerCenter +
        machiAzimuthDir(_boardAz + math.pi / 3 + k * 2 * math.pi / 3) *
            (faceR * 1.4);
    items.add(
      machiPost(
        at.x,
        at.z,
        _parapet - 0.2,
        _boardY0,
        0.16,
        MachiPalette.darkMetal,
      ),
    );
  }
  items.add(MachiSolid(prism, towerCenter));
  // 塔顶的屋顶 logo（朝默认视线）。
  final MachiV3 logoN = machiAzimuthDir(_boardAz);
  final MachiV3 logoU = MachiV3(math.cos(_boardAz), 0, -math.sin(_boardAz));
  final MachiV3 logoOrigin =
      MachiV3(_boardCx, _boardY0 + machiKonbiniScreenH + 0.75, _boardCz) +
      logoN * (faceR * 0.4) -
      logoU * 1.1;
  items.add(
    MachiSolid.panel(
      MachiFace.panel(
        MachiFaceFrame(logoOrigin, logoU, MachiV3.down, 2.2, 0.62),
        p.brand[1],
        emissive: true,
        doubleSided: true,
        decal: (Canvas c, Size s, MachiFrame f) {
          machiPaintBrandStripes(
            c,
            Rect.fromLTWH(0, s.height - 14, s.width, 14),
            f,
            k: f.beat.lightbox(2),
          );
          machiPaintLogo(
            c,
            Rect.fromLTWH(10, 6, s.height - 26, s.height - 26),
            f,
            f.title,
          );
          f.text.drawFitted(
            c,
            '24H',
            Rect.fromLTWH(s.height, 6, s.width - s.height - 10, s.height - 26),
            f.emissive(p.brand[0], f.beat.lightbox(2)),
            fill: 0.8,
          );
        },
      ),
    ),
  );

  // —— 街边 ——————————————————————————————————————————————
  // 贩卖机（靠右墙后段，正面朝 +x）。
  for (final (int i, double z) in <(int, double)>[(0, -3.25), (1, -4.3)]) {
    items.add(
      machiVending(
        x0: _x1 + 0.02,
        z0: z - 0.5,
        x1: _x1 + 0.76,
        z1: z + 0.5,
        height: 1.83,
        facing: MachiSide.right,
        palette: p,
        seed: seed + i,
      ),
    );
    lamps.add(
      MachiLamp(
        position: MachiV3(_x1 + 0.9, 1.3, z),
        color: MachiPalette.vendingLight,
        radius: 0.0,
        pool: 1.1,
        poolAt: MachiV3(_x1 + 1.3, _floor + 0.01, z),
      ),
    );
  }
  // 立柱灯箱。
  items.add(machiPost(1.62, -5.4, _floor, 3.4, 0.2, MachiPalette.pole));
  void pylonFace(Canvas c, Size s, MachiFrame f) {
    machiPaintBrandStripes(
      c,
      Rect.fromLTWH(0, 0, s.width, s.height * 0.22),
      f,
      k: f.beat.lightbox(1),
    );
    machiPaintLogo(
      c,
      Rect.fromCenter(
        center: Offset(s.width / 2, s.height * 0.52),
        width: s.height * 0.34,
        height: s.height * 0.34,
      ),
      f,
      f.title,
    );
    f.text.drawFitted(
      c,
      'OPEN 24H',
      Rect.fromLTWH(6, s.height * 0.74, s.width - 12, s.height * 0.22),
      f.emissive(p.signText, f.beat.lightbox(1)),
      fill: 0.7,
    );
  }

  items.add(
    machiBox(
      1.0,
      3.4,
      -5.6,
      2.24,
      4.6,
      -5.2,
      p.brand[1],
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: pylonFace,
        MachiSide.right: pylonFace,
      },
      emissive: const <MachiSide>{MachiSide.front, MachiSide.right},
    ),
  );
  lamps.add(
    MachiLamp(
      position: const MachiV3(1.62, 4.0, -5.1),
      color: p.brand[0],
      radius: 1.0,
      intensity: (MachiFrame f) => 0.5 * f.beat.lightbox(1),
    ),
  );

  // 电线杆与电线。
  items.add(machiPost(-5.3, 1.96, _floor, 7.6, 0.24, machiHex(0x8f8a80)));
  items.add(
    machiBox(-6.0, 7.0, 1.86, -4.6, 7.12, 2.06, MachiPalette.darkMetal),
  );
  items.add(machiBox(-5.15, 6.0, 1.78, -4.85, 6.6, 2.14, machiHex(0x8a9099)));
  // 路灯。
  final (List<MachiItem> lampItems, MachiLamp streetLamp) = machiStreetLamp(
    x: 5.74,
    z: -1.2,
    height: 5.2,
    armX: -1.3,
    armZ: 0,
  );
  items.addAll(lampItems);
  lamps.add(streetLamp);
  items.add(
    MachiCustom(const MachiV3(0, 6.8, 2.0), (MachiRenderer r) {
      final Color w = r.frame.lighting.shade(MachiPalette.wire, MachiV3.up);
      r.wire(
        const MachiV3(-6.0, 7.05, 1.9),
        const MachiV3(6.0, 6.7, 1.9),
        0.35,
        w,
      );
      r.wire(
        const MachiV3(-4.6, 7.05, 2.0),
        const MachiV3(6.0, 6.9, 2.05),
        0.4,
        w,
      );
      r.wire(
        const MachiV3(-5.3, 6.4, 1.96),
        const MachiV3(-5.4, _parapet, 0.4),
        0.15,
        w,
      );
      r.wire(
        const MachiV3(-4.7, 7.05, 1.96),
        const MachiV3(5.74, 5.25, -1.2),
        0.5,
        w,
      );
    }),
  );
  // 曲面镜。
  items.add(machiPost(-1.2, 5.74, _floor, 2.4, 0.08, MachiPalette.caution));
  items.add(
    MachiCustom(const MachiV3(-1.2, 2.5, 5.74), (MachiRenderer r) {
      const MachiV3 n = MachiV3(0.6, 0, -0.8);
      final MachiV3 u = MachiV3(n.z, 0, -n.x).normalized();
      r.canvas.save();
      r.canvas.transform(
        r.camera.planeMatrix(const MachiV3(-1.2, 2.55, 5.74), u, MachiV3.down),
      );
      r.canvas.drawCircle(
        Offset.zero,
        30,
        Paint()
          ..color = r.frame.lighting.shade(
            MachiPalette.caution,
            n.normalized(),
          ),
      );
      r.canvas.drawCircle(
        Offset.zero,
        24,
        Paint()..color = r.frame.lighting.shade(MachiPalette.glass, MachiV3.up),
      );
      r.canvas.restore();
    }),
  );
  // 停止牌（倒三角「止まれ」）。
  items.add(machiPost(1.95, 5.74, _floor, 2.1, 0.07, MachiPalette.pole));
  items.add(
    MachiCustom(const MachiV3(1.95, 2.2, 5.74), (MachiRenderer r) {
      const MachiV3 n = MachiV3(0, 0, -1);
      r.canvas.save();
      r.canvas.transform(
        r.camera.planeMatrix(
          const MachiV3(1.95, 2.4, 5.7),
          const MachiV3(1, 0, 0),
          MachiV3.down,
        ),
      );
      final Path tri = Path()
        ..moveTo(-34, 0)
        ..lineTo(34, 0)
        ..lineTo(0, 52)
        ..close();
      r.canvas.drawPath(
        tri,
        Paint()
          ..color = r.frame.lighting.shade(
            MachiPalette.stopRed,
            n.dot(r.camera.dir) > 0 ? n : -n,
          ),
      );
      r.frame.text.drawFitted(
        r.canvas,
        '止まれ',
        const Rect.fromLTWH(-24, 4, 48, 18),
        r.frame.lighting.shade(machiHex(0xffffff), MachiV3.up),
        fill: 0.8,
      );
      r.canvas.restore();
    }),
  );
  // 自行车（按 seed 有没有、什么颜色）。
  const List<int> bikeColors = <int>[
    0xc7302b,
    0x2f6fd6,
    0xe7b42e,
    0x6c7384,
    0x1d9a63,
  ];
  for (final (int i, double x, double z) in <(int, double, double)>[
    (0, -4.5, 1.32),
    (1, -2.85, 1.36),
  ]) {
    if (machiHash01(seed, i, 0xb1) < 0.25) continue;
    items.add(
      machiBike(
        x,
        z,
        false,
        machiHex(bikeColors[(machiHash01(seed, i, 0xb2) * 5).floor() % 5]),
      ),
    );
  }
  // 垃圾箱、伞架、门口 A 字立牌。
  items.add(
    machiBox(
      -3.85,
      _floor,
      0.5,
      -3.25,
      _floor + 0.9,
      0.86,
      machiHex(0x6c7380),
      top: machiHex(0x2f6fd6),
    ),
  );
  items.add(
    machiBox(
      -1.8,
      _floor,
      0.55,
      -1.44,
      _floor + 0.55,
      0.82,
      MachiPalette.darkMetal,
    ),
  );
  items.add(
    MachiCustom(const MachiV3(-1.62, 0.9, 0.68), (MachiRenderer r) {
      final double rain = r.frame.env.rain;
      final int n = rain > 0.3 ? 4 : 2;
      for (int i = 0; i < n; i++) {
        final double dx = -0.12 + i * 0.08;
        r.line(
          MachiV3(-1.62 + dx, 0.6, 0.68),
          MachiV3(-1.62 + dx * 1.6, 1.05, 0.68 + dx),
          r.frame.lighting.shade(
            p.products[(i + seed) % p.products.length],
            MachiV3.up,
          ),
          0.05,
        );
      }
    }),
  );
  items.add(
    machiBox(
      0.7,
      _floor,
      1.08,
      1.2,
      _floor + 0.85,
      1.22,
      machiHex(0x2b2f36),
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: (Canvas c, Size s, MachiFrame f) {
          c.drawRect(
            Rect.fromLTWH(4, 4, s.width - 8, s.height - 8),
            Paint()
              ..color = f.lighting.shade(
                machiHex(0xf4f1ea),
                const MachiV3(0, 0, 1),
              ),
          );
          f.text.drawVertical(
            c,
            f.album.isEmpty ? '本日' : f.album,
            Rect.fromLTWH(8, 8, s.width - 16, s.height - 16),
            f.lighting.shade(p.brand[0], const MachiV3(0, 0, 1)),
          );
        },
      },
    ),
  );
  // のぼり旗。
  for (int i = 0; i < 3; i++) {
    items.add(
      machiNobori(
        x: 1.4,
        z: 0.1 - i * 0.95,
        facing: const MachiV3(1, 0, 0),
        text: _noboriWords[(i + seed) % _noboriWords.length],
        color: i.isEven ? p.brand[0] : p.brand[2],
        textColor: machiHex(0xffffff),
        index: i,
      ),
    );
  }

  // —— 灯 ————————————————————————————————————————————————
  lamps.addAll(<MachiLamp>[
    MachiLamp(
      position: const MachiV3(-2.0, 1.4, 0.45),
      color: p.interiorLight,
      radius: 0,
      pool: 2.6,
      poolAt: const MachiV3(-2.0, _floor + 0.01, 1.4),
      intensity: (MachiFrame f) => f.beat.warm,
    ),
    MachiLamp(
      position: const MachiV3(0.85, 1.4, -1.0),
      color: p.interiorLight,
      radius: 0,
      pool: 2.0,
      poolAt: const MachiV3(1.6, _floor + 0.01, -1.0),
      intensity: (MachiFrame f) => f.beat.warm,
    ),
    MachiLamp(
      position:
          MachiV3(_boardCx, _boardY0 - 0.2, _boardCz) +
          machiAzimuthDir(_boardAz) * faceR,
      color: p.boardLit,
      radius: 1.6,
      intensity: (MachiFrame f) => 0.35 * (1 + f.chorus * 0.3),
    ),
  ]);

  const List<MachiLane> lanes = <MachiLane>[
    MachiLane(-8, 3.0, 8, 3.0),
    MachiLane(8, 4.7, -8, 4.7),
    MachiLane(3.0, 8, 3.0, -8),
    MachiLane(4.7, -8, 4.7, 8),
  ];
  final List<Color> carColors = <Color>[
    machiHex(0xe8e8ea),
    machiHex(0x2b2f36),
    machiHex(0xc7302b),
    machiHex(0x4f7fb8),
    machiHex(0x9aa0ab),
  ];

  final MachiV3 focus =
      MachiV3(_boardCx, _boardY0 + machiKonbiniScreenH / 2, _boardCz) +
      machiAzimuthDir(_boardAz) * faceR;
  return MachiSceneModel(
    id: MachiSceneId.konbini,
    screenFace: screenFace,
    base: machiPlinth(),
    ground: ground,
    items: items,
    lamps: lamps,
    reflectors: <MachiReflector>[
      MachiReflector(
        center: focus,
        width: machiKonbiniScreenW * 0.8,
        height: machiKonbiniScreenH,
        color: (MachiFrame f) => f.palette.boardLit,
      ),
      MachiReflector(
        center: const MachiV3(-2.0, 1.3, 0.4),
        width: 4.4,
        height: 2.0,
        color: (MachiFrame f) => f.palette.interiorLight,
      ),
    ],
    framing: <MachiV3>[
      for (final double x in <double>[-6, 6])
        for (final double z in <double>[-6, 6]) ...<MachiV3>[
          MachiV3(x, -0.6, z),
          MachiV3(x, 0, z),
        ],
      MachiV3(_boardCx, _boardY0 + machiKonbiniScreenH + 1.1, _boardCz),
      const MachiV3(-5.3, 7.6, 1.96),
    ],
    home: const MachiHomeView(
      azimuth: 45 * machiDeg,
      elevation: 31 * machiDeg,
      zoom: 1.58,
    ),
    focus: focus,
    lanes: lanes,
    roofs: <(Rect, double)>[
      (Rect.fromLTRB(_x0 - 0.12, _z0 - 0.12, _x1 + 0.12, _z1 + 0.12), _parapet),
    ],
    dynamicItems: (MachiFrame f) => machiTraffic(f, lanes, carColors),
  );
}
