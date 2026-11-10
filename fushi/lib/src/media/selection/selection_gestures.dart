/// 库页多选的手势层：按键修饰符判定、卡片身份标记、长按扫选。
///
/// 与 [MediaSelectionController]（纯语义）分开：这一层只负责「用户这一下是什么
/// 意思」，判完调 controller。
///
/// ## 手势归属
///
/// 两个库页都必须先通过标签栏末尾明确的「选择」入口进入多选态。未进入选择态时，
/// 触屏长按和桌面长按 / 右键都继续打开卡片上下文菜单；进入选择态后，卡片点击切换
/// 勾选，长按后滑动由 [SelectionDragArea] 接管为扫选；鼠标按下即拖则拉出选框框选。桌面额外保留
/// Ctrl/⌘/Shift + 点击直接进入多选的既有快捷路径。
///
/// | | 触屏（Android / iOS / Fuchsia） | 桌面（鼠标） |
/// |---|---|---|
/// | 上下文菜单 | 长按卡片 | 长按 / 右键 |
/// | 进入多选 | 点「选择」 | 点「选择」或 Ctrl/⌘/Shift + 点击 |
/// | 多选态内扩选 | 长按后滑动扫选 | Shift + 点击 / 长按后滑动扫选 / 按住左键拖动框选 |
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable, setEquals;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart'
    show
        ParentData,
        RenderMetaData,
        RenderOffstage,
        SliverMultiBoxAdaptorParentData;
import 'package:flutter/services.dart';

import 'package:fushi/src/media/selection/media_selection_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 多选态内的一次点击该按哪种语义：按住 Shift = 区间扩选，否则普通切换。
///
/// 读 [HardwareKeyboard] 而不是从手势事件里取：`InkWell.onTap` 不带修饰符，
/// 而全局键盘状态在点击那一刻就是准的。
SelectionTapKind selectionTapKind() => HardwareKeyboard.instance.isShiftPressed
    ? SelectionTapKind.extend
    : SelectionTapKind.toggle;

/// 非多选态下，这一次点击是不是「用修饰键直接进多选」。
///
/// macOS 用 ⌘、其余桌面用 Ctrl（各自平台的多选惯例）；Shift 也算，此时相当于
/// 进多选并选中该项（无锚点，区间退化为单项）。Android / iOS / Fuchsia 即使
/// 外接物理键盘也恒 false：触屏库页必须先点明确的「选择」入口。
bool selectionEntryModifierPressed(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
      break;
  }
  final HardwareKeyboard keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed) return true;
  return Theme.of(context).platform == TargetPlatform.macOS
      ? keyboard.isMetaPressed
      : keyboard.isControlPressed;
}

/// 给卡片贴上「我是哪一格」的标记，供 [SelectionDragArea] 按屏幕坐标反查。
///
/// 用 [MetaData] 而不是自建几何注册表（视频页 `CardDropRegistry` 那种）：
/// [MetaData] 走真实命中测试，滚动、裁剪、遮挡、`Sliver` 复用全部天然正确，
/// 且不改变布局（不会动到既有的等尺寸 golden 断言）。
class SelectionSlotTarget extends StatelessWidget {
  const SelectionSlotTarget({
    required this.slot,
    required this.child,
    super.key,
  });

  final SelectionSlot slot;
  final Widget child;

  @override
  Widget build(BuildContext context) => MetaData(metaData: slot, child: child);
}

/// 长按扫选 + 鼠标拖动框选的接管区：包在库页滚动体外面，多选态才生效。
///
/// 只在 [enabled] 为真（= 多选态）时**接上**手势回调。多选态下参与多选的卡片
/// 自身的 `onLongPress` / 右键菜单已置 null（两页原有纪律；右键那一半 BUG-2111 后由
/// 卡片外层的 [ContextMenuTrigger] 承担，`onInvoke` 传 null 即整层让路），故这里的
/// 长按在这些卡上无竞争对手；快速点击仍归卡片 `InkWell.onTap`（长按识别器要过
/// `kLongPressTimeout` 才宣布胜出），列表滚动仍归 `Scrollable`（手指先动就
/// 由拖动识别器赢下竞技场，长按根本不会触发）。
///
/// ⚠️ 「卡片长按已置 null」只对**参与多选的卡**成立。不可单独勾选的卡（合集成员
/// 卡、远端占位卡）在多选态仍保留自己的长按菜单，长按它们归卡片、不起手扫选——
/// 它们本来也没有 [SelectionSlot]，扫不出东西。别把这条注释读成「多选态下全页
/// 没有第二个长按识别器」。
///
/// ## 鼠标框选（反馈 bFtYB0_Arl）
///
/// 桌面用户批量删视频时要「鼠标一拖就选一片」，长按 500ms 再扫太慢。多选态下
/// **鼠标**左键按下即拖 = 拉出一个矩形框，框碰到的卡全部并入选中集（基线 ∪
/// 框内，框缩回去离开的格恢复原状），松手框淡出。只认 [PointerDeviceKind.mouse]：
///
/// - 触屏的「按下即拖」是滚动列表，不能被抢；触屏仍走长按扫选。
/// - 桌面 `Scrollable` 的 `dragDevices` 默认不含鼠标，所以鼠标拖动在库页本来
///   就不滚动，框选不和滚动争竞技场；卡片单击仍归 `InkWell.onTap`
///   （框选识别器要移动超过与点击容差相同的 [kTouchSlop] 才宣布胜出，见
///   [_BoxSelectGestureRecognizer]）。
/// - 卡片的拖拽排序 / 拖入合集在多选态已关闭（两页的拖拽开关都随
///   `!_selectionMode`），也不冲突。
/// - 嵌在库页里的横滑行（合集书架行等）给鼠标放开了横向拖动，它的识别器更深、
///   横向 slop 更小，在那上面横拖仍归横滑；框选从别处起手即可。
///
/// 框内命中**不走点命中测试**，而是遍历本层渲染子树里所有 [SelectionSlotTarget]
/// 的 [RenderMetaData]，取其在本层坐标系里的包围盒与框求交。跳过 sliver
/// keep-alive 桶里的离屏子节点与 [Offstage] 子树（它们不在屏幕上，几何也不可信），
/// 再把框夹在本层边界内——列表 cache extent 里预建、但在视口外的卡因此不会被
/// 框进来。
///
/// 🔴 [GestureDetector] / [RawGestureDetector] / [CustomPaint] **恒建**，只按
/// [enabled] 决定回调 / 识别器传不传：早期实现在 `!enabled` 时 early-return
/// `child`，导致进/退多选态时这一层的子树形状变化（`Element` 无法复用 → 整棵
/// body 重建），用户正翻到列表中段一进多选就被弹回顶部（两个库页都没有
/// `PageStorageKey` / 外挂 `ScrollController` 兜底）。守卫见
/// `test/media/selection_gestures_test.dart` 的「进/退多选态不重建子树」组。
///
/// ⚠️ 未做边缘自动滚动：手指 / 鼠标扫到边缘不会自动翻页，需要松开滚动后再扫 /
/// 再框（框选在基线上叠加，分几次框不会丢前面框过的）。这是刻意的范围——
/// 自动滚动要引入定时器 + 速度曲线，且框的起点要改成内容坐标，值得单独一轮验证。
class SelectionDragArea extends StatefulWidget {
  const SelectionDragArea({
    required this.enabled,
    required this.onDragBegin,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
    this.onBoxSelectBegin,
    this.onBoxSelectUpdate,
    super.key,
  });

  /// 多选态才为真。
  final bool enabled;

  /// 长按落在某张卡上：记基线并选中它。
  final void Function(SelectionSlot slot) onDragBegin;

  /// 扫过某张卡：刷成 [锚点, slot] 区间。
  final void Function(SelectionSlot slot) onDragUpdate;

  /// 抬手（长按扫选与鼠标框选共用）。
  final VoidCallback onDragEnd;

  /// 鼠标框选起手：记基线（[MediaSelectionController.beginBoxSelect]）。
  /// 与 [onBoxSelectUpdate] 都给了才启用鼠标框选。
  final VoidCallback? onBoxSelectBegin;

  /// 框内命中的格集合变化：选中集 = 基线 ∪ slots
  /// （[MediaSelectionController.updateBoxSelect]）。
  final void Function(Set<SelectionSlot> slots)? onBoxSelectUpdate;

  final Widget child;

  @override
  State<SelectionDragArea> createState() => _SelectionDragAreaState();
}

class _SelectionDragAreaState extends State<SelectionDragArea>
    with SingleTickerProviderStateMixin {
  /// 本次扫选是否真的起始于一张卡。落在空白处长按不算开始，后续移动一概忽略。
  bool _dragging = false;

  /// 上一次已上报的格，用于对 `onLongPressMoveUpdate` 的高频回调去重
  /// （一次滑动每帧都回调，同一张卡上重复刷区间是纯浪费）。
  SelectionSlot? _lastSlot;

  /// 框选进行中。
  bool _boxing = false;

  /// 框的起点（本层局部坐标）。
  Offset _boxOrigin = Offset.zero;

  /// 上一次已上报的框内格集合，去重用（每帧鼠标移动都回调，集合没变不上报）。
  Set<SelectionSlot> _lastBoxSlots = const <SelectionSlot>{};

  /// 当前框（本层局部坐标，已夹在本层边界内）；null = 不画。走 notifier 只重绘
  /// 前景层，不触发整棵库页重建。
  final ValueNotifier<Rect?> _boxRect = ValueNotifier<Rect?>(null);

  /// 框的不透明度：起手瞬间到 1，松手淡出到 0 后清框。
  late final AnimationController _boxFade = AnimationController(
    vsync: this,
    value: 0,
  );

  bool get _boxEnabled =>
      widget.enabled &&
      widget.onBoxSelectBegin != null &&
      widget.onBoxSelectUpdate != null;

  /// 多选态在扫选途中被关掉（批量操作落库后自动退出多选）时，识别器的回调已被
  /// 摘成 null，`onLongPressEnd` 永远不会再来。不在这里收尾的话 [_dragging] 会
  /// 一直留 true，下次进多选后第一次滑动就会绕过 [_handleStart] 直接刷区间。
  /// 框选同理：识别器被摘掉后 `onEnd` 不会再来，框要就地收起。
  @override
  void didUpdateWidget(SelectionDragArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _dragging = false;
      _lastSlot = null;
      _boxing = false;
      _lastBoxSlots = const <SelectionSlot>{};
      _boxFade.value = 0;
      _boxRect.value = null;
    }
  }

  @override
  void dispose() {
    _boxFade.dispose();
    _boxRect.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 恒建 GestureDetector + RawGestureDetector + CustomPaint（见类 doc 🔴）：
    // 树形状不随 enabled 变，滚动位置才不会在进/退多选态时被重建冲掉。回调置
    // null / 识别器表为空时不注册任何识别器，命中行为与不存在这一层等价。
    final bool on = widget.enabled;
    final Color tint = isCupertinoPlatform(context)
        ? CupertinoTheme.of(context).primaryColor
        : Theme.of(context).colorScheme.primary;
    return GestureDetector(
      // 卡片之间的间隙也要能起手（不然扫选起点必须精确落在卡上）。非多选态回调
      // 全 null，此时 translucent 也不会吃掉任何命中（无识别器 = 不参与竞技场）。
      behavior: HitTestBehavior.translucent,
      onLongPressStart: on ? _handleStart : null,
      onLongPressMoveUpdate: on ? _handleMove : null,
      onLongPressEnd: on ? _handleEnd : null,
      onLongPressCancel: on ? _handleCancel : null,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          if (_boxEnabled)
            _BoxSelectGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _BoxSelectGestureRecognizer
                >(() => _BoxSelectGestureRecognizer(debugOwner: this), (
                  _BoxSelectGestureRecognizer instance,
                ) {
                  instance
                    // 框的起点必须是按下处，而不是越过 slop 后的位置。
                    ..dragStartBehavior = DragStartBehavior.down
                    ..onStart = _handleBoxStart
                    ..onUpdate = _handleBoxUpdate
                    ..onEnd = _handleBoxEnd
                    ..onCancel = _handleBoxCancel;
                }),
        },
        child: CustomPaint(
          foregroundPainter: _SelectionBoxPainter(
            rect: _boxRect,
            opacity: _boxFade,
            color: tint,
          ),
          // 选框每帧随鼠标重绘：把库页正文隔成独立图层，重绘只画框、不重放
          // 整页卡片的绘制。不改布局。
          child: RepaintBoundary(child: widget.child),
        ),
      ),
    );
  }

  void _handleStart(LongPressStartDetails details) {
    // 鼠标按住不动过了长按时限前已开始框选：同一指针不再另起扫选。
    if (_boxing) return;
    final SelectionSlot? slot = _slotAt(details.globalPosition);
    if (slot == null) return;
    _dragging = true;
    _lastSlot = slot;
    widget.onDragBegin(slot);
  }

  void _handleMove(LongPressMoveUpdateDetails details) {
    if (!_dragging) return;
    final SelectionSlot? slot = _slotAt(details.globalPosition);
    // 滑到空白 / 跨到另一分区时保持上一帧结果，不抖动。
    if (slot == null || slot == _lastSlot) return;
    _lastSlot = slot;
    widget.onDragUpdate(slot);
  }

  void _handleEnd(LongPressEndDetails details) => _finish();

  void _handleCancel() => _finish();

  void _finish() {
    if (!_dragging) return;
    _dragging = false;
    _lastSlot = null;
    widget.onDragEnd();
  }

  void _handleBoxStart(DragStartDetails details) {
    // 同一指针已被长按扫选接管时不另起框。
    if (_dragging) return;
    final VoidCallback? begin = widget.onBoxSelectBegin;
    if (begin == null) return;
    _boxing = true;
    _boxOrigin = details.localPosition;
    _lastBoxSlots = const <SelectionSlot>{};
    _boxFade.value = 1;
    _boxRect.value = _clampedRect(_boxOrigin, _boxOrigin);
    begin();
  }

  void _handleBoxUpdate(DragUpdateDetails details) {
    if (!_boxing) return;
    final Rect? rect = _clampedRect(_boxOrigin, details.localPosition);
    _boxRect.value = rect;
    final Set<SelectionSlot> hits = rect == null
        ? const <SelectionSlot>{}
        : _slotsIn(rect);
    if (setEquals(hits, _lastBoxSlots)) return;
    _lastBoxSlots = hits;
    widget.onBoxSelectUpdate?.call(hits);
  }

  void _handleBoxEnd(DragEndDetails details) => _finishBox();

  void _handleBoxCancel() => _finishBox();

  void _finishBox() {
    if (!_boxing) return;
    _boxing = false;
    _lastBoxSlots = const <SelectionSlot>{};
    widget.onDragEnd();
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    if (fade == Duration.zero) {
      _boxFade.value = 0;
      _boxRect.value = null;
      return;
    }
    _boxFade
        .animateTo(0, duration: fade, curve: FushiMotion.exit)
        .whenCompleteOrCancel(() {
          // 淡出途中又起了新框：框归新一轮，不清。
          if (!_boxing && mounted) _boxRect.value = null;
        });
  }

  /// 起点 / 终点围成的框，夹在本层边界内（框外的部分本来就看不见，也不该框到
  /// 视口外 cache extent 里预建的卡）。本层还没布局时返回 null。
  Rect? _clampedRect(Offset a, Offset b) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final Rect bounds = Offset.zero & box.size;
    final Rect raw = Rect.fromPoints(a, b);
    final Rect clamped = Rect.fromLTRB(
      raw.left.clamp(bounds.left, bounds.right).toDouble(),
      raw.top.clamp(bounds.top, bounds.bottom).toDouble(),
      raw.right.clamp(bounds.left, bounds.right).toDouble(),
      raw.bottom.clamp(bounds.top, bounds.bottom).toDouble(),
    );
    return clamped;
  }

  /// [rect]（本层局部坐标）碰到的所有 [SelectionSlotTarget] 身份。
  Set<SelectionSlot> _slotsIn(Rect rect) {
    final RenderObject? root = context.findRenderObject();
    if (root is! RenderBox || !root.attached) return const <SelectionSlot>{};
    final Set<SelectionSlot> hits = <SelectionSlot>{};
    void visit(RenderObject node) {
      if (node is RenderOffstage && node.offstage) return;
      if (node is RenderMetaData) {
        final Object? meta = node.metaData;
        if (meta is SelectionSlot && node.hasSize) {
          final Rect bounds = MatrixUtils.transformRect(
            node.getTransformTo(root),
            Offset.zero & node.size,
          );
          if (bounds.overlaps(rect)) hits.add(meta);
        }
      }
      node.visitChildren((RenderObject child) {
        // sliver 列表 keep-alive 桶里的子节点已滚出视口，不在本次布局里，
        // 它的变换不代表屏幕位置。
        final ParentData? data = child.parentData;
        if (data is SliverMultiBoxAdaptorParentData && data.keptAlive) return;
        visit(child);
      });
    }

    visit(root);
    return hits;
  }

  /// 屏幕坐标 → 该处卡片的 [SelectionSlot]（无卡则 null）。
  SelectionSlot? _slotAt(Offset globalPosition) {
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      globalPosition,
      View.of(context).viewId,
    );
    for (final HitTestEntry<HitTestTarget> entry in result.path) {
      final HitTestTarget target = entry.target;
      // 命中路径上可能有别的 MetaData（视频页给卡挂过 meta: VideoBookRow），
      // 按类型筛掉，不做位置约定。
      if (target is RenderMetaData) {
        final Object? meta = target.metaData;
        if (meta is SelectionSlot) return meta;
      }
    }
    return null;
  }
}

/// 鼠标框选的拖动识别器：只认鼠标，且要移动超过 [kTouchSlop] 才宣布胜出。
///
/// 为什么不直接用 [PanGestureRecognizer]：它对鼠标的起拖阈值是
/// [kPrecisePointerPanSlop]（2 逻辑像素），而卡片 `InkWell` 的点击容差是
/// [kTouchSlop]。点一下取消勾选时手抖 3 像素，框选就会抢走这次点击、把卡又框
/// 回选中——用户以为点了没反应。把起拖阈值对齐点击容差后，「点击」与「拖框」
/// 的分界和卡片自身的点击判定是同一条线，不会互相吃。
class _BoxSelectGestureRecognizer extends PanGestureRecognizer {
  _BoxSelectGestureRecognizer({super.debugOwner})
    : super(
        supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse},
      );

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved.abs() > kTouchSlop;
}

/// 鼠标框选的选框：半透明填充 + 1px 描边，颜色取当前设计系统的主色。
class _SelectionBoxPainter extends CustomPainter {
  _SelectionBoxPainter({
    required this.rect,
    required this.opacity,
    required this.color,
  }) : super(repaint: Listenable.merge(<Listenable>[rect, opacity]));

  final ValueListenable<Rect?> rect;
  final Animation<double> opacity;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? box = rect.value;
    final double alpha = opacity.value.clamp(0.0, 1.0).toDouble();
    if (box == null || alpha == 0 || box.isEmpty) return;
    canvas.drawRect(
      box,
      Paint()..color = color.withValues(alpha: 0.16 * alpha),
    );
    canvas.drawRect(
      box.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.85 * alpha),
    );
  }

  @override
  bool shouldRepaint(_SelectionBoxPainter oldDelegate) =>
      oldDelegate.rect != rect ||
      oldDelegate.opacity != opacity ||
      oldDelegate.color != color;
}
