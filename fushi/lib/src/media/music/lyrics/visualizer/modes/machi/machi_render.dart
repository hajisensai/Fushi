/// 町景的 2.5D 渲染核心：folia 用 three.js 正交斜俯视画微缩街角，这里用 Canvas 复刻——
/// 正交投影下任何平面都映成平行四边形，所以每个面（连同上面的招牌、屏幕、窗格）都能用一次
/// 仿射变换直接画进去；物件按离镜头的深度从远到近画（画家算法），面按卡通光照着色、描一圈
/// 墨线（folia 后期的墨线 pass）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_text.dart';

/// 面上的局部坐标：每米多少个局部像素（招牌、屏幕的字按这个单位排）。
const double machiLocalPxPerMeter = 100;

// ---------------------------------------------------------------------------
// 镜头
// ---------------------------------------------------------------------------

/// 正交镜头：绕 [target] 的方位角 / 俯角，每米 [scale] 个屏幕像素，[target] 落在 [anchor]。
class MachiCamera {
  MachiCamera({
    required this.azimuth,
    required this.elevation,
    required this.scale,
    required this.target,
    required this.anchor,
  }) : dir = MachiV3(
         math.sin(azimuth) * math.cos(elevation),
         math.sin(elevation),
         math.cos(azimuth) * math.cos(elevation),
       ),
       right = MachiV3(math.cos(azimuth), 0, -math.sin(azimuth)) {
    up = dir.cross(right);
  }

  final double azimuth;
  final double elevation;
  final double scale;
  final MachiV3 target;
  final Offset anchor;

  /// 从目标点指向镜头的方向（面的法线与它点积为正就看得见）。
  final MachiV3 dir;
  final MachiV3 right;
  late final MachiV3 up;

  Offset project(MachiV3 p) {
    final MachiV3 d = p - target;
    return Offset(
      anchor.dx + d.dot(right) * scale,
      anchor.dy - d.dot(up) * scale,
    );
  }

  /// 越大离镜头越近。
  double depth(MachiV3 p) => (p - target).dot(dir);

  bool faces(MachiV3 normal) => normal.dot(dir) > 1e-4;

  /// 平面局部坐标（局部像素，u 向右、v 向下）→ 屏幕的仿射矩阵。
  Float64List planeMatrix(MachiV3 origin, MachiV3 u, MachiV3 v) {
    final Offset o = project(origin);
    const double k = 1 / machiLocalPxPerMeter;
    final double ux = u.dot(right) * scale * k;
    final double uy = -u.dot(up) * scale * k;
    final double vx = v.dot(right) * scale * k;
    final double vy = -v.dot(up) * scale * k;
    return Float64List.fromList(<double>[
      ux, uy, 0, 0, //
      vx, vy, 0, 0, //
      0, 0, 1, 0, //
      o.dx, o.dy, 0, 1, //
    ]);
  }
}

/// 场景给的默认构图：方位角、俯角（弧度）与缩放（框住构图点是 1）。
class MachiHomeView {
  const MachiHomeView({
    required this.azimuth,
    required this.elevation,
    required this.zoom,
  });

  final double azimuth;
  final double elevation;
  final double zoom;
}

/// 视角限：方位角在默认 ±75°，俯角 20°–70°，缩放 0.75–3.6，平移 ±5m。
const double machiMaxAzimuthRange = 75 * machiDeg;
const double machiMinElevation = 20 * machiDeg;
const double machiMaxElevation = 70 * machiDeg;

/// 按构图点和视口求镜头：缩放 1 框住构图点；放大后装不下时 85% 从下沿裁（保住上沿的
/// 招牌）；竖屏把默认的拉近减半；歌词屏中心始终留在画面里。[offset] 是相对默认构图的
/// 转角 / 俯仰 / 缩放 / 平移（自定义视角与运镜叠在一起）。
MachiCamera machiFitCamera({
  required List<MachiV3> framing,
  required MachiHomeView home,
  required Size size,
  required MachiV3 focus,
  MachiViewOffset offset = const MachiViewOffset(),
}) {
  double minX = double.infinity;
  double maxX = -double.infinity;
  double minY = double.infinity;
  double maxY = -double.infinity;
  double sx = 0;
  double sy = 0;
  double sz = 0;
  for (final MachiV3 p in framing) {
    sx += p.x;
    sy += p.y;
    sz += p.z;
  }
  final int n = math.max(1, framing.length);
  final MachiV3 target = MachiV3(sx / n, sy / n, sz / n);
  final MachiCamera probe = MachiCamera(
    azimuth: home.azimuth,
    elevation: home.elevation,
    scale: 1,
    target: target,
    anchor: Offset.zero,
  );
  for (final MachiV3 p in framing) {
    final Offset o = probe.project(p);
    minX = math.min(minX, o.dx);
    maxX = math.max(maxX, o.dx);
    minY = math.min(minY, o.dy);
    maxY = math.max(maxY, o.dy);
  }
  final double w = math.max(1, size.width);
  final double h = math.max(1, size.height);
  const double margin = 0.02;
  final double fit = math.min(
    w * (1 - 2 * margin) / math.max(1e-3, maxX - minX),
    h * (1 - 2 * margin - 0.05) / math.max(1e-3, maxY - minY),
  );
  final double aspect = w / h;
  // 竖屏：宽度先装满，再拉近一点，左右按歌词屏居中裁。
  final double homeZoom = aspect < 1 ? home.zoom * 1.35 : home.zoom;
  final double baseScale = fit * homeZoom;
  // 默认构图下目标点在屏幕上的位置。
  double ax = w / 2 - (minX + maxX) / 2 * baseScale;
  final double contentH = (maxY - minY) * baseScale;
  final double availH = h * (1 - 2 * margin - 0.05);
  double ay;
  if (contentH <= availH) {
    ay = h * margin + (availH - contentH) / 2 - minY * baseScale;
  } else {
    final double overflow = contentH - availH;
    ay = h * margin - overflow * 0.15 - minY * baseScale;
  }
  // 歌词屏中心留在画面里（竖屏时尤其要紧）。
  final Offset f = Offset(
    ax + (probe.project(focus).dx) * baseScale,
    ay + (probe.project(focus).dy) * baseScale,
  );
  if (aspect < 1) {
    ax += w / 2 - f.dx;
  } else {
    if (f.dx < w * 0.2) ax += w * 0.2 - f.dx;
    if (f.dx > w * 0.8) ax -= f.dx - w * 0.8;
  }
  if (f.dy < h * 0.15) ay += h * 0.15 - f.dy;

  final double az = machiClamp(
    home.azimuth + offset.azimuth * machiDeg,
    home.azimuth - machiMaxAzimuthRange,
    home.azimuth + machiMaxAzimuthRange,
  );
  final double el = machiClamp(
    home.elevation + offset.elevation * machiDeg,
    machiMinElevation,
    machiMaxElevation,
  );
  final double zoom = machiClamp(homeZoom * offset.zoom, 0.75, 3.6) / homeZoom;
  // 平移沿默认朝向的左右、前后（地面上）。
  final MachiV3 rightAxis = MachiV3(
    math.cos(home.azimuth),
    0,
    -math.sin(home.azimuth),
  );
  final MachiV3 backAxis = MachiV3(
    math.sin(home.azimuth),
    0,
    math.cos(home.azimuth),
  );
  final MachiV3 panned =
      target +
      rightAxis * machiClamp(offset.panX, -5, 5) +
      backAxis * machiClamp(offset.panZ, -5, 5);
  return MachiCamera(
    azimuth: az,
    elevation: el,
    scale: baseScale * zoom,
    target: panned,
    anchor: Offset(ax, ay),
  );
}

// ---------------------------------------------------------------------------
// 光照
// ---------------------------------------------------------------------------

/// 一帧的光照：半球光（天空色）+ 一盏平行光（夜里月光、黄昏低低的橙色太阳、白天高处的
/// 太阳），再加闪电。卡通着色：只按法线算一档漫反射。
class MachiLighting {
  MachiLighting({
    required MachiPalette palette,
    required MachiEnvironmentState env,
    required MachiEnvironmentLook look,
    required double lightning,
  }) {
    final double d = env.daylight;
    Color tri(Color night, Color dusk, Color day) => d < machiDaylightDusk
        ? machiMix(night, dusk, d / machiDaylightDusk)
        : machiMix(
            dusk,
            day,
            (d - machiDaylightDusk) / (1 - machiDaylightDusk),
          );
    final Color hemi = machiMix(
      tri(palette.hemiSky, palette.hemiSkyDusk, palette.hemiSkyDay),
      machiHex(0x9aa1ab),
      look.overcast * 0.45,
    );
    final Color sun = tri(palette.moon, palette.moonDusk, palette.moonDay);
    final double ambientK = 0.42 + 0.5 * d;
    _ar = machiClamp(hemi.r * ambientK * 1.35 + 0.08 + lightning * 0.6, 0, 1.6);
    _ag = machiClamp(hemi.g * ambientK * 1.35 + 0.08 + lightning * 0.6, 0, 1.6);
    _ab = machiClamp(hemi.b * ambientK * 1.35 + 0.1 + lightning * 0.7, 0, 1.6);
    final double sunK = look.sunIntensity / 3.0 * 0.55;
    _sr = sun.r * sunK;
    _sg = sun.g * sunK;
    _sb = sun.b * sunK;
    // 夜里月光从左前高处，黄昏太阳从左前低处，白天高处。
    final MachiV3 night = const MachiV3(-0.4, 0.8, 0.45).normalized();
    final MachiV3 dusk = const MachiV3(-0.85, 0.32, 0.42).normalized();
    final MachiV3 day = const MachiV3(0.25, 0.9, 0.35).normalized();
    sunDir =
        (d < machiDaylightDusk
                ? night * (1 - d / machiDaylightDusk) +
                      dusk * (d / machiDaylightDusk)
                : dusk * (1 - (d - machiDaylightDusk) / 0.55) +
                      day * ((d - machiDaylightDusk) / 0.55))
            .normalized();
    snowCover = env.snowCover;
    wetness = env.wetness;
  }

  late final double _ar;
  late final double _ag;
  late final double _ab;
  late final double _sr;
  late final double _sg;
  late final double _sb;
  late final MachiV3 sunDir;
  late final double snowCover;
  late final double wetness;

  /// 面的颜色 × 光照；朝上的面按积雪往白里拉。
  Color shade(Color c, MachiV3 normal, {bool snowable = true}) {
    final double lambert = math.max(0, normal.dot(sunDir));
    // 卡通：两档。
    final double step = lambert > 0.55 ? 1 : (lambert > 0.12 ? 0.6 : 0.15);
    final double up = normal.y > 0 ? 0.12 * normal.y : 0;
    Color out = machiModulate(
      c,
      _ar + up + _sr * step,
      _ag + up + _sg * step,
      _ab + up + _sb * step,
    );
    if (snowable && snowCover > 0 && normal.y > 0.6) {
      out = machiMix(
        out,
        machiModulate(MachiPalette.snow, _ar + _sr, _ag + _sg, _ab + _sb),
        snowCover * 0.82,
      );
    }
    return out;
  }

  /// 地面：湿的时候暗一点。
  Color ground(Color c) => machiScale(shade(c, MachiV3.up), 1 - 0.28 * wetness);
}

// ---------------------------------------------------------------------------
// 一帧的共享量（面上的招牌、屏幕读它）
// ---------------------------------------------------------------------------

/// 一帧里各处都要读的量。由运行时每帧填好再交给渲染器。
class MachiFrame {
  MachiFrame({required this.palette, required this.text, required this.seed});

  final MachiPalette palette;
  final MachiTextCache text;
  final int seed;

  late MachiCamera camera;
  late MachiLighting lighting;
  MachiEnvironmentState env = MachiEnvironmentState.settled(
    MachiEnvironmentTarget.of(0, MachiWeatherKind.clear),
  );
  MachiEnvironmentLook look = resolveMachiEnvironmentLook(
    MachiEnvironmentState.settled(
      MachiEnvironmentTarget.of(0, MachiWeatherKind.clear),
    ),
  );
  final MachiBeatFrame beat = MachiBeatFrame();

  /// 氛围时间（秒；只在播放且开着动态效果时走）。
  double ambient = 0;

  /// 歌曲时间（秒）。
  double song = 0;
  double chorus = 0;
  double audio = 0;

  /// 动画强度对雨雪的倍数（folia `INTENSITY_SCALE`：平静 0.7 / 普通 1 / 激烈 1.3）。
  double intensity = 1;
  double flicker = 1;
  double lightning = 0;
  double doorOpen = 0;
  bool motion = true;
  bool glow = true;
  bool reflections = true;

  String title = '';
  String artist = '';
  String album = '';
  String tickerText = '';

  /// 跑马灯滚了多少（以字条高度为单位，累积）。
  double tickerScroll = 0;

  /// 下一句（全息投影 / 出租车顶灯）与它的换字错位。
  String nextLine = '';
  double nextGlitch = 0;
  int lineNumber = 0;
  int lineCount = 0;
  double positionSec = 0;
  double durationSec = 0;
  MachiCarPass? car;

  /// 人造光的亮度倍数（白天弱）乘闪烁。
  double get artificial => look.artificial;

  /// 自发光色：不吃环境光，按人造光亮度走。
  Color emissive(Color c, [double k = 1]) =>
      machiScale(c, (0.72 + 0.28 * artificial) * k);
}

typedef MachiDecal = void Function(Canvas canvas, Size size, MachiFrame frame);

/// 面的局部坐标系：左上角、u（向右）、v（向下）单位向量、宽高（米）。
class MachiFaceFrame {
  const MachiFaceFrame(this.origin, this.u, this.v, this.width, this.height);

  final MachiV3 origin;
  final MachiV3 u;
  final MachiV3 v;
  final double width;
  final double height;

  Size get localSize =>
      Size(width * machiLocalPxPerMeter, height * machiLocalPxPerMeter);

  MachiV3 at(double fu, double fv) =>
      origin + u * (width * fu) + v * (height * fv);

  List<MachiV3> get corners => <MachiV3>[
    origin,
    origin + u * width,
    origin + u * width + v * height,
    origin + v * height,
  ];

  MachiV3 get normal => v.cross(u).normalized();
}

class MachiFace {
  MachiFace({
    required this.corners,
    required this.normal,
    required this.color,
    this.frame,
    this.decal,
    this.emissive = false,
    this.snowable = true,
    this.outline = true,
    this.doubleSided = false,
    this.dynamicColor,
  });

  /// 用局部坐标系建一个四边面。
  factory MachiFace.panel(
    MachiFaceFrame frame,
    Color color, {
    MachiDecal? decal,
    bool emissive = false,
    bool outline = true,
    bool doubleSided = false,
    Color Function(MachiFrame f)? dynamicColor,
  }) => MachiFace(
    corners: frame.corners,
    normal: frame.normal,
    color: color,
    frame: frame,
    decal: decal,
    emissive: emissive,
    snowable: false,
    outline: outline,
    doubleSided: doubleSided,
    dynamicColor: dynamicColor,
  );

  final List<MachiV3> corners;
  final MachiV3 normal;
  final Color color;
  final MachiFaceFrame? frame;
  final MachiDecal? decal;
  final bool emissive;
  final bool snowable;
  final bool outline;
  final bool doubleSided;

  /// 每帧变的底色（自发光的灯箱之类）。
  final Color Function(MachiFrame f)? dynamicColor;
}

// ---------------------------------------------------------------------------
// 物件
// ---------------------------------------------------------------------------

abstract class MachiItem {
  MachiItem();

  MachiV3 get center;

  void draw(MachiRenderer r);
}

enum MachiSide { top, front, back, left, right, bottom }

/// 凸多面体（盒子、三角柱……）：看得见的面互不遮挡，直接画。
class MachiSolid extends MachiItem {
  MachiSolid(this.faces, this.center);

  /// 轴对齐的盒子。[decals] 按面挂招牌 / 窗格；[emissiveSides] 的面是自发光的。
  factory MachiSolid.box(
    MachiV3 min,
    MachiV3 max,
    Color color, {
    Color? top,
    Map<MachiSide, MachiDecal> decals = const <MachiSide, MachiDecal>{},
    Set<MachiSide> emissiveSides = const <MachiSide>{},
    Map<MachiSide, Color> sideColors = const <MachiSide, Color>{},
    bool outline = true,
    bool snowable = true,
  }) {
    final List<MachiFace> faces = <MachiFace>[];
    for (final MachiSide side in MachiSide.values) {
      if (side == MachiSide.bottom) continue;
      final MachiFaceFrame frame = machiBoxFaceFrame(min, max, side);
      faces.add(
        MachiFace(
          corners: frame.corners,
          normal: frame.normal,
          color:
              sideColors[side] ??
              (side == MachiSide.top ? (top ?? color) : color),
          frame: frame,
          decal: decals[side],
          emissive: emissiveSides.contains(side),
          snowable: snowable && side == MachiSide.top,
          outline: outline,
        ),
      );
    }
    return MachiSolid(
      faces,
      MachiV3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2),
    );
  }

  /// 一块面板（招牌、屏幕、旗）。
  factory MachiSolid.panel(MachiFace face) {
    final MachiFaceFrame f = face.frame!;
    return MachiSolid(<MachiFace>[face], f.at(0.5, 0.5));
  }

  final List<MachiFace> faces;
  @override
  final MachiV3 center;

  @override
  void draw(MachiRenderer r) {
    for (final MachiFace face in faces) {
      r.drawFace(face);
    }
  }
}

/// 盒子某个面的局部坐标系（左上角起，v 朝下；顶面 v 朝 +z）。
MachiFaceFrame machiBoxFaceFrame(MachiV3 mn, MachiV3 mx, MachiSide side) {
  final double dx = mx.x - mn.x;
  final double dy = mx.y - mn.y;
  final double dz = mx.z - mn.z;
  const MachiV3 ex = MachiV3(1, 0, 0);
  const MachiV3 ez = MachiV3(0, 0, 1);
  switch (side) {
    case MachiSide.front:
      return MachiFaceFrame(
        MachiV3(mn.x, mx.y, mx.z),
        ex,
        MachiV3.down,
        dx,
        dy,
      );
    case MachiSide.back:
      return MachiFaceFrame(
        MachiV3(mx.x, mx.y, mn.z),
        -ex,
        MachiV3.down,
        dx,
        dy,
      );
    case MachiSide.right:
      return MachiFaceFrame(
        MachiV3(mx.x, mx.y, mx.z),
        -ez,
        MachiV3.down,
        dz,
        dy,
      );
    case MachiSide.left:
      return MachiFaceFrame(
        MachiV3(mn.x, mx.y, mn.z),
        ez,
        MachiV3.down,
        dz,
        dy,
      );
    case MachiSide.top:
      return MachiFaceFrame(MachiV3(mn.x, mx.y, mn.z), ex, ez, dx, dz);
    case MachiSide.bottom:
      return MachiFaceFrame(MachiV3(mn.x, mn.y, mx.z), ex, -ez, dx, dz);
  }
}

/// 一组物件（车、自行车……）：组内每帧按深度排。
class MachiGroup extends MachiItem {
  MachiGroup(this.children, this.center);

  final List<MachiItem> children;
  @override
  final MachiV3 center;

  @override
  void draw(MachiRenderer r) => r.drawSorted(children);
}

/// 自己画的物件（电线、会动的东西）。
class MachiCustom extends MachiItem {
  MachiCustom(this.center, this.painter);

  @override
  final MachiV3 center;
  final void Function(MachiRenderer r) painter;

  @override
  void draw(MachiRenderer r) => painter(r);
}

/// 地面上的一块（按给的顺序先画，不参与排序）。
class MachiGround {
  const MachiGround(this.frame, this.color, {this.decal, this.wet = true});

  final MachiFaceFrame frame;
  final Color color;
  final MachiDecal? decal;

  /// 下雨时变暗、映灯。
  final bool wet;
}

/// 灯：亮处的光晕（加色）与地上的光斑。
class MachiLamp {
  const MachiLamp({
    required this.position,
    required this.color,
    this.radius = 0.5,
    this.pool = 0,
    this.poolAt,
    this.intensity,
    this.streetLamp = false,
  });

  final MachiV3 position;
  final Color color;

  /// 光晕半径（米）。
  final double radius;

  /// 地上光斑的半径（米；0 没有）。
  final double pool;
  final MachiV3? poolAt;

  /// 每帧的亮度倍数（闪烁、节拍）。
  final double Function(MachiFrame f)? intensity;

  /// 路灯：黄昏才点亮、白天关。
  final bool streetLamp;

  double strength(MachiFrame f) {
    final double base = streetLamp ? f.look.streetLamps : f.artificial;
    return base * (intensity?.call(f) ?? 1);
  }
}

/// 湿地面上会映出来的发光面（屏幕、招牌）。
class MachiReflector {
  const MachiReflector({
    required this.center,
    required this.width,
    required this.height,
    required this.color,
  });

  final MachiV3 center;
  final double width;
  final double height;
  final Color Function(MachiFrame f) color;
}

/// 一个场景。
class MachiSceneModel {
  MachiSceneModel({
    required this.id,
    required this.ground,
    required this.items,
    required this.lamps,
    required this.reflectors,
    required this.framing,
    required this.home,
    required this.focus,
    required this.lanes,
    required this.roofs,
    this.base = const <MachiItem>[],
    this.screenFace = const <MachiV3>[],
    this.dynamicItems,
  });

  /// 歌词屏那一面的四个角（景深不虚它，歌词总是清楚的）。
  final List<MachiV3> screenFace;

  /// 底座（先画，在地面之前）。
  final List<MachiItem> base;

  final MachiSceneId id;
  final List<MachiGround> ground;
  final List<MachiItem> items;
  final List<MachiLamp> lamps;
  final List<MachiReflector> reflectors;
  final List<MachiV3> framing;
  final MachiHomeView home;

  /// 歌词屏的中心（对焦在歌词上时、构图时对着它）。
  final MachiV3 focus;
  final List<MachiLane> lanes;

  /// 屋顶（xz 矩形 + 高度）：雨雪落到这里为止。
  final List<(Rect, double)> roofs;

  /// 每帧另加的物件（开过的车）。
  final List<MachiItem> Function(MachiFrame f)? dynamicItems;

  double groundAt(double x, double z) {
    for (final (Rect r, double h) in roofs) {
      if (r.contains(Offset(x, z))) return h;
    }
    return 0;
  }
}

// ---------------------------------------------------------------------------
// 渲染器
// ---------------------------------------------------------------------------

class MachiRenderer {
  MachiRenderer(this.canvas, this.camera, this.frame);

  final Canvas canvas;
  final MachiCamera camera;
  final MachiFrame frame;
  final Paint _fill = Paint()..isAntiAlias = true;
  final Paint _ink = Paint()
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true
    ..strokeJoin = StrokeJoin.round;

  late final double inkWidth = math.max(0.6, camera.scale * 0.012);
  late final Color inkColor = machiMix(
    machiHex(0x0b0d12),
    machiHex(0x2a2f3a),
    frame.env.daylight,
  ).withValues(alpha: 0.55);

  Path polygon(List<MachiV3> pts) {
    final Path p = Path();
    for (int i = 0; i < pts.length; i++) {
      final Offset o = camera.project(pts[i]);
      if (i == 0) {
        p.moveTo(o.dx, o.dy);
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    return p..close();
  }

  void drawFace(MachiFace face) {
    final bool visible = camera.faces(face.normal);
    if (!visible && !face.doubleSided) return;
    final Path path = polygon(face.corners);
    final Color base = face.dynamicColor?.call(frame) ?? face.color;
    final Color color = face.emissive
        ? frame.emissive(base)
        : frame.lighting.shade(
            base,
            visible ? face.normal : -face.normal,
            snowable: face.snowable,
          );
    _fill
      ..color = color
      ..blendMode = BlendMode.srcOver
      ..shader = null;
    canvas.drawPath(path, _fill);
    if (visible && face.decal != null && face.frame != null) {
      drawInFrame(face.frame!, face.decal!);
    }
    if (face.outline) {
      _ink
        ..strokeWidth = inkWidth
        ..color = inkColor;
      canvas.drawPath(path, _ink);
    }
  }

  /// 在面的局部坐标里画（裁到面内）。
  void drawInFrame(MachiFaceFrame f, MachiDecal decal) {
    canvas.save();
    canvas.transform(camera.planeMatrix(f.origin, f.u, f.v));
    final Size size = f.localSize;
    canvas.clipRect(Offset.zero & size);
    decal(canvas, size, frame);
    canvas.restore();
  }

  void drawSorted(List<MachiItem> items) {
    final List<(double, MachiItem)> order =
        <(double, MachiItem)>[
          for (final MachiItem it in items) (camera.depth(it.center), it),
        ]..sort(
          ((double, MachiItem) a, (double, MachiItem) b) =>
              a.$1.compareTo(b.$1),
        );
    for (final (double _, MachiItem it) in order) {
      it.draw(this);
    }
  }

  /// 一段 3D 线（电线、细杆），宽度按米给（至少 0.7 像素）。
  void line(MachiV3 a, MachiV3 b, Color color, double widthMeters) {
    canvas.drawLine(
      camera.project(a),
      camera.project(b),
      Paint()
        ..color = color
        ..strokeWidth = math.max(0.7, widthMeters * camera.scale)
        ..strokeCap = StrokeCap.round,
    );
  }

  /// 下垂的电线（抛物线）。
  void wire(MachiV3 a, MachiV3 b, double sag, Color color) {
    final Path p = Path();
    const int steps = 10;
    for (int i = 0; i <= steps; i++) {
      final double t = i / steps;
      final MachiV3 q = a + (b - a) * t + MachiV3(0, -sag * 4 * t * (1 - t), 0);
      final Offset o = camera.project(q);
      if (i == 0) {
        p.moveTo(o.dx, o.dy);
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = color
        ..strokeWidth = math.max(0.6, 0.025 * camera.scale),
    );
  }

  /// 地面上的光斑（加色椭圆）。
  void groundPool(MachiV3 at, double radius, Color color, double alpha) {
    if (alpha <= 0.003) return;
    canvas.save();
    canvas.transform(
      camera.planeMatrix(at, const MachiV3(1, 0, 0), const MachiV3(0, 0, 1)),
    );
    final double r = radius * machiLocalPxPerMeter;
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(Offset.zero, r, <Color>[
          color.withValues(alpha: machiClamp(alpha, 0, 1)),
          color.withValues(alpha: 0),
        ]),
    );
    canvas.restore();
  }

  /// 光晕（加色圆）。
  void glow(MachiV3 at, double radiusMeters, Color color, double alpha) {
    if (alpha <= 0.003) return;
    final Offset o = camera.project(at);
    final double r = math.max(2, radiusMeters * camera.scale);
    canvas.drawCircle(
      o,
      r,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(
          o,
          r,
          <Color>[
            color.withValues(alpha: machiClamp(alpha, 0, 1)),
            color.withValues(alpha: machiClamp(alpha * 0.3, 0, 1)),
            color.withValues(alpha: 0),
          ],
          const <double>[0, 0.35, 1],
        ),
    );
  }

  /// 画一整个场景（天空、天气、雾由运行时另画）。
  void drawScene(MachiSceneModel scene) {
    final MachiLighting light = frame.lighting;
    drawSorted(scene.base);
    for (final MachiGround g in scene.ground) {
      final Path p = polygon(g.frame.corners);
      _fill
        ..shader = null
        ..blendMode = BlendMode.srcOver
        ..color = g.wet
            ? light.ground(g.color)
            : light.shade(g.color, MachiV3.up);
      canvas.drawPath(p, _fill);
      if (g.decal != null) drawInFrame(g.frame, g.decal!);
    }
    // 地上的光斑。
    for (final MachiLamp lamp in scene.lamps) {
      if (lamp.pool <= 0) continue;
      final double s = lamp.strength(frame);
      final MachiV3 at = lamp.poolAt ?? lamp.position.withY(0.02);
      groundPool(
        at,
        lamp.pool * (1 + 0.15 * light.wetness),
        lamp.color,
        0.34 *
            s *
            (1 - 0.6 * frame.env.daylight) *
            (frame.beat.warm + frame.beat.thump),
      );
    }
    _drawKickRipples(scene, light.wetness);
    // 湿地面的倒影：沿竖向拉成光带。
    if (frame.reflections && light.wetness > 0.05) {
      _drawReflections(scene);
    }
    final List<MachiItem> items = <MachiItem>[
      ...scene.items,
      ...?scene.dynamicItems?.call(frame),
    ];
    drawSorted(items);
    if (frame.glow) {
      for (final MachiLamp lamp in scene.lamps) {
        if (lamp.radius <= 0) continue;
        final double s = lamp.strength(frame);
        glow(
          lamp.position,
          lamp.radius * (1 + 0.3 * frame.look.mist),
          lamp.color,
          0.55 * s * (0.45 + frame.look.bloom * frame.beat.bloom * 1.6),
        );
      }
    }
  }

  /// 鼓点涟漪（folia 地面着色器的 kick rings）：从歌词屏脚下（场景焦点）在湿地面上荡开的亮环，环按
  /// [machiRippleSpeed] 走、按剩余寿命的平方淡；地面越干越淡（[machiRippleWetness]）。
  void _drawKickRipples(MachiSceneModel scene, double wetness) {
    final double wet = machiRippleWetness(wetness);
    if (wet <= 0.01) return;
    final MachiBeatFrame beat = frame.beat;
    final Color c = Color.lerp(
      frame.palette.neon,
      const Color(0xFFFFFFFF),
      0.55,
    )!;
    for (int i = 0; i < machiRippleMax; i++) {
      final double age = beat.ringAge[i];
      final double amp = beat.ringAmp[i];
      if (age < 0 || amp <= 0) continue;
      final double left = 1 - age / machiRippleLife;
      if (left <= 0) continue;
      final double alpha = machiClamp(0.45 * amp * left * left * wet, 0, 1);
      if (alpha < 0.01) continue;
      final double r = machiRippleSpeed * age + 0.2;
      final Path ring = Path();
      const int steps = 48;
      for (int k = 0; k <= steps; k++) {
        final double a = k / steps * 2 * math.pi;
        final Offset o = camera.project(
          MachiV3(
            scene.focus.x + r * math.cos(a),
            0.03,
            scene.focus.z + r * math.sin(a),
          ),
        );
        if (k == 0) {
          ring.moveTo(o.dx, o.dy);
        } else {
          ring.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..blendMode = BlendMode.plus
          ..strokeWidth = math.max(1.5, 0.12 * camera.scale)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..color = c.withValues(alpha: alpha),
      );
    }
  }

  void _drawReflections(MachiSceneModel scene) {
    final double wet = frame.lighting.wetness;
    // 倒影只在底座顶面上。
    canvas.save();
    canvas.clipPath(
      polygon(const <MachiV3>[
        MachiV3(-6, 0, -6),
        MachiV3(6, 0, -6),
        MachiV3(6, 0, 6),
        MachiV3(-6, 0, 6),
      ]),
    );
    void streak(MachiV3 src, double widthM, double heightM, Color c, double a) {
      final MachiV3 mirror = MachiV3(src.x, -src.y * 0.92, src.z);
      final Offset o = camera.project(mirror);
      final double w = math.max(2, widthM * camera.scale * 0.8);
      final double h = math.max(4, (heightM + src.y * 0.6) * camera.scale);
      final Rect r = Rect.fromCenter(center: o, width: w, height: h);
      canvas.drawRect(
        r,
        Paint()
          ..blendMode = BlendMode.plus
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.max(1, w * 0.08),
          )
          ..shader = ui.Gradient.linear(
            r.topCenter,
            r.bottomCenter,
            <Color>[
              c.withValues(alpha: 0),
              c.withValues(alpha: machiClamp(a, 0, 1)),
              c.withValues(alpha: 0),
            ],
            const <double>[0, 0.35, 1],
          ),
      );
    }

    for (final MachiReflector rf in scene.reflectors) {
      streak(rf.center, rf.width, rf.height, rf.color(frame), 0.32 * wet);
    }
    for (final MachiLamp lamp in scene.lamps) {
      if (lamp.radius <= 0) continue;
      final double s = lamp.strength(frame);
      streak(
        lamp.position,
        lamp.radius * 0.6,
        lamp.radius,
        lamp.color,
        0.4 * wet * s,
      );
    }
    canvas.restore();
  }
}
