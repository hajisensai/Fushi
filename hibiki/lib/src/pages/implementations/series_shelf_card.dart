import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/utils.dart';

/// TODO-616 A2 series folded card: one card stands for a whole series (cover =
/// first volume, count badge = members, name footer). Same slot aspect ratio as
/// a normal book card so it mixes inline with loose books. Tap -> series detail.
///
/// Generic over the cover widget so both the book shelf and the video library
/// reuse it (each passes its own first-volume cover widget; this card adds only
/// the stack affordance + count badge + name, never re-renders the cover).
class SeriesShelfCard extends StatelessWidget {
  const SeriesShelfCard({
    required this.name,
    required this.itemCount,
    required this.cover,
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
  final Widget cover;
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
                      // Stack affordance: a back layer peeking out top/right to
                      // read as a pile of volumes folded into one card.
                      Positioned(
                        top: 0,
                        left: 6,
                        right: 0,
                        bottom: 8,
                        child: _stackBackLayer(theme, tokens),
                      ),
                      Positioned(
                        top: 4,
                        left: 0,
                        right: 6,
                        bottom: 0,
                        child: HibikiCard(
                          padding: EdgeInsets.zero,
                          margin: EdgeInsets.zero,
                          child: ClipRect(child: cover),
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

  Widget _stackBackLayer(ThemeData theme, HibikiDesignTokens tokens) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaces.overlay,
        borderRadius: tokens.radii.cardRadius,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
    );
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
