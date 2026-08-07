import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:fushi/utils.dart';

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
            onScrape: () async {
              // 在线刮削封面（P1b）：搜 Bangumi 书籍条目，选中即下载封面成临时文件，
              // 走与手动选图完全相同的 override 通道（保存时 setOverrideThumbnail）。
              final String query =
                  _nameOverrideController.text.trim().isNotEmpty
                      ? _nameOverrideController.text.trim()
                      : widget.item.title;
              final File? scraped = await showBookCoverScrapeDialog(
                context: context,
                initialQuery: query,
              );
              if (scraped != null) {
                _newFile = scraped;
                _coverImageProvider = FileImage(scraped);
                _clearOverrideImage = false;
                setState(() {});
              }
            },
            onPickImage: () async {
              // BUG-1074：桌面端 image_picker 无平台实现，直接调 pickImage 抛
              // MissingPluginException 且无人捕获 → 按钮「点了没反应」。统一走
              // 封面服务的平台感知入口（移动端相册、桌面端 file_picker 文件
              // 对话框，三媒体岛同一条选图路径）。
              final File? pickedFile = await MediaCoverService.pickCoverImage();
              if (pickedFile != null) {
                _newFile = pickedFile;
                _coverImageProvider = FileImage(pickedFile);
                _clearOverrideImage = false;
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

      // 统一封面服务（P3）：薄路由到 setOverrideThumbnailFromMediaItem（存储
      // 位置/键不变），落盘后在该路径末尾统一驱逐旧解码缓存。
      await MediaCoverService.applyBookCoverOverride(
        appModel: appModel,
        mediaSource: mediaSource,
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

      // BUG-1018 (A2): the shelf's reactive source (_epubBookKeysProvider)
      // dedupes by key set, so a pure column update like the author write above
      // never re-fires it — refreshTab() alone re-renders stale cached
      // MediaItems and the edit looks like it "did not save". Invalidate the
      // book providers so the shelf re-reads the DB rows.
      // 覆盖全部书族源（EPUB / 漫画 / PDF 都 extends ReaderMediaSource）：漫画作者编辑
      // （MangaHibikiSource，非 ReaderHibikiSource）此前落在此条件外，改完书架不刷新。
      if (mediaSource is ReaderMediaSource) {
        ref.invalidate(hibikiBooksProvider);
        ref.invalidate(srtBooksProvider);
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
    this.onScrape,
    super.key,
  });

  final ImageProvider imageProvider;
  final Future<void> Function()? onPickImage;
  final Future<void> Function()? onUndo;

  /// 在线刮削封面（非空才显示刮削按钮）。书族复用视频/游戏之外的第三条封面来源。
  final Future<void> Function()? onScrape;

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
            if (onScrape != null) ...<Widget>[
              HibikiIconButton(
                tooltip: t.book_scrape_cover,
                isWideTapArea: true,
                icon: Icons.image_search_outlined,
                onTap: onScrape,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
            ],
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
