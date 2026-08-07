import 'dart:io';

import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// Fully resolved online chapter handed to the shared manga reader.
class MihonReaderChapter {
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
  final Directory managedDirectory;
  final bool persistProgress;
  final int? initialPage;
}
