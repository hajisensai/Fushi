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
    this.onLongPress,
    this.onSecondaryTap,
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

  /// 长按 / 桌面右键（与散书卡 onLongPress/onSecondaryTap 同语义，巡检 PR-3 补齐
  /// 交互对称性）。null 时保持纯点击（零破坏）；多选态下自动禁用（与散卡一致）。
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

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
          onLongPress: selectionMode ? null : onLongPress,
          onSecondaryTap: selectionMode ? null : onSecondaryTap,
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
                          child: ShelfSelectionCheck(selected: selected),
                        ),
                      if (selected)
                        const Positioned.fill(child: ShelfSelectedOverlay()),
                    ],
                  ),
                ),
                SizedBox(
                  // BUG-1177：与散书卡同步，随文字缩放变高，防止系列名第二行被裁。
                  height: ShelfCardFooter.heightFor(context),
                  child: ShelfCardFooter(title: name),
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
