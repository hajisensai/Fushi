import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
  // BUG-220: author editing, only shown when the source supports it (EPUB).
  final TextEditingController _authorController = TextEditingController();

  bool get _supportsAuthorEdit => mediaSource.supportsAuthorEdit;

  @override
  void dispose() {
    _nameOverrideController.dispose();
    _authorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_defaultImageProvider == null) {
      String? overrideTitle =
          mediaSource.getOverrideTitleFromMediaItem(widget.item);
      String title = overrideTitle ?? widget.item.title;
      _nameOverrideController.text = title;
      _authorController.text = widget.item.author ?? '';

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
          if (_supportsAuthorEdit) ...<Widget>[
            const SizedBox(height: 8),
            HibikiTextField(
              controller: _authorController,
              labelText: t.book_edit_author,
              hintText: t.book_edit_author,
              maxLines: 1,
              suffixIcon: HibikiIconButton(
                tooltip: t.undo,
                isWideTapArea: true,
                icon: Icons.undo_outlined,
                onTap: () async {
                  _authorController.text = widget.item.author ?? '';
                  FocusScope.of(context).unfocus();
                },
              ),
            ),
          ],
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

      // BUG-220: persist the edited author (e.g. epubBooks.author). No-op for
      // sources that do not support author editing.
      if (_supportsAuthorEdit) {
        await mediaSource.setAuthorFromMediaItem(
          item: widget.item,
          author: _authorController.text,
        );
      }

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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.72,
      scrollable: false,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      child: HibikiModalSheetFrame(
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: content,
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiCard(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.gap,
      ),
      color: tokens.surfaces.search,
      borderColor: tokens.surfaces.outline,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: tokens.spacing.gap * 7,
          maxHeight: tokens.spacing.gap * 8,
        ),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ClipRRect(
                  borderRadius: tokens.radii.chipRadius,
                  child: Image(
                    height: tokens.spacing.gap * 6,
                    width: tokens.spacing.gap * 6,
                    image: imageProvider,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            HibikiIconButton(
              tooltip: t.pick_image,
              isWideTapArea: true,
              icon: Icons.file_upload_outlined,
              onTap: onPickImage,
            ),
            SizedBox(width: tokens.spacing.gap / 2),
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
