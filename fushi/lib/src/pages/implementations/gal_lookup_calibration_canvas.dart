import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';

enum GalCalibrationEditMode { region, points, pan }

enum _GridDragKind { cellAdvance, specialCharacterAdvance }

/// Edits screenshot coordinates only. Zoom never changes stored coordinates.
class GalLookupCalibrationCanvas extends StatefulWidget {
  const GalLookupCalibrationCanvas({
    required this.pngBytes,
    required this.client,
    required this.rect,
    this.layoutRect,
    this.grid,
    this.gridEditing = false,
    this.text,
    this.characterAdvances = const <GalLookupCharacterAdvanceV1>[],
    required this.boxes,
    required this.anchors,
    required this.selectedIndex,
    required this.mode,
    required this.opacity,
    required this.enabled,
    required this.onRectChanged,
    this.onLayoutRectChanged,
    this.onGridChanged,
    this.onCharacterAdvanceChanged,
    required this.onAnchorChanged,
    required this.onIndexSelected,
    required this.onHover,
    super.key,
  });

  final Uint8List pngBytes;
  final GalLookupReferenceClientV1 client;
  final GalLookupNormalizedRectV1 rect;
  final GalLookupNormalizedRectV1? layoutRect;
  final GalLookupCellGridV1? grid;
  final bool gridEditing;
  final String? text;
  final List<GalLookupCharacterAdvanceV1> characterAdvances;
  final List<GalCalibrationBox> boxes;
  final Map<int, Offset> anchors;
  final int? selectedIndex;
  final GalCalibrationEditMode mode;
  final double opacity;
  final bool enabled;
  final ValueChanged<GalLookupNormalizedRectV1> onRectChanged;
  final ValueChanged<GalLookupNormalizedRectV1>? onLayoutRectChanged;
  final ValueChanged<GalLookupCellGridV1>? onGridChanged;
  final void Function(int codePoint, double advanceRatio)?
  onCharacterAdvanceChanged;
  final void Function(int index, Offset point) onAnchorChanged;
  final ValueChanged<int> onIndexSelected;
  final ValueChanged<int?> onHover;

  @override
  State<GalLookupCalibrationCanvas> createState() =>
      _GalLookupCalibrationCanvasState();
}

class _GalLookupCalibrationCanvasState
    extends State<GalLookupCalibrationCanvas> {
  // A cell drag also updates every normal cell and the blue frame's right
  // edge, so using raw pointer distance makes a one-pixel movement feel much
  // too large. Keep the interaction continuous, but make it four times finer.
  static const double _cellResizeSensitivity = 0.25;

  final GlobalKey _sceneKey = GlobalKey();
  final TransformationController _transform = TransformationController();
  Rect? _dragRect;
  Offset? _dragStart;
  Offset? _anchorStart;
  Offset? _anchorOriginal;
  GalLookupNormalizedRectV1? _gridStartLayout;
  GalLookupCellGridV1? _gridStart;
  _GridDragKind? _gridDragKind;
  int? _gridStartCodePoint;
  double? _gridStartCharacterAdvanceRatio;
  int? _dragPointer;
  int? _panPointer;
  Offset? _panStartGlobal;
  Matrix4? _panStartTransform;
  Size _sceneSize = Size.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Offset _normalized(Offset global) {
    final RenderBox box =
        _sceneKey.currentContext!.findRenderObject()! as RenderBox;
    final Offset at = box.globalToLocal(global);
    return Offset(at.dx / _sceneSize.width, at.dy / _sceneSize.height);
  }

  Rect get _rect => Rect.fromLTWH(
    widget.rect.left,
    widget.rect.top,
    widget.rect.width,
    widget.rect.height,
  );

  void _beginRect(Offset global) {
    _dragRect = _rect;
    _dragStart = _normalized(global);
  }

  void _dragRegion(Offset global, Alignment? handle) {
    final Rect? original = _dragRect;
    final Offset? start = _dragStart;
    if (!widget.enabled || original == null || start == null) return;
    final Offset delta = _normalized(global) - start;
    // Older drafts may have a valid region smaller than the editor minimum.
    final double minWidth = math.min(
      original.width,
      math.max(0.001, 8 / widget.client.widthPx),
    );
    final double minHeight = math.min(
      original.height,
      math.max(0.001, 8 / widget.client.heightPx),
    );
    final Rect next;
    if (handle == null) {
      next = Rect.fromLTWH(
        (original.left + delta.dx).clamp(0, 1 - original.width),
        (original.top + delta.dy).clamp(0, 1 - original.height),
        original.width,
        original.height,
      );
    } else {
      next = Rect.fromLTRB(
        handle.x < 0
            ? (original.left + delta.dx).clamp(0, original.right - minWidth)
            : original.left,
        handle.y < 0
            ? (original.top + delta.dy).clamp(0, original.bottom - minHeight)
            : original.top,
        handle.x > 0
            ? (original.right + delta.dx).clamp(original.left + minWidth, 1)
            : original.right,
        handle.y > 0
            ? (original.bottom + delta.dy).clamp(original.top + minHeight, 1)
            : original.bottom,
      );
    }
    final GalLookupNormalizedRectV1 value = GalLookupNormalizedRectV1(
      left: next.left,
      top: next.top,
      width: next.width,
      height: next.height,
    );
    if (value.isValid) widget.onRectChanged(value);
  }

  void _moveAnchor(int index, Offset global) {
    if (!widget.enabled) return;
    final Offset at = _normalized(global);
    widget.onAnchorChanged(index, Offset(at.dx.clamp(0, 1), at.dy.clamp(0, 1)));
  }

  void _beginLayout(Offset global) {
    if (!widget.enabled || widget.grid == null) return;
    _gridStartLayout = widget.layoutRect ?? widget.rect;
    _dragStart = _normalized(global);
  }

  void _dragLayout(Offset global, Alignment? handle) {
    final Rect? original = _gridStartLayout == null
        ? null
        : Rect.fromLTWH(
            _gridStartLayout!.left,
            _gridStartLayout!.top,
            _gridStartLayout!.width,
            _gridStartLayout!.height,
          );
    final Offset? start = _dragStart;
    if (!widget.enabled || original == null || start == null) return;
    final Offset delta = _normalized(global) - start;
    final Rect next;
    if (handle == null) {
      next = Rect.fromLTWH(
        (original.left + delta.dx).clamp(0.0, 1.0 - original.width),
        (original.top + delta.dy).clamp(0.0, 1.0 - original.height),
        original.width,
        original.height,
      );
    } else {
      final double minWidth = math.min(
        original.width,
        math.max(0.001, 8 / widget.client.widthPx),
      );
      final double minHeight = math.min(
        original.height,
        math.max(0.001, 8 / widget.client.heightPx),
      );
      next = Rect.fromLTRB(
        handle.x < 0
            ? (original.left + delta.dx).clamp(0.0, original.right - minWidth)
            : original.left,
        handle.y < 0
            ? (original.top + delta.dy).clamp(0.0, original.bottom - minHeight)
            : original.top,
        handle.x > 0
            ? (original.right + delta.dx).clamp(original.left + minWidth, 1.0)
            : original.right,
        handle.y > 0
            ? (original.bottom + delta.dy).clamp(original.top + minHeight, 1.0)
            : original.bottom,
      );
    }
    widget.onLayoutRectChanged?.call(
      GalLookupNormalizedRectV1(
        left: next.left,
        top: next.top,
        width: next.width,
        height: next.height,
      ),
    );
  }

  void _beginCell(Offset global, int? codePoint) {
    if (!widget.enabled || widget.grid == null) return;
    _gridStartLayout = widget.layoutRect ?? widget.rect;
    _gridStart = widget.grid;
    _gridStartCodePoint = codePoint;
    _gridStartCharacterAdvanceRatio = codePoint == null
        ? null
        : _characterAdvanceRatio(codePoint);
    _gridDragKind = codePoint != null && _gridStartCharacterAdvanceRatio != null
        ? _GridDragKind.specialCharacterAdvance
        : _GridDragKind.cellAdvance;
    _dragStart = _normalized(global);
  }

  void _dragCell(Offset global) {
    final GalLookupCellGridV1? originalGrid = _gridStart;
    final GalLookupNormalizedRectV1? originalLayout = _gridStartLayout;
    final Offset? start = _dragStart;
    final _GridDragKind? kind = _gridDragKind;
    if (!widget.enabled ||
        originalGrid == null ||
        originalLayout == null ||
        start == null ||
        kind == null) {
      return;
    }
    final Offset delta = _normalized(global) - start;
    final double horizontalClientDelta =
        delta.dx *
        widget.client.widthPx /
        widget.client.heightPx *
        _cellResizeSensitivity;
    if (kind == _GridDragKind.specialCharacterAdvance) {
      final int? codePoint = _gridStartCodePoint;
      final double? originalRatio = _gridStartCharacterAdvanceRatio;
      final double baseAdvance = originalGrid.advancePerClientHeight;
      if (codePoint == null || originalRatio == null || baseAdvance <= 0) {
        return;
      }
      final double nextRatio =
          (originalRatio + horizontalClientDelta / baseAdvance).clamp(
            GalLookupCharacterAdvanceV1.minAdvanceRatio,
            GalLookupCharacterAdvanceV1.maxAdvanceRatio,
          );
      final double actualDelta = baseAdvance * (nextRatio - originalRatio);
      widget.onCharacterAdvanceChanged?.call(codePoint, nextRatio);
      _syncLayoutRight(
        originalLayout,
        actualDelta,
        cellCount: _specialCharacterOccurrences(codePoint),
      );
      return;
    }

    final double nextAdvance =
        (originalGrid.advancePerClientHeight + horizontalClientDelta).clamp(
          0.001,
          0.25,
        );
    final double actualDelta =
        nextAdvance - originalGrid.advancePerClientHeight;
    final GalLookupCellGridV1 nextGrid = _copyGrid(
      originalGrid,
      advancePerClientHeight: nextAdvance,
    );
    if (nextGrid.isValid) {
      widget.onGridChanged?.call(nextGrid);
      _syncLayoutRight(
        originalLayout,
        actualDelta,
        cellCount: originalGrid.effectiveLineWidthInCells,
      );
    }
  }

  void _syncLayoutRight(
    GalLookupNormalizedRectV1 originalLayout,
    double cellAdvanceDelta, {
    required num cellCount,
  }) {
    if (cellAdvanceDelta == 0 || !cellAdvanceDelta.isFinite) return;
    final double widthDelta =
        cellAdvanceDelta * widget.client.heightPx / widget.client.widthPx;
    final double right = (originalLayout.right + widthDelta * cellCount).clamp(
      originalLayout.left +
          math.min(
            originalLayout.width,
            math.max(0.001, 8 / widget.client.widthPx),
          ),
      1.0,
    );
    widget.onLayoutRectChanged?.call(
      GalLookupNormalizedRectV1(
        left: originalLayout.left,
        top: originalLayout.top,
        width: right - originalLayout.left,
        height: originalLayout.height,
      ),
    );
  }

  double? _characterAdvanceRatio(int codePoint) {
    for (final GalLookupCharacterAdvanceV1 value in widget.characterAdvances) {
      if (value.codePoint == codePoint) return value.advanceRatio;
    }
    return null;
  }

  int? _characterAtBox(GalCalibrationBox box) {
    final String? text = widget.text;
    if (text == null ||
        box.charIndex < 0 ||
        box.charIndex >= text.length ||
        box.charLength <= 0) {
      return null;
    }
    final int end = math.min(text.length, box.charIndex + box.charLength);
    final Iterator<int> codePoints = text
        .substring(box.charIndex, end)
        .runes
        .iterator;
    return codePoints.moveNext() ? codePoints.current : null;
  }

  int _specialCharacterOccurrences(int codePoint) {
    if (widget.boxes.isEmpty) return 1;
    final double rowTolerance = math.max(
      1.0,
      widget.client.heightPx *
          (widget.grid?.lineAdvancePerClientHeight ?? 0.05) *
          0.45,
    );
    final List<({double top, int count})> rows = [];
    for (final GalCalibrationBox box in widget.boxes) {
      if (_characterAtBox(box) != codePoint) continue;
      final double top = box.hitRect.top;
      final int row = rows.indexWhere(
        (value) => (value.top - top).abs() <= rowTolerance,
      );
      if (row < 0) {
        rows.add((top: top, count: 1));
      } else {
        rows[row] = (top: rows[row].top, count: rows[row].count + 1);
      }
    }
    if (rows.isEmpty) return 1;
    return rows
        .map((({double top, int count}) value) => value.count)
        .reduce(math.max);
  }

  GalLookupCellGridV1 _copyGrid(
    GalLookupCellGridV1 grid, {
    double? advancePerClientHeight,
  }) => grid.copyWith(advancePerClientHeight: advancePerClientHeight);

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!widget.enabled || event is! PointerScrollEvent) return;
    final double delta = event.scrollDelta.dy;
    if (delta == 0) return;
    final double current = _transform.value.getMaxScaleOnAxis();
    final double factor = delta < 0 ? 1.15 : 1 / 1.15;
    _zoom(current * factor, focusGlobal: event.position);
  }

  bool _isEditingSurfaceHit(Offset global) {
    if (_sceneSize == Size.zero || widget.mode == GalCalibrationEditMode.pan) {
      return false;
    }
    final Offset at = _normalized(global);
    final GalLookupNormalizedRectV1 active = widget.gridEditing
        ? (widget.layoutRect ?? widget.rect)
        : widget.rect;
    final double paddingX = 14 / widget.client.widthPx;
    final double paddingY = 14 / widget.client.heightPx;
    return at.dx >= active.left - paddingX &&
        at.dx <= active.right + paddingX &&
        at.dy >= active.top - paddingY &&
        at.dy <= active.bottom + paddingY;
  }

  void _beginPan(PointerDownEvent event) {
    if (!widget.enabled ||
        widget.mode == GalCalibrationEditMode.pan ||
        _panPointer != null ||
        event.buttons != kPrimaryButton ||
        _isEditingSurfaceHit(event.position)) {
      return;
    }
    _panPointer = event.pointer;
    _panStartGlobal = event.position;
    _panStartTransform = _transform.value.clone();
  }

  void _dragPan(PointerMoveEvent event) {
    if (!widget.enabled ||
        event.pointer != _panPointer ||
        _panStartGlobal == null ||
        _panStartTransform == null) {
      return;
    }
    final Offset delta = event.position - _panStartGlobal!;
    final Matrix4 next = _panStartTransform!.clone();
    next.setTranslationRaw(
      _panStartTransform!.entry(0, 3) + delta.dx,
      _panStartTransform!.entry(1, 3) + delta.dy,
      _panStartTransform!.entry(2, 3),
    );
    _transform.value = next;
    setState(() {});
  }

  void _endPan(PointerEvent event) {
    if (event.pointer != _panPointer) return;
    _panPointer = null;
    _panStartGlobal = null;
    _panStartTransform = null;
  }

  void _zoom(double zoom, {Offset? focusGlobal}) {
    final double currentScale = _transform.value.getMaxScaleOnAxis();
    final double scale = zoom.clamp(1.0, 8.0).toDouble();
    if (scale == 1) {
      _transform.value = Matrix4.identity();
    } else if (focusGlobal != null && _sceneSize != Size.zero) {
      // Keep the image point currently under the pointer at the same screen
      // position while changing scale. `_normalized` accounts for the
      // existing transform, so this also behaves correctly after panning.
      final Offset focus = _normalized(focusGlobal);
      final Offset focusPx = Offset(
        focus.dx * _sceneSize.width,
        focus.dy * _sceneSize.height,
      );
      final Matrix4 currentTransform = _transform.value;
      final Matrix4 next = Matrix4.diagonal3Values(scale, scale, 1);
      next.setTranslationRaw(
        currentTransform.entry(0, 3) + (currentScale - scale) * focusPx.dx,
        currentTransform.entry(1, 3) + (currentScale - scale) * focusPx.dy,
        currentTransform.entry(2, 3),
      );
      _transform.value = next;
    } else {
      final Offset focus = widget.anchors[widget.selectedIndex] ?? _rect.center;
      _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(
          _sceneSize.width * (0.5 - focus.dx * scale),
          _sceneSize.height * (0.5 - focus.dy * scale),
          0,
        );
    }
    setState(() {});
  }

  Widget _viewport(Widget scene) {
    if (widget.mode == GalCalibrationEditMode.pan) {
      return InteractiveViewer(
        transformationController: _transform,
        maxScale: 8,
        boundaryMargin: const EdgeInsets.all(2000),
        child: scene,
      );
    }
    // InteractiveViewer installs a scale recognizer even when pan/scale are
    // disabled. Editing has one pointer owner and responds to small movements.
    return ClipRect(
      child: Transform(transform: _transform.value, child: scene),
    );
  }

  Widget _dragTarget({
    required Key key,
    required ValueChanged<Offset> onStart,
    required ValueChanged<Offset> onUpdate,
    Widget? child,
  }) => Listener(
    key: key,
    behavior: HitTestBehavior.opaque,
    onPointerDown: (PointerDownEvent event) {
      if (!widget.enabled ||
          _dragPointer != null ||
          event.buttons != kPrimaryButton) {
        return;
      }
      _dragPointer = event.pointer;
      onStart(event.position);
    },
    onPointerMove: (PointerMoveEvent event) {
      if (widget.enabled && event.pointer == _dragPointer) {
        onUpdate(event.position);
      }
    },
    onPointerUp: (PointerUpEvent event) {
      if (event.pointer == _dragPointer) _dragPointer = null;
    },
    onPointerCancel: (PointerCancelEvent event) {
      if (event.pointer == _dragPointer) _dragPointer = null;
    },
    child: child,
  );

  Widget _layoutDragTarget({
    required Key key,
    required Rect rect,
    required Alignment? handle,
  }) => Positioned.fromRect(
    rect: rect,
    child: MouseRegion(
      cursor: handle == null
          ? SystemMouseCursors.move
          : handle.x == 0
          ? SystemMouseCursors.resizeUpDown
          : handle.y == 0
          ? SystemMouseCursors.resizeLeftRight
          : handle.x == handle.y
          ? SystemMouseCursors.resizeUpLeftDownRight
          : SystemMouseCursors.resizeUpRightDownLeft,
      child: _dragTarget(
        key: key,
        onStart: _beginLayout,
        onUpdate: (Offset global) => _dragLayout(global, handle),
        child: const SizedBox.expand(),
      ),
    ),
  );

  Widget _layoutCornerHandle({
    required String key,
    required Offset center,
    required Alignment handle,
  }) => Positioned(
    left: center.dx - 6,
    top: center.dy - 6,
    width: 12,
    height: 12,
    child: MouseRegion(
      cursor: handle.x == handle.y
          ? SystemMouseCursors.resizeUpLeftDownRight
          : SystemMouseCursors.resizeUpRightDownLeft,
      child: _dragTarget(
        key: ValueKey<String>(key),
        onStart: _beginLayout,
        onUpdate: (Offset global) => _dragLayout(global, handle),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.lightBlue,
            border: Border.all(color: Colors.white, width: 1),
          ),
        ),
      ),
    ),
  );

  Widget _cellResizeHandle({
    required String key,
    required Rect rect,
    required int? codePoint,
  }) => Positioned(
    left: rect.right - 6,
    top: rect.top,
    width: 12,
    height: math.max(12, rect.height),
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: _dragTarget(
        key: ValueKey<String>(key),
        onStart: (Offset global) => _beginCell(global, codePoint),
        onUpdate: _dragCell,
        child: const SizedBox.expand(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double scale = math.min(
        constraints.maxWidth / widget.client.widthPx,
        constraints.maxHeight / widget.client.heightPx,
      );
      _sceneSize = Size(
        widget.client.widthPx * scale,
        widget.client.heightPx * scale,
      );
      final Rect body = Rect.fromLTWH(
        widget.rect.left * _sceneSize.width,
        widget.rect.top * _sceneSize.height,
        widget.rect.width * _sceneSize.width,
        widget.rect.height * _sceneSize.height,
      );
      final GalLookupNormalizedRectV1 layoutRect =
          widget.layoutRect ?? widget.rect;
      final Rect layoutBody = Rect.fromLTWH(
        layoutRect.left * _sceneSize.width,
        layoutRect.top * _sceneSize.height,
        layoutRect.width * _sceneSize.width,
        layoutRect.height * _sceneSize.height,
      );
      final bool editRegion =
          widget.enabled &&
          widget.mode == GalCalibrationEditMode.region &&
          !widget.gridEditing;
      final bool editPoints =
          widget.enabled && widget.mode == GalCalibrationEditMode.points;
      final bool editGrid =
          widget.enabled && widget.gridEditing && widget.grid != null;
      final double sx = _sceneSize.width / widget.client.widthPx;
      final double sy = _sceneSize.height / widget.client.heightPx;
      Rect? sceneRectForBox(GalCalibrationBox? box) => box == null
          ? null
          : Rect.fromLTRB(
              box.hitRect.left * sx,
              box.hitRect.top * sy,
              box.hitRect.right * sx,
              box.hitRect.bottom * sy,
            );
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: Center(
              child: _viewport(
                SizedBox.fromSize(
                  key: _sceneKey,
                  size: _sceneSize,
                  child: Listener(
                    onPointerSignal: _handlePointerSignal,
                    onPointerDown: _beginPan,
                    onPointerMove: _dragPan,
                    onPointerUp: _endPan,
                    onPointerCancel: _endPan,
                    child: MouseRegion(
                      onExit: (_) => widget.onHover(null),
                      onHover: (PointerHoverEvent event) {
                        final Offset at = event.localPosition / scale;
                        int? hit;
                        for (final GalCalibrationBox box in widget.boxes) {
                          if (box.rect.contains(at)) {
                            hit = box.charIndex;
                            break;
                          }
                        }
                        widget.onHover(hit);
                      },
                      child: Stack(
                        clipBehavior: Clip.none,
                        fit: StackFit.expand,
                        children: <Widget>[
                          GestureDetector(
                            key: const ValueKey<String>('calibration-image'),
                            onTapUp: !editPoints || widget.selectedIndex == null
                                ? null
                                : (TapUpDetails details) => _moveAnchor(
                                    widget.selectedIndex!,
                                    details.globalPosition,
                                  ),
                            child: Image.memory(
                              widget.pngBytes,
                              fit: BoxFit.fill,
                              gaplessPlayback: false,
                            ),
                          ),
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _CalibrationPainter(
                                boxes: widget.boxes,
                                client: widget.client,
                                region: editRegion ? body : null,
                                layoutRegion: editGrid ? layoutBody : null,
                                anchors: widget.anchors,
                                selectedIndex: widget.selectedIndex,
                                opacity: widget.opacity,
                              ),
                            ),
                          ),
                          if (editRegion)
                            Positioned.fromRect(
                              rect: body,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.move,
                                child: _dragTarget(
                                  key: const ValueKey<String>(
                                    'calibration-region-move',
                                  ),
                                  onStart: _beginRect,
                                  onUpdate: (Offset global) =>
                                      _dragRegion(global, null),
                                ),
                              ),
                            ),
                          if (editRegion)
                            for (final (String, Alignment) handle
                                in const <(String, Alignment)>[
                                  ('top-left', Alignment.topLeft),
                                  ('top', Alignment.topCenter),
                                  ('top-right', Alignment.topRight),
                                  ('right', Alignment.centerRight),
                                  ('bottom-right', Alignment.bottomRight),
                                  ('bottom', Alignment.bottomCenter),
                                  ('bottom-left', Alignment.bottomLeft),
                                  ('left', Alignment.centerLeft),
                                ])
                              Positioned(
                                left:
                                    body.left +
                                    body.width * (handle.$2.x + 1) / 2 -
                                    10,
                                top:
                                    body.top +
                                    body.height * (handle.$2.y + 1) / 2 -
                                    10,
                                width: 20,
                                height: 20,
                                child: MouseRegion(
                                  cursor: handle.$2.x == 0
                                      ? SystemMouseCursors.resizeUpDown
                                      : handle.$2.y == 0
                                      ? SystemMouseCursors.resizeLeftRight
                                      : handle.$2.x == handle.$2.y
                                      ? SystemMouseCursors.resizeUpLeftDownRight
                                      : SystemMouseCursors
                                            .resizeUpRightDownLeft,
                                  child: _dragTarget(
                                    key: ValueKey<String>(
                                      'calibration-region-${handle.$1}',
                                    ),
                                    onStart: _beginRect,
                                    onUpdate: (Offset global) =>
                                        _dragRegion(global, handle.$2),
                                    child: Center(
                                      child: Container(
                                        width: 9,
                                        height: 9,
                                        color: Colors.orange,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          if (editPoints)
                            for (final MapEntry<int, Offset> anchor
                                in widget.anchors.entries)
                              Positioned(
                                left: anchor.value.dx * _sceneSize.width - 12,
                                top: anchor.value.dy * _sceneSize.height - 12,
                                width: 24,
                                height: 24,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.move,
                                  child: _dragTarget(
                                    key: ValueKey<String>(
                                      'calibration-anchor-${anchor.key}',
                                    ),
                                    onStart: (Offset global) {
                                      _anchorStart = _normalized(global);
                                      _anchorOriginal = anchor.value;
                                      widget.onIndexSelected(anchor.key);
                                    },
                                    onUpdate: (Offset global) {
                                      final Offset at =
                                          _anchorOriginal! +
                                          _normalized(global) -
                                          _anchorStart!;
                                      widget.onAnchorChanged(
                                        anchor.key,
                                        Offset(
                                          at.dx.clamp(0, 1),
                                          at.dy.clamp(0, 1),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                          if (editGrid) ...<Widget>[
                            _layoutDragTarget(
                              key: const ValueKey<String>(
                                'calibration-grid-move',
                              ),
                              rect: layoutBody,
                              handle: null,
                            ),
                            for (final GalCalibrationBox box in widget.boxes)
                              if (sceneRectForBox(box) case final Rect boxRect)
                                _cellResizeHandle(
                                  key: 'calibration-cell-${box.charIndex}',
                                  rect: boxRect,
                                  codePoint: _characterAtBox(box),
                                ),
                            for (final (String, Alignment) handle
                                in const <(String, Alignment)>[
                                  ('top-left', Alignment.topLeft),
                                  ('top-right', Alignment.topRight),
                                  ('bottom-left', Alignment.bottomLeft),
                                  ('bottom-right', Alignment.bottomRight),
                                ])
                              _layoutCornerHandle(
                                key: 'calibration-grid-${handle.$1}',
                                center: Offset(
                                  layoutBody.left +
                                      layoutBody.width * (handle.$2.x + 1) / 2,
                                  layoutBody.top +
                                      layoutBody.height * (handle.$2.y + 1) / 2,
                                ),
                                handle: handle.$2,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: t.game_lookup_samples_zoom_out,
                    icon: const Icon(Icons.zoom_out),
                    onPressed: () =>
                        _zoom(_transform.value.getMaxScaleOnAxis() / 1.5),
                  ),
                  IconButton(
                    tooltip: t.game_lookup_samples_zoom_in,
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () =>
                        _zoom(_transform.value.getMaxScaleOnAxis() * 1.5),
                  ),
                  IconButton(
                    tooltip: t.game_lookup_samples_zoom_reset,
                    icon: const Icon(Icons.fit_screen),
                    onPressed: () => _zoom(1),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _CalibrationPainter extends CustomPainter {
  const _CalibrationPainter({
    required this.boxes,
    required this.client,
    required this.region,
    required this.layoutRegion,
    required this.anchors,
    required this.selectedIndex,
    required this.opacity,
  });
  final List<GalCalibrationBox> boxes;
  final GalLookupReferenceClientV1 client;
  final Rect? region;
  final Rect? layoutRegion;
  final Map<int, Offset> anchors;
  final int? selectedIndex;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final double sx = size.width / client.widthPx;
    final double sy = size.height / client.heightPx;
    for (final GalCalibrationBox box in boxes) {
      final bool active = box.charIndex == selectedIndex;
      final Rect rect = Rect.fromLTRB(
        box.visualRect.left * sx,
        box.visualRect.top * sy,
        box.visualRect.right * sx,
        box.visualRect.bottom * sy,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = (active ? Colors.amber : Colors.cyan).withValues(
            alpha: opacity,
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 2 : 1,
      );
      if (active) {
        canvas.drawRect(
          rect,
          Paint()..color = Colors.amber.withValues(alpha: 0.15),
        );
      }
    }
    final Rect? region = this.region;
    if (region != null) {
      canvas.drawRect(
        region,
        Paint()
          ..color = Colors.orange
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final Rect? layoutRegion = this.layoutRegion;
    if (layoutRegion != null) {
      canvas.drawRect(
        layoutRegion,
        Paint()
          ..color = Colors.lightBlue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    for (final MapEntry<int, Offset> point in anchors.entries) {
      final Offset at = Offset(
        point.value.dx * size.width,
        point.value.dy * size.height,
      );
      final Paint paint = Paint()
        ..color = Colors.deepOrangeAccent
        ..strokeWidth = 2;
      canvas.drawLine(at - const Offset(5, 0), at + const Offset(5, 0), paint);
      canvas.drawLine(at - const Offset(0, 5), at + const Offset(0, 5), paint);
      if (point.key == selectedIndex) {
        canvas.drawCircle(at, 8, paint..style = PaintingStyle.stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CalibrationPainter old) =>
      old.boxes != boxes ||
      old.client != client ||
      old.region != region ||
      old.layoutRegion != layoutRegion ||
      old.anchors != anchors ||
      old.selectedIndex != selectedIndex ||
      old.opacity != opacity;
}
