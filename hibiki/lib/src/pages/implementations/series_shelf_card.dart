import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/utils.dart';

/// TODO-616 A2 series folded card: one card stands for a whole series (cover =
/// first volume, count badge = members, name footer). Same slot aspect ratio as
/// a normal book card so it mixes inline with loose books. Tap -> series detail.
///
/// Generic over the cover widgets so both the book shelf and the video library
/// reuse it (each passes its own member-cover widget list; this card adds only
/// the stacked-pile affordance + count badge + name, never re-renders a cover).
///
/// TODO-1125 A：堆叠样式——[covers] 传前 N 张成员封面（首卷在 first，最前层），
/// 后 1~2 张真实成员封面偏移 + 缩小 + 描边/阴影铺在后层，读作「一摞书」（苹果式）。
/// 成员不足 2 张优雅降级为单封面（无堆叠）。
class SeriesShelfCard extends StatelessWidget {
  const SeriesShelfCard({
    required this.name,
    required this.itemCount,
    required this.covers,
    required this.onTap,
    required this.slotAspectRatio,
    this.focusId,
    this.selectionKey,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionToggle,
    super.key,
  });

  final String name;
  final int itemCount;

  /// 系列前 N 张成员封面（N≤3），[covers].first 为主封面（首卷，最前层），其余
  /// 作为后层「露出后面几本书」的堆叠视觉。为空则不渲染封面（防御性，调用方保证非空）。
  final List<Widget> covers;
  final VoidCallback onTap;
  final double slotAspectRatio;

  /// Gamepad/keyboard focus id. When non-null and a [HibikiFocusRoot] is present
  /// the card becomes a directional-focus target that opens on Enter / gamepad A,
  /// mirroring the loose book cards ([_bookCardShell]). Without it (or outside a
  /// focus root) the card stays a plain, tap-only InkWell as before.
  final HibikiFocusId? focusId;

  /// Optional selection wiring (so a series card is selectable in batch mode
  /// just like a normal card). When [selectionMode] is on, tap toggles
  /// selection instead of opening the detail page.
  final String? selectionKey;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectionToggle;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    final VoidCallback effectiveTap =
        selectionMode && onSelectionToggle != null ? onSelectionToggle! : onTap;

    final Widget card = Padding(
      padding: EdgeInsets.all(tokens.spacing.rowVertical),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          canRequestFocus: false,
          borderRadius: tokens.radii.cardRadius,
          onTap: effectiveTap,
          child: AspectRatio(
            aspectRatio: slotAspectRatio,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      Positioned.fill(
                        child: HibikiCard(
                          padding: EdgeInsets.zero,
                          margin: EdgeInsets.zero,
                          child: ClipRRect(
                            borderRadius: tokens.radii.cardRadius,
                            child: SeriesFolderCover(covers: covers),
                          ),
                        ),
                      ),
                      PositionedDirectional(
                        end: overlayInset + 6,
                        top: overlayInset + 4,
                        child: _countBadge(theme, tokens),
                      ),
                      if (selectionMode && selectionKey != null)
                        Positioned(
                          top: tokens.spacing.gap / 2,
                          left: tokens.spacing.gap / 2,
                          child: _selectionCheck(theme, tokens),
                        ),
                      if (selected)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: tokens.surfaces.primary
                                    .withValues(alpha: 0.12),
                                borderRadius: tokens.radii.cardRadius,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 40,
                  child: Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(
                      tokens.spacing.gap * 0.75,
                      tokens.spacing.gap / 2,
                      tokens.spacing.gap * 0.75,
                      0,
                    ),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        softWrap: true,
                        style: tokens.type.metadata.copyWith(
                          color: tokens.surfaces.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Loose book cards are gamepad/keyboard focusable via _bookCardShell; a
    // folded series card must be too, else a shelf with series can't be entered
    // by D-pad. Only wrap when a focusId is supplied AND a HibikiFocusRoot exists
    // (plain tests / no-controller contexts keep the bare InkWell). Enter /
    // gamepad A activate the same tap as a mouse; in selection mode that tap
    // toggles selection (effectiveTap), matching the InkWell.
    if (focusId != null && HibikiFocusRoot.maybeControllerOf(context) != null) {
      return Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              effectiveTap();
              return null;
            },
          ),
        },
        child: HibikiFocusTarget(id: focusId!, child: card),
      );
    }
    return card;
  }

  Widget _countBadge(ThemeData theme, HibikiDesignTokens tokens) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.collections_bookmark_outlined,
            size: 13,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 3),
          Text(
            t.series_item_count(n: itemCount),
            style: tokens.type.metadata.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectionCheck(ThemeData theme, HibikiDesignTokens tokens) {
    final Color selectionColor = tokens.surfaces.primary;
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? selectionColor
              : tokens.surfaces.page.withValues(alpha: 0.7),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? selectionColor : tokens.surfaces.outline,
            width: 1.5,
          ),
        ),
        padding: EdgeInsets.all(tokens.spacing.gap / 4),
        child: Icon(
          Icons.check,
          size: tokens.spacing.gap * 1.75,
          color: selected ? theme.colorScheme.onPrimary : Colors.transparent,
        ),
      ),
    );
  }
}

/// TODO-947：手机文件夹式合集封面——把前 N 张成员封面（[covers]，首卷在 first）铺成
/// 2x2 网格缩略（像 iOS/安卓桌面文件夹图标），让用户一眼看出合集里合并了哪几本书。
///
/// [SeriesShelfCard] 折叠卡与「组合成系列」命名弹窗预览共用本组件（同一视觉语言）。
/// 成员不足 2 张优雅降级为整封面（无网格，never break 单成员）；成员多于 4 张只取前
/// 4 张（配角标显示真实总数）。空 [covers] 渲染占位空盒（防御性，调用方保证非空）。
class SeriesFolderCover extends StatelessWidget {
  const SeriesFolderCover({
    required this.covers,
    this.cellRadius = 4,
    super.key,
  });

  /// 系列前 N 张成员封面（N 由调用方裁到 ≤4），[covers].first 为主封面（首卷）。
  final List<Widget> covers;

  /// 每个网格单元的圆角半径（文件夹内小缩略图的描边圆角）。
  final double cellRadius;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // 单张成员：整封面填满（与散书卡视觉一致，never break 单成员合集）。
    if (covers.length <= 1) {
      return covers.isEmpty ? const SizedBox.shrink() : covers.first;
    }
    final double gap = tokens.spacing.gap / 2;
    final double pad = tokens.spacing.gap / 2;
    // 文件夹底：微着色圆角容器 + 内边距，内嵌 2x2 成员封面网格。
    return DecoratedBox(
      decoration:
          BoxDecoration(color: theme.colorScheme.surfaceContainerHighest),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          children: <Widget>[
            Expanded(child: _mosaicRow(theme, gap, 0, 1)),
            SizedBox(height: gap),
            Expanded(child: _mosaicRow(theme, gap, 2, 3)),
          ],
        ),
      ),
    );
  }

  Widget _mosaicRow(ThemeData theme, double gap, int a, int b) {
    return Row(
      children: <Widget>[
        Expanded(child: _mosaicCell(theme, a)),
        SizedBox(width: gap),
        Expanded(child: _mosaicCell(theme, b)),
      ],
    );
  }

  Widget _mosaicCell(ThemeData theme, int i) {
    final BorderRadius radius = BorderRadius.circular(cellRadius);
    if (i >= covers.length) {
      // 空槽：成员不足 4 本时补齐网格的占位底（更浅一档，视觉平衡）。
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: radius,
        ),
      );
    }
    // 成员封面填满该单元并按各自 BoxFit 呈现，超出用圆角裁掉（center-crop 观感）。
    return ClipRRect(
      key: ValueKey<String>('series-folder-cell-$i'),
      borderRadius: radius,
      child: SizedBox.expand(child: covers[i]),
    );
  }
}

/// TODO-947 P4：书架「编辑排序」页里给**内联展开的系列成员卡**套的分组框。用户拍板：
/// 编辑排序里合集成员要连续相邻 + 用框圈在一起，一眼看出哪几本是同一个合集。
///
/// 用 [Container.foregroundDecoration] 在成员卡**之上**画同色圆角边框——纯前景绘制，不占
/// 布局尺寸，故不破坏等尺寸重排网格（[HibikiReorderableGrid] 每格固定 cellExtent×高）。同一
/// 系列的每个成员卡都用同一个 [color]（由 seriesId 稳定映射到调色板，相邻系列颜色不同），
/// 配上 groupAndSortShelfEntries 保证的连续相邻 → 读作「这一串同色框是一个合集」。首个成员
/// （[showHeader]）左上角额外叠一个系列名 header chip（不改尺寸的 Positioned 叠层）标注名字。
class SeriesReorderFrame extends StatelessWidget {
  const SeriesReorderFrame({
    required this.color,
    required this.showHeader,
    required this.seriesName,
    required this.memberCount,
    required this.child,
    super.key,
  });

  /// 本系列的分组框颜色（同系列所有成员同色；由调用方按 seriesId 稳定分配）。
  final Color color;

  /// 是否本系列内联展开后的**首个成员**——仅首个成员叠系列名 header（避免每格都标名字）。
  final bool showHeader;

  /// 系列名（header 文本；无名兜底由调用方传 `t.series`）。
  final String seriesName;

  /// 系列成员总数（header 角标显示，配合连续相邻让用户数清一个合集有几本）。
  final int memberCount;

  /// 被套框的成员卡（书架既有卡片渲染，不重画）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const BorderRadius radius = BorderRadius.all(Radius.circular(14));
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        // 系列色「衬垫」+ 描边：书卡自带 12px 内边距（[_bookCardShell]），故本 Container
        // 的**背景**在卡片四周露出一圈同系列色的实心 matte，前景再叠一道实心边框——
        // 二者都是**填充/实心**而非早期的 2.5px 细线：细线在祖先 [HibikiAppUiScale]
        // 的 FittedBox 缩小（手机默认缩放 <1）下会被压成亚像素而「看不见」，实心 matte
        // 在任意缩放下都留得住可见宽度。同系列成员同色 matte → 读作「同一叠」。
        // decoration（背景）画在卡片之下、只从 12px 内边距漏出，不会给不透明封面着色；
        // foregroundDecoration（边框）画在卡片之上，保证边界永远可见。
        Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.32),
            borderRadius: radius,
          ),
          foregroundDecoration: BoxDecoration(
            border: Border.all(color: color, width: 3),
            borderRadius: radius,
          ),
          child: child,
        ),
        if (showHeader)
          PositionedDirectional(
            top: 6,
            start: 6,
            child: _SeriesFrameHeader(
              color: color,
              seriesName: seriesName,
              memberCount: memberCount,
            ),
          ),
      ],
    );
  }
}

/// [SeriesReorderFrame] 首成员左上角的系列名 chip（folder 图标 + 名字 + 数量）。白字铺在
/// 系列色底上，与成员框同色，读作「这个合集叫 X、共 N 本，从这里开始」。
class _SeriesFrameHeader extends StatelessWidget {
  const _SeriesFrameHeader({
    required this.color,
    required this.seriesName,
    required this.memberCount,
  });

  final Color color;
  final String seriesName;
  final int memberCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.all(Radius.circular(9)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
              color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.collections_bookmark_outlined,
              size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              seriesName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            t.series_item_count(n: memberCount),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
