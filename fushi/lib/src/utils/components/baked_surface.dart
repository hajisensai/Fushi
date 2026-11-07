import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 把一块**静态**子树烘焙成一张纹理：内容与屏幕位置都稳定后，之后每帧只画这一张
/// 图，不再重放子树里的全部绘制命令（模糊投影、圆角裁切、封面图、多层光泽渐变、
/// 描边……）。
///
/// 起因（2026-11-05，用户反馈「鼠标悬浮在媒体卡上 GPU 飙到 40% 多、很卡」）：
/// 悬停的 3D 倾斜 / 高光 / 扫光 / 抬升会连续出帧，而桌面 Impeller 没有局部重绘，
/// **每帧整窗重画**。实测（RTX 4070 Ti、1217×849 窗口、真实书库，PresentMon 逐帧
/// GPU 耗时）书架页每帧 1.7–2.0 ms，其中一半以上是几十张封面面的静态内容——扇形 /
/// 叠层每格要画 3–4 张完整的面；把这些关掉后直接落到空 app 的 0.6–0.7 ms 地板。
/// 动效本身不贵，贵的是它们逼出来的每一帧都要把整页静态内容再画一遍。
///
/// Impeller 没有 raster cache，这里就是手动的那一份。不变式：
/// - **内容变了就实时画。** 本节点是 repaint boundary：子树任何重绘都会走到本节点
///   的 [RenderObject.paint]，于是「paint 被调到 = 内容变了」，这一帧照常实时绘制。
///   正在动的内容（封面淡入、加载圈、抬升投影）因此一直实时绘制，不会被烘焙成过时
///   快照。
/// - **轴对齐（均匀缩放 + 平移）的位置只用 1:1 纹理。** 纹理按本节点的真实全局变换
///   （缩放 + 亚像素相位）烘焙、边界对齐到物理像素，贴回去不经任何重采样，与实时
///   绘制逐像素一致。滚动、进场动画、悬停放大让相位 / 倍数变了，下一帧回实时绘制，
///   停稳一帧后重新烘焙。
/// - **带旋转 / 斜切 / 透视的位置贴重采样纹理。** 这类变换下不存在 1:1 贴图，实时
///   绘制本身也是把封面图重采样一遍，于是改按「本节点在屏幕上的最大放大倍数」向上
///   取整到设备像素比的 1/4 档烘焙一张（[_resampledRatio]），贴图时双线性采样；只要
///   内容不变、倍数没超过纹理分辨率，变换怎么变都贴同一张，不再重放子树。
///
///   这一条是 BUG-4220 的根因修复：扇形合集卡后面几本**常驻**旋转，悬停中的整摞
///   又带 3D 倾斜透视——此前「只认 1:1」，这些面永远烘焙不了：页面上只要有东西在
///   出帧，每张合集卡的 3 本后层都整套实时重画（模糊投影 + 圆角裁切 + 封面图 + 多层
///   光泽），悬停中的合集卡再加 4 本透视下的实时面。实测（独立 profile 包复刻同一
///   套面、RTX 4070 Ti、Impeller OpenGLES、1440×852 窗口、24 格其中 12 张合集卡、
///   悬停倾斜持续出帧，FrameTiming raster 均值）：旧逻辑悬停单本 5.3–6.3 ms、悬停
///   合集 7.1–7.4 ms；本逻辑两者都是 0.7–0.8 ms。
/// - **内容（轴对齐时连同位置）连续一整帧没变才烘焙。**
///
/// 子树里嵌套 repaint boundary 时不烘焙：烘焙态下它的层不在场景里，它自己重绘时
/// Flutter 不会通知到本节点（`_skippedPaintingOnLayer` 停在第一个已挂载的祖先层），
/// 纹理就会过时。
class BakedSurface extends SingleChildRenderObjectWidget {
  const BakedSurface({super.key, this.overflow = EdgeInsets.zero, super.child});

  /// 子树画出自身布局框之外的范围（投影）。纹理按「布局框外扩它」烘焙，否则框外
  /// 的部分会被裁掉。
  final EdgeInsets overflow;

  @override
  RenderBakedSurface createRenderObject(BuildContext context) =>
      RenderBakedSurface(overflow: overflow);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderBakedSurface renderObject,
  ) {
    renderObject.overflow = overflow;
  }
}

/// 本节点坐标 → 物理像素的变换，限于「均匀缩放 + 平移」（只有这种才能 1:1 贴图）。
@immutable
class _Placement {
  const _Placement(this.scale, this.dx, this.dy);

  final double scale;
  final double dx;
  final double dy;

  /// 从全局变换取；带旋转 / 斜切 / 透视 / 非均匀缩放时返回 null。
  static _Placement? of(Matrix4 m) {
    final Float64List s = m.storage;
    const double eps = 1e-6;
    // x' = s0·x + s4·y + s12；y' = s1·x + s5·y + s13；w = s3·x + s7·y + s15。
    if (s[1].abs() > eps ||
        s[4].abs() > eps ||
        s[3].abs() > eps ||
        s[7].abs() > eps ||
        (s[15] - 1).abs() > eps ||
        s[0] <= 0 ||
        (s[0] - s[5]).abs() > eps) {
      return null;
    }
    return _Placement(s[0], s[12], s[13]);
  }

  /// 与 [other] 贴图结果是否完全一致：缩放相同，平移只差整数个物理像素。
  bool pixelEquivalent(_Placement other) {
    const double eps = 1e-3;
    double frac(double v) => v - v.roundToDouble();
    return (scale - other.scale).abs() < 1e-6 &&
        frac(dx - other.dx).abs() < eps &&
        frac(dy - other.dy).abs() < eps;
  }
}

/// [BakedSurface] 的渲染对象。
class RenderBakedSurface extends RenderRepaintBoundary {
  RenderBakedSurface({EdgeInsets overflow = EdgeInsets.zero})
    : _overflow = overflow;

  EdgeInsets _overflow;
  EdgeInsets get overflow => _overflow;
  set overflow(EdgeInsets value) {
    if (value == _overflow) return;
    _overflow = value;
    markNeedsPaint();
  }

  /// 当前纹理与它覆盖的范围（本节点坐标，已对齐物理像素）；null = 实时绘制。
  ui.Image? _image;
  Rect _imageBounds = Rect.zero;

  /// 纹理里有效区域的物理像素尺寸。[OffsetLayer.toImageSync] 按
  /// `(宽 × 倍率).ceil()` 取整，浮点误差会多出一行空像素，源矩形必须按这个精确
  /// 尺寸取，否则整张图被压缩约 1 像素。
  Rect _imageSource = Rect.zero;

  /// 1:1 纹理烘焙时的全局位置（null = 重采样纹理或未烘焙）；轴对齐的位置不再与它
  /// 等价就回实时绘制。
  _Placement? _bakedPlacement;

  /// 纹理分辨率：本节点每个逻辑单位对应的纹理像素数（0 = 未烘焙）。
  double _bakedRatio = 0;

  /// 刚烘焙完、下一次 paint 要改画纹理（而不是把它当成「内容变了」）。
  bool _showBake = false;

  /// 正在由 [_bake] / [_unbake] 自己标脏（区分于子树传上来的重绘请求）。
  bool _selfMarking = false;

  /// 上次 paint 之后子树又请求过重绘（`debugNeedsPaint` 在 release 下不可用）。
  bool _dirty = true;

  /// 每次实时绘制 +1；帧末检查比较它判断内容是否稳定。
  int _liveSerial = 0;

  /// 帧末检查上一次看到的实时绘制序号与位置。
  int _seenSerial = -1;
  _Placement? _seenPlacement;

  /// 是否处于烘焙态（测试 / 诊断用）。
  bool get debugIsBaked => _image != null;

  /// 当前纹理分辨率（每逻辑单位的纹理像素数；未烘焙为 0，测试 / 诊断用）。
  double get debugBakedPixelRatio => _bakedRatio;

  @override
  void markNeedsPaint() {
    // 子树的重绘请求沿父链传到本节点：哪怕刚烘焙完、还没来得及改画纹理，
    // 这次 paint 也必须按「内容变了」实时画。
    if (!_selfMarking) {
      _showBake = false;
      _dirty = true;
    }
    super.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _dirty = false;
    final ui.Image? image = _image;
    if (_showBake && image != null) {
      _showBake = false;
      context.canvas.drawImageRect(
        image,
        _imageSource,
        _imageBounds.shift(offset),
        // 像素对齐时双线性采样正好落在纹素中心，结果与 none 逐像素相同；位置刚变
        // 的那一帧（帧末才发现、下一帧才回实时绘制）贴出来是平滑的而不是锯齿。
        Paint()..filterQuality = FilterQuality.low,
      );
      _watch(this);
      return;
    }
    // 走到这里 = 子树内容（或尺寸）变了，或位置变了被 [_unbake] 打回：实时画。
    _dropBake();
    _liveSerial++;
    super.paint(context, offset);
    _watch(this);
  }

  /// 帧末检查（每帧对所有在场的烘焙面跑一次）。
  void _endOfFrame() {
    final Matrix4 transform = _physicalTransform();
    final _Placement? now = _Placement.of(transform);
    if (_image != null) {
      if (!_textureFits(transform, now)) _unbake();
      return;
    }
    if (_dirty) return; // 已经标脏，下一帧会实时画。
    final bool contentStable = _seenSerial == _liveSerial;
    final _Placement? seen = _seenPlacement;
    final bool placementStable =
        now != null && seen != null && now.pixelEquivalent(seen);
    _seenSerial = _liveSerial;
    _seenPlacement = now;
    if (now != null) {
      if (contentStable && placementStable) {
        _bake(now);
        return;
      }
    } else {
      final double? ratio = _resampledRatio(transform);
      // 退化变换（缩到 0、翻到视点背后）或放大过头：不烘焙，也不必自己要帧。
      if (ratio == null) return;
      if (contentStable) {
        _bakeResampled(ratio);
        return;
      }
    }
    // 还差一帧确认；没有别的东西在出帧时自己要一帧。
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// 现有纹理在当前变换下还能不能直接贴。
  ///
  /// 轴对齐：只认与烘焙位置像素等价的 1:1 纹理（重采样纹理也要回实时绘制、停稳后
  /// 重烘一张 1:1 的，静止的卡才逐像素等于实时绘制）。带旋转 / 透视：任何纹理只要
  /// 分辨率不低于屏幕上的最大放大倍数就照贴（1:1 纹理在变换刚出现时也就地沿用）。
  bool _textureFits(Matrix4 transform, _Placement? now) {
    if (now != null) {
      final _Placement? baked = _bakedPlacement;
      return baked != null && now.pixelEquivalent(baked);
    }
    final double? need = _screenScale(transform);
    return need != null && need <= _bakedRatio * (1 + 1e-3);
  }

  /// 本节点盒子在屏幕上的最大放大倍数（物理像素 / 逻辑单位）：四条边映射后的长度
  /// 与原长之比取最大（含透视除法，近端那条边最长）。有角落翻到视点背后、或结果
  /// 不是有限正数时返回 null。
  double? _screenScale(Matrix4 transform) {
    final double w = size.width;
    final double h = size.height;
    if (w <= 0 || h <= 0) return null;
    final Float64List s = transform.storage;
    final List<Offset> corners = <Offset>[];
    for (final Offset local in <Offset>[
      Offset.zero,
      Offset(w, 0),
      Offset(w, h),
      Offset(0, h),
    ]) {
      final double cw = s[3] * local.dx + s[7] * local.dy + s[15];
      if (cw <= 0) return null;
      corners.add(MatrixUtils.transformPoint(transform, local));
    }
    final double scale = <double>[
      (corners[1] - corners[0]).distance / w,
      (corners[2] - corners[3]).distance / w,
      (corners[3] - corners[0]).distance / h,
      (corners[2] - corners[1]).distance / h,
    ].reduce(math.max);
    return scale.isFinite && scale > 0 ? scale : null;
  }

  /// 重采样纹理的分辨率：屏幕最大放大倍数按设备像素比的 1/4 档向上取整（悬停放大
  /// 1.05 与倾斜透视落在同一档里，倾斜中一直贴同一张，不逐帧重烘）。超过设备像素比
  /// 两倍（被缩放手势放得很大）就不烘焙——纹理面积随倍数平方涨。
  double? _resampledRatio(Matrix4 transform) {
    final double? need = _screenScale(transform);
    if (need == null) return null;
    final double dpr = _devicePixelRatio();
    if (need > dpr * 2) return null;
    final double step = dpr / 4;
    return math.max(1, (need / step - 1e-3).ceil()) * step;
  }

  /// 本节点坐标 → 物理像素：[getTransformTo] 只到根 [RenderView] 的逻辑坐标，
  /// 还要乘上视图的设备像素比（纹理按物理像素烘焙，否则高 DPI 屏上发糊）。
  Matrix4 _physicalTransform() {
    final double dpr = _devicePixelRatio();
    return Matrix4.diagonal3Values(dpr, dpr, 1)..multiply(getTransformTo(null));
  }

  double _devicePixelRatio() {
    RenderObject root = this;
    while (root.parent != null) {
      root = root.parent!;
    }
    return root is RenderView ? root.configuration.devicePixelRatio : 1.0;
  }

  void _bake(_Placement p) {
    if (!attached || size.isEmpty || _hasNestedBoundary()) return;
    // 边界外扩到投影范围，再对齐到物理像素：纹理的像素格与屏幕像素格重合。
    final Rect r = _overflow.inflateRect(Offset.zero & size);
    final double leftPx = (p.dx + p.scale * r.left).floorToDouble();
    final double topPx = (p.dy + p.scale * r.top).floorToDouble();
    final double rightPx = (p.dx + p.scale * r.right).ceilToDouble();
    final double bottomPx = (p.dy + p.scale * r.bottom).ceilToDouble();
    final double left = leftPx - p.dx;
    final double top = topPx - p.dy;
    final double right = rightPx - p.dx;
    final double bottom = bottomPx - p.dy;
    final Rect bounds = Rect.fromLTRB(
      left / p.scale,
      top / p.scale,
      right / p.scale,
      bottom / p.scale,
    );
    // 等价于 [RenderRepaintBoundary.toImageSync]，只是范围是对齐后的 [bounds]。
    final OffsetLayer layer = this.layer! as OffsetLayer;
    _image = layer.toImageSync(bounds, pixelRatio: p.scale);
    _imageBounds = bounds;
    _imageSource = Rect.fromLTWH(0, 0, rightPx - leftPx, bottomPx - topPx);
    _bakedPlacement = p;
    _bakedRatio = p.scale;
    _showBake = true;
    _selfMarking = true;
    markNeedsPaint();
    _selfMarking = false;
  }

  /// 带旋转 / 透视时的烘焙：在本节点自己的坐标系里按 [ratio] 倍分辨率烘焙（边界
  /// 对齐到纹理像素格），之后在任意祖先变换下都贴这一张（见 [_textureFits]）。
  /// [OffsetLayer.toImageSync] 只渲染本层子树、不含祖先变换，所以倾斜中也能烘焙。
  void _bakeResampled(double ratio) {
    if (!attached || size.isEmpty || _hasNestedBoundary()) return;
    final Rect r = _overflow.inflateRect(Offset.zero & size);
    final double leftPx = (r.left * ratio).floorToDouble();
    final double topPx = (r.top * ratio).floorToDouble();
    final double rightPx = (r.right * ratio).ceilToDouble();
    final double bottomPx = (r.bottom * ratio).ceilToDouble();
    final Rect bounds = Rect.fromLTRB(
      leftPx / ratio,
      topPx / ratio,
      rightPx / ratio,
      bottomPx / ratio,
    );
    final OffsetLayer layer = this.layer! as OffsetLayer;
    _image = layer.toImageSync(bounds, pixelRatio: ratio);
    _imageBounds = bounds;
    _imageSource = Rect.fromLTWH(0, 0, rightPx - leftPx, bottomPx - topPx);
    _bakedPlacement = null;
    _bakedRatio = ratio;
    _showBake = true;
    _selfMarking = true;
    markNeedsPaint();
    _selfMarking = false;
  }

  /// 位置变了：下一帧回实时绘制（纹理在那次 paint 里释放）。
  void _unbake() {
    _showBake = false;
    _bakedPlacement = null;
    _seenPlacement = null;
    _selfMarking = true;
    markNeedsPaint();
    _selfMarking = false;
  }

  bool _hasNestedBoundary() {
    bool found = false;
    void visit(RenderObject node) {
      if (found) return;
      if (node.isRepaintBoundary) {
        found = true;
        return;
      }
      node.visitChildren(visit);
    }

    visitChildren(visit);
    return found;
  }

  void _dropBake() {
    _showBake = false;
    _bakedPlacement = null;
    _bakedRatio = 0;
    _image?.dispose();
    _image = null;
  }

  @override
  void detach() {
    _dropBake();
    _watched.remove(this);
    super.detach();
  }

  @override
  void dispose() {
    _dropBake();
    _watched.remove(this);
    super.dispose();
  }

  // ── 帧末检查的登记表 ─────────────────────────────────────────────────────
  //
  // 只挂 post-frame 回调、不主动要帧：没有帧就没有位置变化，也就不用检查。

  static final Set<RenderBakedSurface> _watched = <RenderBakedSurface>{};
  static bool _endOfFrameScheduled = false;

  static void _watch(RenderBakedSurface surface) {
    _watched.add(surface);
    if (_endOfFrameScheduled) return;
    _endOfFrameScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(_runEndOfFrame);
  }

  static void _runEndOfFrame(Duration _) {
    _endOfFrameScheduled = false;
    if (_watched.isEmpty) return;
    for (final RenderBakedSurface surface in _watched.toList()) {
      if (surface.attached) surface._endOfFrame();
    }
    if (_watched.isNotEmpty) {
      _endOfFrameScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback(_runEndOfFrame);
    }
  }
}
