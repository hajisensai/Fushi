import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_sections.dart';
import 'package:fushi/src/mining/advanced_mining/manga_crop_geometry.dart'
    show containRect;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;
import 'package:fushi_engine/media/image_mosaic.dart' show applyMosaicRgba;

/// 「高级制卡」的打码：在卡图上框出一块或多块打马赛克（galgame HCG 等不想原图进卡）。
///
/// 预览与出卡同一个纯函数（`applyMosaicRgba`，块大小按长边比例），所以这里看到的
/// 马赛克就是卡上的样子。坐标一律是相对**未裁切原图**的 0..1 归一化矩形。

/// 预览解码时长边上限：对话框里的图最大也就几百逻辑像素，全尺寸解 4K 截图只是白占
/// 内存；马赛克块按比例取，缩小解码不改变打出来的块形。
const int kMiningMosaicPreviewMaxEdge = 1600;

/// 框选时小于这个归一化边长的拖动当作误触（与 [MiningMosaicRegion.isDegenerate] 同阈）。
const double kMiningMosaicMinExtent = 0.005;

/// 读出编码图像的像素尺寸（只读头，不解整图）；解不开返回 null。
Future<Size?> decodeMiningImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 || descriptor.height <= 0) return null;
    return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// 两点拖出的归一化区域（[imageRect] 是图在画布里的像素矩形）。太小返回 null。
MiningMosaicRegion? mosaicRegionFromDrag(Offset a, Offset b, Rect imageRect) {
  if (imageRect.width <= 0 || imageRect.height <= 0) return null;
  double nx(double x) =>
      ((x - imageRect.left) / imageRect.width).clamp(0.0, 1.0);
  double ny(double y) =>
      ((y - imageRect.top) / imageRect.height).clamp(0.0, 1.0);
  final MiningMosaicRegion region = MiningMosaicRegion(
    left: math.min(nx(a.dx), nx(b.dx)),
    top: math.min(ny(a.dy), ny(b.dy)),
    right: math.max(nx(a.dx), nx(b.dx)),
    bottom: math.max(ny(a.dy), ny(b.dy)),
  );
  if (region.width < kMiningMosaicMinExtent ||
      region.height < kMiningMosaicMinExtent) {
    return null;
  }
  return region;
}

/// 把 [bytes] 解出来、按 [regions] 打好码再画（[fit] 同 [Image]）。[bytes] 为 null /
/// 解不开时画一块中性底。
class MiningMosaicImage extends StatefulWidget {
  const MiningMosaicImage({
    super.key,
    required this.bytes,
    required this.regions,
    this.fit = BoxFit.contain,
  });

  final Uint8List? bytes;
  final List<MiningMosaicRegion> regions;
  final BoxFit fit;

  @override
  State<MiningMosaicImage> createState() => _MiningMosaicImageState();
}

class _MiningMosaicImageState extends State<MiningMosaicImage> {
  Uint8List? _rgba;
  int _width = 0;
  int _height = 0;
  ui.Image? _shown;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  @override
  void didUpdateWidget(MiningMosaicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      unawaited(_decode());
    } else if (!_sameRegions(oldWidget.regions, widget.regions)) {
      unawaited(_render());
    }
  }

  @override
  void dispose() {
    _gen++;
    _shown?.dispose();
    super.dispose();
  }

  static bool _sameRegions(
    List<MiningMosaicRegion> a,
    List<MiningMosaicRegion> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _decode() async {
    final int gen = ++_gen;
    final Uint8List? bytes = widget.bytes;
    _rgba = null;
    if (bytes == null || bytes.isEmpty) {
      _setShown(null, gen);
      return;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int w = descriptor.width;
      final int h = descriptor.height;
      final double scale = math.min(
        1.0,
        kMiningMosaicPreviewMaxEdge / math.max(1, math.max(w, h)),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (w * scale).round()),
        targetHeight: math.max(1, (h * scale).round()),
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (!mounted || gen != _gen || data == null) {
        image.dispose();
        return;
      }
      _rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      _width = image.width;
      _height = image.height;
      if (widget.regions.isEmpty) {
        _setShown(image, gen);
      } else {
        image.dispose();
        await _render();
      }
    } catch (_) {
      _setShown(null, gen);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> _render() async {
    final Uint8List? base = _rgba;
    if (base == null) return;
    final int gen = ++_gen;
    final Uint8List pixels = Uint8List.fromList(base);
    applyMosaicRgba(pixels, _width, _height, widget.regions);
    final Completer<ui.Image> done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      _width,
      _height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    final ui.Image image = await done.future;
    if (!mounted || gen != _gen) {
      image.dispose();
      return;
    }
    _setShown(image, gen);
  }

  void _setShown(ui.Image? image, int gen) {
    if (!mounted || gen != _gen) {
      image?.dispose();
      return;
    }
    final ui.Image? old = _shown;
    setState(() => _shown = image);
    old?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui.Image? image = _shown;
    if (image == null) {
      return ColoredBox(color: FushiDesignTokens.of(context).surfaces.overlay);
    }
    return RawImage(
      image: image,
      fit: widget.fit,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// 打码画布：图按 contain 放进画布，在图上拖动拉出一个新区域（[onAdd]），已有区域画
/// 描边。纯受控：区域真值在父组件。[image] 是画在图位置上的内容（通常是
/// [MiningMosaicImage]），测试里可换成色块。
class MiningMosaicCanvas extends StatefulWidget {
  const MiningMosaicCanvas({
    super.key,
    required this.imageSize,
    required this.image,
    required this.regions,
    required this.onAdd,
    this.focusRect,
    this.enabled = true,
  });

  /// 图的像素尺寸：决定显示纵横比（必须与归一化坐标同一张图）。
  final Size imageSize;
  final Widget image;
  final List<MiningMosaicRegion> regions;
  final ValueChanged<MiningMosaicRegion> onAdd;

  /// 参考框（漫画的取景框，归一化）：框外压暗，提示「框外的码会被裁掉」。
  final Rect? focusRect;
  final bool enabled;

  @override
  State<MiningMosaicCanvas> createState() => _MiningMosaicCanvasState();
}

class _MiningMosaicCanvasState extends State<MiningMosaicCanvas> {
  Rect _imageRect = Rect.zero;
  Offset? _dragStart;
  Offset? _dragNow;

  void _end() {
    final Offset? a = _dragStart;
    final Offset? b = _dragNow;
    setState(() {
      _dragStart = null;
      _dragNow = null;
    });
    if (a == null || b == null) return;
    final MiningMosaicRegion? region = mosaicRegionFromDrag(a, b, _imageRect);
    if (region != null) widget.onAdd(region);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size box = constraints.biggest;
        _imageRect = containRect(widget.imageSize, box);
        final Offset? a = _dragStart;
        final Offset? b = _dragNow;
        return MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.precise
              : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 框从按下的那一点起，而不是越过拖动阈值的那一点。
            dragStartBehavior: DragStartBehavior.down,
            onPanStart: widget.enabled
                ? (DragStartDetails d) => setState(() {
                    _dragStart = d.localPosition;
                    _dragNow = d.localPosition;
                  })
                : null,
            onPanUpdate: widget.enabled
                ? (DragUpdateDetails d) =>
                      setState(() => _dragNow = d.localPosition)
                : null,
            onPanEnd: widget.enabled ? (_) => _end() : null,
            onPanCancel: widget.enabled
                ? () => setState(() {
                    _dragStart = null;
                    _dragNow = null;
                  })
                : null,
            child: Stack(
              children: <Widget>[
                Positioned.fromRect(rect: _imageRect, child: widget.image),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _MosaicOverlayPainter(
                      imageRect: _imageRect,
                      regions: widget.regions,
                      focusRect: widget.focusRect,
                      draft: a == null || b == null
                          ? null
                          : Rect.fromPoints(
                              a,
                              b,
                            ).intersect(_imageRect.inflate(0.5)),
                      stroke: scheme.primary,
                      scrim: Colors.black.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MosaicOverlayPainter extends CustomPainter {
  _MosaicOverlayPainter({
    required this.imageRect,
    required this.regions,
    required this.focusRect,
    required this.draft,
    required this.stroke,
    required this.scrim,
  });

  final Rect imageRect;
  final List<MiningMosaicRegion> regions;
  final Rect? focusRect;
  final Rect? draft;
  final Color stroke;
  final Color scrim;

  Rect _toPx(double l, double t, double r, double b) => Rect.fromLTRB(
    imageRect.left + l * imageRect.width,
    imageRect.top + t * imageRect.height,
    imageRect.left + r * imageRect.width,
    imageRect.top + b * imageRect.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? focus = focusRect;
    if (focus != null) {
      final Path outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(imageRect)
        ..addRect(_toPx(focus.left, focus.top, focus.right, focus.bottom));
      canvas.drawPath(outside, Paint()..color = scrim);
    }
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = stroke;
    for (final MiningMosaicRegion r in regions) {
      canvas.drawRect(_toPx(r.left, r.top, r.right, r.bottom), line);
    }
    final Rect? d = draft;
    if (d != null) {
      canvas.drawRect(d, Paint()..color = stroke.withValues(alpha: 0.18));
      canvas.drawRect(d, line..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_MosaicOverlayPainter old) =>
      old.imageRect != imageRect ||
      old.regions != regions ||
      old.focusRect != focusRect ||
      old.draft != draft ||
      old.stroke != stroke;
}

/// 打开打码编辑页：在 [bytes] 上增删区域，「完成」返回新的整组区域，「×」/ 返回键
/// 返回 null（不改）。
Future<List<MiningMosaicRegion>?> showMiningMosaicEditor(
  BuildContext context, {
  required Uint8List bytes,
  required List<MiningMosaicRegion> initial,
  Rect? focusRect,
}) {
  final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<List<MiningMosaicRegion>>(
    PageRouteBuilder<List<MiningMosaicRegion>>(
      fullscreenDialog: true,
      transitionDuration: duration,
      reverseTransitionDuration: fushiMotionDuration(
        context,
        FushiMotion.longReverse,
      ),
      pageBuilder:
          (BuildContext context, Animation<double> a, Animation<double> b) =>
              MiningMosaicEditorPage(
                bytes: bytes,
                initial: initial,
                focusRect: focusRect,
              ),
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondary,
            Widget child,
          ) {
            final Animation<double> curved = CurvedAnimation(
              parent: animation,
              curve: FushiMotion.enter,
              reverseCurve: FushiMotion.exit,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
    ),
  );
}

/// 打码编辑页：顶栏 ×（放弃）/「完成」，工具行「撤销 / 清除」，中间整图框选。
/// 撤销按操作步回退（含撤销「清除」）；Ctrl/⌘+Z 撤销，Enter 完成，Esc 放弃。
class MiningMosaicEditorPage extends StatefulWidget {
  const MiningMosaicEditorPage({
    super.key,
    required this.bytes,
    required this.initial,
    this.focusRect,
  });

  final Uint8List bytes;
  final List<MiningMosaicRegion> initial;
  final Rect? focusRect;

  @override
  State<MiningMosaicEditorPage> createState() => _MiningMosaicEditorPageState();
}

class _MiningMosaicEditorPageState extends State<MiningMosaicEditorPage> {
  late List<MiningMosaicRegion> _regions = List<MiningMosaicRegion>.of(
    widget.initial,
  );
  final List<List<MiningMosaicRegion>> _history = <List<MiningMosaicRegion>>[];
  Size? _size;
  bool _sizeFailed = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSize());
  }

  Future<void> _loadSize() async {
    final Size? size = await decodeMiningImageSize(widget.bytes);
    if (!mounted) return;
    setState(() {
      _size = size;
      _sizeFailed = size == null;
    });
  }

  void _commit(List<MiningMosaicRegion> next) {
    setState(() {
      _history.add(_regions);
      _regions = next;
    });
  }

  void _add(MiningMosaicRegion region) =>
      _commit(<MiningMosaicRegion>[..._regions, region]);

  void _undo() {
    if (_history.isEmpty) return;
    setState(() => _regions = _history.removeLast());
  }

  void _clear() {
    if (_regions.isEmpty) return;
    _commit(const <MiningMosaicRegion>[]);
  }

  void _close({required bool keep}) {
    if (_done) return;
    _done = true;
    Navigator.of(
      context,
    ).pop(keep ? List<MiningMosaicRegion>.unmodifiable(_regions) : null);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    if ((kb.isControlPressed || kb.isMetaPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      _undo();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      _close(keep: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Size? size = _size;
    final Widget canvas;
    if (size != null) {
      canvas = MiningMosaicCanvas(
        imageSize: size,
        regions: _regions,
        focusRect: widget.focusRect,
        onAdd: _add,
        image: MiningMosaicImage(
          bytes: widget.bytes,
          regions: _regions,
          fit: BoxFit.fill,
        ),
      );
    } else if (_sizeFailed) {
      canvas = Center(
        child: Text(
          t.popup_advanced_mining_still_unavailable,
          style: context.fushiType.bodyMedium.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    } else {
      canvas = const Center(child: FushiLoadingView(compact: true));
    }
    return PopScope(
      canPop: false,
      // 系统返回 = 「×」放弃。
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _close(keep: false);
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          appBar: FushiAppBar(
            leading: FushiIconButtonControl(
              tooltip: t.popup_ctx_cancel,
              onPressed: () => _close(keep: false),
              icon: const FushiIcon(FushiIcons.close),
            ),
            title: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(t.popup_advanced_mining_mosaic_page_title),
            ),
            actions: <Widget>[
              FushiFilledButton(
                onPressed: () => _close(keep: true),
                child: Text(t.popup_advanced_mining_crop_done),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      FushiFilledButton.tonalIcon(
                        size: FushiButtonSize.s,
                        onPressed: _history.isEmpty ? null : _undo,
                        icon: const FushiIcon(FushiIcons.undo, size: 18),
                        label: Text(t.popup_advanced_mining_mosaic_undo),
                      ),
                      FushiFilledButton.tonalIcon(
                        size: FushiButtonSize.s,
                        onPressed: _regions.isEmpty ? null : _clear,
                        icon: const FushiIcon(FushiIcons.deleteSweep, size: 18),
                        label: Text(t.popup_advanced_mining_mosaic_clear),
                      ),
                      Text(
                        _regions.isEmpty
                            ? t.popup_advanced_mining_mosaic_hint
                            : t.popup_advanced_mining_mosaic_count(
                                count: _regions.length,
                              ),
                        style: context.fushiType.labelMedium.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: FushiDesignTokens.of(context).surfaces.search,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(14),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: canvas,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 图片分区里的打码行：「打码」按钮（打开编辑页）+ 已打几处 +「清除」。
///
/// [loadBytes] 交出要打码的那张原图（未裁切）；返回 null = 此刻取不到图，按钮如实
/// 提示不可用。[note] 是额外说明（例如「打码后改为静态截图」）。
class AdvancedMiningMosaicBar extends StatelessWidget {
  const AdvancedMiningMosaicBar({
    super.key,
    required this.controller,
    required this.loadBytes,
    this.focusRect,
    this.note,
  });

  final AdvancedMiningController controller;
  final Future<Uint8List?> Function() loadBytes;
  final Rect? focusRect;
  final String? note;

  Future<void> _edit(BuildContext context) async {
    final AdvancedMiningController c = controller;
    final Uint8List? bytes = await loadBytes();
    if (!context.mounted) return;
    if (bytes == null || bytes.isEmpty) {
      FushiToast.show(
        msg: t.popup_advanced_mining_still_unavailable,
        severity: ToastSeverity.info,
      );
      return;
    }
    final List<MiningMosaicRegion>? next = await showMiningMosaicEditor(
      context,
      bytes: bytes,
      initial: c.mosaicRegions,
      focusRect: focusRect,
    );
    if (next != null) c.setMosaicRegions(next);
  }

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int count = c.mosaicRegions.length;
    final TextStyle caption = context.fushiType.labelMedium.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FushiFilledButton.tonalIcon(
              size: FushiButtonSize.xs,
              onPressed: c.locked ? null : () => unawaited(_edit(context)),
              icon: const FushiIcon(FushiIcons.blur, size: 16),
              label: Text(t.popup_advanced_mining_mosaic_edit),
            ),
            Text(
              count == 0
                  ? t.popup_advanced_mining_mosaic_none
                  : t.popup_advanced_mining_mosaic_count(count: count),
              style: caption,
            ),
            if (count > 0)
              FushiTextButton(
                size: FushiButtonSize.xs,
                onPressed: c.locked ? null : c.clearMosaic,
                child: Text(t.popup_advanced_mining_mosaic_clear),
              ),
          ],
        ),
        if (note != null && count > 0) ...<Widget>[
          const SizedBox(height: 4),
          Text(note!, style: caption),
        ],
      ],
    );
  }
}

/// 静态截图分区（galgame texthooker）：冻结的那一帧（打好码的样子）+ 打码行。
class AdvancedMiningStillImagePanel extends StatelessWidget {
  const AdvancedMiningStillImagePanel({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  final AdvancedMiningController controller;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Uint8List? bytes = c.stillImageBytes;
    final Widget body;
    if (c.stillImageLoading) {
      body = const SizedBox(
        height: 120,
        child: Center(child: FushiLoadingView(compact: true)),
      );
    } else if (bytes == null) {
      body = Text(
        t.popup_advanced_mining_still_unavailable,
        style: context.fushiType.bodyMedium.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            child: SizedBox(
              height: 180,
              child: ColoredBox(
                color: FushiDesignTokens.of(context).surfaces.search,
                child: MiningMosaicImage(
                  bytes: bytes,
                  regions: c.mosaicRegions,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          AdvancedMiningMosaicBar(
            controller: c,
            loadBytes: () async => c.stillImageBytes,
            note: c.stillSection?.mosaicForcesStill ?? false
                ? t.popup_advanced_mining_mosaic_forces_still
                : null,
          ),
        ],
      );
    }
    final bool historical = c.stillSection?.historicalLine ?? false;
    return AdvancedMiningSectionShell(
      title: t.popup_advanced_mining_image_section,
      embedded: embedded,
      child: historical
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  t.popup_advanced_mining_still_stale,
                  style: context.fushiType.labelMedium.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                body,
              ],
            )
          : body,
    );
  }
}

/// 窄屏摘要行里的静态截图说明：`截图 · 已打码 2 处`。
String advancedMiningStillSummary(AdvancedMiningController c) {
  if (c.stillImageLoading) return '…';
  if (c.stillImageBytes == null) {
    return t.popup_advanced_mining_still_unavailable;
  }
  final int count = c.mosaicRegions.length;
  return count == 0
      ? t.popup_advanced_mining_still_screenshot
      : '${t.popup_advanced_mining_still_screenshot} · '
            '${t.popup_advanced_mining_mosaic_count(count: count)}';
}
