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
/// Impeller 没有 raster cache，这里就是手动的那一份。三条不变式保证观感与实时
/// 绘制逐像素一致：
/// - **内容变了就实时画。** 本节点是 repaint boundary：子树任何重绘都会走到本节点
///   的 [RenderObject.paint]，于是「paint 被调到 = 内容变了」，这一帧照常实时绘制。
///   正在动的内容（封面淡入、加载圈）因此一直实时绘制，不会被烘焙成过时快照。
/// - **只在屏幕位置可 1:1 贴图时才用纹理。** 纹理按本节点的真实全局变换（缩放 +
///   亚像素相位）烘焙、边界对齐到物理像素，贴回去不经任何重采样。每帧结束检查
///   一次全局变换：滚动、进场动画、悬停放大、3D 倾斜让它变了（相位变化或出现
///   旋转 / 透视），下一帧就回到实时绘制——悬停中的那张卡是实时画的，烘焙的只有
///   静止的卡。变换刚出现的那一帧（帧末才看得到）仍贴纹理，双线性采样，与动画
///   本身逐帧插值的观感相同。
/// - **内容与位置都连续一整帧没变才烘焙。**
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

  /// 烘焙时的全局位置；之后位置不再等价就回实时绘制。
  _Placement? _bakedPlacement;

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
    final _Placement? now = _Placement.of(_physicalTransform());
    if (_image != null) {
      final _Placement? baked = _bakedPlacement;
      if (now == null || baked == null || !now.pixelEquivalent(baked)) {
        _unbake();
      }
      return;
    }
    if (_dirty) return; // 已经标脏，下一帧会实时画。
    final bool contentStable = _seenSerial == _liveSerial;
    final _Placement? seen = _seenPlacement;
    final bool placementStable =
        now != null && seen != null && now.pixelEquivalent(seen);
    _seenSerial = _liveSerial;
    _seenPlacement = now;
    if (contentStable && placementStable) {
      _bake(now);
    } else if (now != null) {
      // 还差一帧确认；没有别的东西在出帧时自己要一帧。
      SchedulerBinding.instance.ensureVisualUpdate();
    }
  }

  /// 本节点坐标 → 物理像素：[getTransformTo] 只到根 [RenderView] 的逻辑坐标，
  /// 还要乘上视图的设备像素比（纹理按物理像素烘焙，否则高 DPI 屏上发糊）。
  Matrix4 _physicalTransform() {
    RenderObject root = this;
    while (root.parent != null) {
      root = root.parent!;
    }
    final double dpr = root is RenderView
        ? root.configuration.devicePixelRatio
        : 1.0;
    return Matrix4.diagonal3Values(dpr, dpr, 1)..multiply(getTransformTo(null));
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
