import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/utils.dart';

/// Resolves a Mihon chapter and hands it to Hibiki's existing manga reader.
///
/// This loading shell intentionally owns no WebView or reading UI. Online and
/// local manga therefore share OCR, dictionary/mining, spread/webtoon layout,
/// zoom, shortcuts, statistics and progress behavior.
class MihonChapterReaderPage extends StatefulWidget {
  const MihonChapterReaderPage({
    required this.manager,
    required this.context,
    required this.manga,
    required this.chapter,
    this.libraryBookKey,
    super.key,
  });

  final MihonManager manager;
  final MihonSourceContext context;
  final MihonManga manga;
  final MihonChapter chapter;
  final String? libraryBookKey;

  @override
  State<MihonChapterReaderPage> createState() => _MihonChapterReaderPageState();
}

class _MihonChapterReaderPageState extends State<MihonChapterReaderPage> {
  MihonReaderChapter? _resolved;
  Object? _error;
  late final String _onlineBookKey = OnlineMangaLibraryService.bookKeyFor(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: widget.context.extension.packageName,
    sourceId: widget.context.source.id,
    seriesKey: widget.manga.url,
  );
  late final String _readerBookKey =
      widget.libraryBookKey ?? '$_onlineBookKey-preview';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<MihonPage> pages = await widget.manager.runtime.getPages(
        widget.context.extension,
        widget.context.source,
        widget.chapter,
        preferences: widget.context.preferences,
      );
      final String? libraryBookKey = widget.libraryBookKey;
      final Directory managedDirectory =
          mihonOnlineLibraryService(widget.manager).chapterDirectory(
        libraryBookKey ?? _onlineBookKey,
        MihonLibraryAdapter.chapterOf(widget.chapter),
      );
      if (!mounted) return;
      setState(() {
        _resolved = MihonReaderChapter(
          manager: widget.manager,
          sourceContext: widget.context,
          manga: widget.manga,
          chapter: widget.chapter,
          pages: pages,
          managedDirectory: managedDirectory,
          persistProgress: libraryBookKey != null,
        );
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final MihonReaderChapter? resolved = _resolved;
    if (resolved != null) {
      return FushiAppUiScaleNeutralizer(
        child: MangaFushiPage(
          item: null,
          bookKey: _readerBookKey,
          onlineChapter: resolved,
        ),
      );
    }
    final String title = '${widget.manga.title} · ${widget.chapter.name}';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _error == null
          ? Center(child: adaptiveIndicator(context: context))
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('$_error', textAlign: TextAlign.center),
              ),
            ),
    );
  }
}
