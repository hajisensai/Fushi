import 'package:flutter/material.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

// ---------------------------------------------------------------------------
// Action data model
// ---------------------------------------------------------------------------

sealed class DialogAction {
  const DialogAction({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}

final class DialogQuickAction extends DialogAction {
  const DialogQuickAction({
    required super.label,
    required super.onPressed,
    required this.icon,
  });
  final IconData icon;
}

final class DialogListAction extends DialogAction {
  const DialogListAction({required super.label, required super.onPressed});
}

final class DialogDangerAction extends DialogAction {
  const DialogDangerAction({
    required super.label,
    required super.onPressed,
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
          DialogListAction(label: t.dialog_edit_info, onPressed: _executeEdit),
      ];

  List<DialogDangerAction> get _dangerActions => [
        ..._externalActions.whereType<DialogDangerAction>(),
        if (widget.item.canDelete && widget.isHistory)
          DialogDangerAction(
            label: t.dialog_clear,
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

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: screenHeight * 0.82,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // -- Cover --
              if (cover != null)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: screenHeight * 0.28,
                  ),
                  child: Container(
                    color: cs.surfaceContainerHighest,
                    child: cover,
                  ),
                ),

              // -- Text + actions area --
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleMedium,
                    ),

                    // Author
                    if (author != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),

                    // Primary action (Read)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: onLaunch,
                        child: Text(launchLabel),
                      ),
                    ),

                    // Quick actions
                    if (quickActions.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _buildQuickActions(),
                    ],

                    // List actions
                    if (listActions.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      const Divider(),
                      for (final action in listActions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          title: Text(action.label),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: cs.onSurfaceVariant,
                          ),
                          onTap: action.onPressed,
                        ),
                    ],

                    // Danger actions
                    if (dangerActions.isNotEmpty) ...[
                      const Divider(),
                      const SizedBox(height: 4),
                      for (final action in dangerActions)
                        Center(
                          child: TextButton(
                            onPressed: action.onPressed,
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  action.muted ? cs.onSurfaceVariant : cs.error,
                            ),
                            child: Text(action.label),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final action in quickActions)
          _QuickActionChip(action: action),
      ],
    );
  }
}

class _QuickActionChip extends StatelessWidget {
  const _QuickActionChip({required this.action});
  final DialogQuickAction action;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: action.onPressed,
      icon: Icon(action.icon, size: 18),
      label: Text(
        action.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
