import 'package:flutter/material.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

// ---------------------------------------------------------------------------
// Action data model
// ---------------------------------------------------------------------------
//
// Every action carries a label + icon + onPressed. The three subtypes differ in
// placement / weight in the below-cover action column:
//   * [DialogQuickAction]  -> equal-width quick-action chip (HibikiActionChip).
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
    super.key,
  });

  final MediaItem item;
  final bool isHistory;
  final List<DialogAction> Function(MediaItem)? extraActions;
  final bool showLaunchAction;

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
      showLaunchAction: widget.showLaunchAction,
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
@visibleForTesting
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;

    return HibikiDialogFrame(
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
                if (quickActions.isNotEmpty) _buildQuickActions(tokens),
                if (listActions.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  const HibikiDivider(),
                  for (final DialogListAction action in listActions)
                    HibikiListItem(
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
                  const HibikiDivider(),
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

  /// 单行等宽时单个 chip 仍能容纳中文「导入有声书」这类标签的保守最小宽度；
  /// 平分后低于此宽度就降级成竖排整行，避免 intrinsic-width 横排被 ellipsis 截断。
  static const double _quickActionMinChipWidth = 96.0;

  Widget _buildQuickActions(HibikiDesignTokens tokens) {
    final double gap = tokens.spacing.gap;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int count = quickActions.length;
        final double available = constraints.maxWidth;
        final bool fitsOneRow = available.isFinite &&
            (available - gap * (count - 1)) / count >= _quickActionMinChipWidth;
        final double chipWidth = fitsOneRow
            ? (available - gap * (count - 1)) / count
            : (available.isFinite ? available : double.infinity);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final DialogQuickAction action in quickActions)
              SizedBox(
                width: chipWidth,
                child: _quickActionChip(action),
              ),
          ],
        );
      },
    );
  }

  Widget _quickActionChip(DialogQuickAction action) {
    return HibikiActionChip(
      label: action.label,
      icon: action.icon,
      onPressed: action.onPressed,
    );
  }
}
