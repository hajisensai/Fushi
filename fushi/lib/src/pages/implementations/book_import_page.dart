import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show kDragAudioExtensions, kDragBookExtensions, kDragSubtitleExtensions;
import 'package:fushi/src/media/drag_drop/reader_shelf_drop_router.dart';
import 'package:fushi/src/media/import/import_collage_page.dart';
import 'package:fushi/src/media/import/import_inbox.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/media/import/pasted_text_book_dialog.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart' show MediaItemAppLookup;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart'
    show openMediaServerSettings;
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 书库「导入」视图（导入稿 v2「2. 书」）：引导首块 + 五种方式块 + 常驻来源色块。
///
/// 方式按规范顺序声明：导入书（主方式）→ 导入文件夹 → 粘贴文本 → 有声书（IM15）
/// → 网络共享（IM1：旧快速导入区把书的顺序重排反了）。来源区是 [MediaSourcesView]
/// 的色块呈现，末尾带「连接服务器 ›」块（IM17：没配服务器时库页上找不到 Kavita /
/// Audiobookshelf / OPDS 的入口）。
///
/// 整页是拖放落点（IM2）：此前导入视图画着拖放虚线，祖先链上却没有
/// `FushiFileDropTarget`，而书架的落点被壳的 `DropSurfaceScope` 关在隐藏视图里，
/// 拖进来什么都不发生。现在落下交给与书架同一份 [routeReaderShelfDrop]。
class BookImportPage extends ConsumerStatefulWidget {
  const BookImportPage({super.key, this.navigation, this.onLibraryChanged});

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  /// 来源扫描 / 导入完成后通知保活的媒体库重读合集、排序和封面。
  final VoidCallback? onLibraryChanged;

  @override
  ConsumerState<BookImportPage> createState() => _BookImportPageState();
}

class _BookImportPageState extends ConsumerState<BookImportPage> {
  final GlobalKey<MediaSourcesViewState> _viewKey =
      GlobalKey<MediaSourcesViewState>();

  /// BUG-513 同款纪律：AppModel 在 initState 捕获，async gap 之后不再 `ref.read`。
  late final AppModel _appModel = ref.read(appProvider);

  /// 书架 provider 失效（导入落库后书架立即刷新）。
  void _invalidateBookProviders() {
    if (!mounted) return;
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(srtBooksProvider);
    widget.onLibraryChanged?.call();
  }

  /// 单本书导入（EPUB / PDF / 文本 / 字幕书，可附带音频）。[pickAudioFirst] 是
  /// 「有声书」方式块的起点：同一个对话框，打开就先选音频（IM15）。
  Future<void> _importBook({bool pickAudioFirst = false}) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        prefs: _appModel.prefsRepo,
        repo: SrtBookRepository(_appModel.database),
        audiobookRepo: AudiobookRepository(_appModel.database),
        db: _appModel.database,
        pickAudioFirst: pickAudioFirst,
      ),
    );
    if (imported == true) _invalidateBookProviders();
  }

  /// 「导入文件夹」：二选一（设为常驻来源 / 仅导入这一次），对话框与分发在
  /// [MediaSourcesViewState.importFolder]。
  Future<void> _importFolder() async {
    await _viewKey.currentState?.importFolder();
    _invalidateBookProviders();
  }

  /// 「从『文件』App 导入」：收 `我的 iPhone › Fushi › 书子目录` 里的文件（重入保护在
  /// [MediaSourcesViewState.importFromInbox] 入口）。
  Future<void> _importFromInbox() async {
    await _viewKey.currentState?.importFromInbox();
    _invalidateBookProviders();
  }

  /// 「粘贴文本」：落成书库里的一本书后直接打开阅读器（反馈 f2k9m1oU0j）。
  Future<void> _readPastedText() async {
    final String? bookKey = await showAppDialog<String>(
      context: context,
      builder: (_) => PastedTextBookDialog(db: _appModel.database),
    );
    if (bookKey == null || !mounted) return;
    _invalidateBookProviders();
    final MediaItem? item = await ReaderFushiSource.instance
        .mediaItemForBookKey(bookKey);
    if (item == null || !mounted) return;
    await _appModel.openMedia(
      ref: ref,
      mediaSource: item.getMediaSource(appModel: _appModel),
      item: item,
      waitUntilClosed: false,
    );
  }

  /// 「网络共享」：直接打开网络来源表单（不再先过「本地 / 网络」二选一）。
  Future<void> _addNetworkSource() async {
    await _viewKey.currentState?.addNetworkSource();
  }

  /// 整页落点：与书架同一份分发（IM2），导入视图没有书卡可命中。
  Future<void> _handleDrop(List<String> paths, Offset globalPosition) =>
      routeReaderShelfDrop(
        context: context,
        appModel: _appModel,
        mangaOnly: false,
        paths: paths,
        globalPosition: globalPosition,
        onLibraryChanged: _invalidateBookProviders,
        debugLabel: 'import-book',
      );

  ImportSurfaceSpec _buildSpec() {
    return ImportSurfaceSpec(
      id: 'book',
      tone: ImportTone.coral,
      guideIcon: FushiIcons.books,
      guideTitle: t.import_guide_book_title,
      guideDescription: t.import_guide_book_desc,
      guideDescriptionWithoutDrop: t.import_guide_book_desc_no_drop,
      methods: <ImportMethod>[
        ImportMethod(
          id: 'book-file',
          kind: ImportMethodKind.primary,
          icon: FushiIcons.importFile,
          label: t.srt_import,
          description: t.import_method_book_desc,
          destination: ImportDestination.dialog,
          onTap: _importBook,
        ),
        ImportMethod(
          id: 'book-folder',
          kind: ImportMethodKind.folder,
          icon: FushiIcons.folder,
          label: t.media_import_folder,
          description: t.import_method_folder_desc,
          destination: ImportDestination.choice,
          onTap: _importFolder,
        ),
        // iOS「文件」App 收件箱（拍板台 nLXhu0d7gV）：其它平台没有收件箱，不放空壳入口。
        if (ImportInbox.isSupported)
          ImportMethod(
            id: 'book-inbox',
            kind: ImportMethodKind.folder,
            icon: FushiIcons.folderOpen,
            label: t.media_import_inbox,
            description: t.media_import_inbox_hint(
              folder: ImportInbox.folderNameFor('book') ?? '',
            ),
            destination: ImportDestination.dialog,
            enabled: _viewKey.currentState?.isBusy != true,
            onTap: _importFromInbox,
          ),
        ImportMethod(
          id: 'book-paste-text',
          kind: ImportMethodKind.pasteText,
          icon: FushiIcons.paste,
          label: t.book_paste_text_action,
          description: t.import_method_paste_text_desc,
          destination: ImportDestination.read,
          onTap: _readPastedText,
        ),
        ImportMethod(
          id: 'book-audiobook',
          kind: ImportMethodKind.audiobook,
          icon: FushiIcons.audio,
          label: t.import_method_audiobook,
          description: t.import_method_audiobook_desc,
          destination: ImportDestination.dialog,
          onTap: () => _importBook(pickAudioFirst: true),
        ),
        ImportMethod(
          id: 'book-network',
          kind: ImportMethodKind.network,
          icon: FushiIcons.cloud,
          label: t.media_source_add_network,
          description: importNetworkTransportsSummary('book'),
          destination: ImportDestination.source,
          onTap: _addNetworkSource,
        ),
      ],
      formatGroups: <ImportFormatGroup>[
        ImportFormatGroup(
          title: t.import_format_group_books,
          labels: importFormatLabels(<Iterable<String>>[kDragBookExtensions]),
        ),
        ImportFormatGroup(
          title: t.import_format_group_subtitles,
          labels: importFormatLabels(<Iterable<String>>[
            kDragSubtitleExtensions,
          ]),
        ),
        ImportFormatGroup(
          title: t.import_format_group_audio,
          labels: importFormatLabels(<Iterable<String>>[kDragAudioExtensions]),
        ),
      ],
      onDrop: _handleDrop,
    );
  }

  Widget _buildHeader() {
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(
        title: navigation,
        actions: const <Widget>[],
      );
    }
    return FushiPageHeader(
      title: t.media_source_manage_title,
      actions: const <Widget>[],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ImportSurfaceSpec spec = _buildSpec();
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          Expanded(
            child: ImportCollagePage(
              spec: spec,
              onAddSource: () => unawaited(_viewKey.currentState?.addSource()),
              addSourceEnabled: _viewKey.currentState?.isBusy != true,
              sources: MediaSourcesView(
                key: _viewKey,
                mediaKind: 'book',
                presentation: MediaSourcesPresentation.blocks,
                entranceIndexOffset: spec.sourceEntranceIndex,
                onConnectServer: () => openMediaServerSettings(context),
                connectServerHint: 'Kavita · Audiobookshelf · OPDS',
                onLibraryChanged: widget.onLibraryChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
