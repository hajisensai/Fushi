import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show ReaderPosition, ReaderPositionRepository;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/epub/epub_book.dart' show EpubBook, EpubImageRef;
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/reader/illustration_zoom_viewer.dart';
import 'package:fushi/src/reader/reader_collection_volumes.dart'
    show epubImageFileFor, parseVolumeBookForPeek;
import 'package:fushi/src/reader/reader_gallery_page.dart';
import 'package:fushi/src/reader/ttu_toc_flatten.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/utils.dart';

/// 书架端「查看插图」：装载这本书的结构 / 阅读位置 / 已揭开集，然后交给阅读器
/// 内的同一份插图册 [ReaderGalleryPage]。此前书架端是另一套网格 + 翻页查看器
/// （BUG-2589 之前），同一本书两处长得不一样、横版图也各裁各的；现在这里只剩
/// 装载与接线，画廊本体只有一份。
///
/// 与阅读器内打开的差别只在数据来源：
/// - 结构在 isolate 里解析（[parseVolumeBookForPeek]，与看兄弟卷同一入口）；
/// - 阅读位置读 Drift `reader_positions`；没有位置行 = 这本一次都没打开过，
///   传 `currentChapter: null`——不按进度遮罩、不出「当前阅读位置」标记；
/// - 揭开 / 恢复遮罩直接落 `revealed_images`（与阅读器共享真相源，BUG-898）；
/// - 「跳到此插图」= 关掉本页再由调用方按章开书（[onJumpTo]）。
class IllustrationsViewerPage extends StatefulWidget {
  const IllustrationsViewerPage({
    required this.bookTitle,
    required this.extractDir,
    required this.bookUid,
    required this.database,
    required this.onJumpTo,
    super.key,
  });

  /// 装载态 / 出错态页面标题（画廊本体有自己的顶栏）。
  final String bookTitle;

  /// The book's on-disk extracted directory (`EpubBooks.extractDir`).
  final String extractDir;

  /// 书稳定身份（v82 起 = EpubBooks.uid）；图片 reveal 状态按它键控持久化。
  /// 空串 = 旧行无 uid（不应出现）——reveal 只在内存生效、不落库。
  final String bookUid;

  /// 图片 reveal 状态真相源（与阅读器 WebView 共享，实现书内↔图片库双向同步）。
  final FushiDatabase database;

  /// 「跳到此插图」：本页已 pop，调用方据此按章开书。
  final Future<void> Function(EpubImageRef ref) onJumpTo;

  @override
  State<IllustrationsViewerPage> createState() =>
      _IllustrationsViewerPageState();
}

/// 装载完成后画廊需要的全部输入。
class _GalleryInput {
  const _GalleryInput({
    required this.book,
    required this.position,
    required this.revealed,
    required this.toc,
  });

  final EpubBook book;
  final ReaderPosition? position;
  final Set<String> revealed;
  final List<TtuTocEntry> toc;
}

class _IllustrationsViewerPageState extends State<IllustrationsViewerPage> {
  _GalleryInput? _input;
  String? _error;

  /// 防剧透遮罩总开关：与阅读器同一偏好（`ttu_blur_images`）。
  bool get _blurEnabled =>
      ReaderFushiSource.readerSettings?.blurImages ?? false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!Directory(widget.extractDir).existsSync()) {
      setState(() => _error = t.book_directory_not_found);
      return;
    }
    try {
      // 结构解析（isolate）与两次 Drift 读互不依赖，并行起跑。
      final Future<EpubBook> bookFuture =
          compute(parseVolumeBookForPeek, widget.extractDir);
      final Future<ReaderPosition?> positionFuture = widget.bookUid.isEmpty
          ? Future<ReaderPosition?>.value(null)
          : ReaderPositionRepository(widget.database)
              .findByBookUid(widget.bookUid);
      final Future<Set<String>> revealedFuture = widget.bookUid.isEmpty
          ? Future<Set<String>>.value(<String>{})
          : widget.database.getRevealedImageKeys(widget.bookUid);
      final EpubBook book = await bookFuture;
      final ReaderPosition? position = await positionFuture;
      final Set<String> revealed = await revealedFuture;
      if (!mounted) return;
      setState(() {
        _input = _GalleryInput(
          book: book,
          position: position,
          revealed: revealed,
          toc: flattenTtuTocEntries(book.toc, book.chapterIndexForHref),
        );
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('IllustrationsViewer.load', e, stack);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 节头章名：与阅读器顶栏同一口径（[resolveCurrentTocEntry] 取不晚于该章的
  /// 最后一条目录项）；目录里没有就交给画廊退到「第 N 章」。
  String? _chapterLabelFor(_GalleryInput input, int chapterIndex) {
    final int? entry = resolveCurrentTocEntry(input.toc, chapterIndex, null);
    return entry == null ? null : input.toc[entry].label;
  }

  Future<void> _reveal(String key) async {
    if (widget.bookUid.isEmpty) return; // 无 uid 只留内存态，不落孤儿行。
    try {
      await widget.database.markImageRevealed(
          widget.bookUid, key, DateTime.now().millisecondsSinceEpoch);
    } catch (e, stack) {
      ErrorLogService.instance.log('IllustrationsViewer.reveal', e, stack);
    }
  }

  Future<void> _unreveal(String key) async {
    if (widget.bookUid.isEmpty) return;
    try {
      await widget.database.unmarkImageRevealed(widget.bookUid, key);
    } catch (e, stack) {
      ErrorLogService.instance.log('IllustrationsViewer.unreveal', e, stack);
    }
  }

  File? _fileFor(EpubImageRef ref) => epubImageFileFor(widget.extractDir, ref);

  /// 与阅读器正文 / 阅读器插图册同一条缩放路径；Windows 右键复制、移动端长按
  /// 分享（TODO-093 / BUG-177 的两个入口）。
  void _openZoom(EpubImageRef ref) {
    final File? file = _fileFor(ref);
    if (file == null) return;
    Navigator.push(
      context,
      illustrationZoomRoute(
        context,
        (BuildContext routeContext) => ContextMenuTrigger(
          onInvoke: isWindowsPlatform
              ? (Offset position) => unawaited(showImageCopyContextMenu(
                    routeContext,
                    position,
                    onCopy: () => copyImageFileToClipboard(file),
                  ))
              : null,
          child: IllustrationZoomViewer(
            file: file,
            diagnosticTag: 'IllustrationsViewer.zoom',
            onLongPress: isWindowsPlatform
                ? null
                : () => unawaited(shareImageFile(file)),
          ),
        ),
      ),
    );
  }

  void _jumpTo(EpubImageRef ref) {
    Navigator.of(context).pop();
    unawaited(widget.onJumpTo(ref));
  }

  @override
  Widget build(BuildContext context) {
    final _GalleryInput? input = _input;
    if (input == null) return _buildPending(context);
    final ReaderPosition? position = input.position;
    return ReaderGalleryPage(
      images: input.book.images,
      // 没有位置行 = 从没打开过：不按进度遮罩、不出当前位置标记。
      currentChapter: position?.sectionIndex,
      currentNormCharOffset: position?.normCharOffset ?? 0,
      blurImages: _blurEnabled,
      revealedImageKeys: input.revealed,
      onRevealImage: (String key) => unawaited(_reveal(key)),
      onUnrevealImage: (String key) => unawaited(_unreveal(key)),
      chapterLabelFor: (int chapterIndex) =>
          _chapterLabelFor(input, chapterIndex) ??
          t.auto_chapter(n: chapterIndex + 1),
      fileForRef: _fileFor,
      onOpenImage: _openZoom,
      onJumpTo: _jumpTo,
    );
  }

  /// 装载中 / 出错：带返回键的普通页面壳。
  Widget _buildPending(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? error = _error;
    return FushiPageScaffold(
      title: widget.bookTitle,
      body: Center(
        child: error != null
            ? Padding(
                padding:
                    EdgeInsets.all(tokens.spacing.page + tokens.spacing.card),
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  adaptiveIndicator(context: context),
                  SizedBox(height: tokens.spacing.card),
                  Text(t.loading_illustrations),
                ],
              ),
      ),
    );
  }
}
