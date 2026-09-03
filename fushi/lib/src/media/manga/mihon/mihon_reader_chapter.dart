import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// Runtime-neutral contract consumed by Hibiki's shared manga reader.
abstract class OnlineMangaReaderChapter {
  const OnlineMangaReaderChapter();

  Directory get managedDirectory;
  bool get persistProgress;
  int? get initialPage;
  String get title;
  String? get author;

  /// 源声明的内容语言（Mihon `source.lang` / Aidoku 单语言 manifest）；
  /// 未知或多语言源返回 null，由消费方决定回退（Lens OCR 回退用户偏好）。
  String? get sourceLanguage;
  int get pageCount;
  List<String> get pageIdentities;
  String get identityFileName;
  Future<MangaReaderSession> openPageSession();
}

/// Fully resolved online chapter handed to the shared manga reader.
class MihonReaderChapter extends OnlineMangaReaderChapter {
  const MihonReaderChapter({
    required this.manager,
    required this.sourceContext,
    required this.manga,
    required this.chapter,
    required this.pages,
    required this.managedDirectory,
    required this.persistProgress,
    this.initialPage,
  });

  final MihonManager manager;
  final MihonSourceContext sourceContext;
  final MihonManga manga;
  final MihonChapter chapter;
  final List<MihonPage> pages;
  @override
  final Directory managedDirectory;
  @override
  final bool persistProgress;
  @override
  final int? initialPage;

  @override
  String get title => manga.title;

  @override
  String? get author => manga.author ?? manga.artist;

  @override
  String? get sourceLanguage {
    final String language = sourceContext.source.language.trim();
    return language.isEmpty ? null : language;
  }

  @override
  int get pageCount => pages.length;

  @override
  List<String> get pageIdentities => <String>[
        for (final MihonPage page in pages)
          mihonPageCacheIdentity(sourceContext, page),
      ];

  @override
  String get identityFileName => '.mihon-chapter.json';

  @override
  Future<MangaReaderSession> openPageSession() => MihonMangaPageProvider(
        runtime: manager.runtime,
        context: sourceContext,
        pages: pages,
        cacheRoot: Directory(
          p.join(manager.rootDirectory.path, 'reader-cache', 'pages'),
        ),
      ).open();
}
