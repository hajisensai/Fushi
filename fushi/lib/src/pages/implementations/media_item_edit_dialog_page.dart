import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show ItemScrapeMetaRow;
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_media_source.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart'
    show itemScrapeKeyForBook;
import 'package:fushi_engine/media/collections/book_series_key.dart'
    show parseBookSeriesKey;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// The content of the dialog upon selecting 'Edit' in the
/// [MediaItemDialogPage].
class MediaItemEditDialogPage extends BasePage {
  /// Create an instance of this page.
  const MediaItemEditDialogPage({required this.item, super.key});

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

  /// 书的刮削层（「已获取的每卷封面」）来源；null = 没有 / 不是书。
  BookArtRecord? _scrapedRecord;

  /// 用户点了「移除已获取的封面」，保存时落地。
  bool _removeScrapedArt = false;

  String? get _bookKey => mediaSource is ReaderMediaSource
      ? ReaderFushiSource.parseBookKey(widget.item.mediaIdentifier)
      : null;

  BookArtStore get _artStore => BookArtStore.of(appModel.thumbnailsDirectory);

  final TextEditingController _nameOverrideController = TextEditingController();
  // BUG-220: author editing, only shown when the source supports it (EPUB).
  final TextEditingController _authorController = TextEditingController();

  bool get _supportsAuthorEdit => mediaSource.supportsAuthorEdit;

  /// 书族条目（EPUB / 漫画 / PDF / 字幕书）在 `item_scrape_meta` 里的身份；
  /// null = 还没读完 / 不是书（视频、游戏不显示简介框）。BUG-5111：刮不到资料
  /// 的书也能手填简介，手填即上锁，之后条目刮削不覆盖。
  ItemScrapeKey? _scrapeKey;

  /// 打开弹窗时库里的简介（判「改没改」；没改就不写，免得给刮来的简介凭空上锁）。
  String _initialSummary = '';
  final TextEditingController _summaryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    // initState 里调用：不能 ref.watch，读缓存的 AppModel。
    final ItemScrapeKey? key = await itemScrapeKeyForBook(
      appModelNoUpdate.database,
      widget.item,
    );
    if (key == null) return;
    final ItemScrapeMetaRow? row = await appModelNoUpdate.database
        .getItemScrapeMeta(key.mediaType, key.entryKey);
    if (!mounted) return;
    setState(() {
      _scrapeKey = key;
      _initialSummary = row?.summary ?? '';
      _summaryController.text = _initialSummary;
    });
  }

  @override
  void dispose() {
    _nameOverrideController.dispose();
    _authorController.dispose();
    _summaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_defaultImageProvider == null) {
      String? overrideTitle = mediaSource.getOverrideTitleFromMediaItem(
        widget.item,
      );
      String title = overrideTitle ?? widget.item.title;
      _nameOverrideController.text = title;
      _authorController.text = widget.item.author ?? '';

      final String? bookKey = _bookKey;
      // 有卷封面、或只有横幅（本地更清晰时只写了横幅）都显示来源 / 署名与移除。
      _scrapedRecord = bookKey == null
          ? null
          : _artStore.displayableRecordFor(bookKey);
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

    return MediaItemEditDialogFrame(content: buildContent(), actions: actions);
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
          FushiTextField(
            controller: _nameOverrideController,
            maxLines: null,
            suffixIcon: FushiIconButton(
              tooltip: t.undo,
              isWideTapArea: true,
              icon: FushiIcons.undo,
              onTap: () async {
                _nameOverrideController.text = widget.item.title;
                FocusScope.of(context).unfocus();
              },
            ),
          ),
          if (_supportsAuthorEdit) ...<Widget>[
            const SizedBox(height: 8),
            FushiTextField(
              controller: _authorController,
              labelText: t.book_edit_author,
              hintText: t.book_edit_author,
              maxLines: 1,
              suffixIcon: FushiIconButton(
                tooltip: t.undo,
                isWideTapArea: true,
                icon: FushiIcons.undo,
                onTap: () async {
                  _authorController.text = widget.item.author ?? '';
                  FocusScope.of(context).unfocus();
                },
              ),
            ),
          ],
          if (_scrapeKey != null) ...<Widget>[
            const SizedBox(height: 8),
            FushiTextField(
              key: const ValueKey<String>('book_edit_summary_field'),
              controller: _summaryController,
              labelText: t.book_edit_summary,
              helperText: t.book_edit_summary_helper,
              keyboardType: TextInputType.multiline,
              minLines: 2,
              maxLines: 6,
              suffixIcon: FushiIconButton(
                tooltip: t.undo,
                isWideTapArea: true,
                icon: FushiIcons.undo,
                onTap: () async {
                  _summaryController.text = _initialSummary;
                  FocusScope.of(context).unfocus();
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
          MediaItemCoverOverrideField(
            imageProvider: _coverImageProvider ?? _defaultImageProvider!,
            // 「在线服务」模块关掉时传 null —— [MediaItemCoverOverrideField] 已有
            // 「onScrape 为空就不渲染刮削按钮」的契约（书/视频/游戏三库共用本弹窗，
            // 一处接线三处生效）。手动选图 / 撤销不受影响：那是本地操作。
            onScrape: !appModel.moduleVisibility.isEnabled(ModuleId.services)
                ? null
                : () async {
                    // 在线刮削封面（P1b）：搜 Bangumi 书籍条目，选中即下载封面成临时文件，
                    // 走与手动选图完全相同的 override 通道（保存时 setOverrideThumbnail）。
                    final String query =
                        _nameOverrideController.text.trim().isNotEmpty
                        ? _nameOverrideController.text.trim()
                        : widget.item.title;
                    // 编辑弹窗只取封面（保存才落地，取消不留副作用）；条目资料
                    // 走书架卡菜单的「在线刮削封面」（选中即写回）。弹窗里点
                    // 「标为 NSFW」是用户明确的另一个动作，即时落库。
                    final File? scraped =
                        (await showBookCoverScrapeDialogForItem(
                          context: context,
                          db: appModel.database,
                          item: widget.item,
                          initialQuery: query,
                          volume: parseBookSeriesKey(widget.item.title)?.volume,
                          rakuten: appModel.bookScrapeRakutenCredentials,
                        ))?.cover;
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
          if (_scrapedRecord != null && !_removeScrapedArt)
            _ScrapedArtRow(
              record: _scrapedRecord!,
              onRemove: () {
                // 刮削层挂错时单本也能撤掉（不只合集级「清除」）；保存时落地。
                _removeScrapedArt = true;
                _defaultImageProvider = mediaSource
                    .getDisplayThumbnailFromMediaItem(
                      appModel: appModel,
                      item: widget.item,
                      noOverride: true,
                      noScraped: true,
                    );
                if (_newFile == null && !_hasOverride) {
                  _coverImageProvider = null;
                }
                setState(() {});
              },
            ),
        ],
      ),
    );
  }

  bool get _hasOverride =>
      !_clearOverrideImage &&
      mediaSource.resolveOverrideThumbnailFile(
            appModel: appModel,
            item: widget.item,
          ) !=
          null;

  List<Widget> get actions => [buildCancelButton(), buildSaveButton()];

  Widget buildCancelButton() {
    return FushiDialogAction(label: t.dialog_cancel, onPressed: executeCancel);
  }

  Widget buildSaveButton() {
    return FushiDialogAction(
      label: t.dialog_save,
      kind: FushiDialogActionKind.primary,
      onPressed: executeSave,
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

      final String? bookKey = _bookKey;
      if (_removeScrapedArt && bookKey != null) {
        // 单本移除 = 这张贴错了：记为否决，之后合集重刮不会把同一张写回来。
        await _artStore.rejectCover(bookKey);
      }

      // BUG-220: persist the edited author (e.g. epubBooks.author). No-op for
      // sources that do not support author editing.
      if (_supportsAuthorEdit) {
        await mediaSource.setAuthorFromMediaItem(
          item: widget.item,
          author: _authorController.text,
        );
      }

      // BUG-5111：简介改过才写（手填 = 上锁，清空 = 解锁交还刮削）。
      final ItemScrapeKey? scrapeKey = _scrapeKey;
      if (scrapeKey != null &&
          _summaryController.text.trim() != _initialSummary.trim()) {
        await ItemScrapeStore(appModel.database).setManualFields(
          scrapeKey,
          <ItemScrapeLockableField, String?>{
            ItemScrapeLockableField.summary: _summaryController.text,
          },
        );
      }

      // BUG-1018 (A2): the shelf's reactive source (_epubBookKeysProvider)
      // dedupes by key set, so a pure column update like the author write above
      // never re-fires it — refreshTab() alone re-renders stale cached
      // MediaItems and the edit looks like it "did not save". Invalidate the
      // book providers so the shelf re-reads the DB rows.
      // 覆盖全部书族源（EPUB / 漫画 / PDF 都 extends ReaderMediaSource）：漫画作者编辑
      // （MangaFushiSource，非 ReaderFushiSource）此前落在此条件外，改完书架不刷新。
      if (mediaSource is ReaderMediaSource) {
        ref.invalidate(fushiBooksProvider);
        ref.invalidate(srtBooksProvider);
      }

      navigator.pop();
      navigator.pop();
      mediaSource.mediaType.refreshTab();
    }
  }
}

/// 刮削层来源行：「封面取自 X」+ MangaBaka 署名（CC BY-NC-SA 要求可见）+ 移除按钮。
class _ScrapedArtRow extends StatelessWidget {
  const _ScrapedArtRow({required this.record, required this.onRemove});

  final BookArtRecord record;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    final String source = switch (record.coverSource ?? record.source) {
      'mangabaka' => 'MangaBaka',
      'bangumi' => 'Bangumi',
      final String? other => other ?? '',
    };
    return Padding(
      key: const ValueKey<String>('book_edit_scraped_art_row'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t.book_art_scraped_cover_from(source: source),
                  style: small,
                ),
                if (record.usesMangaBaka)
                  Text(t.book_scrape_mangabaka_attribution, style: small),
              ],
            ),
          ),
          FushiTextButton(
            key: const ValueKey<String>('book_edit_remove_scraped_art'),
            onPressed: onRemove,
            child: Text(t.book_art_remove_scraped),
          ),
        ],
      ),
    );
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.72,
      scrollable: false,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      child: FushiModalSheetFrame(
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.gap,
      ),
      // Apple：对话框里的内嵌块是无描边的系统灰填充（tertiaryFill），不画
      // 描边方框；MD3 维持 search 底 + outline 描边。
      color: isGlassDesign(context)
          ? appleColorsOf(context).tertiaryFill
          : tokens.surfaces.search,
      borderColor: isGlassDesign(context) ? null : tokens.surfaces.outline,
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
                    // BUG-2496：坏封面文件解码失败退回占位图标，不当致命错误。
                    // FileImage.toString() 自带路径，直接记 provider 就有 path。
                    errorBuilder: (_, Object error, __) {
                      ErrorLogService.instance.logDiagnostic(
                        'MediaItemCoverOverrideField.coverDecode',
                        '$imageProvider: $error',
                      );
                      return SizedBox(
                        height: tokens.spacing.gap * 6,
                        width: tokens.spacing.gap * 6,
                        child: const FushiIcon(FushiIcons.brokenImage),
                      );
                    },
                  ),
                ),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            if (onScrape != null) ...<Widget>[
              FushiIconButton(
                tooltip: t.book_scrape_cover,
                isWideTapArea: true,
                icon: FushiIcons.imageSearch,
                onTap: onScrape,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
            ],
            FushiIconButton(
              tooltip: t.pick_image,
              isWideTapArea: true,
              icon: FushiIcons.upload,
              onTap: onPickImage,
            ),
            SizedBox(width: tokens.spacing.gap / 2),
            FushiIconButton(
              tooltip: t.undo,
              isWideTapArea: true,
              icon: FushiIcons.undo,
              onTap: onUndo,
            ),
          ],
        ),
      ),
    );
  }
}
