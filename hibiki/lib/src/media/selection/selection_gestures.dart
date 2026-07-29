/// 库页多选的手势层：按键修饰符判定、卡片身份标记、长按扫选。
///
/// 与 [MediaSelectionController]（纯语义）分开：这一层只负责「用户这一下是什么
/// 意思」，判完调 controller。
///
/// ## 手势归属
///
/// 两个库页都必须先通过标签栏末尾明确的「选择」入口进入多选态。未进入选择态时，
/// 触屏长按和桌面长按 / 右键都继续打开卡片上下文菜单；进入选择态后，卡片点击切换
/// 勾选，长按后滑动才由 [SelectionDragArea] 接管为扫选。桌面额外保留
/// Ctrl/⌘/Shift + 点击直接进入多选的既有快捷路径。
///
/// | | 触屏（Android / iOS / Fuchsia） | 桌面（鼠标） |
/// |---|---|---|
/// | 上下文菜单 | 长按卡片 | 长按 / 右键 |
/// | 进入多选 | 点「选择」 | 点「选择」或 Ctrl/⌘/Shift + 点击 |
/// | 多选态内扩选 | 长按后滑动扫选 | Shift + 点击 / 长按后滑动扫选 |
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderMetaData;
import 'package:flutter/services.dart';

import 'package:hibiki/src/media/selection/media_selection_controller.dart';

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
/// 只在 [enabled] 为真（= 多选态）时**接上**长按回调。多选态下参与多选的卡片
/// 自身的 `onLongPress` / `onSecondaryTap` 已置 null（两页原有纪律），故这里的
/// 长按在这些卡上无竞争对手；快速点击仍归卡片 `InkWell.onTap`（长按识别器要过
/// `kLongPressTimeout` 才宣布胜出），列表滚动仍归 `Scrollable`（手指先动就
/// 由拖动识别器赢下竞技场，长按根本不会触发）。
///
/// ⚠️ 「卡片长按已置 null」只对**参与多选的卡**成立。不可单独勾选的卡（合集成员
/// 卡、远端占位卡）在多选态仍保留自己的长按菜单，长按它们归卡片、不起手扫选——
/// 它们本来也没有 [SelectionSlot]，扫不出东西。别把这条注释读成「多选态下全页
/// 没有第二个长按识别器」。
///
/// 🔴 [GestureDetector] **恒建**，只按 [enabled] 决定回调传不传 null：早期实现
/// 在 `!enabled` 时 early-return `child`，导致进/退多选态时这一层的子树形状
/// 变化（`GestureDetector` ↔ 业务子树 `runtimeType` 不同 → `Element` 无法复用
/// → 整棵 body 重建），用户正翻到列表中段一进多选就被弹回顶部（两个库页都没有
/// `PageStorageKey` / 外挂 `ScrollController` 兜底）。守卫见
/// `test/media/selection_gestures_test.dart` 的「进/退多选态不重建子树」组。
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

  /// 多选态在扫选途中被关掉（批量操作落库后自动退出多选）时，识别器的回调已被
  /// 摘成 null，`onLongPressEnd` 永远不会再来。不在这里收尾的话 [_dragging] 会
  /// 一直留 true，下次进多选后第一次滑动就会绕过 [_handleStart] 直接刷区间。
  @override
  void didUpdateWidget(SelectionDragArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _dragging = false;
      _lastSlot = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 恒建 GestureDetector（见类 doc 🔴）：树形状不随 enabled 变，滚动位置才不会
    // 在进/退多选态时被重建冲掉。回调置 null 时 GestureDetector 不注册任何识别器，
    // 命中行为与不存在这一层等价。
    final bool on = widget.enabled;
    return GestureDetector(
      // 卡片之间的间隙也要能起手（不然扫选起点必须精确落在卡上）。非多选态回调
      // 全 null，此时 translucent 也不会吃掉任何命中（无识别器 = 不参与竞技场）。
      behavior: HitTestBehavior.translucent,
      onLongPressStart: on ? _handleStart : null,
      onLongPressMoveUpdate: on ? _handleMove : null,
      onLongPressEnd: on ? _handleEnd : null,
      onLongPressCancel: on ? _handleCancel : null,
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
