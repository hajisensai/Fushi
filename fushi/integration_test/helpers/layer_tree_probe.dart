// 逐帧抓合成后的 layer 树，统计离屏层 / 外部纹理 / 平台视图（BUG-3888 续）。
//
// profile 下 `RenderObject.debugLayer` 恒为 null（藏在 assert 里），所以从
// `RenderView.layer` 起沿 `firstChild` / `nextSibling` 自己走；边界按子孙
// PictureLayer.canvasBounds / TextureLayer.rect / PlatformViewLayer.rect 的并集
// 换算到根坐标（物理像素，根 TransformLayer 自带 DPR 缩放）。
//
// 归属：layer → 持有它的 RenderObject（`RenderObject.layer` 句柄）→ 对应
// Element 的 widget 祖先链。经别的句柄推出的层（如 RenderFlex 的溢出裁剪）找不到
// 直接持有者，回退到最近的、有持有者的祖先层并标 `~`。
// ignore_for_file: invalid_use_of_protected_member
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// 层的类别：离屏（saveLayer 一类）、外部纹理、平台视图。
enum ProbeLayerKind { offscreen, texture, platformView }

/// 一帧里一个被统计的层。
class ProbeLayer {
  ProbeLayer(this.layer, this.kind, this.type, this.bounds, this.extra);
  final Layer layer;
  final ProbeLayerKind kind;
  final String type;
  final Rect bounds;
  final String extra;

  int get id => identityHashCode(layer);
  double get area => bounds.isEmpty ? 0 : bounds.width * bounds.height;

  String brief(double rootArea) {
    final String pct = rootArea <= 0
        ? '?'
        : (area / rootArea * 100).toStringAsFixed(0);
    return '$type#${id.toRadixString(16)}'
        '[${bounds.left.round()},${bounds.top.round()} '
        '${bounds.width.round()}x${bounds.height.round()} $pct%'
        '${extra.isEmpty ? '' : ' $extra'}]';
  }
}

/// 一帧的统计。
class LayerFrame {
  LayerFrame(this.layers, this.rootBounds, this.totalLayers);
  final List<ProbeLayer> layers;
  final Rect rootBounds;
  final int totalLayers;

  double get rootArea => rootBounds.width * rootBounds.height;

  Iterable<ProbeLayer> of(ProbeLayerKind k) =>
      layers.where((ProbeLayer l) => l.kind == k);

  /// 离屏层总面积占根面积的百分比（重叠按各自面积累加，近似 saveLayer 的填充量）。
  double offscreenAreaPct() {
    if (rootArea <= 0) return 0;
    double sum = 0;
    for (final ProbeLayer l in of(ProbeLayerKind.offscreen)) {
      sum += l.area;
    }
    return sum / rootArea * 100;
  }
}

Rect _union(Rect? a, Rect b) => a == null ? b : a.expandToInclude(b);

LayerFrame captureLayerFrame() {
  final RenderView view = RendererBinding.instance.renderViews.first;
  final ContainerLayer? root = view.layer;
  final List<ProbeLayer> out = <ProbeLayer>[];
  int total = 0;

  Rect? walk(Layer l, Matrix4 m, Rect? clip) {
    total++;
    Matrix4 cm = m;
    Rect? childClip = clip;
    Rect? self;
    Rect clipRoot(Rect local) => MatrixUtils.transformRect(m, local);

    if (l is OffsetLayer && l.offset != Offset.zero) {
      cm = m.clone()..translateByDouble(l.offset.dx, l.offset.dy, 0, 1);
    }
    if (l is TransformLayer && l.transform != null) {
      cm = cm.clone()..multiply(l.transform!);
    }
    String? offType;
    String extra = '';
    if (l is ClipRectLayer && l.clipRect != null) {
      childClip = clipRoot(l.clipRect!);
      if (l.clipBehavior == Clip.antiAliasWithSaveLayer) offType = 'ClipRect';
    } else if (l is ClipRRectLayer && l.clipRRect != null) {
      childClip = clipRoot(l.clipRRect!.outerRect);
      if (l.clipBehavior == Clip.antiAliasWithSaveLayer) offType = 'ClipRRect';
    } else if (l is ClipPathLayer && l.clipPath != null) {
      childClip = clipRoot(l.clipPath!.getBounds());
      if (l.clipBehavior == Clip.antiAliasWithSaveLayer) offType = 'ClipPath';
    } else if (l is OpacityLayer) {
      final int a = l.alpha ?? 255;
      if (a < 255) offType = 'Opacity';
      extra = 'a=$a';
    } else if (l is ColorFilterLayer) {
      offType = 'ColorFilter';
    } else if (l is ShaderMaskLayer) {
      offType = 'ShaderMask';
    } else if (l is BackdropFilterLayer) {
      offType = 'Backdrop';
    } else if (l is ImageFilterLayer) {
      offType = 'ImageFilter';
    }
    if (childClip != null && clip != null) {
      childClip = childClip.intersect(clip);
    }

    if (l is PictureLayer) {
      self = MatrixUtils.transformRect(m, l.canvasBounds);
    } else if (l is TextureLayer) {
      self = MatrixUtils.transformRect(m, l.rect);
      out.add(
        ProbeLayer(
          l,
          ProbeLayerKind.texture,
          'Texture',
          clip == null ? self : self.intersect(clip),
          'tex=${l.textureId} freeze=${l.freeze}',
        ),
      );
    } else if (l is PlatformViewLayer) {
      self = MatrixUtils.transformRect(m, l.rect);
      out.add(
        ProbeLayer(
          l,
          ProbeLayerKind.platformView,
          'PlatformView',
          clip == null ? self : self.intersect(clip),
          'pv=${l.viewId}',
        ),
      );
    } else if (l is ContainerLayer) {
      Layer? c = l.firstChild;
      while (c != null) {
        final Rect? b = walk(c, cm, childClip);
        if (b != null) self = _union(self, b);
        c = c.nextSibling;
      }
    }

    if (self != null && childClip != null && l is! PictureLayer) {
      self = self.intersect(childClip);
    }
    if (offType != null) {
      // 背景滤镜作用于它下方、裁剪范围内的全部内容，面积按所在裁剪算。
      final Rect b = offType == 'Backdrop'
          ? (childClip ?? self ?? Rect.zero)
          : (self ?? Rect.zero);
      out.add(ProbeLayer(l, ProbeLayerKind.offscreen, offType, b, extra));
    }
    return self;
  }

  Rect rootBounds = Rect.zero;
  if (root != null) {
    rootBounds = walk(root, Matrix4.identity(), null) ?? Rect.zero;
  }
  final Size phys = view.flutterView.physicalSize;
  if (!phys.isEmpty) rootBounds = Offset.zero & phys;
  return LayerFrame(out, rootBounds, total);
}

/// 两帧之间离屏 / 纹理 / 平台视图的增删与换位，按 identity 比。
String diffLayerFrames(LayerFrame prev, LayerFrame cur, double minPct) {
  final Map<int, ProbeLayer> a = <int, ProbeLayer>{
    for (final ProbeLayer l in prev.layers) l.id: l,
  };
  final Map<int, ProbeLayer> b = <int, ProbeLayer>{
    for (final ProbeLayer l in cur.layers) l.id: l,
  };
  bool big(ProbeLayer l, double rootArea) =>
      l.kind != ProbeLayerKind.offscreen ||
      (rootArea > 0 && l.area / rootArea * 100 >= minPct);
  final List<String> parts = <String>[];
  for (final ProbeLayer l in cur.layers) {
    final ProbeLayer? o = a[l.id];
    if (o == null) {
      if (big(l, cur.rootArea)) parts.add('+${l.brief(cur.rootArea)}');
    } else if (l.kind != ProbeLayerKind.offscreen &&
        (o.bounds != l.bounds || o.extra != l.extra)) {
      parts.add('~${l.brief(cur.rootArea)}');
    }
  }
  for (final ProbeLayer l in prev.layers) {
    if (!b.containsKey(l.id) && big(l, prev.rootArea)) {
      parts.add('-${l.brief(prev.rootArea)}');
    }
  }
  return parts.join(' ');
}

String countsOf(LayerFrame f) =>
    'n=${f.totalLayers} off=${f.of(ProbeLayerKind.offscreen).length}'
    '(${f.offscreenAreaPct().toStringAsFixed(0)}%) '
    'tex=${f.of(ProbeLayerKind.texture).length} '
    'pv=${f.of(ProbeLayerKind.platformView).length}';

/// 层 → 持有者 widget 链（最多 [depth] 个祖先，按 widget 运行时类型）。
Map<int, String> attributeLayers(
  Iterable<ProbeLayer> layers, {
  int depth = 14,
}) {
  final Map<int, RenderObject> owners = <int, RenderObject>{};
  void visitRender(RenderObject ro) {
    final ContainerLayer? l = ro.layer;
    if (l != null) owners[identityHashCode(l)] = ro;
    ro.visitChildren(visitRender);
  }

  for (final RenderView v in RendererBinding.instance.renderViews) {
    visitRender(v);
  }
  final Map<int, Element> elements = <int, Element>{};
  void visitElement(Element e) {
    final RenderObject? ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro != null) elements.putIfAbsent(identityHashCode(ro), () => e);
    e.visitChildren(visitElement);
  }

  final Element? rootElement = WidgetsBinding.instance.rootElement;
  if (rootElement != null) visitElement(rootElement);

  String chainOf(Element e) {
    final List<String> names = <String>[_widgetName(e.widget)];
    e.visitAncestorElements((Element a) {
      final String n = _widgetName(a.widget);
      if (n.startsWith('_') && a.widget.key == null) return true;
      names.add(n);
      return names.length < depth;
    });
    return names.join(' < ');
  }

  final Map<int, String> result = <int, String>{};
  for (final ProbeLayer p in layers) {
    Layer? l = p.layer;
    bool indirect = false;
    String? found;
    while (l != null) {
      final RenderObject? ro = owners[identityHashCode(l)];
      if (ro != null) {
        final Element? e = elements[identityHashCode(ro)];
        found =
            '${indirect ? '~' : ''}${ro.runtimeType}'
            '${e == null ? '' : ' :: ${chainOf(e)}'}';
        break;
      }
      indirect = true;
      l = l.parent;
    }
    result[p.id] = found ?? '?';
  }
  return result;
}

String _widgetName(Widget w) {
  final Key? k = w.key;
  return k is ValueKey<String>
      ? '${w.runtimeType}(${k.value})'
      : '${w.runtimeType}';
}

/// 逐帧记录：每帧合成之后走一次 layer 树（持久帧回调排在 RendererBinding 的
/// drawFrame 之后，此时树就是刚送进引擎的那一棵）。
class LayerFrameRecorder {
  LayerFrameRecorder() {
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  bool active = false;
  bool Function()? panelMounted;
  final List<(int, bool, LayerFrame)> frames = <(int, bool, LayerFrame)>[];

  /// 帧序号 → 当帧就地做的归属（element 树还在的时候做）。只在首帧、列表挂载
  /// 状态翻转那帧、以及离屏 / 纹理 / 平台视图有增删的帧做，平时不走 element 树。
  final Map<int, Map<int, String>> owners = <int, Map<int, String>>{};

  void start() {
    frames.clear();
    owners.clear();
    active = true;
  }

  void _onFrame(Duration _) {
    if (!active) return;
    final int vs =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    final bool panel = panelMounted?.call() ?? false;
    final LayerFrame f = captureLayerFrame();
    final int idx = frames.length;
    final bool changed =
        idx == 0 ||
        frames.last.$2 != panel ||
        diffLayerFrames(frames.last.$3, f, 5).isNotEmpty;
    if (changed) owners[idx] = attributeLayers(f.layers);
    frames.add((vs, panel, f));
  }
}
