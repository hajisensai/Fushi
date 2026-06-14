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
/// The cover is shown complete (BoxFit.contain, never cropped) at the top of a
/// vertical column. Below it sit the title / author and a column of full-width
/// action buttons: a primary read launch button, equal-width quick actions,
/// list actions, and (muted) destructive actions. Keeping the buttons in their
/// own below-cover column -- instead of translucent chips stacked on the cover
/// -- avoids the cover being eaten and the actions piling up over the artwork.
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
  final String launchLabel;
  final VoidCallback onLaunch;
  final List<DialogQuickAction> quickActions;
  final List<DialogListAction> listActions;
  final List<DialogDangerAction> dangerActions;

  /// Cover height cap as a fraction of screen height. With BoxFit.contain the
  /// artwork is letterboxed inside this box, so the whole cover stays visible
  /// (no hard crop) while the dialog never grows taller than the screen.
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
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card + 4,
              tokens.spacing.card,
              tokens.spacing.card + 4,
              tokens.spacing.card - 4,
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
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (author != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    author!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listSubtitle,
                  ),
                ],
                SizedBox(height: tokens.spacing.card),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onLaunch,
                    child: Text(
                      launchLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (quickActions.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap + 4),
                  _buildQuickActions(tokens),
                ],
                if (listActions.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap / 2),
                  const HibikiDivider(),
                  for (final DialogListAction action in listActions)
                    HibikiListItem(
                      minHeight: 44,
                      padding: EdgeInsets.zero,
                      title: Text(action.label),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: colors.onSurfaceVariant,
                      ),
                      onTap: action.onPressed,
                    ),
                ],
                if (dangerActions.isNotEmpty) ...<Widget>[
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
        // 一行平分后每格仍够宽 → 等宽横排；否则窄屏降级成竖排整行。
        final bool fitsOneRow = available.isFinite &&
            (available - gap * (count - 1)) / count >= _quickActionMinChipWidth;
        return fitsOneRow ? _quickActionsRow(gap) : _quickActionsColumn(gap);
      },
    );
  }

  /// 等宽横排：每个 chip 用 Expanded 平分一行，消除 intrinsic-width 参差。
  Widget _quickActionsRow(double gap) {
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < quickActions.length; i++) {
      if (i > 0) children.add(SizedBox(width: gap));
      children.add(Expanded(child: _quickActionChip(quickActions[i])));
    }
    return Row(children: children);
  }

  /// 窄屏降级：每个 chip 占整行，宽度一致。
  Widget _quickActionsColumn(double gap) {
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < quickActions.length; i++) {
      if (i > 0) children.add(SizedBox(height: gap));
      children.add(
        SizedBox(
            width: double.infinity, child: _quickActionChip(quickActions[i])),
      );
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _quickActionChip(DialogQuickAction action) {
    return HibikiActionChip(
      label: action.label,
      icon: action.icon,
      onPressed: action.onPressed,
    );
  }
}
