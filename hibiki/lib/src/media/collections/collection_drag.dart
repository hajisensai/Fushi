/// 「把卡片拖进合集」的共享拖放件（书架 / 漫画 / 视频库 / 游戏库共用）。
///
/// 拖拽源 [MediaCardDraggable] 挂在各库页的媒体卡上，payload 是统一媒体身份
/// [MediaRef]；接收端 [CollectionDropTarget] 挂在合集行头（书架 / 游戏）与合集
/// 封面卡（视频），落下即 `HibikiDatabase.addToCollection`（幂等：同一张卡重复
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

/// 提示通道。默认 [HibikiToast.show]；测试注入自己的收集器。
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
  required HibikiDatabase database,
  required int collectionId,
  required MediaRef mediaRef,
  CollectionAddNotifier? notify,
}) async {
  final CollectionAddNotifier tell =
      notify ?? (String message) => HibikiToast.show(msg: message);
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
/// **仅桌面端建拖拽源**（镜像 `hibiki_reorder_drag_listener.dart` 的按平台范式）：
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
class MediaCardDraggable extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (!enabled) return child;
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        // 触屏：不建拖拽源（见类 doc）。
        return child;
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
        return Draggable<MediaRef>(
          data: mediaRef,
          // 浮层跟指针而不是保持「按下点相对卡片的位置」：浮层是紧凑 chip、尺寸
          // 与原卡完全不同，沿用 childDragAnchorStrategy 会让它偏到指针外面去。
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _DragFeedback(label: label),
          childWhenDragging: Opacity(opacity: 0.3, child: child),
          child: child,
        );
    }
  }
}

/// 拖拽浮层：紧凑 chip（图标 + 条目名），不复用卡片本体。
///
/// 刻意不拿 [MediaCardDraggable.child] 当 feedback：卡片内含 `HibikiFocusTarget`
/// （焦点 id 唯一）与 `InkWell`，同一棵树里渲染第二份会造成焦点 id 撞车。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
