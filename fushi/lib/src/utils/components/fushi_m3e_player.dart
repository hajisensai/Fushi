import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable, immutable;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

// M3 Expressive 播放器公共件：歌词模式（MD3）与手机字幕遥控器共用。
//
// 从 `lyrics_player_md3.dart` 原样抽出（行为与像素不变）：封面取色流动 mesh
// 背景、波浪进度条、形变播放键、上一句 / 播放 / 下一句按钮组。这里不认识任何
// 业务对象——播放位置经 [FushiPlaybackClock] 读，操作全是回调。

/// 播放位置读口：进度条按帧 / 按定时器轮询（只读、无副作用）。
abstract interface class FushiPlaybackClock {
  /// 当前播放位置。
  Duration get position;

  /// 总时长；未知为 [Duration.zero]。
  Duration get duration;
}

/// 时长显示：`m:ss`，满 1 小时 `h:mm:ss`。
String formatFushiPlaybackTime(Duration d) {
  final int total = math.max(0, d.inSeconds);
  final int h = total ~/ 3600;
  final int m = total ~/ 60 % 60;
  final int s = total % 60;
  final String ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

// ---------------------------------------------------------------------------
// 背景：封面动态色的流动 mesh
// ---------------------------------------------------------------------------

/// 背景流动一周的时长：几十秒一圈，慢到不抢正文的注意力。
const Duration _kMeshPeriod = Duration(seconds: 48);

/// mesh 重画间隔（≈30fps）。
const int _kMeshFrameMicros = 33000;

/// 本帧的 vsync 时刻（微秒）。同一帧里所有回调读到同一个值：页面与桌面标题栏
/// 里的两份 mesh 背景按它取相位，同一帧必然同相位，接缝处连续。
int _frameClockMicros() =>
    SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;

/// 按最小间隔要帧的驱动：等到 [interval] 的下一个档位（按本帧 vsync 时刻
/// [_frameClockMicros] 对齐，多个实例落在同一帧）才 `scheduleFrameCallback`
/// 要一帧，帧回调里跑 [onFrame] 再排下一次。
///
/// 为什么不用 [Ticker]：Ticker 只要在跑，每个 vsync 都要一帧；而
/// `RendererBinding.drawFrame` 即使没有脏节点也照样 `compositeFrame` 把整棵层树
/// 送去栅格化——120Hz 屏上就是每秒 120 次整屏重画（mesh 的整屏径向渐变、封面
/// 投影、平台视图合成），回调里自己按 33ms 跳过更新也省不掉这些帧。这里改成真正
/// 只在需要时要帧。后台 / 熄屏时引擎不出帧，帧回调不来，链条自然停住，恢复出帧
/// 后接着跑，不会在后台空转定时器。
class _ThrottledFrameDriver {
  _ThrottledFrameDriver({required this.interval, required this.onFrame});

  final Duration interval;
  final void Function(int frameMicros) onFrame;

  Timer? _timer;
  int? _callbackId;
  bool _active = false;

  bool get isActive => _active;

  void start() {
    if (_active) return;
    _active = true;
    _requestFrame();
  }

  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    final int? id = _callbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _callbackId = null;
    }
  }

  void _requestFrame() {
    _callbackId = SchedulerBinding.instance.scheduleFrameCallback(_handleFrame);
  }

  void _handleFrame(Duration _) {
    _callbackId = null;
    if (!_active) return;
    final int now = _frameClockMicros();
    onFrame(now);
    if (!_active) return;
    final int step = interval.inMicroseconds;
    final int wait = step - now % step;
    _timer = Timer(Duration(microseconds: wait), () {
      _timer = null;
      if (_active) _requestFrame();
    });
  }
}

/// 底板圆角：MD3 extra-large（28，与底部弹层同档）。
const double _kPlateRadius = FushiRadii.sheetValue;

/// 底板矩形解析：[page] 是页面尺寸，[padding] 是系统安全区。
/// 返回 null = 不画底板。
typedef FushiMeshPlateResolver = Rect? Function(Size page, EdgeInsets padding);

/// 不透明背景：surface 底上叠四团缓慢漂移的径向渐变（primary / tertiary /
/// secondary 容器色 + 一团低透明 primary），可再垫一块半透明底板。动效关闭
/// （减少动态效果 / 墨水屏）或 [animate] = false 时静止在相位 0。
class FushiMeshBackdrop extends StatefulWidget {
  const FushiMeshBackdrop({
    super.key,
    this.plateRect,
    this.animate = true,
    this.colorTransition = false,
  });

  /// 底板矩形（页面坐标）；null / 返回 null = 不画。
  final FushiMeshPlateResolver? plateRect;

  /// false = 整张背景静止在相位 0（不起 Ticker）：手机遥控器这类长时间常亮页面
  /// 不为背景流动白花 GPU。
  final bool animate;

  /// true = 配色变化（封面取色到达、换书换章取色变了、主题 / 深浅色切换）时用
  /// [FushiMotion.medium] 做一次交叉过渡，过渡完就停、不再出帧；减弱动态效果时
  /// 直接切换。false（默认）= 配色变了下一帧直接换（原行为）。歌词模式用
  /// `animate: false` + 这个：静态网格渐变，只在颜色变化时动一下。
  final bool colorTransition;

  @override
  State<FushiMeshBackdrop> createState() => _FushiMeshBackdropState();
}

class _FushiMeshBackdropState extends State<FushiMeshBackdrop> {
  /// 按 33ms 档位要帧（不用 Ticker：Ticker 一开就逐 vsync 出整帧，见
  /// [_ThrottledFrameDriver]）。
  late final _ThrottledFrameDriver _driver = _ThrottledFrameDriver(
    interval: const Duration(microseconds: _kMeshFrameMicros),
    onFrame: _onFrame,
  );

  /// 流动相位（0–1，一周 [_kMeshPeriod]）。只驱动画家重绘，不重建。
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);

  /// 低分辨率渐变图缓存（见 [_MeshImageCache]）。
  final _MeshImageCache _cache = _MeshImageCache();
  int _lastFrame = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant FushiMeshBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncTicker();
  }

  void _syncTicker() {
    // TickerMode 照旧生效（被别的路由盖住时停）：driver 不是 Ticker，要自己读。
    final bool motion =
        widget.animate &&
        fushiExpressiveMotionEnabled(context) &&
        TickerMode.valuesOf(context).enabled;
    if (motion && !_driver.isActive) {
      _lastFrame = -1;
      _driver.start();
    } else if (!motion && _driver.isActive) {
      _driver.stop();
      _phase.value = 0;
    }
  }

  void _onFrame(int frameMicros) {
    // 漂移极慢，30fps 足够顺；整屏渐变每帧重画是白花 GPU。相位取本帧 vsync 时刻
    // 并量化到 33ms 一档。
    final int frame = frameMicros ~/ _kMeshFrameMicros;
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    _phase.value =
        (frame * _kMeshFrameMicros / _kMeshPeriod.inMicroseconds) % 1.0;
  }

  @override
  void dispose() {
    _driver.stop();
    _phase.dispose();
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    final bool dark = cs.brightness == Brightness.dark;
    // 缓存小图的分辨率（图像素 / 逻辑像素）。静止时只画一次，按物理像素全分辨率
    // 画：低分辨率图拉伸到整屏，8-bit 量化的渐变经双线性插值会露出菱形网格，
    // 静止不动时网格钉在屏幕上（BUG-3933）。流动时网格随相位漂移看不出，仍按
    // [_kMeshAnimatedTexelPx] 个**物理**像素一个纹素降采样省 GPU。
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final double rasterScale = _driver.isActive
        ? devicePixelRatio / _kMeshAnimatedTexelPx
        : devicePixelRatio;
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          final Rect? plate = widget.plateRect?.call(size, padding);
          final _MeshColors target = _MeshColors(
            base: cs.surface,
            blobs: <Color>[
              cs.primaryContainer.withValues(alpha: dark ? 0.85 : 0.9),
              cs.tertiaryContainer.withValues(alpha: dark ? 0.75 : 0.8),
              cs.secondaryContainer.withValues(alpha: dark ? 0.7 : 0.75),
              cs.primary.withValues(alpha: dark ? 0.22 : 0.16),
            ],
            // 底板：surfaceContainerLow 档（令牌 group）半透明，透出流动
            // 背景又压住对比度。
            plate: tokens.surfaces.group.withValues(alpha: dark ? 0.5 : 0.55),
          );
          Widget paint(_MeshColors colors) => CustomPaint(
            size: size,
            isComplex: true,
            painter: _MeshPainter(
              phase: _phase,
              cache: _cache,
              rasterScale: rasterScale,
              base: colors.base,
              blobs: colors.blobs,
              plate: plate,
              plateColor: colors.plate,
            ),
          );
          if (!widget.colorTransition) return paint(target);
          // 几何（相位）不变、只换颜色：逐色线性插值与两张渐变交叉淡化等价，
          // 且只在过渡期间出帧（TweenAnimationBuilder 到终点即停 Ticker）。
          return TweenAnimationBuilder<_MeshColors>(
            tween: _MeshColorsTween(end: target),
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            builder: (BuildContext context, _MeshColors colors, _) =>
                paint(colors),
          );
        },
      ),
    );
  }
}

/// 网格背景的一套配色（底色 + 四团 + 底板）。
@immutable
class _MeshColors {
  const _MeshColors({
    required this.base,
    required this.blobs,
    required this.plate,
  });

  final Color base;
  final List<Color> blobs;
  final Color plate;

  static _MeshColors lerp(_MeshColors a, _MeshColors b, double t) {
    if (a.blobs.length != b.blobs.length) return t < 0.5 ? a : b;
    return _MeshColors(
      base: Color.lerp(a.base, b.base, t)!,
      blobs: <Color>[
        for (int i = 0; i < a.blobs.length; i++)
          Color.lerp(a.blobs[i], b.blobs[i], t)!,
      ],
      plate: Color.lerp(a.plate, b.plate, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _MeshColors &&
      other.base == base &&
      other.plate == plate &&
      _MeshPainter._sameColors(other.blobs, blobs);

  @override
  int get hashCode => Object.hash(base, plate, Object.hashAll(blobs));
}

class _MeshColorsTween extends Tween<_MeshColors> {
  _MeshColorsTween({super.end});

  @override
  _MeshColors lerp(double t) => _MeshColors.lerp(begin ?? end!, end!, t);
}

class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.phase,
    required this.cache,
    required this.rasterScale,
    required this.base,
    required this.blobs,
    required this.plate,
    required this.plateColor,
  }) : super(repaint: phase);

  final ValueListenable<double> phase;
  final _MeshImageCache cache;

  /// 缓存图分辨率：图像素 / 逻辑像素（见 [_MeshImageCache.resolve]）。
  final double rasterScale;
  final Color base;
  final List<Color> blobs;
  final Rect? plate;
  final Color plateColor;

  // 每团的轨迹：中心 = (0.5 + ax·sin(2π·fx·t + px), 0.5 + ay·cos(2π·fy·t + py))，
  // fx / fy 取整数，一周后回到原点（循环无缝）。半径按对角线比例并缓慢呼吸。
  static const List<
    ({double ax, double ay, int fx, int fy, double px, double py, double r})
  >
  _orbits =
      <
        ({double ax, double ay, int fx, int fy, double px, double py, double r})
      >[
        (ax: 0.32, ay: 0.28, fx: 1, fy: 1, px: 0.0, py: 0.0, r: 0.62),
        (ax: 0.36, ay: 0.3, fx: 1, fy: 2, px: 2.1, py: 1.3, r: 0.55),
        (ax: 0.3, ay: 0.34, fx: 2, fy: 1, px: 4.2, py: 2.9, r: 0.5),
        (ax: 0.4, ay: 0.36, fx: 1, fy: 1, px: 3.3, py: 4.6, r: 0.42),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    // 整屏四团径向渐变按 [rasterScale] 画成一张图缓存起来，这里只贴图
    // （Impeller 没有栅格缓存：直接整屏画渐变的话，页面上任何一处每帧变化——
    // 歌词逐帧擦色、进度条——都会让四个整屏 shader 跟着重新栅格化，宽屏高刷下
    // 就是音乐歌词页的卡顿）。
    final ui.Image? image = cache.resolve(
      size,
      phase.value,
      rasterScale,
      (Canvas c, Size s) => _paintMesh(c, s, phase.value, base, blobs),
    );
    if (image == null) {
      _paintMesh(canvas, size, phase.value, base, blobs);
    } else {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        bounds,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    final Rect? plate = this.plate;
    if (plate != null && plate.width > 1 && plate.height > 1) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(plate, const Radius.circular(_kPlateRadius)),
        Paint()..color = plateColor,
      );
    }
  }

  static void _paintMesh(
    Canvas canvas,
    Size size,
    double phase,
    Color base,
    List<Color> blobs,
  ) {
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = base);
    final double t = phase * 2 * math.pi;
    final double diag = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    for (int i = 0; i < blobs.length && i < _orbits.length; i++) {
      final ({
        double ax,
        double ay,
        int fx,
        int fy,
        double px,
        double py,
        double r,
      })
      o = _orbits[i];
      final Offset center = Offset(
        size.width * (0.5 + o.ax * math.sin(o.fx * t + o.px)),
        size.height * (0.5 + o.ay * math.cos(o.fy * t + o.py)),
      );
      final double radius = diag * o.r * (1 + 0.08 * math.sin(t + i));
      final Rect circle = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[blobs[i], blobs[i].withValues(alpha: 0)],
          ).createShader(circle),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter old) {
    // 配色变了小图要重画（相位变化由 [_MeshImageCache] 自己按相位值判断）。
    final bool colors = old.base != base || !_sameColors(old.blobs, blobs);
    if (colors) cache.invalidate();
    return colors ||
        old.phase != phase ||
        old.rasterScale != rasterScale ||
        old.plate != plate ||
        old.plateColor != plateColor;
  }

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// 波浪进度条
// ---------------------------------------------------------------------------

/// 静态波形（[FushiWavySeekBar.animateWave] = false）时的位置轮询间隔。
const Duration _kStaticWavePoll = Duration(milliseconds: 250);

/// M3 Expressive 波浪进度条。共享的 FushiWavyLinearProgress 不能变平、没有
/// thumb，这里自绘：已播段是正弦波（播放中流动，暂停时振幅弹簧收到 0 变直线），
/// 未播段是平直轨道 + 尾端停止点，中间一根竖条 thumb（拖动时变粗变高），拖动时
/// thumb 上方冒时长气泡，松手才 [onSeek]。下方左右两端是已播 / -剩余。
///
/// 播放中波浪按 ≈30fps 流动（[_ThrottledFrameDriver]，不是逐 vsync 的 Ticker：
/// 波浪 2.4 秒才流过一个 40px 波长，每帧只挪零点几像素，逐 vsync 重画看不出差别，
/// 却让整屏每秒多合成几十到上百帧），顺带读 [FushiPlaybackClock.position]；振幅
/// 弹簧 / 拖动这些短暂过渡期才用 vsync Ticker。重画只落在自带的 RepaintBoundary
/// 里，不连带外层卡片、封面投影一起重录。暂停时降到每 400ms 轮询一次（还要跟上
/// 外部跳转）。←/→ 键前后跳 5 秒。
///
/// [onSeek] 为 null 时只显示进度（不可拖、不可聚焦）。[animateWave] = false 时
/// 波形静止（不流动，振幅照样随播放态弹簧收放），位置每 250ms 轮询一次——
/// 常亮的遥控页不为一条进度条逐帧重建。
///
/// 给了 [clockListenable]（位置变化的推送源）时，位置改由它的通知驱动，**不再起任何
/// 轮询定时器**；帧驱动只负责波浪流动 / 振幅弹簧 / 拖动这些纯动画。
class FushiWavySeekBar extends StatefulWidget {
  const FushiWavySeekBar({
    super.key,
    required this.clock,
    required this.isPlaying,
    required this.onSeek,
    required this.strokeWidth,
    required this.barHeight,
    this.animateWave = true,
    this.showTimes = true,
    this.debugLabel = 'fushi-wavy-seek',
    this.clockListenable,
  });

  final FushiPlaybackClock clock;
  final bool isPlaying;
  final ValueChanged<Duration>? onSeek;
  final double strokeWidth;
  final double barHeight;
  final bool animateWave;

  /// 下方「已播 / -剩余」两端时间。
  final bool showTimes;

  /// 焦点节点调试名。
  final String debugLabel;

  /// [clock] 位置 / 时长变化时通知；null = 没有推送源，按上面的节奏轮询 [clock]。
  final Listenable? clockListenable;

  @override
  State<FushiWavySeekBar> createState() => _FushiWavySeekBarState();
}

class _FushiWavySeekBarState extends State<FushiWavySeekBar>
    with TickerProviderStateMixin {
  /// 只在过渡期（振幅弹簧 / 拖动 / thumb 弹簧）跑的逐 vsync 驱动。
  late final Ticker _ticker = createTicker(_onTick);

  /// 稳态波浪流动（≈30fps）。
  late final _ThrottledFrameDriver _flow = _ThrottledFrameDriver(
    interval: const Duration(microseconds: _kMeshFrameMicros),
    onFrame: _advance,
  );

  bool _tickerModeEnabled = true;
  late final FushiSpring _amp = FushiSpring(
    vsync: this,
    spring: fushiExpressiveDefaultSpatial,
  );
  late final FushiSpring _drag = FushiSpring(vsync: this);
  late final FocusNode _focusNode = FocusNode(debugLabel: widget.debugLabel);
  Timer? _idlePoll;
  Duration? _idlePollInterval;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _phase = 0;

  /// 拖动中的比例（null = 没在拖）。
  double? _dragFraction;

  /// 刚松手 / 按键跳转的目标：播放器回报位置追上来之前先显示它，免得 thumb
  /// 弹回旧位置再跳过去。
  Duration? _pendingSeek;
  DateTime _pendingAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _focused = false;

  bool get _seekable => widget.onSeek != null;

  @override
  void initState() {
    super.initState();
    _position = widget.clock.position;
    _duration = widget.clock.duration;
    widget.clockListenable?.addListener(_onClockChanged);
  }

  /// 推送源通知：读一次时钟，有变化才重建（拖动中不打断拖动显示）。
  void _onClockChanged() {
    if (!mounted) return;
    if (_readClock()) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncMotion(animate: false);
  }

  @override
  void didUpdateWidget(covariant FushiWavySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.animateWave != widget.animateWave) {
      _syncMotion(animate: true);
    }
    if (!identical(oldWidget.clockListenable, widget.clockListenable)) {
      oldWidget.clockListenable?.removeListener(_onClockChanged);
      widget.clockListenable?.addListener(_onClockChanged);
      _syncMotion(animate: false);
    }
    if (!identical(oldWidget.clock, widget.clock)) _readClock();
  }

  bool get _motion => fushiExpressiveMotionEnabled(context);

  /// 播放态 → 振幅目标 + 刷新节奏。波浪只在「播放中且允许动效」时有。
  void _syncMotion({required bool animate}) {
    final bool wave = widget.isPlaying && _motion;
    _amp.animateTo(wave ? 1 : 0, animate: animate && _motion);
    if (_amp.animation.isAnimating && !_ticker.isActive) _ticker.start();
    _syncSteady();
  }

  /// 过渡期（振幅 / thumb 弹簧在动、正在拖）需要逐 vsync 重建。
  bool get _transient =>
      _amp.animation.isAnimating ||
      _drag.animation.isAnimating ||
      _dragFraction != null;

  /// 过渡期之外的刷新：播放中波浪流动走 ≈30fps 驱动（顺带读位置）；否则位置按
  /// 轮询 / 推送源刷新。过渡期 Ticker 在跑时两者都停。
  void _syncSteady() {
    if (_ticker.isActive) {
      _flow.stop();
      _stopIdlePoll();
      return;
    }
    final bool flowing =
        widget.animateWave && widget.isPlaying && _motion && _tickerModeEnabled;
    if (flowing) {
      _stopIdlePoll();
      _flow.start();
      return;
    }
    _flow.stop();
    _startIdlePoll(
      widget.animateWave ? const Duration(milliseconds: 400) : _kStaticWavePoll,
    );
  }

  void _stopIdlePoll() {
    _idlePoll?.cancel();
    _idlePoll = null;
  }

  void _startIdlePoll(Duration interval) {
    if (widget.clockListenable != null) return; // 有推送源：位置不靠轮询。
    if (_idlePoll != null && _idlePollInterval == interval) return;
    _idlePoll?.cancel();
    _idlePollInterval = interval;
    _idlePoll = Timer.periodic(interval, (_) {
      if (!mounted) return;
      if (_readClock()) setState(() {});
    });
  }

  /// 读一次时钟；有变化返回 true。
  bool _readClock() {
    final Duration p = widget.clock.position;
    final Duration d = widget.clock.duration;
    final Duration? pending = _pendingSeek;
    if (pending != null) {
      final bool caughtUp = (p - pending).abs() < const Duration(seconds: 2);
      final bool stale =
          DateTime.now().difference(_pendingAt) > const Duration(seconds: 1);
      if (caughtUp || stale) _pendingSeek = null;
    }
    final bool changed = p != _position || d != _duration;
    _position = p;
    _duration = d;
    return changed;
  }

  void _onTick(Duration _) {
    _advance(_frameClockMicros());
    if (!_transient) {
      _ticker.stop();
      _syncSteady();
    }
  }

  /// 推进一帧：波浪相位 + 读位置 + 重建这一小块。相位取本帧 vsync 时刻，跨
  /// Ticker / 稳态驱动切换连续，不随重启归零。
  void _advance(int frameMicros) {
    if (!mounted) return;
    if (widget.animateWave) {
      // 一个波长约 2.4 秒流过（慢而可感）。
      _phase = frameMicros / 1e6 * (2 * math.pi / 2.4);
    }
    _readClock();
    setState(() {});
  }

  @override
  void dispose() {
    widget.clockListenable?.removeListener(_onClockChanged);
    _ticker.dispose();
    _flow.stop();
    _idlePoll?.cancel();
    _amp.dispose();
    _drag.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  double get _shownFraction {
    final double? drag = _dragFraction;
    if (drag != null) return drag;
    final int total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    final Duration pos = _pendingSeek ?? _position;
    return (pos.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration get _shownPosition {
    final double? drag = _dragFraction;
    if (drag != null) return _duration * drag;
    return _pendingSeek ?? _position;
  }

  double _fractionAt(double dx, double width) {
    if (width <= 0) return 0;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final double f = (dx / width).clamp(0.0, 1.0);
    return rtl ? 1 - f : f;
  }

  void _beginDrag(double fraction) {
    if (_duration <= Duration.zero) return;
    setState(() => _dragFraction = fraction);
    _drag.animateTo(1, animate: _motion);
    if (!_ticker.isActive) _ticker.start();
    _syncSteady();
  }

  void _endDrag({required bool commit}) {
    final double? fraction = _dragFraction;
    if (fraction == null) return;
    _drag.animateTo(0, animate: _motion);
    setState(() {
      _dragFraction = null;
      if (commit) {
        final Duration target = _duration * fraction;
        _pendingSeek = target;
        _pendingAt = DateTime.now();
        widget.onSeek?.call(target);
      }
    });
  }

  void _seekBy(Duration delta) {
    if (_duration <= Duration.zero) return;
    final Duration base = _pendingSeek ?? _position;
    Duration target = base + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;
    setState(() {
      _pendingSeek = target;
      _pendingAt = DateTime.now();
    });
    widget.onSeek?.call(target);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    const Duration step = Duration(seconds: 5);
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _seekBy(rtl ? -step : step);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _seekBy(rtl ? step : -step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final double fraction = _shownFraction;
    final Duration shown = _shownPosition;
    final Duration remaining = _duration > shown
        ? _duration - shown
        : Duration.zero;
    final TextStyle? timeStyle = theme.textTheme.labelMedium?.copyWith(
      color: cs.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final bool seekable = _seekable;
    final Widget bar = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double half = widget.strokeWidth / 2;
        final double usable = math.max(0, width - widget.strokeWidth);
        final double thumbX = rtl
            ? width - half - usable * fraction
            : half + usable * fraction;
        final double drag = _drag.value.clamp(0.0, 1.2);
        // 波浪逐帧重画只落在这一层，不连带时间文字 / 外层卡片重录。
        final Widget paint = RepaintBoundary(
          child: CustomPaint(
            size: Size(width, widget.barHeight),
            painter: _SeekPainter(
              fraction: fraction,
              phase: _phase,
              amplitude: 4 * _amp.value.clamp(0.0, 1.2),
              strokeWidth: widget.strokeWidth,
              activeColor: cs.primary,
              trackColor: cs.secondaryContainer,
              thumbWidth: 4 + 2 * drag,
              thumbHeight: widget.barHeight * (0.6 + 0.25 * drag),
              focused: _focused,
              rtl: rtl,
            ),
          ),
        );
        if (!seekable) return paint;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (TapDownDetails d) =>
                  _beginDrag(_fractionAt(d.localPosition.dx, width)),
              onTapUp: (_) => _endDrag(commit: true),
              onTapCancel: () => _endDrag(commit: false),
              onHorizontalDragStart: (DragStartDetails d) =>
                  _beginDrag(_fractionAt(d.localPosition.dx, width)),
              onHorizontalDragUpdate: (DragUpdateDetails d) {
                if (_dragFraction == null) return;
                setState(
                  () => _dragFraction = _fractionAt(d.localPosition.dx, width),
                );
              },
              onHorizontalDragEnd: (_) => _endDrag(commit: true),
              onHorizontalDragCancel: () => _endDrag(commit: false),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: paint,
              ),
            ),
            // 拖动时的时长气泡（M3 slider value indicator：inverseSurface 胶囊）。
            Positioned(
              left: thumbX - 40,
              bottom: widget.barHeight - 2,
              width: 80,
              child: IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _dragFraction == null ? 0 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: AnimatedScale(
                      scale: _dragFraction == null ? 0.6 : 1,
                      alignment: Alignment.bottomCenter,
                      duration: FushiMotion.medium,
                      curve: FushiSpringCurve.spatialFast,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: cs.inverseSurface,
                          shape: const StadiumBorder(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Text(
                            formatFushiPlaybackTime(shown),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: cs.onInverseSurface,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    final Widget column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: widget.barHeight, child: bar),
        if (widget.showTimes)
          Row(
            children: <Widget>[
              Text(formatFushiPlaybackTime(shown), style: timeStyle),
              const Spacer(),
              Text('-${formatFushiPlaybackTime(remaining)}', style: timeStyle),
            ],
          ),
      ],
    );
    // 自带重绘边界：时间文字每秒一变也只重录这一小块，不连带外层播放卡
    // （投影 / 封面）一起重画。
    return RepaintBoundary(
      child: Semantics(
        slider: seekable,
        value: formatFushiPlaybackTime(shown),
        child: seekable
            ? Focus(
                focusNode: _focusNode,
                onKeyEvent: _onKey,
                onFocusChange: (bool focused) =>
                    setState(() => _focused = focused),
                child: column,
              )
            : column,
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({
    required this.fraction,
    required this.phase,
    required this.amplitude,
    required this.strokeWidth,
    required this.activeColor,
    required this.trackColor,
    required this.thumbWidth,
    required this.thumbHeight,
    required this.focused,
    required this.rtl,
  });

  final double fraction;
  final double phase;
  final double amplitude;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;
  final double thumbWidth;
  final double thumbHeight;
  final bool focused;
  final bool rtl;

  static const double _wavelength = 40;

  /// thumb 与两侧轨道之间的缝（M3 Expressive slider 的 track gap）。
  static const double _gap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    if (rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final double cy = size.height / 2;
    final double half = strokeWidth / 2;
    final double left = half;
    final double right = size.width - half;
    final double usable = right - left;
    if (usable <= 0) return;
    final double x = left + usable * fraction.clamp(0.0, 1.0);
    final double gap = _gap + thumbWidth / 2;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // 已播段：两端各用半个波长把振幅从 0 拉起，接 thumb 与起点都是平的。
    final double activeEnd = x - gap;
    if (activeEnd > left) {
      final Path wave = Path()..moveTo(left, cy);
      const double ramp = _wavelength / 2;
      for (double xx = left; xx <= activeEnd; xx += 1.5) {
        final double taper = math.min(
          ((xx - left) / ramp).clamp(0.0, 1.0),
          ((activeEnd - xx) / ramp).clamp(0.0, 1.0),
        );
        final double y =
            cy +
            amplitude *
                taper *
                math.sin((xx - left) / _wavelength * 2 * math.pi - phase);
        wave.lineTo(xx, y);
      }
      wave.lineTo(activeEnd, cy);
      canvas.drawPath(wave, stroke..color = activeColor);
    }

    // 未播段：平直轨道 + 尾端停止点。
    final double inactiveStart = x + gap;
    if (inactiveStart < right) {
      canvas.drawLine(
        Offset(inactiveStart, cy),
        Offset(right, cy),
        stroke..color = trackColor,
      );
      if (right - inactiveStart > strokeWidth * 2) {
        canvas.drawCircle(
          Offset(right, cy),
          half * 0.5,
          Paint()..color = activeColor,
        );
      }
    }

    // thumb：竖向胶囊；有键盘焦点时外圈一层淡主色光晕。
    final Rect thumb = Rect.fromCenter(
      center: Offset(x, cy),
      width: thumbWidth,
      height: math.min(size.height, thumbHeight),
    );
    if (focused) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          thumb.inflate(5),
          Radius.circular(thumbWidth / 2 + 5),
        ),
        Paint()..color = activeColor.withValues(alpha: 0.24),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumb, Radius.circular(thumbWidth / 2)),
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _SeekPainter old) =>
      old.fraction != fraction ||
      old.phase != phase ||
      old.amplitude != amplitude ||
      old.strokeWidth != strokeWidth ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor ||
      old.thumbWidth != thumbWidth ||
      old.thumbHeight != thumbHeight ||
      old.focused != focused ||
      old.rtl != rtl;
}

// ---------------------------------------------------------------------------
// 播放键组
// ---------------------------------------------------------------------------

/// −10 秒 / 上一句 / 播放 / 下一句 / +10 秒：M3 Expressive 标准按钮组（按下的
/// 变宽、邻居让出）。±10 秒是小号 tonal 圆钮，只在给了 [onSeekRelative] 且
/// [showRelativeSeek] 时出现。
class FushiTransportGroup extends StatelessWidget {
  const FushiTransportGroup({
    super.key,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.playSize,
    required this.sideSize,
    required this.sideWidth,
    this.onSeekRelative,
    this.spacing = 8,
    this.showRelativeSeek = true,
    this.relativeSeekKeyPrefix = 'lyrics',
  });

  final bool isPlaying;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final double playSize;
  final ButtonSizeVariant sideSize;
  final IconButtonWidthVariant sideWidth;

  /// 后退 / 前进若干秒（负数后退）。null = 不显示 ±10 秒键。
  final ValueChanged<int>? onSeekRelative;
  final double spacing;

  /// false = ±10 秒不在这一行（窄屏放不下时挪到进度条两侧）。
  final bool showRelativeSeek;

  /// ±10 秒键的 key 前缀（`<prefix>_seek_back_button` / `_forward_button`）。
  final String relativeSeekKeyPrefix;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<int>? seekBy = showRelativeSeek ? onSeekRelative : null;
    return FushiButtonGroup(
      spacing: spacing,
      children: <Widget>[
        if (seekBy != null)
          fushiRelativeSeekButton(
            -10,
            seekBy,
            keyPrefix: relativeSeekKeyPrefix,
          ),
        FushiIconButtonControl.filledTonal(
          size: sideSize,
          width: sideWidth,
          tooltip: t.prev_sentence,
          onPressed: onPrevious,
          icon: const FushiIcon(FushiIcons.skipPrevious),
        ),
        FushiExpressivePlayButton(
          isPlaying: isPlaying,
          size: playSize,
          onPressed: onPlayPause,
        ),
        FushiIconButtonControl.filledTonal(
          size: sideSize,
          width: sideWidth,
          tooltip: t.next_sentence,
          onPressed: onNext,
          icon: const FushiIcon(FushiIcons.skipNext),
        ),
        if (seekBy != null)
          fushiRelativeSeekButton(10, seekBy, keyPrefix: relativeSeekKeyPrefix),
      ],
    );
  }
}

/// ±10 秒小号 tonal 圆钮（播放键组里或窄屏进度条两侧共用同一颗）。
Widget fushiRelativeSeekButton(
  int seconds,
  ValueChanged<int> seekBy, {
  String keyPrefix = 'lyrics',
}) {
  final bool back = seconds < 0;
  return FushiIconButtonControl.filledTonal(
    key: ValueKey<String>(
      back
          ? '${keyPrefix}_seek_back_button'
          : '${keyPrefix}_seek_forward_button',
    ),
    size: ButtonSizeVariant.small,
    tooltip: back ? '-10s' : '+10s',
    onPressed: () => seekBy(seconds),
    icon: FushiIcon(back ? FushiIcons.replay10 : FushiIcons.forward10),
  );
}

/// 大号 Expressive 播放键：播放中是圆、暂停时是圆角方（圆角 = 边长 30%），两态
/// 之间按 default spatial 弹簧形变；按下整体缩 6%（fast spatial）。图标交叉缩放 +
/// 轻旋转切换。外形是显式 shape，所以 FushiFilledButton 自己的按压变形让位。
class FushiExpressivePlayButton extends StatefulWidget {
  const FushiExpressivePlayButton({
    super.key,
    required this.isPlaying,
    required this.size,
    required this.onPressed,
  });

  final bool isPlaying;
  final double size;
  final VoidCallback? onPressed;

  @override
  State<FushiExpressivePlayButton> createState() =>
      _FushiExpressivePlayButtonState();
}

class _FushiExpressivePlayButtonState extends State<FushiExpressivePlayButton>
    with TickerProviderStateMixin {
  late final FushiSpring _shape = FushiSpring(
    vsync: this,
    initial: widget.isPlaying ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );
  late final FushiSpring _press = FushiSpring(vsync: this);

  @override
  void didUpdateWidget(covariant FushiExpressivePlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _shape.animateTo(
        widget.isPlaying ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _shape.dispose();
    _press.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (!fushiExpressiveMotionEnabled(context)) return;
    _press.animateTo(pressed ? 1 : 0, animate: true);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double size = widget.size;
    final bool motion = fushiExpressiveMotionEnabled(context);
    final Widget icon = AnimatedSwitcher(
      duration: Duration(milliseconds: motion ? 220 : 0),
      switchInCurve: FushiSpringCurve.spatialFast,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          RotationTransition(
            turns: Tween<double>(begin: -0.08, end: 0).animate(animation),
            child: ScaleTransition(scale: animation, child: child),
          ),
      child: FushiIcon(
        widget.isPlaying
            ? FushiIcons.filled(FushiIcons.pause)
            : FushiIcons.filled(FushiIcons.play),
        key: ValueKey<bool>(widget.isPlaying),
        size: size * 0.46,
      ),
    );
    return FushiTooltip(
      message: widget.isPlaying ? t.pause : t.play,
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            _shape.animation,
            _press.animation,
          ]),
          builder: (BuildContext context, Widget? child) {
            final double pill = _shape.value;
            return Transform.scale(
              scale: 1 - 0.06 * _press.value,
              child: FushiFilledButton(
                onPressed: widget.onPressed,
                style: ButtonStyle(
                  fixedSize: WidgetStatePropertyAll<Size>(Size.square(size)),
                  minimumSize: WidgetStatePropertyAll<Size>(Size.square(size)),
                  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                    EdgeInsets.zero,
                  ),
                  backgroundColor: WidgetStatePropertyAll<Color>(cs.primary),
                  foregroundColor: WidgetStatePropertyAll<Color>(cs.onPrimary),
                  elevation: const WidgetStatePropertyAll<double>(0),
                  animationDuration: Duration.zero,
                  shape: WidgetStatePropertyAll<OutlinedBorder>(
                    FushiMorphBorder(
                      radius: size * 0.3,
                      startPill: pill,
                      endPill: pill,
                    ),
                  ),
                ),
                child: child!,
              ),
            );
          },
          child: icon,
        ),
      ),
    );
  }
}

/// mesh 背景流动时缓存图一个纹素覆盖的**物理**像素边长。按物理像素算：按逻辑
/// 像素算的话 DPR 3 的手机上一个纹素会被拉成 24×24 物理像素（BUG-3933）。
const double _kMeshAnimatedTexelPx = 8;

/// 测试钩子：[FushiMeshBackdrop] 每重画一次缓存图就回调一次（参数是本次产出的图，
/// 归背景 State 所有，测试只读不释放）。
@visibleForTesting
ValueChanged<ui.Image>? debugOnFushiMeshImageRendered;

/// [FushiMeshBackdrop] 的渐变图缓存：同一尺寸、同一相位、同一分辨率只画一次。
class _MeshImageCache {
  ui.Image? _image;
  Size? _size;
  double? _phase;
  double? _rasterScale;

  void invalidate() {
    _phase = null;
  }

  ui.Image? resolve(
    Size size,
    double phase,
    double rasterScale,
    void Function(Canvas canvas, Size size) paint,
  ) {
    if (size.isEmpty || !size.isFinite || rasterScale <= 0) return null;
    if (_image != null &&
        _size == size &&
        _phase == phase &&
        _rasterScale == rasterScale) {
      return _image;
    }
    final int w = math.max(1, (size.width * rasterScale).ceil());
    final int h = math.max(1, (size.height * rasterScale).ceil());
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas c = Canvas(recorder);
    paint(c, Size(w.toDouble(), h.toDouble()));
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(w, h);
    picture.dispose();
    _image?.dispose();
    _image = image;
    _size = size;
    _phase = phase;
    _rasterScale = rasterScale;
    debugOnFushiMeshImageRendered?.call(image);
    return image;
  }

  void dispose() {
    _image?.dispose();
    _image = null;
  }
}
