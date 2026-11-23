/// 城寨酒吧（folia `scenes/kowloon/`）：左边一排、后排一排高低错落的窄楼（L 形），前右是
/// 一条湿巷子；后排正中一楼是酒吧（玻璃门面、吧台下一道霓虹、背光酒架），楼面上挂着逐字
/// 点亮当前行的歌词大屏，屏幕下沿的 LED 跑马灯滚译文 / 曲名；门头霓虹写曲名；左边楼面
/// 伸出一串霓虹招牌（一块竖灯箱写歌手，其余按 seed 挑店名），楼顶「九龍城寨」；巷子里一台
/// 全息投影放下一句；铁窗、冷气机、晾衫竹、水箱、天线、电线、大排档、贩卖机。
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

/// 歌词大屏的尺寸（米）。
const double machiKowloonScreenW = 4.2;
const double machiKowloonScreenH = 1.8;

class _Block {
  const _Block(
    this.name,
    this.x0,
    this.x1,
    this.z0,
    this.z1,
    this.height,
    this.wall,
  );

  final String name;
  final double x0;
  final double x1;
  final double z0;
  final double z1;
  final double height;
  final int wall;
}

const List<_Block> _blocks = <_Block>[
  _Block('L0', -6, -3.0, -6, -1.8, 6.9, 0),
  _Block('L1', -6, -3.35, -1.8, -0.2, 7.3, 1),
  _Block('L2', -6, -3.6, -0.2, 1.3, 6.6, 3),
  _Block('L3', -6, -3.2, 1.3, 2.9, 6.2, 2),
  _Block('L4', -6, -3.45, 2.9, 4.5, 5.2, 4),
  _Block('L5', -6, -3.75, 4.5, 6, 4.0, 3),
  _Block('B0', -3.0, -1.6, -6, -1.8, 6.4, 4),
  _Block('B0b', -1.6, -0.3, -6, -2.05, 7.0, 2),
  _Block('B2', 4.5, 6, -6, -2.3, 5.4, 1),
];

const List<int> _walls = <int>[
  0x8f8a7c,
  0x7d8a86,
  0x9a8270,
  0x77808f,
  0x8c7f8f,
];

class _Hanging {
  const _Hanging(
    this.alongX,
    this.wall,
    this.tip,
    this.y0,
    this.y1,
    this.at,
    this.vertical,
    this.artist,
  );

  final bool alongX;
  final double wall;
  final double tip;
  final double y0;
  final double y1;
  final double at;
  final bool vertical;
  final bool artist;
}

const List<_Hanging> _hanging = <_Hanging>[
  _Hanging(true, -3.45, -2.65, 2.95, 4.75, 3.65, true, true),
  _Hanging(true, -3.6, -1.35, 5.15, 5.95, 0.55, false, false),
  _Hanging(true, -3.35, -2.67, 3.3, 5.5, -0.85, true, false),
  _Hanging(true, -3.2, -1.45, 3.45, 4.2, 2.25, false, false),
  _Hanging(true, -3.2, -1.95, 4.45, 5.05, 1.5, false, false),
  _Hanging(true, -3.75, -3.1, 2.6, 3.75, 5.25, true, false),
  _Hanging(false, -2.05, -1.3, 3.4, 5.7, -0.72, true, false),
  _Hanging(false, -1.8, -1.25, 4.0, 5.5, -2.2, true, false),
];

const List<String> _verticalShops = <String>[
  '義體診所',
  '夜總會',
  '麻雀館',
  '跌打',
  '大押',
  '旅館',
  '牙科',
  '電腦維修',
  '髮廊',
  '找換店',
  '義肢',
  '桑拿',
];
const List<String> _horizontalShops = <String>[
  '冰室',
  '魚蛋粉',
  '卡拉OK',
  '當舖',
  '網吧',
  '雀館',
  '燒臘',
  '涼茶',
  '電子煙',
  '記憶交易',
];
const List<int> _neonColors = <int>[
  0xff4fb0,
  0x3fe8ff,
  0xffb547,
  0x57ff9a,
  0xff5a4a,
  0xb38bff,
];
const List<List<int>> _lightboxColors = <List<int>>[
  <int>[0xf4efe2, 0xc8282c],
  <int>[0xffd23f, 0x1c1c1c],
  <int>[0xd8262c, 0xfff4d6],
  <int>[0x1f6fd1, 0xffffff],
  <int>[0x18a058, 0xffffff],
];

MachiSceneModel buildMachiKowloon(
  MachiPalette p,
  int seed,
  MachiLyricScreen screen,
) {
  final List<MachiItem> items = <MachiItem>[];
  final List<MachiLamp> lamps = <MachiLamp>[];

  // —— 地面：湿巷子、明渠 ——————————————————————————————————
  void alley(Canvas c, Size s, MachiFrame f) {
    final Paint crack = Paint()
      ..color = f.lighting.shade(machiScale(p.asphalt, 0.7), MachiV3.up)
      ..strokeWidth = 3;
    for (int i = 0; i < 14; i++) {
      final double x = machiHash01(seed, i, 0xa1) * s.width;
      final double z = machiHash01(seed, i, 0xa2) * s.height;
      c.drawLine(
        Offset(x, z),
        Offset(x + 40 - machiHash01(seed, i, 0xa3) * 80, z + 30),
        crack,
      );
    }
    final double wet = 0.25 + 0.75 * f.env.wetness;
    final Paint puddle = Paint()
      ..color = machiMix(
        p.skyBottom,
        p.neon,
        0.25,
      ).withValues(alpha: 0.24 * wet);
    for (int i = 0; i < 6; i++) {
      c.drawOval(
        Rect.fromCenter(
          center: Offset(
            machiHash01(seed, i, 0xa4) * s.width,
            machiHash01(seed, i, 0xa5) * s.height,
          ),
          width: 110,
          height: 50,
        ),
        puddle,
      );
    }
  }

  final List<MachiGround> ground = <MachiGround>[
    machiGroundRect(
      -6,
      -6,
      6,
      6,
      0.02,
      machiMix(p.asphalt, p.concrete, 0.3),
      decal: alley,
    ),
    machiGroundRect(-2.85, -1.5, -2.5, 6, 0.021, machiHex(0x14171c)),
  ];

  // —— 楼 ——————————————————————————————————————————————————
  for (int i = 0; i < _blocks.length; i++) {
    final _Block b = _blocks[i];
    final Color wall = machiHex(_walls[b.wall]);
    final MachiDecal windows = machiWindowsDecal(
      seed: seed ^ (i * 7919),
      cellW: 0.62,
      cellH: 1.0,
      top: 0.3,
      bottom: 3.0,
      litRatio: 0.42,
      grille: true,
    );
    // 一楼铺面：卷闸、灯箱。
    void shopfront(Canvas c, Size s, MachiFrame f) {
      windows(c, s, f);
      final double top = s.height - 300;
      final Paint shutter = Paint()
        ..color = f.lighting.shade(machiHex(0x6b6f77), const MachiV3(0, 0, 1));
      final Paint line = Paint()
        ..color = f.lighting.shade(machiHex(0x4a4d54), const MachiV3(0, 0, 1))
        ..strokeWidth = 2;
      for (double x = 20; x < s.width - 60; x += 150) {
        final bool open = machiHash01(seed, i * 31 + x.floor(), 0xd1) < 0.45;
        final Rect r = Rect.fromLTWH(x, top + 90, 120, 210);
        if (open) {
          c.drawRect(
            r,
            Paint()..color = f.emissive(machiHex(0xffd79a), 0.75 * f.beat.warm),
          );
        } else {
          c.drawRect(r, shutter);
          for (double y = r.top + 8; y < r.bottom; y += 10) {
            c.drawLine(Offset(r.left, y), Offset(r.right, y), line);
          }
        }
      }
    }

    items.add(
      machiBox(
        b.x0,
        0.02,
        b.z0,
        b.x1,
        b.height,
        b.z1,
        wall,
        top: machiScale(wall, 0.8),
        decals: <MachiSide, MachiDecal>{
          MachiSide.right: shopfront,
          MachiSide.front: shopfront,
        },
      ),
    );
    // 楼顶：水箱、天线、天台小屋。
    final double cx = (b.x0 + b.x1) / 2;
    final double cz = (b.z0 + b.z1) / 2;
    if (machiHash01(seed, i, 0xe1) < 0.7) {
      items.add(
        machiBox(
          cx - 0.35,
          b.height,
          cz - 0.3,
          cx + 0.35,
          b.height + 0.7,
          cz + 0.3,
          machiHex(0x8e9aa6),
        ),
      );
    }
    if (machiHash01(seed, i, 0xe2) < 0.6) {
      final double ax = b.x0 + 0.4;
      final double az = b.z1 - 0.4;
      items.add(
        MachiCustom(MachiV3(ax, b.height + 0.8, az), (MachiRenderer r) {
          final Color c = r.frame.lighting.shade(
            MachiPalette.metal,
            MachiV3.up,
          );
          r.line(
            MachiV3(ax, b.height, az),
            MachiV3(ax, b.height + 1.6, az),
            c,
            0.03,
          );
          for (int k = 0; k < 4; k++) {
            final double y = b.height + 0.8 + k * 0.2;
            r.line(
              MachiV3(ax - 0.3 + k * 0.05, y, az),
              MachiV3(ax + 0.3 - k * 0.05, y, az),
              c,
              0.02,
            );
          }
        }),
      );
    }
    // 楼面的冷气机（左排朝 +x，后排朝 +z）。
    // L0 的楼面整面贴着 B0，不挂东西。
    final bool left = b.name.startsWith('L');
    final bool exposed = b.name != 'L0';
    for (int k = 0; k < 5; k++) {
      if (!exposed || machiHash01(seed, i * 13 + k, 0xe3) < 0.35) continue;
      final double y =
          3.4 + machiHash01(seed, i * 13 + k, 0xe4) * (b.height - 4.2);
      final double along = machiHash01(seed, i * 13 + k, 0xe5);
      if (left) {
        final double z = b.z0 + 0.4 + along * (b.z1 - b.z0 - 0.8);
        items.add(
          machiBox(
            b.x1,
            y,
            z - 0.25,
            b.x1 + 0.34,
            y + 0.32,
            z + 0.25,
            machiHex(0xc8ccd2),
          ),
        );
      } else {
        final double x = b.x0 + 0.3 + along * (b.x1 - b.x0 - 0.6);
        items.add(
          machiBox(
            x - 0.25,
            y,
            b.z1,
            x + 0.25,
            y + 0.32,
            b.z1 + 0.34,
            machiHex(0xc8ccd2),
          ),
        );
      }
    }
    // 晾衫竹（左排楼面伸出来）。
    if (left && exposed && machiHash01(seed, i, 0xe6) < 0.75) {
      final double y = 4.3 + machiHash01(seed, i, 0xe7) * 1.4;
      final double z = (b.z0 + b.z1) / 2;
      items.add(
        MachiCustom(MachiV3(b.x1 + 0.5, y, z), (MachiRenderer r) {
          final MachiFrame f = r.frame;
          r.line(
            MachiV3(b.x1, y, z - 0.5),
            MachiV3(b.x1 + 1.0, y + 0.05, z - 0.5),
            f.lighting.shade(machiHex(0xc9b27a), MachiV3.up),
            0.03,
          );
          for (int k = 0; k < 3; k++) {
            final double x = b.x1 + 0.2 + k * 0.28;
            r.canvas.save();
            r.canvas.transform(
              r.camera.planeMatrix(
                MachiV3(x, y, z - 0.5),
                const MachiV3(1, 0, 0),
                MachiV3.down,
              ),
            );
            final double sway = f.motion
                ? 3 * math.sin(f.ambient * 1.7 + k + i)
                : 0;
            r.canvas.drawRect(
              Rect.fromLTWH(sway, 2, 22, 36),
              Paint()
                ..color = f.lighting.shade(
                  p.products[(k + i + seed) % p.products.length],
                  const MachiV3(0, 0, 1),
                ),
            );
            r.canvas.restore();
          }
        }),
      );
    }
  }

  // —— B1：酒吧与歌词大屏 ————————————————————————————————————
  const double b1x0 = -0.3;
  const double b1x1 = 4.5;
  const double b1z1 = -1.5;
  final Color b1Wall = machiHex(_walls[0]);
  final MachiDecal b1Windows = machiWindowsDecal(
    seed: seed ^ 0xb1,
    cellW: 0.62,
    cellH: 1.0,
    top: 0.12,
    litRatio: 0.45,
    grille: true,
    avoid: const <Rect>[Rect.fromLTWH(0.1, 0.8, 4.6, 2.6)],
  );
  items.add(
    machiBox(
      b1x0,
      2.95,
      -6,
      b1x1,
      6.2,
      b1z1,
      b1Wall,
      top: machiScale(b1Wall, 0.8),
      decals: <MachiSide, MachiDecal>{MachiSide.front: b1Windows},
    ),
  );
  items.add(machiBox(b1x0, 0.02, -6, -0.1, 2.95, b1z1, b1Wall));
  items.add(machiBox(4.3, 0.02, -6, b1x1, 2.95, b1z1, b1Wall));
  void bar(Canvas c, Size s, MachiFrame f) {
    final double w = s.width;
    final double h = s.height;
    final double warm = f.beat.warm;
    c.drawRect(
      Offset.zero & s,
      Paint()..color = f.emissive(machiHex(0x3a2230), 0.9),
    );
    // 背光酒架与瓶子。
    final Rect shelf = Rect.fromLTWH(w * 0.05, h * 0.12, w * 0.62, h * 0.42);
    c.drawRect(
      shelf,
      Paint()..color = f.emissive(machiHex(0xffb06a), 0.85 * warm),
    );
    final Paint bottle = Paint();
    for (int row = 0; row < 3; row++) {
      for (double x = shelf.left + 6; x < shelf.right - 8; x += 11) {
        bottle.color = f.emissive(
          p.products[((x / 11).floor() + row + seed) % p.products.length],
          0.7,
        );
        c.drawRect(
          Rect.fromLTWH(
            x,
            shelf.top + 8 + row * shelf.height / 3,
            6,
            shelf.height / 3 - 14,
          ),
          bottle,
        );
      }
    }
    // 吊灯。
    for (int k = 0; k < 4; k++) {
      final double x = w * (0.12 + k * 0.17);
      c.drawLine(
        Offset(x, 0),
        Offset(x, h * 0.1),
        Paint()
          ..color = const Color(0xFF15181F)
          ..strokeWidth = 2,
      );
      c.drawCircle(
        Offset(x, h * 0.11),
        7,
        Paint()..color = f.emissive(machiHex(0xffe0a8), 1.1 * warm),
      );
    }
    // 吧台与台下霓虹。
    final Rect counter = Rect.fromLTWH(w * 0.04, h * 0.62, w * 0.62, h * 0.18);
    c.drawRect(counter, Paint()..color = machiHex(0x241820));
    c.drawRect(
      Rect.fromLTWH(counter.left, counter.bottom - 6, counter.width, 5),
      Paint()..color = f.emissive(p.neon, 1.2 * f.beat.group(1)),
    );
    // 高脚凳。
    final Paint stool = Paint()..color = machiHex(0x101216);
    for (int k = 0; k < 5; k++) {
      final double x = counter.left + 20 + k * counter.width / 5;
      c.drawRect(Rect.fromLTWH(x, counter.bottom + 6, 18, 6), stool);
      c.drawRect(Rect.fromLTWH(x + 7, counter.bottom + 12, 4, h * 0.14), stool);
    }
    // 点唱机：随（歌词）节拍明暗。
    final Rect jukebox = Rect.fromLTWH(w * 0.72, h * 0.3, w * 0.08, h * 0.5);
    c.drawRRect(
      RRect.fromRectAndCorners(
        jukebox,
        topLeft: Radius.circular(jukebox.width / 2),
        topRight: Radius.circular(jukebox.width / 2),
      ),
      Paint()
        ..color = f.emissive(
          machiMix(p.brand[0], machiHex(0xffffff), 0.2),
          0.6 + 0.5 * f.audio,
        ),
    );
    // 门（右）与玻璃竖框、反光。
    final Paint frame = Paint()
      ..color = machiHex(0x101216)
      ..strokeWidth = 4;
    for (double x = 0; x <= w; x += w / 5) {
      c.drawLine(Offset(x, 0), Offset(x, h), frame);
    }
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(w, h),
          <Color>[
            const Color(0x00FFFFFF),
            const Color(0x14FFFFFF),
            const Color(0x00FFFFFF),
          ],
          const <double>[0.35, 0.5, 0.65],
        ),
    );
  }

  items.add(
    machiBox(
      -0.1,
      0.06,
      -4.2,
      4.3,
      2.95,
      -1.62,
      machiHex(0x2a1c24),
      decals: <MachiSide, MachiDecal>{MachiSide.front: bar},
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  // 门头霓虹（曲名）。
  items.add(
    machiBox(
      0.15,
      2.45,
      -1.5,
      4.05,
      2.91,
      -1.38,
      machiHex(0x14171c),
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: (Canvas c, Size s, MachiFrame f) {
          c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF14171C));
          machiPaintNeonText(
            c,
            f.title.isEmpty ? 'KOWLOON BAR' : f.title,
            (Offset.zero & s).deflate(4),
            machiHex(0xff4fb0),
            f,
            intensity: f.flicker * f.beat.group(0) * (0.5 + 0.5 * f.artificial),
          );
        },
      },
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  // LED 跑马灯：这一句的译文，没有译文时滚曲名、歌手。
  items.add(
    machiBox(
      0.0,
      3.0,
      -1.5,
      4.2,
      3.17,
      -1.41,
      machiHex(0x0b0d12),
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: (Canvas c, Size s, MachiFrame f) =>
            machiPaintTicker(c, s, f),
      },
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );
  // 歌词大屏。
  void bigScreen(Canvas c, Size s, MachiFrame f) => screen.paint(c, s, f);
  items.add(
    machiBox(
      0.0,
      4.22 - machiKowloonScreenH / 2,
      -1.5,
      machiKowloonScreenW,
      4.22 + machiKowloonScreenH / 2,
      -1.38,
      p.boardBase,
      decals: <MachiSide, MachiDecal>{MachiSide.front: bigScreen},
      emissive: const <MachiSide>{MachiSide.front},
      sideColors: <MachiSide, Color>{
        MachiSide.top: MachiPalette.darkMetal,
        MachiSide.right: MachiPalette.darkMetal,
        MachiSide.left: MachiPalette.darkMetal,
      },
    ),
  );
  // 楼顶「九龍城寨」。
  items.add(machiPost(0.1, -2.15, 6.2, 6.6, 0.08, MachiPalette.darkMetal));
  items.add(machiPost(2.3, -2.15, 6.2, 6.6, 0.08, MachiPalette.darkMetal));
  items.add(
    machiBox(
      -0.05,
      6.6,
      -2.2,
      2.45,
      7.5,
      -2.1,
      machiHex(0x1a1420),
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: (Canvas c, Size s, MachiFrame f) {
          c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF1A1420));
          machiPaintNeonText(
            c,
            '九龍城寨',
            (Offset.zero & s).deflate(8),
            machiHex(0xff5a4a),
            f,
            intensity: f.beat.group(2) * (0.5 + 0.5 * f.artificial),
          );
        },
      },
      emissive: const <MachiSide>{MachiSide.front},
    ),
  );

  // —— 伸出楼面的招牌 ————————————————————————————————————————
  final int shopKey = machiHashString('kowloon-shops:$seed');
  for (int i = 0; i < _hanging.length; i++) {
    final _Hanging h = _hanging[i];
    final bool neon = machiHash01(shopKey, i, 0x1) < 0.55;
    final String text = h.artist
        ? '__artist__'
        : (h.vertical
              ? _verticalShops[(machiHash01(shopKey, i, 0x2) *
                            _verticalShops.length)
                        .floor() %
                    _verticalShops.length]
              : _horizontalShops[(machiHash01(shopKey, i, 0x3) *
                            _horizontalShops.length)
                        .floor() %
                    _horizontalShops.length]);
    final Color neonColor = machiHex(
      _neonColors[(machiHash01(shopKey, i, 0x4) * 6).floor() % 6],
    );
    final List<int> box =
        _lightboxColors[(machiHash01(shopKey, i, 0x5) * 5).floor() % 5];
    final int group = i % machiNeonGroups;
    final bool broken = machiHash01(shopKey, i, 0x6) < 0.25;
    void sign(Canvas c, Size s, MachiFrame f) {
      final String label = text == '__artist__'
          ? (f.artist.isEmpty ? '歌手' : f.artist)
          : text;
      final double k =
          f.beat.group(group) *
          (broken ? f.flicker : 1) *
          (0.5 + 0.5 * f.artificial);
      final Rect r = (Offset.zero & s).deflate(s.shortestSide * 0.08);
      if (neon) {
        c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF16141C));
        c.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s.shortestSide * 0.04
            ..color = f.emissive(neonColor, 0.8 * k),
        );
        machiPaintNeonText(
          c,
          label,
          r.deflate(s.shortestSide * 0.06),
          neonColor,
          f,
          intensity: k,
          vertical: h.vertical,
        );
      } else {
        c.drawRect(
          Offset.zero & s,
          Paint()..color = f.emissive(machiHex(box[0]), f.beat.lightbox(group)),
        );
        if (h.vertical) {
          f.text.drawVertical(c, label, r, f.emissive(machiHex(box[1])));
        } else {
          f.text.drawFitted(
            c,
            label,
            r,
            f.emissive(machiHex(box[1])),
            fill: 0.7,
          );
        }
      }
    }

    final Color boxColor = neon ? machiHex(0x16141c) : machiHex(box[0]);
    if (h.alongX) {
      items.add(
        machiBox(
          h.wall,
          h.y0,
          h.at - 0.08,
          h.tip,
          h.y1,
          h.at + 0.08,
          boxColor,
          decals: <MachiSide, MachiDecal>{
            MachiSide.front: sign,
            MachiSide.back: sign,
          },
          emissive: const <MachiSide>{MachiSide.front, MachiSide.back},
        ),
      );
    } else {
      items.add(
        machiBox(
          h.at - 0.08,
          h.y0,
          h.wall,
          h.at + 0.08,
          h.y1,
          h.tip,
          boxColor,
          decals: <MachiSide, MachiDecal>{
            MachiSide.right: sign,
            MachiSide.left: sign,
          },
          emissive: const <MachiSide>{MachiSide.right, MachiSide.left},
        ),
      );
    }
    if (neon) {
      lamps.add(
        MachiLamp(
          position: h.alongX
              ? MachiV3((h.wall + h.tip) / 2, (h.y0 + h.y1) / 2, h.at + 0.3)
              : MachiV3(h.at + 0.3, (h.y0 + h.y1) / 2, (h.wall + h.tip) / 2),
          color: neonColor,
          radius: 1.1,
          intensity: (MachiFrame f) =>
              0.4 * f.beat.group(group) * (broken ? f.flicker : 1),
        ),
      );
    }
  }

  // —— 巷子 ————————————————————————————————————————————————
  // 全息投影：地上的投影机，往上投一块转向镜头的面板（下一句）。
  const double hx = 0.9;
  const double hz = 2.3;
  const double hAz = 30 * machiDeg;
  items.add(
    machiBox(
      hx - 0.25,
      0.02,
      hz - 0.25,
      hx + 0.25,
      0.4,
      hz + 0.25,
      MachiPalette.darkMetal,
    ),
  );
  final MachiV3 hn = machiAzimuthDir(hAz);
  final MachiV3 hu = MachiV3(hn.z, 0, -hn.x);
  const double hw = 3.0;
  const double hh = 1.1;
  final MachiV3 hOrigin = const MachiV3(hx, 3.0 + hh / 2, hz) - hu * (hw / 2);
  items.add(
    MachiCustom(const MachiV3(hx, 1.6, hz), (MachiRenderer r) {
      // 光柱：从投影机到面板下沿的一束淡青。
      final Offset a = r.camera.project(const MachiV3(hx, 0.4, hz));
      final Offset b0 = r.camera.project(hOrigin + MachiV3.down * hh);
      final Offset b1 = r.camera.project(hOrigin + hu * hw + MachiV3.down * hh);
      final Path cone = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b0.dx, b0.dy)
        ..lineTo(b1.dx, b1.dy)
        ..close();
      r.canvas.drawPath(
        cone,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(
            a,
            Offset((b0.dx + b1.dx) / 2, b0.dy),
            <Color>[const Color(0x553FE8FF), const Color(0x103FE8FF)],
          ),
      );
    }),
  );
  items.add(
    MachiSolid.panel(
      MachiFace.panel(
        MachiFaceFrame(hOrigin, hu, MachiV3.down, hw, hh),
        const Color(0x00000000),
        decal: machiPaintHologram,
        emissive: true,
        outline: false,
      ),
    ),
  );
  // 大排档。
  void stallSign(Canvas c, Size s, MachiFrame f) {
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..color = f.lighting.shade(machiHex(0x2e7d4f), const MachiV3(0, 0, 1)),
    );
    f.text.drawFitted(
      c,
      '大排檔',
      (Offset.zero & s).deflate(6),
      f.lighting.shade(machiHex(0xfff4d6), const MachiV3(0, 0, 1)),
      fill: 0.7,
    );
  }

  items.add(machiBox(4.1, 0.02, 1.3, 5.85, 1.0, 2.25, machiHex(0x2e7d4f)));
  items.add(machiBox(4.1, 1.0, 1.3, 5.85, 2.1, 1.5, machiHex(0x2e7d4f)));
  items.add(
    machiBox(
      4.0,
      2.1,
      1.25,
      5.95,
      2.35,
      2.6,
      machiHex(0x3c9a63),
      decals: <MachiSide, MachiDecal>{MachiSide.front: stallSign},
    ),
  );
  items.add(machiBox(4.5, 0.02, 2.95, 5.2, 0.72, 3.55, machiHex(0xc9b27a)));
  for (final (double x, double z) in <(double, double)>[
    (4.2, 3.9),
    (5.5, 3.0),
    (5.1, 4.0),
  ]) {
    items.add(
      machiBox(
        x - 0.16,
        0.02,
        z - 0.16,
        x + 0.16,
        0.42,
        z + 0.16,
        p.products[((x * 3).floor() + seed) % p.products.length],
      ),
    );
  }
  lamps.add(
    MachiLamp(
      position: const MachiV3(4.95, 2.0, 2.0),
      color: machiHex(0xffd08a),
      radius: 0.6,
      pool: 1.6,
      poolAt: const MachiV3(4.95, 0.03, 2.8),
      intensity: (MachiFrame f) => f.beat.warm,
    ),
  );
  // 电线杆、街灯、电线。
  items.add(machiPost(5.55, -1.15, 0.02, 7.0, 0.22, machiHex(0x7a746a)));
  items.add(
    machiBox(5.0, 6.5, -1.25, 6.0, 6.62, -1.05, MachiPalette.darkMetal),
  );
  final (List<MachiItem> lampItems, MachiLamp street) = machiStreetLamp(
    x: 5.55,
    z: -1.15,
    height: 5.05,
    armX: -1.25,
    armZ: 0,
  );
  items.addAll(lampItems);
  lamps.add(street);
  items.add(
    MachiCustom(const MachiV3(1.0, 6.2, 0.5), (MachiRenderer r) {
      final Color w = r.frame.lighting.shade(MachiPalette.wire, MachiV3.up);
      const MachiV3 top = MachiV3(5.55, 6.6, -1.15);
      r.wire(top, const MachiV3(-3.2, 6.0, 2.0), 0.5, w);
      r.wire(top, const MachiV3(-3.35, 6.6, -0.5), 0.45, w);
      r.wire(top, const MachiV3(-0.3, 5.9, -1.5), 0.3, w);
      r.wire(top, const MachiV3(4.5, 5.2, -2.3), 0.1, w);
      r.wire(
        const MachiV3(-3.6, 5.6, 0.8),
        const MachiV3(-0.3, 5.0, -1.5),
        0.35,
        w,
      );
      r.wire(
        const MachiV3(-3.45, 4.9, 3.6),
        const MachiV3(5.55, 6.3, -1.15),
        0.7,
        w,
      );
    }),
  );
  // 贩卖机、电单车。
  items.add(
    machiVending(
      x0: 4.45,
      z0: -2.3,
      x1: 5.45,
      z1: -1.6,
      height: 1.83,
      facing: MachiSide.front,
      palette: p,
      seed: seed,
    ),
  );
  items.add(machiBike(2.9, 1.0, true, machiHex(0xc7302b)));
  // 夜里一层霓虹色的底光：屏幕前、酒吧门口、招牌一角粉青两盏。
  lamps.addAll(<MachiLamp>[
    MachiLamp(
      position: const MachiV3(2.1, 1.4, -1.3),
      color: p.interiorLight,
      radius: 0,
      pool: 2.6,
      poolAt: const MachiV3(2.1, 0.03, -0.4),
      intensity: (MachiFrame f) => f.beat.warm,
    ),
    MachiLamp(
      position: const MachiV3(2.1, 4.2, -1.2),
      color: p.boardLit,
      radius: 1.8,
      intensity: (MachiFrame f) => 0.3 + 0.1 * f.chorus,
    ),
    MachiLamp(
      position: const MachiV3(-2.6, 3.4, 1.5),
      color: machiHex(0xff4fb0),
      radius: 0.8,
      pool: 2.0,
      poolAt: const MachiV3(-2.0, 0.03, 1.5),
      intensity: (MachiFrame f) => 0.6 * f.beat.group(0),
    ),
    MachiLamp(
      position: const MachiV3(-2.6, 3.0, 4.2),
      color: machiHex(0x3fe8ff),
      radius: 0.8,
      pool: 2.0,
      poolAt: const MachiV3(-2.0, 0.03, 4.2),
      intensity: (MachiFrame f) => 0.6 * f.beat.group(1),
    ),
    MachiLamp(
      position: const MachiV3(hx, 0.5, hz),
      color: machiHex(0x3fe8ff),
      radius: 0.5,
      pool: 1.4,
      poolAt: const MachiV3(hx, 0.03, hz + 0.3),
    ),
  ]);

  const MachiV3 focus = MachiV3(2.1, 4.22, -1.38);
  return MachiSceneModel(
    id: MachiSceneId.kowloon,
    screenFace: const <MachiV3>[
      MachiV3(0, 4.22 + machiKowloonScreenH / 2, -1.38),
      MachiV3(machiKowloonScreenW, 4.22 + machiKowloonScreenH / 2, -1.38),
      MachiV3(machiKowloonScreenW, 4.22 - machiKowloonScreenH / 2, -1.38),
      MachiV3(0, 4.22 - machiKowloonScreenH / 2, -1.38),
    ],
    base: machiPlinth(),
    ground: ground,
    items: items,
    lamps: lamps,
    reflectors: <MachiReflector>[
      MachiReflector(
        center: focus,
        width: machiKowloonScreenW * 0.8,
        height: machiKowloonScreenH,
        color: (MachiFrame f) => f.palette.boardLit,
      ),
      MachiReflector(
        center: const MachiV3(2.1, 2.7, -1.38),
        width: 3.6,
        height: 0.4,
        color: (MachiFrame f) => machiHex(0xff4fb0),
      ),
      MachiReflector(
        center: const MachiV3(hx, 3.0, hz),
        width: 2.4,
        height: 1.0,
        color: (MachiFrame f) => machiHex(0x3fe8ff),
      ),
    ],
    framing: <MachiV3>[
      for (final double x in <double>[-6, 6])
        for (final double z in <double>[-6, 6]) ...<MachiV3>[
          MachiV3(x, -0.6, z),
          MachiV3(x, 0, z),
        ],
      const MachiV3(-6, 7.3, -6),
      const MachiV3(-6, 7.3, 0),
      const MachiV3(2.45, 7.5, -2.2),
      const MachiV3(5.55, 7.0, -1.15),
    ],
    home: const MachiHomeView(
      azimuth: 30 * machiDeg,
      elevation: 30 * machiDeg,
      zoom: 1.55,
    ),
    focus: focus,
    lanes: const <MachiLane>[],
    roofs: <(Rect, double)>[
      for (final _Block b in _blocks)
        (Rect.fromLTRB(b.x0, b.z0, b.x1, b.z1), b.height),
      (const Rect.fromLTRB(b1x0, -6, b1x1, b1z1), 6.2),
      (const Rect.fromLTRB(4.0, 1.25, 5.95, 2.6), 2.35),
    ],
  );
}
