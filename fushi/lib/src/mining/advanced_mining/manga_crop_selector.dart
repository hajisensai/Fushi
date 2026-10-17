import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_mosaic.dart';
import 'package:fushi/src/mining/advanced_mining/manga_crop_geometry.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;

/// 选中框这一次变化是怎么来的。父组件据此决定是否把选项切到「自定义」：
/// 画框 / 平移 / 缩放 / 键盘微调都算用户自己框的，[panel]（Tab 切分镜）不算。
enum MangaCropEdit { draw, move, resize, nudge, panel }

/// 「这句话的位置」框的颜色（交互稿 ② / ④ 的橙色）。刻意不取主题色：它要和
/// primary 色系的选中框、分镜虚线在任何配色下都分得开。
const Color kMangaCropTextRectColor = Color(0xFFF2A65A);

/// 漫画裁切控件（高级制卡 · 漫画图片分区；自绘，不用 crop_image 包——那个包只有
/// 「一个框 + 手柄」，画不了分镜虚线 / 文字位置，也没有框外拖新框与 Tab 切分镜）。
///
/// 纯受控组件：选中框的真值在父组件（[selection]），这里只把指针 / 按键翻译成
/// `manga_crop_geometry.dart` 的纯函数调用，再经 [onChanged] 交回去。
///
/// 交互：
/// * 框外按下即拖出新框（Win+Shift+S 式）；框内拖动 = 平移；8 个手柄 = 缩放；
/// * 方向键平移、Shift+方向键调右 / 下边、Tab / Shift+Tab 在分镜间切换、Enter 提交。
class MangaCropSelector extends StatefulWidget {
  const MangaCropSelector({
    super.key,
    required this.pageBytes,
    required this.pageSize,
    required this.selection,
    required this.onChanged,
    this.panels = const <Rect>[],
    this.textRect,
    this.mosaic = const <MiningMosaicRegion>[],
    this.enabled = true,
    this.onSubmit,
    this.focusNode,
    this.autofocus = false,
    this.touch = false,
  });

  /// 原页图字节；null（还在加载 / 取不到）时画一块与页面同比例的中性占位底，
  /// 框选照常可用——用户能先按分镜 / 文字位置框选，图到了再看。
  final Uint8List? pageBytes;

  /// 原页像素尺寸：决定显示纵横比（必须与归一化坐标同一张图）。
  final Size pageSize;

  /// 当前选中框（归一化）；null = 不画框（「不要图片」）。
  final Rect? selection;

  final void Function(Rect rect, MangaCropEdit edit) onChanged;

  /// 检测到的分镜（归一化，阅读顺序）。
  final List<Rect> panels;

  /// 这句话的 OCR 文本位置（归一化）。
  final Rect? textRect;

  /// 打码区域（归一化，相对整页）：页图按卡上的样子画出马赛克。
  final List<MiningMosaicRegion> mosaic;

  /// false：整图压暗、不响应手势与键盘（「不要图片」时仍展示原页作参考）。
  final bool enabled;

  /// Enter / NumpadEnter：确认（手机全屏框选 = 「完成」，对话框 = 确认制卡）。
  final VoidCallback? onSubmit;

  final FocusNode? focusNode;
  final bool autofocus;

  /// 触屏形态（手机全屏框选）：手柄与命中区放大到手指尺寸。
  final bool touch;

  @override
  State<MangaCropSelector> createState() => _MangaCropSelectorState();
}

enum _DragMode { draw, move, resize }

class _MangaCropSelectorState extends State<MangaCropSelector>
    with SingleTickerProviderStateMixin {
  FocusNode? _ownFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode(debugLabel: 'crop'));

  // 程序性变化（父组件切「整页 / 所在分镜」、Tab 切分镜）用弹簧补间；拖动 / 微调
  // 直接跟手——补间会让框落后于手指，用户以为没拖动。
  late final AnimationController _anim = AnimationController(
    vsync: this,
    value: 1,
  );
  // 初值无所谓（控制器从 1 起步、首帧不补间）；不写裸 Curves，守卫只认 motion token。
  Curve _curve = FushiMotion.standard;
  Rect? _from;
  Rect? _to;

  // 自己最近一次经 [onChanged] 交出去、且应「跟手」的框。父组件把它原样回灌时
  // 识别出来直接到位，不补间。
  Rect? _lastSnapEmit;

  // 最新的选中框：自己刚交出去、父组件还没来得及重建回灌时也以它为准。连按方向键
  // 时两次按键之间可能还没出帧，按 widget.selection 算会从旧框出发、丢掉上一步。
  Rect? _selection;

  // 当前这次拖动。
  _DragMode? _dragMode;
  MangaCropHandle? _dragHandle;
  Offset _dragStartNorm = Offset.zero;
  Rect? _dragBase;
  bool _drawStarted = false;
  Offset _dragStartPx = Offset.zero;

  // 最近一次布局下页图在本控件内的像素矩形（命中判定与坐标换算都靠它）。
  Rect _imageRect = Rect.zero;

  MouseCursor _cursor = SystemMouseCursors.precise;
  bool _focused = false;

  double get _handleSize => widget.touch ? 22 : 14;
  double get _hitSlop => widget.touch ? 24 : 12;

  @override
  void initState() {
    super.initState();
    _selection = widget.selection;
    _from = widget.selection;
    _to = widget.selection;
  }

  @override
  void didUpdateWidget(MangaCropSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Rect? next = widget.selection;
    if (next == oldWidget.selection) return;
    _selection = next;
    final Rect? shown = _displayed;
    if (next == null || shown == null || next == _lastSnapEmit) {
      _snapTo(next);
      return;
    }
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    _from = shown;
    _to = next;
    if (spring.duration == Duration.zero) {
      _anim.value = 1;
      return;
    }
    _curve = spring.curve;
    _anim
      ..duration = spring.duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    _ownFocusNode?.dispose();
    super.dispose();
  }

  void _snapTo(Rect? rect) {
    _anim.stop();
    _from = rect;
    _to = rect;
    _anim.value = 1;
  }

  /// 当前画在屏上的框（补间中取插值）。
  Rect? get _displayed {
    final Rect? to = _to;
    final Rect? from = _from;
    if (to == null || from == null) return to;
    if (_anim.value >= 1) return to;
    return Rect.lerp(from, to, _curve.transform(_anim.value));
  }

  void _emit(Rect rect, MangaCropEdit edit) {
    _selection = rect;
    if (edit == MangaCropEdit.panel) {
      _lastSnapEmit = null;
    } else {
      _lastSnapEmit = rect;
    }
    widget.onChanged(rect, edit);
  }

  // ── 坐标换算 ──────────────────────────────────────────────

  Offset _toNorm(Offset px) {
    if (_imageRect.isEmpty) return Offset.zero;
    return Offset(
      (px.dx - _imageRect.left) / _imageRect.width,
      (px.dy - _imageRect.top) / _imageRect.height,
    );
  }

  Rect _toPx(Rect norm) => Rect.fromLTRB(
    _imageRect.left + norm.left * _imageRect.width,
    _imageRect.top + norm.top * _imageRect.height,
    _imageRect.left + norm.right * _imageRect.width,
    _imageRect.top + norm.bottom * _imageRect.height,
  );

  // ── 指针 ──────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d) {
    if (!widget.enabled || _imageRect.isEmpty) return;
    // 按下即拿焦点：鼠标框完接着用方向键细调，不用再 Tab 过来。
    _focusNode.requestFocus();
    final Offset p = d.localPosition;
    final Rect? sel = _selection;
    _dragStartPx = p;
    _dragStartNorm = _toNorm(p);
    _drawStarted = false;
    if (sel != null) {
      final Rect selPx = _toPx(sel);
      final MangaCropHandle? h = hitTestCropHandle(selPx, p, slop: _hitSlop);
      if (h != null) {
        _dragMode = _DragMode.resize;
        _dragHandle = h;
        _dragBase = sel;
        return;
      }
      if (cropRectContains(selPx, p)) {
        _dragMode = _DragMode.move;
        _dragBase = sel;
        return;
      }
    }
    _dragMode = _DragMode.draw;
    _dragBase = sel;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final _DragMode? mode = _dragMode;
    if (mode == null || !widget.enabled) return;
    final Offset p = d.localPosition;
    final Offset norm = _toNorm(p);
    final Offset delta = norm - _dragStartNorm;
    switch (mode) {
      case _DragMode.draw:
        // 框外单击（没真拖）不应凭空生出一个最小尺寸的小框把原选择冲掉：
        // 移动超过几个像素才算开始画。
        if (!_drawStarted &&
            (p - _dragStartPx).distance < (widget.touch ? 8 : 4)) {
          return;
        }
        _drawStarted = true;
        _emitIfChanged(
          cropRectFromDrag(_dragStartNorm, norm),
          MangaCropEdit.draw,
        );
      case _DragMode.move:
        // 用相对按下点的累计位移（而不是逐帧增量）：撞边被夹住后反向拖回来，
        // 框跟手指的相对位置不会漂。
        _emitIfChanged(moveCropRect(_dragBase!, delta), MangaCropEdit.move);
      case _DragMode.resize:
        _emitIfChanged(
          resizeCropRect(_dragBase!, _dragHandle!, delta),
          MangaCropEdit.resize,
        );
    }
  }

  void _onPanEndDetails(DragEndDetails _) => _onPanEnd();

  void _onPanEnd() {
    _dragMode = null;
    _dragHandle = null;
    _dragBase = null;
    _drawStarted = false;
  }

  void _emitIfChanged(Rect rect, MangaCropEdit edit) {
    if (rect == _selection) return;
    _emit(rect, edit);
  }

  void _onHover(PointerHoverEvent e) {
    final MouseCursor next = _cursorAt(e.localPosition);
    if (next != _cursor) setState(() => _cursor = next);
  }

  MouseCursor _cursorAt(Offset p) {
    if (!widget.enabled) return SystemMouseCursors.basic;
    final Rect? sel = _selection;
    if (sel == null || _imageRect.isEmpty) return SystemMouseCursors.precise;
    final Rect selPx = _toPx(sel);
    switch (hitTestCropHandle(selPx, p, slop: _hitSlop)) {
      case MangaCropHandle.topLeft:
      case MangaCropHandle.bottomRight:
        return SystemMouseCursors.resizeUpLeftDownRight;
      case MangaCropHandle.topRight:
      case MangaCropHandle.bottomLeft:
        return SystemMouseCursors.resizeUpRightDownLeft;
      case MangaCropHandle.top:
      case MangaCropHandle.bottom:
        return SystemMouseCursors.resizeUpDown;
      case MangaCropHandle.left:
      case MangaCropHandle.right:
        return SystemMouseCursors.resizeLeftRight;
      case null:
        return cropRectContains(selPx, p)
            ? SystemMouseCursors.move
            : SystemMouseCursors.precise;
    }
  }

  // ── 键盘 ──────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final bool shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.tab) {
      // 长按 Tab 的连发不切分镜：一次按键一格，免得一路滑出去。
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      final int? i = cyclePanelIndex(
        widget.panels,
        _selection,
        backward: shift,
      );
      // 越过两端交还给焦点遍历，键盘用户才出得去。
      if (i == null) return KeyEventResult.ignored;
      _emit(widget.panels[i], MangaCropEdit.panel);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final VoidCallback? submit = widget.onSubmit;
      if (submit == null || event is KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      submit();
      return KeyEventResult.handled;
    }
    final Offset? dir = switch (key) {
      LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
      LogicalKeyboardKey.arrowRight => const Offset(1, 0),
      LogicalKeyboardKey.arrowUp => const Offset(0, -1),
      LogicalKeyboardKey.arrowDown => const Offset(0, 1),
      _ => null,
    };
    final Rect? sel = _selection;
    if (dir == null || sel == null) return KeyEventResult.ignored;
    final Offset step = dir * kMangaCropNudgeStep;
    final Rect next = shift
        // Shift：只动右 / 下边——左上角是锚点，与常见截图工具的键盘缩放一致。
        ? resizeCropRect(
            sel,
            dir.dx != 0 ? MangaCropHandle.right : MangaCropHandle.bottom,
            step,
          )
        : moveCropRect(sel, step);
    if (next != sel) _emit(next, MangaCropEdit.nudge);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: t.popup_advanced_mining_crop_hint,
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        canRequestFocus: widget.enabled,
        onKeyEvent: _onKey,
        onFocusChange: (bool f) => setState(() => _focused = f),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size box = constraints.biggest;
            _imageRect = containRect(widget.pageSize, box);
            return MouseRegion(
              cursor: _cursor,
              onHover: _onHover,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: <Type, GestureRecognizerFactory>{
                  _EagerPanGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _EagerPanGestureRecognizer
                      >(_EagerPanGestureRecognizer.new, (
                        _EagerPanGestureRecognizer r,
                      ) {
                        r
                          ..dragStartBehavior = DragStartBehavior.down
                          ..onStart = _onPanStart
                          ..onUpdate = _onPanUpdate
                          ..onEnd = _onPanEndDetails
                          ..onCancel = _onPanEnd;
                      }),
                },
                child: SizedBox(
                  width: box.width,
                  height: box.height,
                  child: Stack(
                    children: <Widget>[
                      Positioned.fromRect(
                        rect: _imageRect,
                        child: _page(scheme),
                      ),
                      Positioned.fill(
                        child: AnimatedBuilder(
                          animation: _anim,
                          builder: (BuildContext context, Widget? _) =>
                              CustomPaint(
                                painter: _CropOverlayPainter(
                                  imageRect: _imageRect,
                                  selection: widget.enabled ? _displayed : null,
                                  panels: widget.panels,
                                  textRect: widget.textRect,
                                  enabled: widget.enabled,
                                  focused: _focused,
                                  handleSize: _handleSize,
                                  primary: scheme.primary,
                                  scrim: const Color(0x801C1B20),
                                ),
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _page(ColorScheme scheme) {
    final Uint8List? bytes = widget.pageBytes;
    if (bytes == null) {
      return ColoredBox(color: FushiDesignTokens.of(context).surfaces.overlay);
    }
    if (widget.mosaic.isNotEmpty) {
      return MiningMosaicImage(
        bytes: bytes,
        regions: widget.mosaic,
        fit: BoxFit.fill,
      );
    }
    return Image.memory(
      bytes,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// 按下即胜出的拖动识别器。
///
/// 裁切区常常放在可滚动的对话框正文里：普通 [PanGestureRecognizer] 要越过
/// `kPanSlop` 才认领，而外层竖向滚动只要 `kTouchSlop`，竖着拖框会被滚动抢走、
/// 框没动页面却滚了。在裁切区里按下就是要框选，所以直接认领。
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  _EagerPanGestureRecognizer();

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _CropOverlayPainter extends CustomPainter {
  _CropOverlayPainter({
    required this.imageRect,
    required this.selection,
    required this.panels,
    required this.textRect,
    required this.enabled,
    required this.focused,
    required this.handleSize,
    required this.primary,
    required this.scrim,
  });

  final Rect imageRect;
  final Rect? selection;
  final List<Rect> panels;
  final Rect? textRect;
  final bool enabled;
  final bool focused;
  final double handleSize;
  final Color primary;
  final Color scrim;

  Rect _px(Rect n) => Rect.fromLTRB(
    imageRect.left + n.left * imageRect.width,
    imageRect.top + n.top * imageRect.height,
    imageRect.left + n.right * imageRect.width,
    imageRect.top + n.bottom * imageRect.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (imageRect.isEmpty) return;
    canvas.save();
    // 弹簧补间有过冲，框可能短暂越出页面：一律裁在页图内画。
    canvas.clipRect(imageRect.inflate(handleSize));

    final Paint dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = primary.withValues(alpha: 0.65);
    for (final Rect p in panels) {
      _dashedRect(canvas, _px(p).deflate(1), dash);
    }

    final Rect? sel = selection;
    if (!enabled) {
      // 「不要图片」：整页压暗，保留原页作参考但明确「这张不会进卡片」。
      canvas.drawRect(imageRect, Paint()..color = scrim);
    } else if (sel != null) {
      final Rect selPx = _px(sel);
      final Path outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(imageRect)
        ..addRect(selPx);
      canvas.drawPath(outside, Paint()..color = scrim);
    }

    final Rect? text = textRect;
    if (text != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(_px(text).inflate(2), const Radius.circular(6)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = kMangaCropTextRectColor,
      );
    }

    if (enabled && sel != null) {
      final Rect selPx = _px(sel);
      canvas.drawRect(
        selPx,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = focused ? 3 : 2
          ..color = primary,
      );
      _handles(canvas, selPx);
    }
    canvas.restore();
  }

  void _handles(Canvas canvas, Rect r) {
    final Paint fill = Paint()..color = Colors.white;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = handleSize >= 20 ? 3 : 2
      ..color = primary;
    for (final MangaCropHandle h in MangaCropHandle.values) {
      final Offset c = cropHandleCenter(r, h);
      final bool corner =
          h == MangaCropHandle.topLeft ||
          h == MangaCropHandle.topRight ||
          h == MangaCropHandle.bottomLeft ||
          h == MangaCropHandle.bottomRight;
      final RRect shape;
      if (corner) {
        shape = RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: handleSize, height: handleSize),
          Radius.circular(handleSize / 2),
        );
      } else {
        // 边中点画成短胶囊，与角点区分：一眼看出它只改一条边。
        final bool horizontal =
            h == MangaCropHandle.top || h == MangaCropHandle.bottom;
        final double long = handleSize * 1.5;
        final double short = handleSize * 0.6;
        shape = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: c,
            width: horizontal ? long : short,
            height: horizontal ? short : long,
          ),
          Radius.circular(short / 2),
        );
      }
      canvas
        ..drawRRect(shape, fill)
        ..drawRRect(shape, stroke);
    }
  }

  void _dashedRect(Canvas canvas, Rect r, Paint paint) {
    const double on = 5;
    const double off = 4;
    void line(Offset a, Offset b) {
      final double len = (b - a).distance;
      if (len <= 0) return;
      final Offset dir = (b - a) / len;
      double d = 0;
      while (d < len) {
        final double e = (d + on).clamp(0.0, len);
        canvas.drawLine(a + dir * d, a + dir * e, paint);
        d += on + off;
      }
    }

    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) =>
      old.imageRect != imageRect ||
      old.selection != selection ||
      !identical(old.panels, panels) ||
      old.textRect != textRect ||
      old.enabled != enabled ||
      old.focused != focused ||
      old.handleSize != handleSize ||
      old.primary != primary ||
      old.scrim != scrim;
}
