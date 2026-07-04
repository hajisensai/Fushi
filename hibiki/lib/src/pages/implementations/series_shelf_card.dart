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
                      // TODO-1125 A：堆叠样式——后层铺真实成员封面（露出后面几本书），
                      // 首卷主封面在最前。成员不足 2 张时 _backCovers 为空 → 只画主
                      // 封面，视觉退回单卡（never break 单封面书架）。
                      ..._buildBackLayers(theme, tokens),
                      Positioned(
                        top: 4,
                        left: 0,
                        right: 6,
                        bottom: 0,
                        child: HibikiCard(
                          padding: EdgeInsets.zero,
                          margin: EdgeInsets.zero,
                          child: ClipRect(
                            child: covers.isNotEmpty
                                ? covers.first
                                : const SizedBox.shrink(),
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

  /// TODO-1125 A：后层堆叠封面。取 [covers] 里主封面之后的 1~2 张成员封面，各自
  /// 向右下略偏移 + 缩小 + 描边/阴影铺在主封面后面，读作「一摞书」（苹果式）。
  ///
  /// 越靠后的成员偏移越大、越小（离读者越远），且先渲染（Stack 底层），故主封面最前。
  /// 成员不足 2 张（[covers].length < 2）→ 返回空列表，视觉退回单封面无堆叠。
  List<Widget> _buildBackLayers(ThemeData theme, HibikiDesignTokens tokens) {
    if (covers.length < 2) return const <Widget>[];
    // 最多两张后层（第 2、3 个成员封面）；离读者越远层级越靠后（先绘制）。
    final List<Widget> back = covers.skip(1).take(2).toList(growable: false);
    final List<Widget> layers = <Widget>[];
    for (int i = back.length - 1; i >= 0; i--) {
      // depth 1 = 紧贴主封面的一层；depth 2 = 更远一层。偏移/缩小随 depth 递增。
      final int depth = i + 1;
      final double dx = 6.0 * depth;
      final double dy = 3.0 * depth;
      final double scale = 1.0 - 0.05 * depth;
      layers.add(Positioned(
        // 稳定 Key，供测试精确统计后层数量（与主封面 / app 内部 Transform 区分）。
        key: ValueKey<String>('series-stack-back-$depth'),
        top: 4 + dy,
        left: dx,
        right: 6,
        bottom: 0,
        child: IgnorePointer(
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: tokens.radii.cardRadius,
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 4,
                    offset: const Offset(1, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: tokens.radii.cardRadius,
                child: back[i],
              ),
            ),
          ),
        ),
      ));
    }
    return layers;
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
