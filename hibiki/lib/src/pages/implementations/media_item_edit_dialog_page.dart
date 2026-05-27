import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog upon selecting 'Edit' in the
/// [MediaItemDialogPage].
class MediaItemEditDialogPage extends BasePage {
  /// Create an instance of this page.
  const MediaItemEditDialogPage({
    required this.item,
    super.key,
  });

  /// The [MediaItem] pertaining to the page.
  final MediaItem item;

  @override
  BasePageState createState() => _MediaItemEditDialogPageState();
}

class _MediaItemEditDialogPageState
    extends BasePageState<MediaItemEditDialogPage> {
  MediaSource get mediaSource => widget.item.getMediaSource(appModel: appModel);
  ImageProvider? _defaultImageProvider;
  ImageProvider? _coverImageProvider;

  File? _newFile;
  bool _clearOverrideImage = false;

  final TextEditingController _nameOverrideController = TextEditingController();

  @override
  void dispose() {
    _nameOverrideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_defaultImageProvider == null) {
      String? overrideTitle =
          mediaSource.getOverrideTitleFromMediaItem(widget.item);
      String title = overrideTitle ?? widget.item.title;
      _nameOverrideController.text = title;

      _defaultImageProvider = mediaSource.getDisplayThumbnailFromMediaItem(
        appModel: appModel,
        item: widget.item,
        noOverride: true,
      );
      _coverImageProvider = mediaSource.getDisplayThumbnailFromMediaItem(
        appModel: appModel,
        item: widget.item,
      );
    }

    return MediaItemEditDialogFrame(
      content: buildContent(),
      actions: actions,
    );
  }

  Widget buildTitle() {
    return Text(mediaSource.getDisplayTitleFromMediaItem(widget.item));
  }

  Widget buildContent() {
    return ClipRect(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: double.maxFinite, height: 1),
          HibikiTextField(
            controller: _nameOverrideController,
            maxLines: null,
            suffixIcon: HibikiIconButton(
              tooltip: t.undo,
              isWideTapArea: true,
              icon: Icons.undo_outlined,
              onTap: () async {
                _nameOverrideController.text = widget.item.title;
                FocusScope.of(context).unfocus();
              },
            ),
          ),
          MediaItemCoverOverrideField(
            imageProvider: _coverImageProvider ?? _defaultImageProvider!,
            onPickImage: () async {
              ImagePicker imagePicker = ImagePicker();
              final pickedFile = await imagePicker.pickImage(
                source: ImageSource.gallery,
              );
              if (pickedFile != null) {
                _newFile = File(pickedFile.path);
                _coverImageProvider = FileImage(_newFile!);
                if (_newFile != null) {
                  _clearOverrideImage = false;
                }
              }

              setState(() {});
            },
            onUndo: () async {
              _newFile = null;
              _coverImageProvider = null;
              _clearOverrideImage = true;

              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  List<Widget> get actions => [
        buildCancelButton(),
        buildSaveButton(),
      ];

  Widget buildCancelButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeCancel,
      child: Text(t.dialog_cancel),
    );
  }

  Widget buildSaveButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSave,
      child: Text(t.dialog_save),
    );
  }

  void executeCancel() async {
    Navigator.pop(context);
  }

  void executeSave() async {
    final navigator = Navigator.of(context);

    if (_nameOverrideController.text.trim().isNotEmpty) {
      await mediaSource.setOverrideTitleFromMediaItem(
        item: widget.item,
        title: _nameOverrideController.text,
      );

      await mediaSource.setOverrideThumbnailFromMediaItem(
        appModel: appModel,
        item: widget.item,
        file: _newFile,
        clearOverrideImage: _clearOverrideImage,
      );

      navigator.pop();
      navigator.pop();
      mediaSource.mediaType.refreshTab();
    }
  }
}

@visibleForTesting
class MediaItemEditDialogFrame extends StatelessWidget {
  const MediaItemEditDialogFrame({
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return adaptiveAlertDialog(
      context: context,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      contentPadding: MediaQuery.of(context).orientation == Orientation.portrait
          ? Spacing.of(context).insets.all.big
          : Spacing.of(context).insets.all.normal,
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.54,
        ),
        child: SingleChildScrollView(child: content),
      ),
      actions: actions,
    );
  }
}

@visibleForTesting
class MediaItemCoverOverrideField extends StatelessWidget {
  const MediaItemCoverOverrideField({
    required this.imageProvider,
    required this.onPickImage,
    required this.onUndo,
    super.key,
  });

  final ImageProvider imageProvider;
  final Future<void> Function()? onPickImage;
  final Future<void> Function()? onUndo;

  @override
  Widget build(BuildContext context) {
    return HibikiTextField(
      readOnly: true,
      style: const TextStyle(color: Colors.transparent),
      contentPadding: EdgeInsets.zero,
      suffixIcon: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: 56,
          maxHeight: 64,
          minWidth: 144,
          maxWidth: 180,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Padding(
                padding: Spacing.of(context).insets.all.small,
                child: Image(
                  image: imageProvider,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            HibikiIconButton(
              tooltip: t.pick_image,
              isWideTapArea: true,
              icon: Icons.file_upload_outlined,
              onTap: onPickImage,
            ),
            HibikiIconButton(
              tooltip: t.undo,
              isWideTapArea: true,
              icon: Icons.undo_outlined,
              onTap: onUndo,
            ),
          ],
        ),
      ),
    );
  }
}
