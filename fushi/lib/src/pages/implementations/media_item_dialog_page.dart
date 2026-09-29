import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';

// ---------------------------------------------------------------------------
// Action data model
// ---------------------------------------------------------------------------
//
// Every action carries a label + icon + onPressed. The three subtypes differ in
// placement / weight in the below-cover action column:
//   * [DialogQuickAction]  -> equal-width quick-action chip (FushiActionChip).
//   * [DialogListAction]   -> a labelled list row under a divider.
//   * [DialogDangerAction] -> a muted, centred destructive button at the bottom.

sealed class DialogAction {
  const DialogAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

final class DialogQuickAction extends DialogAction {
  const DialogQuickAction({
    required super.label,
    required super.icon,
    required super.onPressed,
  });
}

final class DialogListAction extends DialogAction {
  const DialogListAction({
    required super.label,
    required super.onPressed,
    super.icon = Icons.tune,
  });
}

final class DialogDangerAction extends DialogAction {
  const DialogDangerAction({
    required super.label,
    required super.onPressed,
    super.icon = Icons.delete_outline,
    this.muted = false,
  });
  final bool muted;
}

// ---------------------------------------------------------------------------
// Dialog page
// ---------------------------------------------------------------------------

class MediaItemDialogPage extends BasePage {
  const MediaItemDialogPage({
    required this.item,
    required this.isHistory,
    this.extraActions,
    this.showLaunchAction = true,
    this.coverFallbackIcon,
    super.key,
  });

  final MediaItem item;
  final bool isHistory;
  final List<DialogAction> Function(MediaItem)? extraActions;
  final bool showLaunchAction;

  /// TODO-1094：当条目没有任何可显示封面（无 override 缩略图 / imageUrl /
  /// base64Image / extraUrl）时，用它作占位图标渲染封面块，而不是整块隐藏封面区。
  /// 供 SRT/字幕卡与网格 `_buildSrtCover` 的占位判据统一；其它来源不传（保持
  /// 「无封面则不渲染封面块」的既有行为）。
  final IconData? coverFallbackIcon;

  @override
  BasePageState createState() => _MediaItemDialogPageState();
}

class _MediaItemDialogPageState extends BasePageState<MediaItemDialogPage> {
  MediaSource get mediaSource => widget.item.getMediaSource(appModel: appModel);

  // -- action categorisation ------------------------------------------------

  List<DialogAction> get _externalActions =>
      widget.extraActions?.call(widget.item) ?? const [];

  List<DialogQuickAction> get _quickActions =>
      _externalActions.whereType<DialogQuickAction>().toList();

  List<DialogListAction> get _listActions => [
        ..._externalActions.whereType<DialogListAction>(),
        if (widget.item.canEdit && widget.isHistory)
          DialogListAction(
            label: t.dialog_edit_info,
            icon: Icons.edit_outlined,
            onPressed: _executeEdit,
          ),
      ];

  List<DialogDangerAction> get _dangerActions => [
        ..._externalActions.whereType<DialogDangerAction>(),
        if (widget.item.canDelete && widget.isHistory)
          DialogDangerAction(
            label: t.dialog_clear,
            icon: Icons.clear_all,
            onPressed: _executeClear,
            muted: true,
          ),
      ];

  // -- callbacks ------------------------------------------------------------

  void _executeEdit() async {
    await showAppDialog(
      context: context,
      builder: (context) => MediaItemEditDialogPage(item: widget.item),
    );
  }

  void _executeLaunch() async {
    Navigator.pop(context);
    await appModel.openMedia(
      mediaSource: mediaSource,
      ref: ref,
      item: widget.item,
    );
  }

  void _executeClear() async {
    final navigator = Navigator.of(context);
    await appModel.deleteMediaItem(widget.item);
    navigator.pop();
  }

  // -- build ----------------------------------------------------------------

  bool get _hasCover =>
      mediaSource.getOverrideThumbnailFromMediaItem(
            appModel: appModel,
            item: widget.item,
          ) !=
          null ||
      (widget.item.imageUrl?.isNotEmpty ?? false) ||
      (widget.item.base64Image?.isNotEmpty ?? false) ||
      (widget.item.extraUrl?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final String displayTitle =
        mediaSource.getDisplayTitleFromMediaItem(widget.item);
    final String? author = widget.item.author;
    final bool hasAuthor = author != null && author.isNotEmpty;

    final IconData? fallbackIcon = widget.coverFallbackIcon;
    final Widget? cover = _hasCover
        ? _buildCover()
        : (fallbackIcon != null ? _buildFallbackCover(fallbackIcon) : null);
    return MediaItemDialogFrame(
      cover: cover,
      title: displayTitle,
      author: hasAuthor ? author : null,
      showLaunchAction: widget.showLaunchAction,
      launchLabel: t.dialog_read,
      onLaunch: _executeLaunch,
      quickActions: _quickActions,
      listActions: _listActions,
      dangerActions: _dangerActions,
    );
  }

  /// TODO-1094：无真实封面时的占位封面块，居中显示一个来源相关图标。视觉与书架
  /// 网格 `_coverPlaceholderIcon`（size 40 / onSurfaceVariant）保持一致，让长按
  /// 对话框不再出现「网格有占位图标、长按却空白」的不一致。
  Widget _buildFallbackCover(IconData icon) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Icon(
          icon,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildCover() {
    return FadeInImage(
      placeholder: MemoryImage(kTransparentImage),
      imageErrorBuilder: (_, __, ___) {
        if (widget.item.extraUrl != null) {
          return FadeInImage(
            placeholder: MemoryImage(kTransparentImage),
            imageErrorBuilder: (_, __, ___) => const SizedBox.shrink(),
            image: mediaSource.getDisplayThumbnailFromMediaItem(
              appModel: appModel,
              item: widget.item,
              fallbackUrl: widget.item.extraUrl,
            ),
            fit: BoxFit.contain,
          );
        }
        return const SizedBox.shrink();
      },
      image: mediaSource.getDisplayThumbnailFromMediaItem(
        appModel: appModel,
        item: widget.item,
      ),
      fit: BoxFit.contain,
    );
  }
}

// ---------------------------------------------------------------------------
// Dialog frame (pure layout, testable in isolation)
// ---------------------------------------------------------------------------

/// Long-press book-settings dialog.
///
/// The cover is used as the dialog background with a readable scrim in front.
/// Title, author, and actions sit in the foreground using shared MD3 controls.
/// The launch/read affordance is optional so shelf book long-press menus can
/// stay management-only while ordinary history dialogs can still expose it.
///
/// 不是 `@visibleForTesting`：视频卡（`home_video_page._showVideoMenu`）与游戏卡
/// （`games_library_page._GameCard`）的长按菜单在生产直接复用本骨架——它是三库
/// 共用的正式 API，不再只服务测试。
class MediaItemDialogFrame extends StatelessWidget {
  const MediaItemDialogFrame({
    required this.title,
    this.cover,
    this.author,
    this.showLaunchAction = true,
    this.launchLabel,
    this.onLaunch,
    this.quickActions = const [],
    this.listActions = const [],
    this.dangerActions = const [],
    super.key,
  });

  final Widget? cover;
  final String title;
  final String? author;
  final bool showLaunchAction;
  final String? launchLabel;
  final VoidCallback? onLaunch;
  final List<DialogQuickAction> quickActions;
  final List<DialogListAction> listActions;
  final List<DialogDangerAction> dangerActions;

  /// Cover height cap as a fraction of screen height. With the cover rendered at
  /// the top of the dialog (BoxFit.contain inside [_buildCover]) the whole cover
  /// stays visible (no hard crop) while the dialog never grows taller than the
  /// screen.
  ///
  /// TODO-455 had turned the cover into a dimmed background behind a heavy
  /// readability scrim, which made the cover effectively invisible (~7% opacity);
  /// TODO-557 restores the cover as a visible top-of-dialog block.
  static const double _coverHeightFactor = 0.34;

  @override
  Widget build(BuildContext context) {
    final double screenHeight = MediaQuery.sizeOf(context).height;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;

    return FushiDialogFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Visible cover block at the top of the dialog (TODO-557). The cover
          // widget itself uses BoxFit.contain, so the whole artwork stays
          // visible and is never cropped; the ColoredBox letterboxes it.
          if (cover != null)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: screenHeight * _coverHeightFactor,
              ),
              child: ColoredBox(
                color: tokens.surfaces.overlay,
                child: cover!,
              ),
            ),
          Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  title,
                  // TODO-2490：本弹窗是库页卡片长按/右键「看全名」的兜底路径——
                  // 卡上标题最多两行省略，这里再截断则超长条目名到处都看不全。
                  // 外层 FushiDialogFrame 默认可滚动且限高，不会撑出屏。
                  style: tokens.type.pageTitle.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (author != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    author!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listSubtitle.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                SizedBox(height: tokens.spacing.card),
                if (showLaunchAction &&
                    launchLabel != null &&
                    onLaunch != null) ...<Widget>[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onLaunch,
                      child: Text(
                        launchLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  SizedBox(height: tokens.spacing.gap + 4),
                ],
                if (quickActions.isNotEmpty)
                  _buildQuickActions(context, tokens),
                if (listActions.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  const FushiDivider(),
                  for (final DialogListAction action in listActions)
                    FushiListItem(
                      minHeight: 44,
                      padding: EdgeInsets.zero,
                      leading: Icon(action.icon),
                      title: Text(action.label),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: colors.onSurfaceVariant,
                      ),
                      onTap: action.onPressed,
                    ),
                ],
                if (dangerActions.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  const FushiDivider(),
                  SizedBox(height: tokens.spacing.gap / 2),
                  for (final DialogDangerAction action in dangerActions)
                    Center(
                      child: TextButton(
                        onPressed: action.onPressed,
                        style: TextButton.styleFrom(
                          foregroundColor: action.muted
                              ? colors.onSurfaceVariant
                              : colors.error,
                        ),
                        child: Text(
                          action.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context, FushiDesignTokens tokens) {
    return _QuickActionGrid(
      gap: tokens.spacing.gap,
      textDirection: Directionality.of(context),
      children: <Widget>[
        for (final DialogQuickAction action in quickActions)
          _quickActionChip(action),
      ],
    );
  }

  Widget _quickActionChip(DialogQuickAction action) {
    return FushiActionChip(
      label: action.label,
      icon: action.icon,
      onPressed: action.onPressed,
    );
  }
}

/// 等宽快捷 chip 网格：按 chip 的**真实内在宽度**决定每行放几列。
///
/// BUG-2603：旧实现用常量 96 猜「一个 chip 最少要多宽」再平分。中文「从互联对端
/// 下载有声书」、日语「オーディオブックをインポート」这类标签远超 96，手机宽度下
/// 三等分后每个 chip 只剩三四个字，被 ellipsis 截成「查…/导…/从…」。这里改成在
/// layout 阶段量每个 chip 的 maxIntrinsicWidth（含图标、内边距与字号缩放），取最宽者
/// 为列宽下限，从「全部一行」往下试到一列，第一个「等分列宽 ≥ 最宽 chip」的列数
/// 胜出；所有 chip 等宽，放不进本行的换行沿用同一列宽。不再依赖任何拍脑袋常量。
class _QuickActionGrid extends MultiChildRenderObjectWidget {
  const _QuickActionGrid({
    required this.gap,
    required this.textDirection,
    required super.children,
  });

  final double gap;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderQuickActionGrid(gap: gap, textDirection: textDirection);
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderQuickActionGrid renderObject) {
    renderObject
      ..gap = gap
      ..textDirection = textDirection;
  }
}

class _QuickActionGridParentData extends ContainerBoxParentData<RenderBox> {}

/// 一次布局决议：[columns] 列、每列 [width] 宽。
typedef _QuickActionColumns = ({int columns, double width});

class _RenderQuickActionGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _QuickActionGridParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _QuickActionGridParentData> {
  _RenderQuickActionGrid({
    required double gap,
    required TextDirection textDirection,
  })  : _gap = gap,
        _textDirection = textDirection;

  double _gap;
  double get gap => _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _QuickActionGridParentData) {
      child.parentData = _QuickActionGridParentData();
    }
  }

  /// 从「全部一行」往下试到一列，第一个「等分列宽容得下最宽 chip」的列数胜出；
  /// 一列都容不下时仍取一列铺满——chip 内部的 ellipsis 只是最后防线，不是布局目标。
  _QuickActionColumns _resolveColumns(double maxWidth) {
    int count = 0;
    double widest = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      count++;
      widest = math.max(widest, child.getMaxIntrinsicWidth(double.infinity));
      child = childAfter(child);
    }
    if (count == 0) return (columns: 0, width: 0);
    if (!maxWidth.isFinite) return (columns: count, width: widest);
    for (int columns = count; columns > 1; columns--) {
      final double width = (maxWidth - gap * (columns - 1)) / columns;
      if (width >= widest) return (columns: columns, width: width);
    }
    return (columns: 1, width: maxWidth);
  }

  /// 逐 chip 走一遍网格：[childHeight] 给出 chip 在 [grid].width 下的高度，
  /// [place] 非空时顺带把 chip 的偏移写进 parentData。返回整块的尺寸。
  Size _walkGrid(
    _QuickActionColumns grid,
    double Function(RenderBox child, BoxConstraints constraints) childHeight, {
    bool place = false,
  }) {
    if (grid.columns == 0) return Size.zero;
    final BoxConstraints chipConstraints =
        BoxConstraints.tightFor(width: grid.width);
    final double totalWidth =
        grid.columns * grid.width + gap * (grid.columns - 1);
    double y = 0;
    double rowHeight = 0;
    int column = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      if (column == grid.columns) {
        column = 0;
        y += rowHeight + gap;
        rowHeight = 0;
      }
      final double height = childHeight(child, chipConstraints);
      if (place) {
        final double start = column * (grid.width + gap);
        final double x = switch (textDirection) {
          TextDirection.ltr => start,
          TextDirection.rtl => totalWidth - start - grid.width,
        };
        final _QuickActionGridParentData parentData =
            child.parentData! as _QuickActionGridParentData;
        parentData.offset = Offset(x, y);
      }
      rowHeight = math.max(rowHeight, height);
      column++;
      child = childAfter(child);
    }
    return Size(totalWidth, y + rowHeight);
  }

  @override
  void performLayout() {
    final _QuickActionColumns grid = _resolveColumns(constraints.maxWidth);
    final Size content = _walkGrid(
      grid,
      (RenderBox child, BoxConstraints chipConstraints) {
        child.layout(chipConstraints, parentUsesSize: true);
        return child.size.height;
      },
      place: true,
    );
    size = constraints.constrain(content);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final _QuickActionColumns grid = _resolveColumns(constraints.maxWidth);
    final Size content = _walkGrid(
      grid,
      (RenderBox child, BoxConstraints chipConstraints) =>
          child.getDryLayout(chipConstraints).height,
    );
    return constraints.constrain(content);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    double widest = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      widest = math.max(widest, child.getMinIntrinsicWidth(height));
      child = childAfter(child);
    }
    return widest;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    return _walkGrid(
      _resolveColumns(double.infinity),
      (RenderBox child, BoxConstraints chipConstraints) => 0,
    ).width;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    return _walkGrid(
      _resolveColumns(width),
      (RenderBox child, BoxConstraints chipConstraints) =>
          child.getMinIntrinsicHeight(chipConstraints.maxWidth),
    ).height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    return _walkGrid(
      _resolveColumns(width),
      (RenderBox child, BoxConstraints chipConstraints) =>
          child.getMaxIntrinsicHeight(chipConstraints.maxWidth),
    ).height;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }
}
