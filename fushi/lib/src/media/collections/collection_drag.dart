/// 「把卡片拖进合集」的共享拖放件（书架 / 漫画 / 视频库 / 游戏库共用）。
///
/// 拖拽源 [MediaCardDraggable] 挂在各库页的媒体卡上，payload 是统一媒体身份
/// [MediaRef]；接收端 [CollectionDropTarget] 挂在合集行头（书架 / 游戏）与合集
/// 封面卡（视频），落下即 `FushiDatabase.addToCollection`（幂等：同一张卡重复
/// 拖同一个合集是 no-op，调用方据回调自行提示）。
///
/// 泛型刻意选 [MediaRef] 而**不复用**标签拖放的 `BookTagRow`：合集行头同时挂着
/// 两个 DragTarget（标签落下=给合集打标签 / 卡片落下=加入合集），靠泛型天然分流
/// 互不误接——`DragTarget<T>` 只接收 `T` 类型的 payload，无需任何运行时判别分支。
/// 这也让 `collection_shelf_row_tag_drop_test.dart` 里「`DragTarget<BookTagRow>`
/// 恰好一个 / 恰好零个」的既有断言保持成立。
library;

import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart'
    show FushiFocusRoot;
import 'package:fushi/utils.dart';

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
    final List<MediaCollectionItemRow> items =
        await database.getCollectionItems(collectionId);
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
///   开书、按住不动仍归 `onLongPress` 弹菜单、右键仍归 `onSecondaryTap`。
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

  @override
  Widget build(BuildContext context) {
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
        return Draggable<MediaRef>(
          key: _anchorKey,
          data: widget.mediaRef,
          // 卡片形浮层与原卡同尺寸，保持「按下点相对卡片的位置」才跟手。
          // （旧实现的浮层是紧凑 chip、尺寸与原卡完全不同，才必须改用
          // pointerDragAnchorStrategy 把浮层钉在指针上。）
          dragAnchorStrategy: childDragAnchorStrategy,
          feedback: _CardDragFeedback(
            anchorKey: _anchorKey,
            label: widget.label,
            child: widget.child,
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: widget.child),
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
        opacity: 0.92,
        child: Material(
          color: Colors.transparent,
          elevation: 8,
          borderRadius: tokens.radii.cardRadius,
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: child,
          ),
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
    return Material(
      color: Colors.transparent,
      elevation: 4,
      borderRadius: tokens.radii.chipRadius,
      clipBehavior: Clip.antiAlias,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.gap / 2,
        ),
        decoration: BoxDecoration(
          color: tokens.surfaces.primaryContainer,
          borderRadius: tokens.radii.chipRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
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
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color hoverColor = tokens.surfaces.primary;
    final bool eink = isEinkTheme(context);
    return DragTarget<MediaRef>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (DragTargetDetails<MediaRef> details) {
        setState(() => _hovering = false);
        widget.onMediaDropped(details.data);
      },
      onMove: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onLeave: (_) {
        if (_hovering) setState(() => _hovering = false);
      },
      builder: (
        BuildContext context,
        List<MediaRef?> candidateData,
        List<dynamic> rejectedData,
      ) {
        return Stack(
          children: <Widget>[
            widget.child,
            if (_hovering)
              Positioned.fill(
                // IgnorePointer：高亮罩只是反馈，不得吞掉行头 / 卡片本身的点击。
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: eink ? null : hoverColor.withValues(alpha: 0.18),
                      borderRadius:
                          widget.borderRadius ?? tokens.radii.cardRadius,
                      border: Border.all(
                        color: hoverColor,
                        width: tokens.spacing.gap / 4,
                      ),
                    ),
                    child: Align(
                      alignment: widget.alignment,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: tokens.spacing.gap,
                        ),
                        child: Icon(
                          Icons.library_add_outlined,
                          color: hoverColor,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
