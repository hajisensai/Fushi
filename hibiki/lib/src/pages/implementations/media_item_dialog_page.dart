import 'package:flutter/material.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

// ---------------------------------------------------------------------------
// Action data model
// ---------------------------------------------------------------------------
//
// TODO-293 redesign: every action now carries a label + icon + onPressed.
// Eliminating the old "list actions have no icon" special case lets the whole
// dialog speak a single visual language — translucent icon/chip buttons layered
// over the cover. The three subtypes only differ in *placement / weight*:
//   * [DialogQuickAction]  -> primary translucent action chip on the cover.
//   * [DialogListAction]   -> secondary translucent action chip on the cover.
//   * [DialogDangerAction] -> destructive entry, hidden inside the translucent
//                             overflow menu so it cannot be mis-tapped.

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
    super.key,
  });

  final MediaItem item;
  final bool isHistory;
  final List<DialogAction> Function(MediaItem)? extraActions;

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

    return MediaItemDialogFrame(
      cover: _hasCover ? _buildCover() : null,
      title: displayTitle,
      author: hasAuthor ? author : null,
      launchLabel: t.dialog_read,
      onLaunch: _executeLaunch,
      quickActions: _quickActions,
      listActions: _listActions,
      dangerActions: _dangerActions,
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
            fit: BoxFit.cover,
          );
        }
        return const SizedBox.shrink();
      },
      image: mediaSource.getDisplayThumbnailFromMediaItem(
        appModel: appModel,
        item: widget.item,
      ),
      fit: BoxFit.cover,
    );
  }
}

// ---------------------------------------------------------------------------
// Dialog frame (pure layout, testable in isolation)
// ---------------------------------------------------------------------------

/// TODO-293 redesign — long-press "book settings" dialog.
///
/// The cover is the hero: it fills the dialog and is itself the *read*
/// affordance (tap the cover to open the book). Title / author and the action
/// buttons are layered translucently over the cover so nothing feels like a
/// detached block. Destructive actions (delete / clear) live behind a
/// translucent overflow menu so they can't be hit by accident.
///
/// "Tap outside to dismiss" (the dialog barrier) and "tap the cover to read"
/// never conflict: the cover tap target is strictly the in-dialog cover region;
/// the barrier is everything outside the [Dialog].
@visibleForTesting
class MediaItemDialogFrame extends StatelessWidget {
  const MediaItemDialogFrame({
    required this.title,
    required this.launchLabel,
    required this.onLaunch,
    this.cover,
    this.author,
    this.quickActions = const [],
    this.listActions = const [],
    this.dangerActions = const [],
    super.key,
  });

  final Widget? cover;
  final String title;
  final String? author;

  /// Accessibility label for the cover tap target ("read"); the cover no longer
  /// carries a separate launch button so this becomes the tap semantics.
  final String launchLabel;
  final VoidCallback onLaunch;
  final List<DialogQuickAction> quickActions;
  final List<DialogListAction> listActions;
  final List<DialogDangerAction> dangerActions;

  /// Hero cover height as a fraction of screen height — large enough to feel
  /// immersive while leaving room for the translucent action bar to float over
  /// its lower edge.
  static const double _coverHeightFactor = 0.34;

  @override
  Widget build(BuildContext context) {
    final double screenHeight = MediaQuery.sizeOf(context).height;
    final double coverHeight = screenHeight * _coverHeightFactor;

    return HibikiDialogFrame(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: coverHeight),
        child: _CoverHero(
          cover: cover,
          title: title,
          author: author,
          launchLabel: launchLabel,
          onLaunch: onLaunch,
          quickActions: quickActions,
          listActions: listActions,
          dangerActions: dangerActions,
        ),
      ),
    );
  }
}

/// The immersive cover stack: cover image, bottom scrim with title/author,
/// the translucent action bar, and the destructive overflow menu.
class _CoverHero extends StatelessWidget {
  const _CoverHero({
    required this.cover,
    required this.title,
    required this.author,
    required this.launchLabel,
    required this.onLaunch,
    required this.quickActions,
    required this.listActions,
    required this.dangerActions,
  });

  final Widget? cover;
  final String title;
  final String? author;
  final String launchLabel;
  final VoidCallback onLaunch;
  final List<DialogQuickAction> quickActions;
  final List<DialogListAction> listActions;
  final List<DialogDangerAction> dangerActions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<DialogAction> barActions = <DialogAction>[
      ...quickActions,
      ...listActions,
    ];

    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        // Cover fills the hero; tapping it opens the book (= read).
        Positioned.fill(
          child: Semantics(
            button: true,
            label: launchLabel,
            child: Material(
              color: tokens.surfaces.overlay,
              child: InkWell(
                onTap: onLaunch,
                child: _coverImage(colors),
              ),
            ),
          ),
        ),
        // Bottom scrim so the overlaid title / actions stay legible over any
        // cover; ignores pointers so the whole cover beneath stays tappable.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const <double>[0.0, 0.45, 1.0],
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0.0),
                    Colors.black.withValues(alpha: 0.18),
                    Colors.black.withValues(alpha: 0.78),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Destructive overflow menu, kept in the top-right corner away from the
        // read tap and behind a deliberate extra tap to avoid mis-taps.
        if (dangerActions.isNotEmpty)
          Positioned(
            top: tokens.spacing.gap,
            right: tokens.spacing.gap,
            child: _OverflowMenu(actions: dangerActions),
          ),
        // Title, author and translucent action bar pinned to the bottom edge.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle.copyWith(
                    color: Colors.white,
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
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
                if (barActions.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.card),
                  _TranslucentActionBar(actions: barActions),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _coverImage(ColorScheme colors) {
    final Widget? cover = this.cover;
    if (cover != null) return cover;
    // No cover: a calm tonal placeholder that still reads as a (tappable) hero
    // rather than an empty box.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            colors.surfaceContainerHighest,
            colors.surfaceContainerHigh,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          size: 56,
          color: colors.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// A horizontally-wrapping row of translucent action chips overlaid on the
/// cover. Each chip is an icon + label on a semi-transparent dark pill so it
/// blends into the cover's lower scrim instead of forming a detached block.
class _TranslucentActionBar extends StatelessWidget {
  const _TranslucentActionBar({required this.actions});

  final List<DialogAction> actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        for (final DialogAction action in actions)
          _TranslucentActionChip(
            icon: action.icon,
            label: action.label,
            onPressed: action.onPressed,
          ),
      ],
    );
  }
}

/// A single translucent capsule button (icon + label) for the cover overlay.
class _TranslucentActionChip extends StatelessWidget {
  const _TranslucentActionChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      shape: StadiumBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: Colors.white),
              SizedBox(width: tokens.spacing.gap / 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.controlLabel.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Translucent circular "more" button hosting the destructive actions. Putting
/// delete / clear behind a menu (instead of a flat button) is the deliberate
/// guard against accidental destructive taps.
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.actions});

  final List<DialogDangerAction> actions;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.black.withValues(alpha: 0.32),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<DialogDangerAction>(
        icon: const Icon(Icons.more_vert, color: Colors.white),
        tooltip: MaterialLocalizations.of(context).showMenuTooltip,
        onSelected: (DialogDangerAction action) => action.onPressed(),
        itemBuilder: (BuildContext context) =>
            <PopupMenuEntry<DialogDangerAction>>[
          for (final DialogDangerAction action in actions)
            PopupMenuItem<DialogDangerAction>(
              value: action,
              child: Row(
                children: <Widget>[
                  Icon(
                    action.icon,
                    size: 20,
                    color:
                        action.muted ? colors.onSurfaceVariant : colors.error,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    action.label,
                    style: TextStyle(
                      color:
                          action.muted ? colors.onSurfaceVariant : colors.error,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
