import 'package:flutter/material.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used upon long-pressing a [MediaItem].
class MediaItemDialogPage extends BasePage {
  /// Create an instance of this page.
  const MediaItemDialogPage({
    required this.item,
    required this.isHistory,
    this.extraActions,
    super.key,
  });

  /// The [MediaItem] pertaining to the page.
  final MediaItem item;

  /// Whether or not the media items are in history.
  final bool isHistory;

  /// Extra actions to include in the dialog page if supplied by a
  /// media source.
  final List<Widget>? Function(MediaItem)? extraActions;

  @override
  BasePageState createState() => _MediaItemDialogPageState();
}

class _MediaItemDialogPageState extends BasePageState<MediaItemDialogPage> {
  MediaSource get mediaSource => widget.item.getMediaSource(appModel: appModel);


  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: buildTitle(),
      content: buildContent(),
      actions: actions,
    );
  }

  Widget buildTitle() {
    return SelectableText(
      mediaSource.getDisplayTitleFromMediaItem(widget.item),
      selectionControls: selectionControls,
    );
  }

  Widget buildContent() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeInImage(
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
              } else {
                return const SizedBox.shrink();
              }
            },
            image: mediaSource.getDisplayThumbnailFromMediaItem(
              appModel: appModel,
              item: widget.item,
            ),
            fit: BoxFit.contain,
          ),
        ],
      ),
    );
  }

  List<Widget> get actions => [
        if (widget.item.canDelete && widget.isHistory) buildClearButton(),
        if (widget.extraActions != null) ...?widget.extraActions!(widget.item),
        if (widget.item.canEdit && widget.isHistory) buildEditButton(),
        buildLaunchButton(),
      ];

  String get launchLabel {
    return t.dialog_read;
  }

  Widget buildClearButton() {
    // Clear 是"擦掉进度"，不动书本身，走次操作 TextButton。
    return TextButton(
      onPressed: executeClear,
      child: Text(t.dialog_clear),
    );
  }

  /// 主操作（打开/阅读）走 FilledButton，视觉上与 Edit / Clear / 扩展按钮
  /// （如"删除"）拉开层级，让用户一眼看到"读"在哪。
  Widget buildLaunchButton() {
    return FilledButton(
      onPressed: executeLaunch,
      child: Text(launchLabel),
    );
  }

  Widget buildEditButton() {
    return TextButton(
      onPressed: executeEdit,
      child: Text(t.dialog_edit),
    );
  }

  void executeEdit() async {
    await showAppDialog(
      context: context,
      builder: (context) => MediaItemEditDialogPage(item: widget.item),
    );
  }

  void executeLaunch() async {
    Navigator.pop(context);
    await appModel.openMedia(
      mediaSource: mediaSource,
      ref: ref,
      item: widget.item,
    );
  }

  void executeClear() async {
    final navigator = Navigator.of(context);
    await appModel.deleteMediaItem(widget.item);
    navigator.pop();
  }
}
