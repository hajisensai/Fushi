/// 媒体库全景的渲染舞台：每帧一次 `ffc_pano_frame`（布局 / 轨道 / 投影 / 远近样式全在
/// Rust，封面是真正的 3D 平面），Flutter 只按返回的批次 `drawVertices`（每图集页一批三角网格）
/// 并用片段着色器画背景。
///
/// 两种模式：
/// - [FfcPanoMode.interactive]（首页默认）：开场是俯视的封面星系；拖拽转视角，双指 / 滚轮 /
///   +- 拉近时星系连续收拢成球幕、直到站在球心，拉远再散回星系；点封面 → 转向并飞到眼前 →
///   书翻开 → 进阅读器；方向键 / Enter 同样可操作。
/// - [FfcPanoMode.cinematic]（分享用）：16 秒开场动画，最后锁定 [PanoramaStage.cinematicTarget]。
///
/// 动效开关：墨水屏 / 系统「减弱动态效果」下不跑 Ticker（只在输入时重算一帧），点封面直接打开。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/panorama/panorama_atlas.dart';
import 'package:fushi/src/media/panorama/panorama_book_flip.dart';
import 'package:fushi/src/media/panorama/panorama_library.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 分享动画里封面停稳（交给翻书）的时刻，与 pano.rs `T_HANDOFF` 一致。
const double kPanoramaHandoffSeconds = 13.5;

/// 分享动画总长（秒）。
const double kPanoramaCinematicSeconds = 16;

/// 翻书时长：交接后到进阅读器，合起来正好 16 秒。
const Duration kPanoramaFlipDuration = Duration(milliseconds: 2500);

/// 飞到眼前的封面高度占视口比例（与 pano.rs `TARGET_SCREEN_HEIGHT` 一致，高清图按它预渲染）。
const double kPanoramaTargetScreenHeight = 0.62;

/// 已建好的全景资源（数据 + 图集），首页面板与全屏页共用一份。
class PanoramaAssets {
  PanoramaAssets({
    required this.library,
    required this.atlas,
    this.db,
    this.bookFont,
  });

  final PanoramaLibrary library;
  final PanoramaAtlas atlas;

  /// 翻开后正文页的字体（小说正文字体那一套）；null = 系统默认。
  final PanoramaFontSet? bookFont;

  /// 取翻开正文用；null（测试）时翻开后显示书名。
  final FushiDatabase? db;

  /// 分享动画默认锁定的作品：最近在读的书 → 任意书 → 最近打开的作品；空库为 -1。
  int get defaultTarget {
    final List<PanoramaWork> works = library.works;
    int best = -1;
    for (int i = 0; i < works.length; i++) {
      if (!works[i].isBook) continue;
      if (best < 0 || works[i].lastOpenedAt > works[best].lastOpenedAt) {
        best = i;
      }
    }
    if (best >= 0) return best;
    for (int i = 0; i < works.length; i++) {
      if (best < 0 || works[i].lastOpenedAt > works[best].lastOpenedAt) {
        best = i;
      }
    }
    return best;
  }

  void dispose() => atlas.dispose();
}

class PanoramaStage extends StatefulWidget {
  const PanoramaStage({
    super.key,
    required this.assets,
    required this.onOpen,
    this.mode = FfcPanoMode.interactive,
    this.cinematicTarget = -1,
    this.onCinematicDone,
  });

  final PanoramaAssets assets;

  /// 打开作品（书 → 阅读器；其他域各自的打开路径）。返回后舞台回到可操作状态。
  final Future<void> Function(PanoramaWork work) onOpen;
  final FfcPanoMode mode;
  final int cinematicTarget;

  /// 分享动画结束（已打开作品或无可锁定作品）。
  final VoidCallback? onCinematicDone;

  @override
  State<PanoramaStage> createState() => _PanoramaStageState();
}

class _PanoramaStageState extends State<PanoramaStage>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _program;

  late final FfcPanorama _pano;
  late final Ticker _ticker;
  final _FrameNotifier _frames = _FrameNotifier();
  ui.FragmentShader? _shader;
  Size _size = Size.zero;
  Duration _last = Duration.zero;
  double _t = 0;
  bool _motion = true;
  double _lastScale = 1;

  /// 锁定中的作品与它的高清带框封面 / 正文片段。
  int _target = -1;
  ui.Image? _hiRes;
  Future<String?>? _excerpt;
  bool _flipping = false;
  Rect? _handoffRect;
  bool _opening = false;
  bool _cinematicEnded = false;

  /// 已备好高清封面 / 正文的作品下标（-1 = 还没备）。
  int _preparedFor = -1;

  @override
  void initState() {
    super.initState();
    _pano = FfcPanorama.create(widget.assets.atlas.scene);
    _ticker = createTicker(_onTick);
    _program ??= ui.FragmentProgram.fromAsset('shaders/panorama_backdrop.frag');
    _program!.then(
      (ui.FragmentProgram p) {
        if (!mounted) return;
        _shader = p.fragmentShader();
        _frames.ping();
      },
      onError: (Object e, StackTrace s) {
        ErrorLogService.instance.log('PanoramaStage.shader', e, s);
      },
    );
    _enterMode();
  }

  void _enterMode() {
    _pano.setMode(widget.mode, target: widget.cinematicTarget);
    _t = 0;
    _last = Duration.zero;
    _target = widget.mode == FfcPanoMode.cinematic
        ? widget.cinematicTarget
        : -1;
    // 高清封面按视口高度出图：等第一帧拿到尺寸再备（见 [_compute]）。
    _preparedFor = -1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = fushiMotionEnabled(context);
    if (_motion) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
      // 不跑动画：交互模式停在球幕静帧（分享动画由入口直接跳过，不会走到这里）。
      _t = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _renderOnce());
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pano.dispose();
    _shader?.dispose();
    _hiRes?.dispose();
    _frames.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final double dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _t = elapsed.inMicroseconds / 1e6;
    _compute(dt);
  }

  void _renderOnce() {
    if (!mounted) return;
    _compute(0);
  }

  void _compute(double dt) {
    if (_size.isEmpty) return;
    if (_target >= 0 && _preparedFor != _target) _prepareTarget(_target);
    final FfcPanoFrame f = _pano.frame(
      t: _t,
      dt: dt,
      width: _size.width,
      height: _size.height,
    );
    _frames.update(f, _size);
    // 分享动画没有可锁定的作品（-1）：放满 16 秒后自行收尾。
    if (widget.mode == FfcPanoMode.cinematic &&
        _target < 0 &&
        !_cinematicEnded &&
        _t >= kPanoramaCinematicSeconds) {
      _cinematicEnded = true;
      widget.onCinematicDone?.call();
    }
    if (_target >= 0 && f.handoff && !_flipping && !_opening) {
      _handoff(f);
    }
  }

  /// 锁定开始时就备好高清封面与正文，交接那一帧已就绪。
  void _prepareTarget(int index) {
    _preparedFor = index;
    final PanoramaWork work = widget.assets.library.works[index];
    final double aspect = widget.assets.atlas.aspects[index];
    final double h = math.max(1, _size.height) * kPanoramaTargetScreenHeight;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    unawaited(
      renderPanoramaHiResCover(
        work,
        cover: Size(h * aspect, h),
        hue: widget.assets.atlas.hues[index],
        pixelRatio: dpr,
      ).then((ui.Image img) {
        if (!mounted || _target != index) {
          img.dispose();
          return;
        }
        _hiRes?.dispose();
        _hiRes = img;
        _frames.hiRes = img;
      }),
    );
    final FushiDatabase? db = widget.assets.db;
    _excerpt = work.isBook && db != null
        ? loadPanoramaBookExcerpt(db: db, work: work)
        : null;
  }

  void _handoff(FfcPanoFrame f) {
    final PanoramaWork work = widget.assets.library.works[_target];
    final Float32List i = f.info;
    final Rect rect = Rect.fromLTWH(
      i[FfcPanoInfo.targetRect],
      i[FfcPanoInfo.targetRect + 1],
      i[FfcPanoInfo.targetRect + 2],
      i[FfcPanoInfo.targetRect + 3],
    );
    if (work.isBook && _motion) {
      setState(() {
        _flipping = true;
        _handoffRect = rect;
      });
      _frames.hideTarget = true;
    } else {
      unawaited(_open(work));
    }
  }

  Future<void> _open(PanoramaWork work) async {
    if (_opening) return;
    _opening = true;
    try {
      await widget.onOpen(work);
    } catch (e, s) {
      ErrorLogService.instance.log('PanoramaStage.open', e, s);
    } finally {
      _opening = false;
    }
    if (!mounted) return;
    if (widget.mode == FfcPanoMode.cinematic) {
      widget.onCinematicDone?.call();
    }
    _resetToInteractive();
  }

  void _resetToInteractive() {
    setState(() {
      _flipping = false;
      _handoffRect = null;
    });
    _target = -1;
    _preparedFor = -1;
    _frames
      ..hideTarget = false
      ..hiRes = null;
    _hiRes?.dispose();
    _hiRes = null;
    _excerpt = null;
    _pano.setMode(FfcPanoMode.interactive);
    _renderOnce();
  }

  void _select(int index) {
    if (index < 0 || _target >= 0 || widget.mode != FfcPanoMode.interactive) {
      return;
    }
    final PanoramaWork work = widget.assets.library.works[index];
    if (!_motion) {
      unawaited(_open(work));
      return;
    }
    _target = index;
    _prepareTarget(index);
    _pano.select(index, _t);
  }

  void _input(FfcPanoInput kind, double a, [double b = 0]) {
    if (_target >= 0) return;
    _pano.input(kind, a, b);
    if (!_motion) _renderOnce();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    const double step = 60;
    final LogicalKeyboardKey k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      _input(FfcPanoInput.drag, step, 0);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _input(FfcPanoInput.drag, -step, 0);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _input(FfcPanoInput.drag, 0, step);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _input(FfcPanoInput.drag, 0, -step);
    } else if (k == LogicalKeyboardKey.equal ||
        k == LogicalKeyboardKey.numpadAdd) {
      _input(FfcPanoInput.zoom, 1.25);
    } else if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract) {
      _input(FfcPanoInput.zoom, 0.8);
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      _select(_pano.pick(_size.width / 2, _size.height / 2));
    } else {
      return KeyEventResult.ignored;
    }
    _input(FfcPanoInput.release, 0, 0);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.mode == FfcPanoMode.interactive;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final Size size = c.biggest;
        if (size != _size) {
          _size = size;
          WidgetsBinding.instance.addPostFrameCallback((_) => _renderOnce());
        }
        Widget canvas = CustomPaint(
          size: size,
          painter: _PanoramaPainter(
            frames: _frames,
            pages: widget.assets.atlas.pages,
            atlasRects: widget.assets.atlas.scene.cellRects,
            atlasCellOfWork: widget.assets.atlas.scene.workCells,
            atlasPages: widget.assets.atlas.scene.cellPages,
            target: () => _target,
            shader: () => _shader,
            time: () => _t,
          ),
        );
        if (interactive) {
          canvas = Listener(
            onPointerSignal: (PointerSignalEvent e) {
              if (e is PointerScrollEvent) {
                _input(
                  FfcPanoInput.zoom,
                  math.pow(1.0015, -e.scrollDelta.dy).toDouble(),
                );
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (ScaleStartDetails d) {
                _lastScale = 1;
                _input(FfcPanoInput.hold, 0);
              },
              onScaleUpdate: (ScaleUpdateDetails d) {
                if (d.pointerCount >= 2 && d.scale != _lastScale) {
                  _input(FfcPanoInput.zoom, d.scale / _lastScale);
                  _lastScale = d.scale;
                }
                _input(
                  FfcPanoInput.drag,
                  d.focalPointDelta.dx,
                  d.focalPointDelta.dy,
                );
              },
              onScaleEnd: (ScaleEndDetails d) => _input(
                FfcPanoInput.release,
                d.velocity.pixelsPerSecond.dx,
                d.velocity.pixelsPerSecond.dy,
              ),
              onTapUp: (TapUpDetails d) =>
                  _select(_pano.pick(d.localPosition.dx, d.localPosition.dy)),
              child: canvas,
            ),
          );
          canvas = Focus(onKeyEvent: _onKey, child: canvas);
        }
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            canvas,
            if (_flipping && _handoffRect != null && _target >= 0)
              PanoramaBookFlip(
                key: ValueKey<int>(_target),
                coverRect: _handoffRect!,
                framedCover: _hiRes,
                fallbackTitle: widget.assets.library.works[_target].title,
                accent: panoramaAccent(widget.assets.atlas.hues[_target]),
                font: widget.assets.bookFont,
                excerpt: _excerpt,
                duration: kPanoramaFlipDuration,
                onOpened: () => _open(widget.assets.library.works[_target]),
              ),
          ],
        );
      },
    );
  }
}

/// 每帧数据的通知器（Ticker → 重绘，不走 setState）。
class _FrameNotifier extends ChangeNotifier {
  FfcPanoFrame? frame;
  Size size = Size.zero;
  ui.Image? hiRes;
  bool hideTarget = false;

  void update(FfcPanoFrame f, Size s) {
    frame = f;
    size = s;
    notifyListeners();
  }

  void ping() => notifyListeners();
}

class _PanoramaPainter extends CustomPainter {
  _PanoramaPainter({
    required this.frames,
    required this.pages,
    required this.atlasRects,
    required this.atlasCellOfWork,
    required this.atlasPages,
    required this.target,
    required this.shader,
    required this.time,
  }) : super(repaint: frames);

  final _FrameNotifier frames;
  final List<ui.Image> pages;
  final Float32List atlasRects;
  final Int32List atlasCellOfWork;
  final Int32List atlasPages;
  final int Function() target;
  final ui.FragmentShader? Function() shader;
  final double Function() time;

  @override
  void paint(Canvas canvas, Size size) {
    final FfcPanoFrame? f = frames.frame;
    final Rect bounds = Offset.zero & size;
    canvas.clipRect(bounds);
    final ui.FragmentShader? sh = shader();
    if (sh != null && f != null) {
      final Float32List i = f.info;
      int k = 0;
      void put(double v) => sh.setFloat(k++, v);
      put(size.width);
      put(size.height);
      put(i[FfcPanoInfo.haloX]);
      put(i[FfcPanoInfo.haloY]);
      put(i[FfcPanoInfo.haloR]);
      put(i[FfcPanoInfo.haloAlpha]);
      for (int a = 0; a < 3; a++) {
        put(i[FfcPanoInfo.forward + a]);
      }
      for (int a = 0; a < 3; a++) {
        put(i[FfcPanoInfo.right + a]);
      }
      for (int a = 0; a < 3; a++) {
        put(i[FfcPanoInfo.up + a]);
      }
      put(i[FfcPanoInfo.focal]);
      put(time());
      canvas.drawRect(bounds, Paint()..shader = sh);
    } else {
      canvas.drawRect(bounds, Paint()..color = const Color(0xFF05070F));
    }
    if (f == null) return;
    for (int b = 0; b < f.batches; b++) {
      final int page = f.batchPage(b);
      final Paint paint;
      if (page == FfcPanorama.targetPage) {
        if (frames.hideTarget) continue;
        paint = _targetPaint(target());
      } else {
        paint = _pagePaint(page);
      }
      final int v0 = f.batchVertexStart(b);
      final int vn = f.batchVertexCount(b);
      final int i0 = f.batchIndexStart(b);
      final int iN = f.batchIndexCount(b);
      if (iN == 0) continue;
      final ui.Vertices v = ui.Vertices.raw(
        VertexMode.triangles,
        Float32List.sublistView(f.positions, v0 * 2, (v0 + vn) * 2),
        textureCoordinates: Float32List.sublistView(
          f.texCoords,
          v0 * 2,
          (v0 + vn) * 2,
        ),
        colors: Int32List.sublistView(f.colors, v0, v0 + vn),
        indices: Uint16List.sublistView(f.indices, i0, i0 + iN),
      );
      canvas.drawVertices(v, BlendMode.modulate, paint);
      v.dispose();
    }
  }

  final Map<int, Paint> _pagePaints = <int, Paint>{};
  ui.Image? _targetImage;
  Paint? _targetPaintCache;

  /// 图集页的纹理画笔（纹理坐标就是图集像素）。
  Paint _pagePaint(int page) => _pagePaints[page] ??= Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true
    ..shader = ImageShader(
      pages[page],
      TileMode.clamp,
      TileMode.clamp,
      Matrix4.identity().storage,
    );

  /// 锁定目标批（纹理坐标 0..1）：高清带框封面；高清图还没出来时用图集里那一格（同一套边框
  /// 比例），把 0..1 映射到格子矩形。
  Paint _targetPaint(int work) {
    final ui.Image? hi = frames.hiRes;
    final ui.Image src;
    final Matrix4 m;
    if (hi != null) {
      src = hi;
      m = Matrix4.diagonal3Values(1 / hi.width, 1 / hi.height, 1);
    } else {
      final int cell = atlasCellOfWork[work];
      src = pages[atlasPages[cell]];
      final double cw = atlasRects[cell * 4 + 2];
      final double ch = atlasRects[cell * 4 + 3];
      m = Matrix4.diagonal3Values(1 / cw, 1 / ch, 1)
        ..translateByDouble(
          -atlasRects[cell * 4],
          -atlasRects[cell * 4 + 1],
          0,
          1,
        );
    }
    if (_targetPaintCache != null && identical(_targetImage, src)) {
      return _targetPaintCache!;
    }
    _targetImage = src;
    return _targetPaintCache = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true
      ..shader = ImageShader(src, TileMode.clamp, TileMode.clamp, m.storage);
  }

  @override
  bool shouldRepaint(_PanoramaPainter old) =>
      old.pages != pages || old.frames != frames;
}
