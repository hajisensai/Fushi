/// 加油站停车场（folia `scenes/station/`）：默认镜头从正前偏右 25° 看；高的罩棚和货车放
/// 后排，前排只有车和细高的立牌。アドトラック货厢侧面是逐字点亮当前行的 LED 屏；出租车
/// 顶灯滚下一句（另一辆滚曲名与歌手）；罩棚店招写歌手；价格立柱的七段数码管是播放进度 /
/// 总时长 / 第几句；汽车旅馆立牌写曲名，副歌时 NO VACANCY 的 NO 亮起来，箭头上一圈走马
/// 灯泡。车位停什么、车色、谁打双闪按 seed。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_props.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_render.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_screen.dart';

// 货车。
const double _truckRear = -5.85;
const double _truckFront = 1.1;
const double _truckZ0 = -5.7;
const double _truckZ1 = -3.6;
const double _truckDeck = 1.0;
const double _boxTop = 3.4;
const double _boxFront = -0.7;
const double _cabBack = -0.55;
const double _cabTop = 2.75;

/// 货厢侧面屏幕的尺寸（米）。
const double machiStationScreenW = _boxFront - _truckRear - 0.36;
const double machiStationScreenH = _boxTop - 0.16 - (_truckDeck + 0.22);

// 罩棚。
const double _canX0 = 1.4;
const double _canX1 = 5.9;
const double _canZ0 = -5.6;
const double _canZ1 = -1.4;
const double _canUnder = 3.85;
const double _canTop = 4.3;

String _mmss(double seconds) {
  final int s = seconds.isFinite ? seconds.floor().clamp(0, 5999) : 0;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

MachiSceneModel buildMachiStation(
  MachiPalette p,
  int seed,
  MachiLyricScreen screen,
) {
  final List<MachiItem> items = <MachiItem>[];
  final List<MachiLamp> lamps = <MachiLamp>[];
  final Color lotColor = machiScale(p.asphalt, 0.9);

  // —— 地面 ——————————————————————————————————————————————
  void roadPaint(Canvas c, Size s, MachiFrame f) {
    final Paint w = Paint()
      ..color = f.lighting
          .shade(MachiPalette.roadPaint, MachiV3.up)
          .withValues(alpha: 0.85);
    const double mid = (4.17 - 2.35) * machiLocalPxPerMeter;
    for (double x = 0; x < s.width; x += 120) {
      c.drawRect(Rect.fromLTWH(x, mid - 5, 60, 10), w);
    }
    c.drawRect(Rect.fromLTWH(0, 20, s.width, 6), w);
    c.drawRect(Rect.fromLTWH(0, s.height - 26, s.width, 6), w);
    if (f.env.wetness > 0.05) {
      final Paint puddle = Paint()
        ..color = machiMix(
          p.skyBottom,
          p.skyBottomDay,
          f.env.daylight,
        ).withValues(alpha: 0.22 * f.env.wetness);
      for (int i = 0; i < 4; i++) {
        c.drawOval(
          Rect.fromCenter(
            center: Offset(
              machiHash01(seed, i, 0x95) * s.width,
              machiHash01(seed, i, 0x96) * s.height,
            ),
            width: 140,
            height: 60,
          ),
          puddle,
        );
      }
    }
  }

  void lotPaint(Canvas c, Size s, MachiFrame f) {
    final Paint w = Paint()
      ..color = f.lighting
          .shade(MachiPalette.roadPaint, MachiV3.up)
          .withValues(alpha: 0.7)
      ..strokeWidth = 5;
    // 车位线（前排三格）。
    for (final double x in <double>[-5.7, -3.8, -1.9, 0.0]) {
      final double lx = (x + 6) * machiLocalPxPerMeter;
      c.drawLine(
        Offset(lx, (-2.2 + 6) * machiLocalPxPerMeter),
        Offset(lx, (1.6 + 6) * machiLocalPxPerMeter),
        w,
      );
    }
  }

  final List<MachiGround> ground = <MachiGround>[
    machiGroundRect(-6, 2.35, 6, 6, 0, p.asphalt, decal: roadPaint),
    machiGroundRect(-6, -6, 6, 2.35, 0.02, lotColor, decal: lotPaint),
    MachiGround(
      MachiFaceFrame(
        const MachiV3(1.2, 0.1, 0.4),
        const MachiV3(1, 0, 0),
        MachiV3.down,
        4.8,
        0.08,
      ),
      machiScale(p.concrete, 0.8),
      wet: false,
    ),
    machiGroundRect(1.2, -6, 6, 0.4, 0.1, p.concrete),
  ];
  // 路缘（两处出入口断开）。
  for (final (double a, double b) in <(double, double)>[
    (-6, -1.2),
    (0.8, 1.8),
    (3.6, 6),
  ]) {
    items.add(
      machiBox(a, 0, 2.27, b, 0.16, 2.43, MachiPalette.curb, outline: false),
    );
  }

  // —— 罩棚与加油岛 ————————————————————————————————————————
  void canopyFront(Canvas c, Size s, MachiFrame f) {
    final double lift = f.beat.lightbox(0);
    c.drawRect(
      Offset.zero & s,
      Paint()..color = f.emissive(machiHex(0xf4f1ea), lift),
    );
    machiPaintBrandStripes(
      c,
      Rect.fromLTWH(0, s.height - 12, s.width, 12),
      f,
      k: lift,
    );
    machiPaintLogo(
      c,
      Rect.fromLTWH(14, 4, s.height - 18, s.height - 18),
      f,
      f.artist,
    );
    f.text.drawFitted(
      c,
      f.artist.isEmpty ? 'MACHI OIL' : f.artist,
      Rect.fromLTWH(s.height, 3, s.width - s.height - 14, s.height - 16),
      f.emissive(p.brand[0], lift),
      fill: 0.78,
      align: Alignment.centerLeft,
    );
  }

  void canopySide(Canvas c, Size s, MachiFrame f) {
    final double lift = f.beat.lightbox(1);
    c.drawRect(
      Offset.zero & s,
      Paint()..color = f.emissive(machiHex(0xf4f1ea), lift),
    );
    machiPaintBrandStripes(
      c,
      Rect.fromLTWH(0, s.height - 12, s.width, 12),
      f,
      k: lift,
    );
  }

  items.add(
    machiBox(
      _canX0,
      _canUnder,
      _canZ0,
      _canX1,
      _canTop,
      _canZ1,
      machiHex(0xeef0f2),
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: canopyFront,
        MachiSide.right: canopySide,
      },
      emissive: const <MachiSide>{MachiSide.front, MachiSide.right},
    ),
  );
  for (final (double x, double z) in <(double, double)>[
    (2.05, -2.1),
    (5.25, -2.1),
    (2.05, -4.9),
    (5.25, -4.9),
  ]) {
    items.add(machiPost(x, z, 0.1, _canUnder, 0.26, machiHex(0xd9dde3)));
  }
  for (final double z in <double>[-4.35, -2.75]) {
    items.add(
      machiBox(2.45, 0.1, z - 0.25, 4.85, 0.26, z + 0.25, machiHex(0xb9bfc8)),
    );
    for (final double x in <double>[3.05, 4.25]) {
      items.add(
        machiBox(
          x - 0.26,
          0.26,
          z - 0.18,
          x + 0.26,
          1.6,
          z + 0.18,
          p.brand[0],
          decals: <MachiSide, MachiDecal>{
            MachiSide.front: (Canvas c, Size s, MachiFrame f) {
              c.drawRect(
                Rect.fromLTWH(6, 14, s.width - 12, 30),
                Paint()..color = const Color(0xFF101318),
              );
              f.text.drawFitted(
                c,
                '${(150 + (seed % 30))}',
                Rect.fromLTWH(8, 16, s.width - 16, 26),
                f.emissive(MachiPalette.caution),
                fill: 0.8,
              );
              c.drawRect(
                Rect.fromLTWH(6, 56, s.width - 12, 10),
                Paint()..color = f.emissive(p.brand[1]),
              );
            },
          },
        ),
      );
    }
  }
  // 罩棚下的筒灯。
  for (final double x in <double>[2.6, 4.7]) {
    for (final double z in <double>[-4.5, -2.5]) {
      lamps.add(
        MachiLamp(
          position: MachiV3(x, _canUnder - 0.05, z),
          color: machiHex(0xf4f7ff),
          radius: 0.45,
          pool: 1.6,
          poolAt: MachiV3(x, 0.11, z + 0.2),
        ),
      );
    }
  }
  // 充气机、垃圾箱、轮胎堆。
  items.add(machiBox(1.42, 0.1, -0.9, 1.78, 1.1, -0.6, MachiPalette.stopRed));
  for (final double z in <double>[-1.2, -1.57]) {
    items.add(
      machiBox(1.43, 0.1, z - 0.17, 1.77, 0.82, z + 0.17, machiHex(0x4f7fb8)),
    );
  }
  for (int i = 0; i < 3; i++) {
    items.add(
      machiBox(
        5.25,
        0.1 + i * 0.22,
        -3.25,
        5.95,
        0.3 + i * 0.22,
        -2.55,
        MachiPalette.rubber,
      ),
    );
  }

  // —— 货车（アドトラック）——————————————————————————————————
  void boxSide(Canvas c, Size s, MachiFrame f) {
    const double k = machiLocalPxPerMeter;
    final Rect r = Rect.fromLTWH(
      0.18 * k,
      0.16 * k,
      machiStationScreenW * k,
      machiStationScreenH * k,
    );
    c.drawRect(r.inflate(6), Paint()..color = const Color(0xFF15181F));
    c.save();
    c.clipRect(r);
    c.translate(r.left, r.top);
    screen.paint(c, r.size, f);
    c.restore();
  }

  items.add(
    machiBox(
      _truckRear,
      0.45,
      _truckZ0 + 0.2,
      _truckFront - 0.2,
      _truckDeck,
      _truckZ1 - 0.2,
      MachiPalette.darkMetal,
    ),
  );
  items.add(
    machiBox(
      _truckRear,
      _truckDeck,
      _truckZ0,
      _boxFront,
      _boxTop,
      _truckZ1,
      machiHex(0xe8e8ea),
      decals: <MachiSide, MachiDecal>{MachiSide.front: boxSide},
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  void cabWindow(Canvas c, Size s, MachiFrame f) {
    c.drawRect(
      Rect.fromLTWH(
        s.width * 0.1,
        s.height * 0.08,
        s.width * 0.8,
        s.height * 0.36,
      ),
      Paint()
        ..color = f.lighting.shade(
          machiMix(MachiPalette.glass, machiHex(0x1d2430), 0.5),
          const MachiV3(0, 0.3, 1),
        ),
    );
  }

  items.add(
    machiBox(
      _cabBack,
      0.45,
      _truckZ0 + 0.05,
      _truckFront,
      _cabTop,
      _truckZ1 - 0.05,
      p.brand[0],
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: cabWindow,
        MachiSide.right: cabWindow,
      },
    ),
  );
  for (final double x in <double>[-5.0, -3.6, 0.5]) {
    for (final double z in <double>[_truckZ1 - 0.36, _truckZ0 + 0.36]) {
      items.add(
        machiBox(
          x - 0.36,
          0,
          z - 0.14,
          x + 0.36,
          0.72,
          z + 0.14,
          MachiPalette.rubber,
          outline: false,
        ),
      );
    }
  }

  // —— 前排车位 ————————————————————————————————————————————
  void andon(Canvas c, Size s, MachiFrame f, {required bool next}) {
    machiPaintTicker(
      c,
      s,
      f,
      led: next ? p.led : MachiPalette.caution,
      text: next
          ? f.tickerText
          : '♪ ${f.title}${f.artist.isEmpty ? '' : ' — ${f.artist}'}   ◆   ',
      speed: 1.4,
    );
  }

  const List<double> stalls = <double>[-4.75, -2.85, -0.95];
  final int taxiStall = machiHashString('taxi:$seed') % 3;
  for (int i = 0; i < stalls.length; i++) {
    final double roll = machiHash01(seed, i, 0xc1);
    final bool taxi = i == taxiStall || roll < 0.2;
    if (!taxi && roll > 0.85) continue; // 空车位
    final bool kei = !taxi && roll > 0.65;
    final Color color = taxi
        ? (i == taxiStall ? machiHex(0xf2c14e) : machiHex(0x2b5f3a))
        : <Color>[
            machiHex(0xe8e8ea),
            machiHex(0x2b2f36),
            machiHex(0x8a1f22),
            machiHex(0x4f7fb8),
          ][(roll * 40).floor() % 4];
    final bool next = i == taxiStall;
    items.add(
      machiCar(
        x: stalls[i],
        z: -0.3,
        alongX: false,
        forward: 1,
        body: color,
        taxi: taxi,
        kei: kei,
        hazard: machiHash01(seed, i, 0xc2) < 0.3,
        roofSign: (Canvas c, Size s, MachiFrame f) =>
            andon(c, s, f, next: next),
      ),
    );
  }
  // 加油区的车、轻卡。
  items.add(
    machiCar(
      x: 3.65,
      z: -0.95,
      alongX: true,
      forward: 1,
      body: p.products[(seed + 3) % p.products.length],
    ),
  );
  items.add(
    machiCar(
      x: 3.1,
      z: 1.1,
      alongX: true,
      forward: -1,
      body: machiHex(0xe8e8ea),
      kei: true,
      length: 3.0,
      height: 1.3,
    ),
  );

  // —— 价格立柱（七段数码管）————————————————————————————————
  void pylonFace(Canvas c, Size s, MachiFrame f) {
    final double lift = f.beat.lightbox(2);
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF15181F));
    machiPaintBrandStripes(
      c,
      Rect.fromLTWH(0, 0, s.width, s.height * 0.16),
      f,
      k: lift,
    );
    final Color seg = f.emissive(MachiPalette.caution, 1.1);
    final double rowH = s.height * 0.22;
    final List<(String, String)> rows = <(String, String)>[
      ('▶', _mmss(f.positionSec)),
      ('◼', _mmss(f.durationSec)),
      ('#', '${f.lineNumber}/${f.lineCount}'),
    ];
    for (int i = 0; i < rows.length; i++) {
      final Rect r = Rect.fromLTWH(
        s.width * 0.06,
        s.height * 0.2 + i * (rowH + 6),
        s.width * 0.88,
        rowH,
      );
      c.drawRect(
        r,
        Paint()
          ..color = f.lighting.shade(
            machiHex(0xf4f1ea),
            const MachiV3(0, 0, 1),
          ),
      );
      f.text.drawFitted(
        c,
        rows[i].$1,
        Rect.fromLTWH(r.left + 4, r.top, r.width * 0.2, r.height),
        f.lighting.shade(p.brand[0], const MachiV3(0, 0, 1)),
        fill: 0.7,
      );
      final Rect digits = Rect.fromLTWH(
        r.left + r.width * 0.26,
        r.top + 4,
        r.width * 0.7,
        r.height - 8,
      );
      c.drawRect(digits, Paint()..color = const Color(0xFF0B0D12));
      machiPaintSevenSeg(c, digits.deflate(3), rows[i].$2, seg, f);
    }
  }

  items.add(machiPost(4.95, 1.75, 0.02, 2.1, 0.12, MachiPalette.pole));
  items.add(machiPost(5.75, 1.75, 0.02, 2.1, 0.12, MachiPalette.pole));
  items.add(
    machiBox(
      4.85,
      2.0,
      1.6,
      5.85,
      4.1,
      1.9,
      machiHex(0x15181f),
      decals: <MachiSide, MachiDecal>{MachiSide.front: pylonFace},
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  lamps.add(
    MachiLamp(
      position: const MachiV3(5.35, 3.0, 2.0),
      color: MachiPalette.caution,
      radius: 0.9,
      intensity: (MachiFrame f) => 0.35,
    ),
  );

  // —— 汽车旅馆高立牌 ——————————————————————————————————————
  const double mx = -5.25;
  const double mz = 1.85;
  items.add(machiPost(mx, mz, 0.02, 6.4, 0.2, MachiPalette.pole));
  void motelNeon(Canvas c, Size s, MachiFrame f) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF1A1420));
    machiPaintNeonText(
      c,
      'MOTEL',
      Rect.fromLTWH(
        s.width * 0.1,
        s.height * 0.05,
        s.width * 0.8,
        s.height * 0.9,
      ),
      machiHex(0xff4f7a),
      f,
      intensity: f.flicker * f.beat.group(0) * (0.5 + 0.5 * f.artificial),
      vertical: true,
    );
  }

  items.add(
    machiBox(
      mx - 0.5,
      4.2,
      mz - 0.1,
      mx + 0.4,
      6.3,
      mz + 0.1,
      machiHex(0x1a1420),
      decals: <MachiSide, MachiDecal>{MachiSide.front: motelNeon},
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  void titleBoard(Canvas c, Size s, MachiFrame f) {
    c.drawRect(
      Offset.zero & s,
      Paint()..color = f.emissive(machiHex(0xf4f1ea), f.beat.lightbox(1)),
    );
    f.text.drawFitted(
      c,
      f.title.isEmpty ? 'MACHI INN' : f.title,
      Offset.zero & s,
      f.emissive(p.brand[2], f.beat.lightbox(1)),
      fill: 0.6,
    );
  }

  items.add(
    machiBox(
      mx - 0.3,
      3.3,
      mz - 0.08,
      mx + 1.9,
      4.0,
      mz + 0.08,
      machiHex(0xf4f1ea),
      decals: <MachiSide, MachiDecal>{MachiSide.front: titleBoard},
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  void vacancy(Canvas c, Size s, MachiFrame f) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF14171C));
    machiPaintNeonText(
      c,
      'NO',
      Rect.fromLTWH(4, 4, s.width * 0.24, s.height - 8),
      machiHex(0xff4f7a),
      f,
      intensity: 0.15 + 0.95 * f.chorus,
    );
    machiPaintNeonText(
      c,
      'VACANCY',
      Rect.fromLTWH(s.width * 0.3, 4, s.width * 0.66, s.height - 8),
      machiHex(0x57ff9a),
      f,
      intensity: f.beat.group(1) * (0.5 + 0.5 * f.artificial),
    );
  }

  items.add(
    machiBox(
      mx - 0.3,
      2.6,
      mz - 0.08,
      mx + 1.6,
      3.15,
      mz + 0.08,
      machiHex(0x14171c),
      decals: <MachiSide, MachiDecal>{MachiSide.front: vacancy},
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  // 箭头与一圈走马灯泡。
  items.add(
    MachiCustom(const MachiV3(mx + 0.9, 5.0, mz + 0.12), (MachiRenderer r) {
      final MachiFrame f = r.frame;
      r.canvas.save();
      r.canvas.transform(
        r.camera.planeMatrix(
          const MachiV3(mx + 0.45, 5.6, mz + 0.12),
          const MachiV3(1, 0, 0),
          MachiV3.down,
        ),
      );
      final Path arrow = Path()
        ..moveTo(0, 0)
        ..lineTo(120, 0)
        ..lineTo(120, -18)
        ..lineTo(165, 22)
        ..lineTo(120, 62)
        ..lineTo(120, 44)
        ..lineTo(0, 44)
        ..close();
      r.canvas.drawPath(
        arrow,
        Paint()
          ..color = f.lighting.shade(
            machiHex(0xd8262c),
            const MachiV3(0, 0, 1),
          ),
      );
      final List<Offset> bulbs = <Offset>[
        for (double x = 6; x <= 114; x += 12) Offset(x, 6),
        const Offset(126, -8),
        const Offset(144, 8),
        const Offset(156, 22),
        const Offset(144, 36),
        const Offset(126, 52),
        for (double x = 114; x >= 6; x -= 12) Offset(x, 38),
      ];
      final int chase = f.motion ? (f.ambient * 8).floor() : 0;
      for (int i = 0; i < bulbs.length; i++) {
        final bool on = (i + chase) % 3 == 0;
        r.canvas.drawCircle(
          bulbs[i],
          3.5,
          Paint()
            ..color = on
                ? f.emissive(machiHex(0xffe9a8), 1.2)
                : machiHex(0x5a4a30),
        );
      }
      r.canvas.restore();
    }),
  );
  lamps.add(
    MachiLamp(
      position: const MachiV3(mx, 5.2, mz + 0.3),
      color: machiHex(0xff4f7a),
      radius: 1.2,
      intensity: (MachiFrame f) => 0.45 * f.flicker * f.beat.group(0),
    ),
  );

  // —— 场地灯 ——————————————————————————————————————————————
  final (List<MachiItem> lampItems, MachiLamp lotLamp) = machiStreetLamp(
    x: 0.9,
    z: 1.85,
    height: 5.0,
    armX: 0,
    armZ: -1.2,
  );
  items.addAll(lampItems);
  lamps.add(lotLamp);

  const List<MachiLane> lanes = <MachiLane>[
    MachiLane(-8, 3.36, 8, 3.36),
    MachiLane(8, 4.99, -8, 4.99),
  ];
  final List<Color> carColors = <Color>[
    machiHex(0xe8e8ea),
    machiHex(0x2b2f36),
    machiHex(0xc7302b),
    machiHex(0x4f7fb8),
    machiHex(0x9aa0ab),
  ];
  const MachiV3 focus = MachiV3(
    (_boxFront + _truckRear) / 2,
    (_truckDeck + _boxTop) / 2,
    _truckZ1,
  );
  return MachiSceneModel(
    id: MachiSceneId.station,
    screenFace: const <MachiV3>[
      MachiV3(_truckRear + 0.18, _boxTop - 0.16, _truckZ1),
      MachiV3(
        _truckRear + 0.18 + machiStationScreenW,
        _boxTop - 0.16,
        _truckZ1,
      ),
      MachiV3(
        _truckRear + 0.18 + machiStationScreenW,
        _truckDeck + 0.22,
        _truckZ1,
      ),
      MachiV3(_truckRear + 0.18, _truckDeck + 0.22, _truckZ1),
    ],
    base: machiPlinth(),
    ground: ground,
    items: items,
    lamps: lamps,
    reflectors: <MachiReflector>[
      MachiReflector(
        center: focus,
        width: machiStationScreenW * 0.8,
        height: machiStationScreenH,
        color: (MachiFrame f) => f.palette.boardLit,
      ),
      MachiReflector(
        center: const MachiV3(3.6, 4.0, -1.4),
        width: 4.0,
        height: 0.4,
        color: (MachiFrame f) => f.palette.brand[0],
      ),
    ],
    framing: <MachiV3>[
      for (final double x in <double>[-6, 6])
        for (final double z in <double>[-6, 6]) ...<MachiV3>[
          MachiV3(x, -0.6, z),
          MachiV3(x, 0, z),
        ],
      const MachiV3(mx, 6.4, mz),
      const MachiV3(_truckRear, _boxTop, _truckZ0),
      const MachiV3(_canX1, _canTop, _canZ0),
    ],
    home: const MachiHomeView(
      azimuth: 25 * machiDeg,
      elevation: 30 * machiDeg,
      zoom: 1.48,
    ),
    focus: focus,
    lanes: lanes,
    roofs: <(Rect, double)>[
      (const Rect.fromLTRB(_canX0, _canZ0, _canX1, _canZ1), _canTop),
      (const Rect.fromLTRB(_truckRear, _truckZ0, _boxFront, _truckZ1), _boxTop),
    ],
    dynamicItems: (MachiFrame f) => machiTraffic(f, lanes, carColors),
  );
}

/// 便于单测：数码管上的时间格式。
String machiStationClock(double seconds) => _mmss(math.max(0, seconds));
