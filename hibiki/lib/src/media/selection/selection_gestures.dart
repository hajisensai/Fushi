/// 库页多选的手势层：按键修饰符判定、卡片身份标记、长按扫选。
///
/// 与 [MediaSelectionController]（纯语义）分开：这一层只负责「用户这一下是什么
/// 意思」，判完调 controller。
///
/// ## 手势归属（2026-07 重划）
///
/// 长按此前在两个库页上都是「上下文菜单」（`card_widgets.part.dart` 的
/// `_bookCardShell`、`home_video_page.dart` 的视频卡），触屏因此没有任何进多选
/// 的快捷路径——这也是 `collection_drag.dart` 里「移动端不建拖拽源」那段注释记的
/// 死结的由来。现在按输入方式重新分派：
///
/// | | 触屏（Android / iOS / Fuchsia） | 桌面（鼠标） |
/// |---|---|---|
/// | 上下文菜单 | 卡片上的 `⋮` 按钮 | 右键 `onSecondaryTap`（**未变**） |
/// | 进入多选 | 长按卡片 | Ctrl/⌘ + 点击 |
/// | 多选态内扩选 | 长按后滑动扫选 | Shift + 点击 |
///
/// 桌面的长按（鼠标按住不动）保持弹菜单不变——桌面用户按住不动就是等菜单。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderMetaData;
import 'package:flutter/services.dart';

import 'package:hibiki/src/media/selection/media_selection_controller.dart';

/// 触屏平台（长按 = 进多选；桌面则长按 = 菜单）。
bool isTouchSelectionPlatform(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return true;
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
      return false;
  }
}

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
/// 进多选并选中该项（无锚点，区间退化为单项）。触屏无键盘，恒 false。
bool selectionEntryModifierPressed(BuildContext context) {
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

/// 长按扫选的接管区：包在库页滚动体外面，多选态才生效。
///
/// 只在 [enabled] 为真（= 多选态）时挂长按识别器。多选态下卡片自身的
/// `onLongPress` / `onSecondaryTap` 本就已置 null（两页原有纪律），故这里的
/// 长按无竞争对手；快速点击仍归卡片 `InkWell.onTap`（长按识别器要过
/// `kLongPressTimeout` 才宣布胜出），列表滚动仍归 `Scrollable`（手指先动就
/// 由拖动识别器赢下竞技场，长按根本不会触发）。
///
/// ⚠️ 未做边缘自动滚动：手指扫到屏幕边缘不会自动翻页，需要抬手滚动后再扫。
/// 这是刻意的 v1 范围——自动滚动要引入定时器 + 速度曲线，且与
/// `Scrollable` 的竞技场归属交互复杂，值得单独一轮验证。
class SelectionDragArea extends StatefulWidget {
  const SelectionDragArea({
    required this.enabled,
    required this.onDragBegin,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
    super.key,
  });

  /// 多选态才为真。
  final bool enabled;

  /// 长按落在某张卡上：记基线并选中它。
  final void Function(SelectionSlot slot) onDragBegin;

  /// 扫过某张卡：刷成 [锚点, slot] 区间。
  final void Function(SelectionSlot slot) onDragUpdate;

  /// 抬手。
  final VoidCallback onDragEnd;

  final Widget child;

  @override
  State<SelectionDragArea> createState() => _SelectionDragAreaState();
}

class _SelectionDragAreaState extends State<SelectionDragArea> {
  /// 本次扫选是否真的起始于一张卡。落在空白处长按不算开始，后续移动一概忽略。
  bool _dragging = false;

  /// 上一次已上报的格，用于对 `onLongPressMoveUpdate` 的高频回调去重
  /// （一次滑动每帧都回调，同一张卡上重复刷区间是纯浪费）。
  SelectionSlot? _lastSlot;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      // 卡片之间的间隙也要能起手（不然扫选起点必须精确落在卡上）。
      behavior: HitTestBehavior.translucent,
      onLongPressStart: _handleStart,
      onLongPressMoveUpdate: _handleMove,
      onLongPressEnd: _handleEnd,
      onLongPressCancel: _handleCancel,
      child: widget.child,
    );
  }

  void _handleStart(LongPressStartDetails details) {
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
