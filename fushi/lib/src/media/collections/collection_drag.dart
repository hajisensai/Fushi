/// 「把卡片拖进合集」的共享拖放件（书架 / 漫画 / 视频库 / 游戏库共用）。
///
/// 拖拽源 [MediaCardDraggable] 挂在各库页的媒体卡上，payload 是 [LibraryCardDrag]
/// （带统一媒体身份 [MediaRef]）；接收端 [CollectionDropTarget] 挂在合集行头与合集
/// 封面卡，落下即 `FushiDatabase.addToCollection`（幂等：同一张卡重复拖同一个合集
/// 是 no-op，调用方据回调自行提示）。
///
/// 桌面库页的**直拖重排**也在这里（[LibraryDragReorderScope] + [LibraryReorderCell]，
/// 见其类 doc）：同一次拖动，落在卡与卡之间 = 重排，落在合集卡正中 = 加入合集。
///
/// payload 刻意用独立类型而**不复用**标签拖放的 `BookTagRow`：合集行头同时挂着
/// 两个 DragTarget（标签落下=给合集打标签 / 卡片落下=加入合集），靠泛型天然分流
/// 互不误接——`DragTarget<T>` 只接收 `T` 类型的 payload，无需任何运行时判别分支。
/// 这也让 `collection_shelf_row_tag_drop_test.dart` 里「`DragTarget<BookTagRow>`
/// 恰好一个 / 恰好零个」的既有断言保持成立。
library;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart'
    show FushiFocusRoot;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// [addMediaRefToCollection] 的结果：三种结局各自对应一条不同的用户可见提示。
enum CollectionAddOutcome {
  /// 真的写进去了。调用方据此刷新并报成功。
  added,

  /// 该条目本就在这个合集里（`addToCollection` 幂等，静默 no-op 对用户就是
  /// 「拖了没反应」）。已提示，调用方不必刷新。
  alreadyPresent,

  /// 落库失败（DB 锁 / 磁盘满 / schema 异常……）。已提示，**没有**写进去。
  failed,
}

/// 提示通道。默认 [FushiToast.show]；测试注入自己的收集器。
///
/// 刻意**不带** `ToastSeverity`：这一个通道要送两种语义（已存在=warning、落库
/// 失败=error），要着色就得把语义塞进 typedef，而 typedef 一改，注入自己收集器的
/// 测试（`test/media/collection_add_failure_test.dart`）全部失配。语义着色留到
/// 通道本身重构时一起做，这里维持旧的中性外观。
typedef CollectionAddNotifier = void Function(String message);

/// 「把一个 [MediaRef] 加进合集」的共享落库编排（书架 / 视频库 / 游戏库三处同一份）。
///
/// 三处此前各抄一遍「查成员 → 幂等提示 → 落库」，且**都没有 try/catch**，又都以
/// unawaited Future 挂在 `onMediaDropped` 这个 `void` 回调上：`addToCollection`
/// 抛出时异常直接漂进 zone，用户看到的只是「拖了没反应」——他会以为加成功了，
/// 而合集里其实什么都没有。这是「让用户基于错误信息做决定」的典型，必须报。
///
/// 故本函数**永不抛出**：任何失败都归到 [CollectionAddOutcome.failed] 并给出
/// 明确提示。调用方只需按返回值决定要不要刷新 + 报成功。
Future<CollectionAddOutcome> addMediaRefToCollection({
  required FushiDatabase database,
  required int collectionId,
  required MediaRef mediaRef,
  CollectionAddNotifier? notify,
}) async {
  final CollectionAddNotifier tell =
      notify ?? (String message) => FushiToast.show(msg: message);
  try {
    final List<MediaCollectionItemRow> items = await database
        .getCollectionItems(collectionId);
    final bool already = items.any(
      (MediaCollectionItemRow it) =>
          it.mediaType == mediaRef.dbMediaType &&
          it.entryKey == mediaRef.entryKey,
    );
    if (already) {
      tell(t.collection_already_has_item);
      return CollectionAddOutcome.alreadyPresent;
    }
    await database.addToCollection(
      collectionId,
      mediaRef.kind,
      mediaRef.entryKey,
    );
    return CollectionAddOutcome.added;
  } catch (error, stackTrace) {
    debugPrint('addMediaRefToCollection failed: $error\n$stackTrace');
    tell(t.collection_add_failed);
    return CollectionAddOutcome.failed;
  }
}

/// 媒体卡的拖拽源：拖起卡片，落到合集上即加入该合集。
///
/// **仅桌面端建拖拽源**（镜像 `fushi_reorder_drag_listener.dart` 的按平台范式）：
/// - 桌面（Windows / Linux / macOS，鼠标为主）→ [Draggable]（按下即拖）。与卡片
///   既有交互零冲突：`ImmediateMultiDragGestureRecognizer` 要指针移动超过
///   `kTouchSlop` 才在手势竞技场胜出，所以点击（按下即抬）仍归 `InkWell.onTap`
///   开书、按住不动仍归 `onLongPress` 弹菜单、右键仍归卡片外层的
///   [ContextMenuTrigger]（BUG-2111 后按绑定表判定，默认右键）。
///
///   ⚠️ **与横向合集行的鼠标拖动滚动（`HorizontalDragScrollable`）如何分流，未在
///   真机验证。** 别把它当成「横拖=滚动、纵拖=拖卡」的自然分工——按识别器的判据
///   推，事实很可能相反：`ImmediateMultiDragGestureRecognizer` 用**总位移**
///   （`_pendingDelta.distance`）过 slop，而 `HorizontalDragGestureRecognizer` 用
///   **水平分量**过 slop；`hypot(dx, dy) >= |dx|` 恒成立，所以纯横向拖动时拖卡这一
///   侧**不晚于**滚动侧宣布胜出，卡片上的横拖大概率归拖卡而不是滚动。行头与卡片
///   之间的空白仍能横拖滚动（那里没有 `Draggable`），滚轮 / 触控板横滚不受影响。
///   真机确认前不要基于「横拖能滚动」这个假设改动这里。
/// - 移动 / 触摸（Android / iOS / Fuchsia）→ **不建拖拽源**，原样返回 [child]。
///   触屏上按下即拖会吞掉列表滚动；而长按已被卡片的上下文菜单占用（改掉它就
///   破坏了既有的长按菜单），没有第三种不打架的触发方式。移动端加入合集走既有
///   的卡片菜单「加入合集」入口，功能不缺，只是少一条快捷路径。
///
/// [enabled] 为 false 时原样返回 [child]（不建 Draggable）——多选态下卡片点击是
/// 切换选中，此时不应能拖走。
///
/// 在开着直拖重排的 [LibraryReorderCell] 里时，整格由格子的拖拽源接管（同一次
/// 拖动既能重排也能进合集），本卡只把 [mediaRef] 登记给格子、自己的 Draggable
/// 停用（`maxSimultaneousDrags: 0`，结构不变）。
class MediaCardDraggable extends StatefulWidget {
  const MediaCardDraggable({
    required this.mediaRef,
    required this.label,
    required this.child,
    this.enabled = true,
    super.key,
  });

  /// 被拖条目的稳定身份（epub=bookKey / srt=uid / video=bookUid / game=id）。
  final MediaRef mediaRef;

  /// 拖拽浮层上显示的条目名（书名 / 视频名 / 游戏名）。
  final String label;

  final Widget child;

  /// false 时不建拖拽源，原样返回 [child]（多选态）。
  final bool enabled;

  @override
  State<MediaCardDraggable> createState() => _MediaCardDraggableState();
}

class _MediaCardDraggableState extends State<MediaCardDraggable> {
  /// 挂在 [Draggable] 上，供浮层量取**原卡的真实尺寸**。
  ///
  /// 不能改用 `LayoutBuilder` 拿父约束：父约束常常是宽松的（卡片直接放在
  /// `Scaffold.body` 里时是 0..屏宽 × 0..屏高），拿它当浮层尺寸会把浮层撑成
  /// 整屏。`Draggable` 的 RenderBox 尺寸就等于卡片尺寸，且拖动期间
  /// （child 被 `childWhenDragging` 等尺寸替换）保持不变。
  final GlobalKey _anchorKey = GlobalKey();

  /// 本卡独立起拖时的 payload。只在没有拖动进行时随 [MediaCardDraggable.mediaRef]
  /// 换新：拖动中的回调必须一直指向起拖那一份（浮层带的就是它）。
  LibraryCardDrag? _payload;
  LibraryCardDrag? _activeDrag;

  /// 外层直拖重排格（[LibraryReorderCell]）：在里面时把本卡身份登记给它。
  _LibraryReorderCellState? _cell;

  @override
  void dispose() {
    _cell?._unregisterMedia(this);
    super.dispose();
  }

  LibraryCardDrag _payloadFor(MediaCardDraggable w) {
    final LibraryCardDrag? current = _payload;
    if (current != null &&
        (_activeDrag != null ||
            (current._mediaRef == w.mediaRef && current._label == w.label))) {
      return current;
    }
    return _payload = LibraryCardDrag(mediaRef: w.mediaRef, label: w.label);
  }

  @override
  Widget build(BuildContext context) {
    // 在直拖重排格里：整格由格子的拖拽源接管（合集卡 / 远端占位也要能拖），本卡
    // 只把「我是谁」登记过去，自己的拖拽源停用（结构不变，见下）。
    final _LibraryReorderCellScope? cellScope =
        _LibraryReorderCellScope.maybeOf(context);
    final _LibraryReorderCellState? cell = cellScope?.cell;
    if (!identical(cell, _cell)) _cell?._unregisterMedia(this);
    _cell = cell;
    if (widget.enabled) {
      cell?._registerMedia(this, widget.mediaRef, widget.label);
    } else {
      cell?._unregisterMedia(this);
    }
    final bool deferToCell = cellScope != null && cellScope.enabled;
    if (!widget.enabled) return widget.child;
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        // 触屏：不建拖拽源（见类 doc）。
        return widget.child;
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
        final LibraryCardDrag payload = _payloadFor(widget);
        return Draggable<LibraryCardDrag>(
          key: _anchorKey,
          data: payload,
          // 交给外层格子时不起拖，但保留 Draggable 本身：筛选 / 多选切换会翻转
          // [deferToCell]，结构不变才不会把整张卡的子树卸掉重建。
          maxSimultaneousDrags: deferToCell ? 0 : null,
          // 只认主键：右键按住拖一下不能既弹菜单又起拖。
          allowedButtonsFilter: (int buttons) => buttons == kPrimaryButton,
          onDragStarted: () {
            _activeDrag = payload;
            payload._begin(null);
          },
          onDragUpdate: (DragUpdateDetails d) =>
              _activeDrag?._updatePointer(d.globalPosition),
          onDragEnd: (DraggableDetails d) {
            _activeDrag?._finish(accepted: d.wasAccepted);
            _activeDrag = null;
          },
          // 卡片形浮层与原卡同尺寸，保持「按下点相对卡片的位置」才跟手。
          // （旧实现的浮层是紧凑 chip、尺寸与原卡完全不同，才必须改用
          // pointerDragAnchorStrategy 把浮层钉在指针上。）
          dragAnchorStrategy: childDragAnchorStrategy,
          feedback: _CardDragFeedback(
            anchorKey: _anchorKey,
            label: widget.label,
            child: widget.child,
          ),
          // eink：30% 的原卡是一块抖动灰，且拖起那一刻整卡重绘一次；原位不动，
          // 浮层 + 落点描边已足够表达「正在拖」。
          childWhenDragging: Opacity(
            opacity: isEinkTheme(context) ? 1 : 0.3,
            child: widget.child,
          ),
          child: widget.child,
        );
    }
  }
}

/// 拖拽浮层：把卡片本体原样再渲染一份，跟着指针走。
///
/// 复用真卡而不是手写一份「纯视觉副本」——后者必然与真卡漂移（改了卡片样式忘了
/// 改浮层，两处越走越远）。
///
/// 卡片内含 `FushiFocusTarget`，同一棵树里渲染第二份本来会撞焦点 id：焦点表按 id
/// 唯一（`FushiFocusController.register` 是 `_entries[id] = entry` 直接覆盖），
/// 第二份注册会顶掉真卡的 entry，浮层消失时 `unregister` 又把这条 entry 整个删
/// 掉，真卡从此在手柄/键盘焦点表里消失。
///
/// 这里用 `FushiFocusRoot(enabled: false)` 把浮层子树的焦点控制器屏蔽成 null
/// （[FushiFocusRoot.enabled] 的既有语义：结构恒定、只把 scope 暴露的 controller
/// 置空），子树里的 `FushiFocusTarget._register` 因 `controller == null` 直接
/// 返回——**撞车的前提不存在了**，于是不必再要求每个调用方手写副本。
///
/// feedback 由 Flutter 的 `_DragAvatar` 包在 `IgnorePointer` 里，卡片内的
/// `InkWell` / 菜单按钮在浮层上不会响应，无需额外处理。
class _CardDragFeedback extends StatelessWidget {
  const _CardDragFeedback({
    required this.anchorKey,
    required this.label,
    required this.child,
  });

  /// 原卡所在的 [Draggable]，用来量它的真实尺寸。
  final GlobalKey anchorKey;

  /// 量不到尺寸时降级用的条目名。
  final String label;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // build 发生在拖动开始、浮层插进 Overlay 的那一刻，此时原卡早已 layout 完，
    // 量得到确定尺寸。量不到（理论上只会在原卡同帧被移除时发生）就降级成 chip：
    // 无约束地渲染一张卡片可能撑爆 Overlay。
    final RenderObject? box = anchorKey.currentContext?.findRenderObject();
    final Size? size = box is RenderBox && box.hasSize ? box.size : null;
    if (size == null || size.isEmpty) return _DragFeedback(label: label);
    return FushiFocusRoot(
      enabled: false,
      child: Opacity(
        opacity: isEinkTheme(context) ? 1 : 0.92,
        // 抬起观感与重排列表同一枚浮层（MD3 elevation 投影 / Apple 柔和大阴影 +
        // 轻微放大）；卡片自带底色，浮层只抬阴影。
        child: FushiReorderDragProxy(
          transparent: true,
          borderRadius: tokens.radii.cardRadius,
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    );
  }
}

/// 拖拽浮层（降级）：紧凑 chip（图标 + 条目名）。
///
/// 只在量不到原卡尺寸时使用；正常情况走 [_CardDragFeedback]。
///
/// （旧注释「刻意不拿 child 当 feedback，会撞焦点 id」已不再成立：
/// [_CardDragFeedback] 用 `FushiFocusRoot(enabled: false)` 屏蔽了浮层子树的
/// 焦点注册。这里保留 chip 只是为了拿不到卡片尺寸时有个安全降级。）
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 中性抬起 chip（MD3 surfaceContainerHigh / Apple 二级分组底），不再铺
    // primaryContainer 彩色块。
    return FushiReorderDragProxy(
      borderRadius: tokens.radii.chipRadius,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.gap / 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              Icons.collections_bookmark_outlined,
              size: 18,
              color: tokens.surfaces.onSurface,
            ),
            SizedBox(width: tokens.spacing.gap / 2),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata.copyWith(
                  color: tokens.surfaces.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 合集侧的接收端：媒体卡落到它上面即加入该合集。
///
/// 视觉与 `BookDragTarget`（标签落卡）/ `CollectionShelfRow._wrapTagDropTarget`
/// （标签落行头）同源：primary 描边 + 半透明填充 + 提示图标；eink 主题下去掉
/// 填充色只留实心描边（半透明罩在墨水屏合成抖动灰，且 primary 已塌缩）。
///
/// [alignment] 决定提示图标的位置：行头形状（扁长）用 `centerEnd`，封面卡形状
/// （方块）用 `center`。
class CollectionDropTarget extends StatefulWidget {
  const CollectionDropTarget({
    required this.onMediaDropped,
    required this.child,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.enabled = true,
    super.key,
  });

  /// 卡片落下：把 [MediaRef] 加进本合集（调用方负责落库 + 刷新 + 提示）。
  final void Function(MediaRef ref) onMediaDropped;

  final Widget child;

  /// 悬停提示图标的对齐位置。
  final AlignmentGeometry alignment;

  /// 悬停高亮罩的圆角。null 时用 `tokens.radii.cardRadius`。
  final BorderRadius? borderRadius;

  /// false 时不建接收端，原样返回 [child]（多选态）。
  final bool enabled;

  @override
  State<CollectionDropTarget> createState() => _CollectionDropTargetState();
}

class _CollectionDropTargetState extends State<CollectionDropTarget> {
  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    // 在开着直拖重排的格子里：卡片正中 = 加入合集，其余 = 重排（判定在格子所属的
    // [LibraryDragReorderScope] 里统一做）。没有格子 / 格子没开重排（筛选态、行头）
    // 时整块都是「加入合集」，与改造前一致。
    final _LibraryReorderCellScope? cellScope =
        _LibraryReorderCellScope.maybeOf(context);
    final _LibraryReorderCellState? cell =
        cellScope != null && cellScope.enabled ? cellScope.cell : null;
    final _LibraryDragReorderScopeState? scope = cell?._scope;
    if (cell == null || scope == null) {
      return DragTarget<LibraryCardDrag>(
        onWillAcceptWithDetails: (DragTargetDetails<LibraryCardDrag> d) =>
            d.data.mediaRef != null,
        onAcceptWithDetails: (DragTargetDetails<LibraryCardDrag> d) {
          final MediaRef? ref = d.data.mediaRef;
          if (ref != null) widget.onMediaDropped(ref);
        },
        builder:
            (
              BuildContext context,
              List<LibraryCardDrag?> candidateData,
              List<dynamic> rejectedData,
            ) => _CollectionDropHighlight(
              hovering: candidateData.isNotEmpty,
              alignment: widget.alignment,
              borderRadius: widget.borderRadius,
              child: widget.child,
            ),
      );
    }
    return DragTarget<LibraryCardDrag>(
      onWillAcceptWithDetails: (DragTargetDetails<LibraryCardDrag> d) =>
          d.data.mediaRef != null || scope._acceptsReorder(d.data),
      onMove: (DragTargetDetails<LibraryCardDrag> d) {
        if (d.data.mediaRef == null && !scope._acceptsReorder(d.data)) return;
        scope._hover(cell, d.data, widget.onMediaDropped);
      },
      onAcceptWithDetails: (DragTargetDetails<LibraryCardDrag> d) =>
          scope._drop(d.data),
      builder:
          (
            BuildContext context,
            List<LibraryCardDrag?> candidateData,
            List<dynamic> rejectedData,
          ) => ValueListenableBuilder<LibraryDropIndicator?>(
            valueListenable: scope._indicator,
            child: widget.child,
            builder:
                (BuildContext context, LibraryDropIndicator? ind, Widget? c) =>
                    _CollectionDropHighlight(
                      hovering:
                          ind != null &&
                          ind.index == cell.widget.index &&
                          ind.zone == LibraryDropZone.into,
                      alignment: widget.alignment,
                      borderRadius: widget.borderRadius,
                      emphasized: true,
                      child: c!,
                    ),
          ),
    );
  }
}

/// 「落下即加入合集」的悬停高亮。
///
/// 视觉与 `BookDragTarget`（标签落卡）同源：primary 描边 + 半透明填充 + 提示图标；
/// eink 去掉填充只留实心描边。[emphasized]（直拖重排网格里的合集卡）再加轻微放大
/// 与更大的图标——同一次拖动里「放进合集」与「插到旁边」必须一眼分得清。
class _CollectionDropHighlight extends StatelessWidget {
  const _CollectionDropHighlight({
    required this.hovering,
    required this.alignment,
    required this.borderRadius,
    required this.child,
    this.emphasized = false,
  });

  final bool hovering;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;
  final bool emphasized;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color hoverColor = tokens.surfaces.primary;
    final bool eink = isEinkTheme(context);
    final Widget stack = Stack(
      children: <Widget>[
        child,
        if (hovering)
          Positioned.fill(
            // IgnorePointer：高亮罩只是反馈，不得吞掉行头 / 卡片本身的点击。
            child: IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey<String>('collection_drop_highlight'),
                decoration: BoxDecoration(
                  // MD3：primary 12% 状态层（原 18% 盖得太实，卡片内容
                  // 发灰）；Apple：中性 systemFill 灰罩 + 强调色描边
                  // （单色强调色下黑 / 白半透明罩是一块脏色）。
                  color: eink
                      ? null
                      : isGlassDesign(context)
                      ? appleColorsOf(context).fill
                      : hoverColor.withValues(alpha: 0.12),
                  borderRadius: borderRadius ?? tokens.radii.cardRadius,
                  border: Border.all(
                    color: hoverColor,
                    width: tokens.spacing.gap / (emphasized ? 2.5 : 4),
                  ),
                ),
                child: Align(
                  alignment: alignment,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: tokens.spacing.gap,
                    ),
                    child: FushiIcon(
                      Icons.library_add_outlined,
                      color: hoverColor,
                      size: emphasized ? 36 : 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    if (!emphasized) return stack;
    return AnimatedScale(
      scale: hovering ? 1.04 : 1,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: stack,
    );
  }
}

// ───────────────────────── 桌面库页直拖重排 ─────────────────────────

/// 库页卡片拖拽的 payload（拖进合集 + 直拖重排共用）。
///
/// 两种来源：
/// - 独立的 [MediaCardDraggable]（不在开着重排的网格里）：只带 [mediaRef]，只能
///   拖进合集；
/// - [LibraryReorderCell] 的整格拖拽源：带所在网格与下标（可重排），[mediaRef] 取
///   格子里 [MediaCardDraggable] 登记的身份（合集卡 / 远端占位没有，只能重排）。
///
/// 指针位置也记在 payload 上：`DragTarget.onMove` 只给浮层左上角（且在祖先
/// `Transform.scale` 下与指针差一个缩放），命中区判定要的是真实全局指针，由拖拽源
/// 的 `onDragUpdate` 写进来。
class LibraryCardDrag {
  LibraryCardDrag({required MediaRef mediaRef, String label = ''})
    : _mediaRef = mediaRef,
      _label = label,
      _cell = null;

  LibraryCardDrag._forCell(_LibraryReorderCellState this._cell)
    : _mediaRef = null,
      _label = '';

  final MediaRef? _mediaRef;
  final String _label;
  final _LibraryReorderCellState? _cell;

  /// 被拖条目的媒体身份；null = 不能拖进合集（合集卡 / 远端占位）。
  MediaRef? get mediaRef {
    final _LibraryReorderCellState? cell = _cell;
    return cell == null ? _mediaRef : cell._mediaRef;
  }

  /// 浮层降级 chip 上的条目名。
  String get label {
    final _LibraryReorderCellState? cell = _cell;
    return cell == null ? _label : cell._label;
  }

  /// 起拖时所在的重排网格；null = 不可重排。
  _LibraryDragReorderScopeState? _sourceScope;

  /// 起拖时在网格里的下标。
  int _sourceIndex = -1;

  /// 最近一次拖拽源报告的全局指针。
  Offset? _pointer;

  /// 当前正在判定落点的网格（悬停在它的某个格子上）。
  _LibraryDragReorderScopeState? _hoverScope;

  void _begin(_LibraryDragReorderScopeState? sourceScope, [int index = -1]) {
    _sourceScope = sourceScope;
    _sourceIndex = index;
    _pointer = null;
    _hoverScope = null;
  }

  void _updatePointer(Offset globalPosition) {
    _pointer = globalPosition;
    _sourceScope?._autoScrollFor(this, globalPosition);
    _hoverScope?._recompute();
  }

  /// 拖动结束。[accepted] = 落在某个 DragTarget 上（已由它处理）；否则落在格子
  /// 之间的缝里，按最后一次的插入指示提交重排。
  void _finish({required bool accepted}) {
    final _LibraryDragReorderScopeState? hover = _hoverScope;
    if (!accepted) hover?._commitPending(this);
    hover?._clear();
    _sourceScope?._stopAutoScroll();
    _sourceScope = null;
    _hoverScope = null;
    _pointer = null;
  }
}

/// 落点类型：插到目标格前 / 后，或放进目标合集。
enum LibraryDropZone { before, after, into }

/// 当前落点指示：网格下标 [index] 的格子 + [zone]。
@immutable
class LibraryDropIndicator {
  const LibraryDropIndicator(this.index, this.zone);

  final int index;
  final LibraryDropZone zone;

  @override
  bool operator ==(Object other) =>
      other is LibraryDropIndicator &&
      other.index == index &&
      other.zone == zone;

  @override
  int get hashCode => Object.hash(index, zone);

  @override
  String toString() => 'LibraryDropIndicator($index, $zone)';
}

/// 「item[from] 移到最终下标 to」（`removeAt(from); insert(to, item)`），与
/// `FushiReorderableGrid.onReorder` 同一语义，各库页直接接已有的 `_on*Reorder`。
typedef LibraryDragReorderCallback = void Function(int from, int to);

/// 桌面库页的**直拖重排**：包在常态网格（`SliverGrid.builder`）外面，网格每格用
/// [LibraryReorderCell] 包一层。书架 / 漫画库 / 视频库 / 游戏库共用这一份。
///
/// 为什么不直接把常态网格换成 `FushiReorderableGrid`：那是把全部格子一次建进一个
/// `Stack` 的非懒加载组件，书库几百张卡每帧全量 build + layout，滚动明显退化。这里
/// 保持 `SliverGrid.builder` 懒构建，只给每格挂一个拖拽源 + 一个 DragTarget：
/// - **拖到卡上**：按指针落在目标卡的哪一半决定插到它前面还是后面（RTL 镜像），
///   目标卡边缘画一根插入竖条；
/// - **拖到卡与卡之间的缝**：保留最后一次的插入指示（指针离最近悬停的卡不超过
///   [gapSlack]），松手照样提交；离远了指示清掉，松手不动；
/// - **拖到合集卡正中**（横向中间一半、纵向中间 60%）且被拖的是能进合集的条目 =
///   放进合集（合集卡放大 + 描边 + 大图标）；合集卡四周仍是插到它前后。
/// - 指针贴近视口上 / 下边缘时自动滚动（被拖的源格用 keep-alive 保住，滚出视口
///   也不会被懒加载回收掉拖拽回调）。
///
/// 只在桌面（Windows / macOS / Linux）生效；触屏仍走「长按菜单 → 排序」进排序模式。
/// [enabled] 为 false（多选 / 筛选 / 列表布局等）时格子不起拖，卡片退回独立的
/// [MediaCardDraggable]（只能拖进合集），与改造前一致。
class LibraryDragReorderScope extends StatefulWidget {
  const LibraryDragReorderScope({
    required this.enabled,
    required this.onReorder,
    required this.child,
    super.key,
  });

  /// 是否允许直拖重排（调用方按多选 / 筛选等页面语义算好）。
  final bool enabled;

  /// 重排提交（下标是本网格的格子下标）。
  final LibraryDragReorderCallback onReorder;

  /// 网格（通常是一个 sliver）。
  final Widget child;

  /// 合集卡「放进合集」区：横向占中间这一比例。
  static const double intoWidthFraction = 0.5;

  /// 合集卡「放进合集」区：纵向占中间这一比例。
  static const double intoHeightFraction = 0.6;

  /// 指针在格子外多远以内仍保留插入指示（格间缝）。
  static const double gapSlack = 20;

  /// 触发自动滚动的视口边缘带宽。
  static const double autoScrollEdge = 64;

  /// 自动滚动每帧步进。
  static const double autoScrollStep = 16;

  /// 由 `from` / 目标格 `target` / 插在其后与否算出 [LibraryDragReorderCallback]
  /// 的最终下标 `to`。
  static int targetIndex({
    required int from,
    required int target,
    required bool after,
  }) {
    // 落在自己身上（无论哪一半）都是原地。
    if (target == from) return from;
    if (after) return from < target ? target : target + 1;
    return from < target ? target - 1 : target;
  }

  @override
  State<LibraryDragReorderScope> createState() =>
      _LibraryDragReorderScopeState();
}

class _LibraryDragReorderScopeState extends State<LibraryDragReorderScope> {
  final ValueNotifier<LibraryDropIndicator?> _indicator =
      ValueNotifier<LibraryDropIndicator?>(null);

  _LibraryReorderCellState? _hoverCell;
  LibraryCardDrag? _hoverData;
  void Function(MediaRef ref)? _hoverInto;
  int? _pendingTo;

  ScrollableState? _scrollable;
  LibraryCardDrag? _autoScrollDrag;
  double _autoScrollStepSigned = 0;
  bool _autoScrollScheduled = false;

  @override
  void didUpdateWidget(covariant LibraryDragReorderScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) _clear();
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _indicator.dispose();
    super.dispose();
  }

  bool _acceptsReorder(LibraryCardDrag data) =>
      widget.enabled && identical(data._sourceScope, this);

  /// 某格的 DragTarget 收到移动：记下悬停的格子。真正的区域判定等拖拽源报告这一
  /// 帧的指针后在 [_recompute] 里做（onMove 早于 onDragUpdate，此刻指针还是旧的）。
  void _hover(
    _LibraryReorderCellState cell,
    LibraryCardDrag data,
    void Function(MediaRef ref)? into,
  ) {
    final _LibraryDragReorderScopeState? previous = data._hoverScope;
    if (previous != null && !identical(previous, this)) previous._clear();
    data._hoverScope = this;
    _hoverCell = cell;
    _hoverData = data;
    _hoverInto = into;
  }

  void _recompute() {
    final _LibraryReorderCellState? cell = _hoverCell;
    final LibraryCardDrag? data = _hoverData;
    final Offset? pointer = data?._pointer;
    if (cell == null || data == null || pointer == null || !cell.mounted) {
      _setIndicator(null, null);
      return;
    }
    final Rect? rect = cell._globalRect();
    if (rect == null ||
        rect.isEmpty ||
        !rect.inflate(LibraryDragReorderScope.gapSlack).contains(pointer)) {
      _clear();
      return;
    }
    final double fx = (pointer.dx - rect.left) / rect.width;
    final double fy = (pointer.dy - rect.top) / rect.height;
    const double ix = (1 - LibraryDragReorderScope.intoWidthFraction) / 2;
    const double iy = (1 - LibraryDragReorderScope.intoHeightFraction) / 2;
    final int index = cell.widget.index;
    if (_hoverInto != null &&
        data.mediaRef != null &&
        fx >= ix &&
        fx <= 1 - ix &&
        fy >= iy &&
        fy <= 1 - iy) {
      _setIndicator(LibraryDropIndicator(index, LibraryDropZone.into), null);
      return;
    }
    if (!_acceptsReorder(data)) {
      _setIndicator(null, null);
      return;
    }
    final bool rtl = Directionality.maybeOf(cell.context) == TextDirection.rtl;
    final bool after = rtl ? fx < 0.5 : fx >= 0.5;
    final int from = data._sourceIndex;
    final int to = LibraryDragReorderScope.targetIndex(
      from: from,
      target: index,
      after: after,
    );
    if (to == from || to < 0) {
      _setIndicator(null, null);
      return;
    }
    _setIndicator(
      LibraryDropIndicator(
        index,
        after ? LibraryDropZone.after : LibraryDropZone.before,
      ),
      to,
    );
  }

  void _setIndicator(LibraryDropIndicator? value, int? to) {
    _pendingTo = to;
    if (mounted) _indicator.value = value;
  }

  /// 某格的 DragTarget 接住了落下：按当前指示执行。
  void _drop(LibraryCardDrag data) {
    final LibraryDropIndicator? ind = _indicator.value;
    final void Function(MediaRef ref)? into = _hoverInto;
    final int? to = _pendingTo;
    _clear();
    if (ind == null) return;
    if (ind.zone == LibraryDropZone.into) {
      final MediaRef? ref = data.mediaRef;
      if (into != null && ref != null) into(ref);
      return;
    }
    _commitReorder(data, to);
  }

  /// 落在格间缝里（没有 DragTarget 接）：按最后的插入指示提交。
  void _commitPending(LibraryCardDrag data) {
    final LibraryDropIndicator? ind = _indicator.value;
    if (ind == null || ind.zone == LibraryDropZone.into) return;
    _commitReorder(data, _pendingTo);
  }

  void _commitReorder(LibraryCardDrag data, int? to) {
    if (to == null || !_acceptsReorder(data)) return;
    final int from = data._sourceIndex;
    if (from < 0 || to == from) return;
    widget.onReorder(from, to);
  }

  void _clear() {
    _hoverCell = null;
    _hoverData = null;
    _hoverInto = null;
    _setIndicator(null, null);
  }

  // ── 自动滚动（与 FushiReorderableGrid 同一套边缘带规则） ──

  void _autoScrollFor(LibraryCardDrag data, Offset globalPosition) {
    _autoScrollDrag = data;
    final ScrollableState? sc = _scrollable ??= Scrollable.maybeOf(context);
    if (sc == null || !sc.mounted || sc.position.axis != Axis.vertical) {
      _autoScrollStepSigned = 0;
      return;
    }
    final RenderObject? ro = sc.context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) {
      _autoScrollStepSigned = 0;
      return;
    }
    // 连尺寸一起过完整变换取屏幕矩形（祖先 FushiAppUiScale 缩放，BUG-778）。
    final Rect viewport = MatrixUtils.transformRect(
      ro.getTransformTo(null),
      Offset.zero & ro.size,
    );
    final ScrollPosition pos = sc.position;
    const double edge = LibraryDragReorderScope.autoScrollEdge;
    double step = 0;
    if (globalPosition.dy < viewport.top + edge &&
        pos.pixels > pos.minScrollExtent) {
      step = -LibraryDragReorderScope.autoScrollStep;
    } else if (globalPosition.dy > viewport.bottom - edge &&
        pos.pixels < pos.maxScrollExtent) {
      step = LibraryDragReorderScope.autoScrollStep;
    }
    _autoScrollStepSigned = step;
    if (step != 0 && !_autoScrollScheduled) {
      _autoScrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback(_autoScrollTick);
      // postFrame 回调本身不调度帧（无 setState 时会永远等不到下一帧）。
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  void _autoScrollTick(Duration _) {
    _autoScrollScheduled = false;
    final LibraryCardDrag? data = _autoScrollDrag;
    final ScrollableState? sc = _scrollable;
    if (!mounted ||
        data == null ||
        _autoScrollStepSigned == 0 ||
        sc == null ||
        !sc.mounted) {
      return;
    }
    final ScrollPosition pos = sc.position;
    final double next = (pos.pixels + _autoScrollStepSigned).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (next != pos.pixels) pos.jumpTo(next);
    // 内容挪了：悬停格的屏幕矩形跟着变，按同一指针重判（离远了就清指示）。
    data._hoverScope?._recompute();
    final Offset? pointer = data._pointer;
    if (pointer != null) _autoScrollFor(data, pointer);
  }

  void _stopAutoScroll() {
    _autoScrollStepSigned = 0;
    _autoScrollDrag = null;
    _scrollable = null;
  }

  @override
  Widget build(BuildContext context) => _LibraryDragReorderInherited(
    state: this,
    enabled: widget.enabled,
    child: widget.child,
  );
}

class _LibraryDragReorderInherited extends InheritedWidget {
  const _LibraryDragReorderInherited({
    required this.state,
    required this.enabled,
    required super.child,
  });

  final _LibraryDragReorderScopeState state;
  final bool enabled;

  @override
  bool updateShouldNotify(_LibraryDragReorderInherited oldWidget) =>
      oldWidget.enabled != enabled || !identical(oldWidget.state, state);
}

/// [LibraryDragReorderScope] 网格里的一格：整格的拖拽源 + 重排落点 + 插入竖条。
///
/// [index] 是该格在网格里的下标（与 scope 的 `onReorder` 同一坐标系）。不在
/// [LibraryDragReorderScope] 里、或在触屏平台上时只是透传。
class LibraryReorderCell extends StatefulWidget {
  const LibraryReorderCell({
    required this.index,
    required this.child,
    super.key,
  });

  final int index;
  final Widget child;

  @override
  State<LibraryReorderCell> createState() => _LibraryReorderCellState();
}

class _LibraryReorderCellState extends State<LibraryReorderCell>
    with AutomaticKeepAliveClientMixin<LibraryReorderCell> {
  final GlobalKey _anchorKey = GlobalKey();
  late final LibraryCardDrag _payload = LibraryCardDrag._forCell(this);

  _LibraryDragReorderScopeState? _scope;
  bool _dragging = false;

  Object? _mediaOwner;
  MediaRef? _mediaRef;
  String _label = '';

  /// 拖动中保活：自动滚动把源格滚出视口时，懒加载网格不得回收它（否则
  /// onDragUpdate / onDragEnd 随 State 卸载失效，重排提交不了）。
  @override
  bool get wantKeepAlive => _dragging;

  void _registerMedia(Object owner, MediaRef ref, String label) {
    _mediaOwner = owner;
    _mediaRef = ref;
    _label = label;
  }

  void _unregisterMedia(Object owner) {
    if (!identical(_mediaOwner, owner)) return;
    _mediaOwner = null;
    _mediaRef = null;
    _label = '';
  }

  Rect? _globalRect() {
    final RenderObject? ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    return MatrixUtils.transformRect(
      ro.getTransformTo(null),
      Offset.zero & ro.size,
    );
  }

  void _setDragging(bool value) {
    if (_dragging == value) return;
    _dragging = value;
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final _LibraryDragReorderInherited? inherited = context
        .dependOnInheritedWidgetOfExactType<_LibraryDragReorderInherited>();
    final _LibraryDragReorderScopeState? scope = inherited?.state;
    _scope = scope;
    final bool enabled = inherited?.enabled ?? false;
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        // 触屏：不建拖拽源 / 落点（长按归菜单，重排走排序模式）。
        return widget.child;
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
        break;
    }
    final LibraryCardDrag payload = _payload;
    final Widget draggable = Draggable<LibraryCardDrag>(
      key: _anchorKey,
      data: payload,
      // 不能重排时只停用、不拆掉：结构恒定，多选 / 筛选切换不把卡片子树重建。
      maxSimultaneousDrags: enabled ? null : 0,
      allowedButtonsFilter: (int buttons) => buttons == kPrimaryButton,
      dragAnchorStrategy: childDragAnchorStrategy,
      feedback: _CardDragFeedback(
        anchorKey: _anchorKey,
        label: payload.label,
        child: widget.child,
      ),
      childWhenDragging: Opacity(
        opacity: isEinkTheme(context) ? 1 : 0.3,
        child: widget.child,
      ),
      onDragStarted: () {
        payload._begin(_scope, widget.index);
        _setDragging(true);
      },
      onDragUpdate: (DragUpdateDetails d) =>
          payload._updatePointer(d.globalPosition),
      onDragEnd: (DraggableDetails d) {
        payload._finish(accepted: d.wasAccepted);
        if (mounted) _setDragging(false);
      },
      child: widget.child,
    );
    return _LibraryReorderCellScope(
      cell: this,
      enabled: enabled,
      child: DragTarget<LibraryCardDrag>(
        onWillAcceptWithDetails: (DragTargetDetails<LibraryCardDrag> d) =>
            scope != null && scope._acceptsReorder(d.data),
        onMove: (DragTargetDetails<LibraryCardDrag> d) {
          if (scope == null || !scope._acceptsReorder(d.data)) return;
          scope._hover(this, d.data, null);
        },
        onAcceptWithDetails: (DragTargetDetails<LibraryCardDrag> d) =>
            scope?._drop(d.data),
        builder:
            (
              BuildContext context,
              List<LibraryCardDrag?> candidateData,
              List<dynamic> rejectedData,
            ) => Stack(
              fit: StackFit.passthrough,
              clipBehavior: Clip.none,
              children: <Widget>[
                draggable,
                if (scope != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _LibraryInsertionMarker(
                        indicator: scope._indicator,
                        index: widget.index,
                      ),
                    ),
                  ),
              ],
            ),
      ),
    );
  }
}

/// 格子 → 子树：卡片里的 [MediaCardDraggable] / [CollectionDropTarget] 据此知道
/// 自己在开着直拖重排的格子里。
class _LibraryReorderCellScope extends InheritedWidget {
  const _LibraryReorderCellScope({
    required this.cell,
    required this.enabled,
    required super.child,
  });

  final _LibraryReorderCellState cell;
  final bool enabled;

  static _LibraryReorderCellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LibraryReorderCellScope>();

  @override
  bool updateShouldNotify(_LibraryReorderCellScope oldWidget) =>
      oldWidget.enabled != enabled || !identical(oldWidget.cell, cell);
}

/// 插入竖条：画在目标格的起 / 止边上（方向跟随 [Directionality]），淡入淡出。
class _LibraryInsertionMarker extends StatelessWidget {
  const _LibraryInsertionMarker({required this.indicator, required this.index});

  final ValueNotifier<LibraryDropIndicator?> indicator;
  final int index;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LibraryDropIndicator?>(
      valueListenable: indicator,
      builder: (BuildContext context, LibraryDropIndicator? ind, Widget? _) {
        final bool show =
            ind != null &&
            ind.index == index &&
            ind.zone != LibraryDropZone.into;
        final bool after = ind?.zone == LibraryDropZone.after;
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        return AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: fushiMotionDuration(context, FushiMotion.micro),
          child: Align(
            alignment: after
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              heightFactor: 0.8,
              child: Container(
                key: show
                    ? ValueKey<String>(
                        'library_reorder_insertion_${after ? 'after' : 'before'}',
                      )
                    : null,
                width: 4,
                // 插入竖条两端全圆（胶囊），不另立圆角常量。
                decoration: ShapeDecoration(
                  color: tokens.surfaces.primary,
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
