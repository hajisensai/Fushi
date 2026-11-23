/// 背景层的共用骨架（folia `backgrounds/` 各背景共用的那部分）：一个场景对象每帧推进（动画时钟、
/// 平滑音频）再画一帧；封面 / 用户素材图的加载；封面代表色（median cut）；帧率无关的缓动与弹簧。
///
/// 背景各自挂一个 [LyricVisualizerFrame]（和样式的时钟同源：都读 `context.clock`），画家
/// `repaint: ticks`，不整树重建。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_cover.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

/// 一个背景的场景：宿主每帧先 [advance] 再 [paint]。异步资源（封面）到手时 `notifyListeners`
/// 触发重画。
abstract class LyricVisualizerBackgroundScene extends ChangeNotifier {
  /// 输入变了（样式 context / 背景参数 / 设备像素比）。首帧前也会调一次。
  void configure(
    LyricVisualizerContext context,
    LyricVisualizerTuning tuning,
    double devicePixelRatio,
  );

  /// 推进一帧（[tick.dt] 是墙钟步长，减弱动态效果时为 0）。
  void advance(LyricVisualizerTick tick);

  void paint(Canvas canvas, Size size);
}

/// 把一个场景挂成填满约束、不吃点击的 widget。
class LyricVisualizerBackgroundView extends StatefulWidget {
  const LyricVisualizerBackgroundView({
    super.key,
    required this.context,
    required this.tuning,
    required this.create,
  });

  final LyricVisualizerContext context;
  final LyricVisualizerTuning tuning;
  final LyricVisualizerBackgroundScene Function() create;

  @override
  State<LyricVisualizerBackgroundView> createState() =>
      _LyricVisualizerBackgroundViewState();
}

class _LyricVisualizerBackgroundViewState
    extends State<LyricVisualizerBackgroundView> {
  late final LyricVisualizerBackgroundScene _scene = widget.create();
  double _dpr = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    _scene.configure(widget.context, widget.tuning, _dpr);
  }

  @override
  void didUpdateWidget(covariant LyricVisualizerBackgroundView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scene.configure(widget.context, widget.tuning, _dpr);
  }

  @override
  void dispose() {
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LyricVisualizerFrame(
      context: widget.context,
      builder: (BuildContext _, LyricVisualizerTicks ticks) =>
          _SceneTicker(scene: _scene, ticks: ticks),
    ),
  );
}

class _SceneTicker extends StatefulWidget {
  const _SceneTicker({required this.scene, required this.ticks});

  final LyricVisualizerBackgroundScene scene;
  final LyricVisualizerTicks ticks;

  @override
  State<_SceneTicker> createState() => _SceneTickerState();
}

class _SceneTickerState extends State<_SceneTicker> {
  @override
  void initState() {
    super.initState();
    widget.ticks.addListener(_onTick);
    _onTick();
  }

  @override
  void didUpdateWidget(covariant _SceneTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticks != widget.ticks) {
      oldWidget.ticks.removeListener(_onTick);
      widget.ticks.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    widget.ticks.removeListener(_onTick);
    super.dispose();
  }

  // 画家的 repaint 监听在这之后注册，推进先于重画。
  void _onTick() => widget.scene.advance(widget.ticks.value);

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _ScenePainter(
      widget.scene,
      Listenable.merge(<Listenable>[widget.ticks, widget.scene]),
    ),
  );
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.scene, Listenable repaint) : super(repaint: repaint);

  final LyricVisualizerBackgroundScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    scene.paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) => old.scene != scene;
}

// ---------------------------------------------------------------------------
// 帧率无关的缓动 / 弹簧 / 颜色过渡
// ---------------------------------------------------------------------------

/// folia 按 60 fps 每帧 `x += (t - x) * perFrame`；换成按墙钟 [dt] 的等效系数。
double lyricBgEaseFactor(double perFrame, double dt) {
  if (dt <= 0) return 0;
  return 1 - math.pow(1 - perFrame.clamp(0.0, 1.0), dt * 60).toDouble();
}

/// `current` 朝 `target` 走一帧（[lyricBgEaseFactor]）。
double lyricBgEase(double current, double target, double perFrame, double dt) =>
    current + (target - current) * lyricBgEaseFactor(perFrame, dt);

/// framer-motion `useSpring` 同型的阻尼弹簧（质量 1）。
class LyricBgSpring {
  LyricBgSpring({this.stiffness = 300, this.damping = 30, double initial = 0})
    : value = initial;

  final double stiffness;
  final double damping;
  double value;
  double _velocity = 0;

  /// 朝 [target] 积分 [dt] 秒（分成 ≤ 1/240 秒的小步，硬弹簧也稳）。
  void step(double target, double dt) {
    if (dt <= 0) return;
    final int steps = math.max(1, (dt * 240).ceil());
    final double h = dt / steps;
    for (int i = 0; i < steps; i++) {
      final double force = -stiffness * (value - target) - damping * _velocity;
      _velocity += force * h;
      value += _velocity * h;
    }
  }

  void snap(double v) {
    value = v;
    _velocity = 0;
  }
}

/// 颜色朝目标过渡（folia `useBlendedColors`：换主题时约 1 秒混过去，ease-out）。
class LyricBgColorBlend {
  LyricBgColorBlend(Color initial) : _from = initial, _to = initial;

  Color _from;
  Color _to;
  double _t = 1;

  /// 混合时长（秒）。
  static const double seconds = 1;

  Color get value => _t >= 1
      ? _to
      : Color.lerp(_from, _to, 1 - math.pow(1 - _t, 3).toDouble())!;

  /// 设目标；[immediate] 时直接跳过去（首帧 / 减弱动态效果）。
  void target(Color c, {bool immediate = false}) {
    if (c == _to) return;
    if (immediate) {
      _from = c;
      _to = c;
      _t = 1;
      return;
    }
    _from = value;
    _to = c;
    _t = 0;
  }

  void advance(double dt) {
    if (_t >= 1) return;
    _t = dt <= 0 ? _t : math.min(1, _t + dt / seconds);
  }
}

/// 0–1 的音频量 → folia 的 0–255 刻度（它的频段 / 响度都在这个刻度上做映射）。
double lyricBgByte(double v) => (v * 255).clamp(0.0, 255.0);

/// CSS `smoothstep`。
double lyricBgSmoothstep(double e0, double e1, double x) {
  final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// GLSL `fract(sin(dot(p, (127.1, 311.7))) * 43758.5453123)`。
double lyricBgHash2(double x, double y) {
  final double v = math.sin(x * 127.1 + y * 311.7) * 43758.5453123;
  return v - v.floorToDouble();
}

/// 图按 `object-fit: cover` 铺进 [dst]（[alignX] 0 左 0.5 中 1 右）。
Rect lyricBgCoverRect(Size src, Rect dst, {double alignX = 0.5}) {
  final double scale = math.max(dst.width / src.width, dst.height / src.height);
  final double w = src.width * scale;
  final double h = src.height * scale;
  return Rect.fromLTWH(
    dst.left + (dst.width - w) * alignX,
    dst.top + (dst.height - h) / 2,
    w,
    h,
  );
}

// ---------------------------------------------------------------------------
// 图源：封面 / 用户素材（folia「封面 / 自定义图片」）
// ---------------------------------------------------------------------------

/// 背景用户素材在素材库里的目录（莫奈 / 漫游 / 自定义图片三个背景共用，folia 也是共用一张上传图）。
const String kLyricVisualizerBackgroundAssetStyle = 'backgrounds';

/// 图片来源参数值：封面。
const String kLyricBgSourceCover = 'cover-derived';

/// 图片来源参数值：用户素材。
const String kLyricBgSourceUploaded = 'uploaded-global';

/// 「图片来源」参数（folia `backgroundSource` / `imageSource`）。
LyricVisualizerChoiceSpec lyricBgImageSourceSpec(String key) =>
    LyricVisualizerChoiceSpec(
      key: key,
      label: () => t.music_visualizer_background_image_source,
      options: <(String, String Function())>[
        (kLyricBgSourceCover, () => t.music_visualizer_background_source_cover),
        (
          kLyricBgSourceUploaded,
          () => t.music_visualizer_background_source_uploaded,
        ),
      ],
      initial: kLyricBgSourceCover,
    );

/// 用户素材包参数（面板里能加图 / 删图）。
LyricVisualizerAssetPackSpec lyricBgImagePackSpec(
  String key, {
  bool Function(LyricVisualizerTuning values)? visibleWhen,
}) => LyricVisualizerAssetPackSpec(
  key: key,
  label: () => t.music_visualizer_background_image_pack,
  style: kLyricVisualizerBackgroundAssetStyle,
  maxFiles: 16,
  visibleWhen: visibleWhen,
);

/// 包里最新导入的那张图（导入时文件名带序号前缀，排序最后的最新）；没有 / 读不了为 null。
Future<File?> lyricBgLatestPackImage(
  String pack, {
  Future<LyricVisualizerAssetStore> Function() open =
      LyricVisualizerAssetStore.open,
}) async {
  try {
    final LyricVisualizerAssetStore store = await open();
    final List<File> files = await store.list(
      kLyricVisualizerBackgroundAssetStyle,
      pack,
    );
    return files.isEmpty ? null : files.last;
  } on Object {
    // 素材库不可用（无数据目录 / 包名非法）：按「没有自定义图」处理。
    return null;
  }
}

/// 背景要画的那张图：[select] 给出封面路径与素材偏好，自己解析成实际地址再交给
/// [LyricVisualizerImageLoader]。与 folia `resolveMonetSourceUrl` 同规则：选了自定义图但包是空的
/// 回落封面；选了封面但没有封面时回落自定义图。
class LyricBgImageSource extends ChangeNotifier {
  LyricBgImageSource({this.openStore = LyricVisualizerAssetStore.open}) {
    _loader.addListener(notifyListeners);
  }

  final Future<LyricVisualizerAssetStore> Function() openStore;
  final LyricVisualizerImageLoader _loader = LyricVisualizerImageLoader();
  String? _coverPath;
  String? _pack;
  bool _preferPack = false;
  String? _packFile;
  int _generation = 0;
  bool _disposed = false;

  ui.Image? get image => _loader.image;

  /// 当前图的地址（封面路径或素材文件路径）。
  String? get path => _loader.path;

  /// 设来源。[pack] 为 null 时不查素材库（只用封面）。
  void select({
    required String? coverPath,
    String? pack,
    bool preferPack = false,
  }) {
    final bool packChanged = pack != _pack;
    _coverPath = coverPath;
    _preferPack = preferPack;
    _pack = pack;
    if (packChanged) {
      _packFile = null;
      final int gen = ++_generation;
      if (pack != null) {
        unawaited(
          lyricBgLatestPackImage(pack, open: openStore).then((File? f) {
            if (_disposed || gen != _generation) return;
            _packFile = f?.path;
            _apply();
          }),
        );
      }
    }
    _apply();
  }

  void _apply() {
    final String? cover = (_coverPath?.isEmpty ?? true) ? null : _coverPath;
    final String? chosen = _preferPack
        ? (_packFile ?? cover)
        : (cover ?? _packFile);
    _loader.load(chosen);
  }

  @override
  void dispose() {
    _disposed = true;
    _loader.removeListener(notifyListeners);
    _loader.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 封面代表色（folia `colorPalette.ts` 的加权 median cut）
// ---------------------------------------------------------------------------

class _WeightedColor {
  _WeightedColor(this.r, this.g, this.b, this.weight);

  double r;
  double g;
  double b;
  int weight;
}

double _channel(_WeightedColor c, int ch) => ch == 0
    ? c.r
    : ch == 1
    ? c.g
    : c.b;

double _range(List<_WeightedColor> colors, int ch) {
  double lo = 255;
  double hi = 0;
  for (final _WeightedColor c in colors) {
    final double v = _channel(c, ch);
    lo = math.min(lo, v);
    hi = math.max(hi, v);
  }
  return hi - lo;
}

int _weightOf(List<_WeightedColor> colors) =>
    colors.fold<int>(0, (int s, _WeightedColor c) => s + c.weight);

/// RGBA8888 像素 → 面积加权的代表色（大块区域优先，按权重降序）。半透明（alpha < 128）跳过。
List<Color> lyricBgRepresentativeColors(Uint8List rgba, int count) {
  if (count <= 0) return const <Color>[];
  final Map<int, _WeightedColor> histogram = <int, _WeightedColor>{};
  for (int i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final int r = rgba[i];
    final int g = rgba[i + 1];
    final int b = rgba[i + 2];
    final int key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    final _WeightedColor? e = histogram[key];
    if (e == null) {
      histogram[key] = _WeightedColor(
        r.toDouble(),
        g.toDouble(),
        b.toDouble(),
        1,
      );
    } else {
      e.r += r;
      e.g += g;
      e.b += b;
      e.weight += 1;
    }
  }
  final List<_WeightedColor> colors = <_WeightedColor>[
    for (final _WeightedColor c in histogram.values)
      _WeightedColor(
        (c.r / c.weight).roundToDouble(),
        (c.g / c.weight).roundToDouble(),
        (c.b / c.weight).roundToDouble(),
        c.weight,
      ),
  ];
  if (colors.isEmpty) return const <Color>[];
  final List<List<_WeightedColor>> buckets = <List<_WeightedColor>>[colors];
  while (buckets.length < math.min(count, colors.length)) {
    int pick = -1;
    double best = -1;
    for (int i = 0; i < buckets.length; i++) {
      final List<_WeightedColor> bucket = buckets[i];
      if (bucket.length < 2) continue;
      final double widest = math.max(
        _range(bucket, 0),
        math.max(_range(bucket, 1), _range(bucket, 2)),
      );
      final double score = widest * math.sqrt(_weightOf(bucket));
      if (score > best) {
        best = score;
        pick = i;
      }
    }
    if (pick < 0) break;
    final List<_WeightedColor> bucket = buckets[pick];
    int ch = 0;
    double widest = _range(bucket, 0);
    for (int c = 1; c < 3; c++) {
      final double r = _range(bucket, c);
      if (r > widest) {
        widest = r;
        ch = c;
      }
    }
    final List<_WeightedColor> sorted = <_WeightedColor>[...bucket]
      ..sort(
        (_WeightedColor a, _WeightedColor b) =>
            _channel(a, ch).compareTo(_channel(b, ch)),
      );
    final double midpoint = _weightOf(bucket) / 2;
    int acc = 0;
    int split = 1;
    for (int i = 0; i < sorted.length - 1; i++) {
      acc += sorted[i].weight;
      split = i + 1;
      if (acc >= midpoint) break;
    }
    buckets.replaceRange(pick, pick + 1, <List<_WeightedColor>>[
      sorted.sublist(0, split),
      sorted.sublist(split),
    ]);
  }
  final List<_WeightedColor> averaged = <_WeightedColor>[
    for (final List<_WeightedColor> bucket in buckets)
      () {
        final int w = _weightOf(bucket);
        double r = 0;
        double g = 0;
        double b = 0;
        for (final _WeightedColor c in bucket) {
          r += c.r * c.weight;
          g += c.g * c.weight;
          b += c.b * c.weight;
        }
        return _WeightedColor(
          (r / w).roundToDouble(),
          (g / w).roundToDouble(),
          (b / w).roundToDouble(),
          w,
        );
      }(),
  ]..sort((_WeightedColor a, _WeightedColor b) => b.weight - a.weight);
  return <Color>[
    for (final _WeightedColor c in averaged)
      Color.fromARGB(255, c.r.toInt(), c.g.toInt(), c.b.toInt()),
  ];
}

/// 把图缩到 50×50（folia `loadImagePixels` 同尺寸）后取代表色。
Future<List<Color>> lyricBgRepresentativeColorsOf(
  ui.Image image,
  int count,
) async {
  const int side = 50;
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    const Rect.fromLTWH(0, 0, side * 1.0, side * 1.0),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final ui.Picture picture = rec.endRecording();
  final ui.Image small = await picture.toImage(side, side);
  picture.dispose();
  try {
    final ByteData? data = await small.toByteData();
    if (data == null) return const <Color>[];
    return lyricBgRepresentativeColors(data.buffer.asUint8List(), count);
  } finally {
    small.dispose();
  }
}
