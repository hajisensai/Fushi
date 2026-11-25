import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/sync/sync_resource_locks.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/sync/epub_repackage.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi_engine/sync/online_novel_book.dart';
import 'package:fushi_engine/sync/pdf_sync_package.dart';
import 'package:fushi_engine/utils/archive/native_zip.dart';
import 'package:path/path.dart' as p;

/// Repairs an existing shelf row in place. It never imports, updates, or
/// deletes a row; all of the book's reading state stays attached to its uid.
class BookContentRecovery {
  BookContentRecovery({required FushiDatabase db, required Directory tempDir})
    : _db = db,
      _tempDir = tempDir;

  final FushiDatabase _db;
  final Directory _tempDir;

  Future<List<EpubBookRow>> missingBooks() async {
    final List<EpubBookRow> books = await _db.getAllEpubBooks();
    final List<EpubBookRow> missing = await _scanMissing(books);
    if (missing.isEmpty) return missing;

    final String root = p.normalize(await EpubStorage.baseDirectory());
    final Set<String> tombstones = await _db.getBookTombstoneKeys();
    return <EpubBookRow>[
      for (final EpubBookRow book in missing)
        if (_isManagedChild(book.extractDir, root) &&
            !tombstones.contains(book.bookKey))
          book,
    ];
  }

  /// The caller must select a matching remote identity and respect that
  /// channel's deletion records. Recheck the local row after the download:
  /// a concurrent deletion, import, or relocation wins over recovery.
  Future<bool> restore(
    EpubBookRow book, {
    required Future<void> Function(File destination) download,
    void Function()? checkCanPlace,
  }) => syncResourceLocks.withResources(<String>{
    syncBookResource(book.bookKey),
  }, () => _restore(book, download: download, checkCanPlace: checkCanPlace));

  Future<bool> _restore(
    EpubBookRow book, {
    required Future<void> Function(File destination) download,
    required void Function()? checkCanPlace,
  }) async {
    if (!_needsRecovery(book)) return false;
    final String root = p.normalize(await EpubStorage.baseDirectory());
    if (!_isManagedChild(book.extractDir, root)) return false;
    checkCanPlace?.call();

    await _tempDir.create(recursive: true);
    final Directory transfer = await _tempDir.createTemp('book-recovery-');
    Directory? staging;
    try {
      final File received = File(p.join(transfer.path, 'content'));
      await download(received);
      checkCanPlace?.call();
      final String stagePath = await EpubStorage.createStagingDirectory(
        parentDir: root,
      );
      staging = Directory(stagePath);
      final String archivePath = received.path;
      await _stageInBackground(book, archivePath, stagePath);

      return await EpubStorage.withBookPlacementLock(
        () => _db.transaction(() async {
          final EpubBookRow? current = await _db.getEpubBook(book.bookKey);
          final Set<String> deleted = await _db.getBookTombstoneKeys();
          if (current == null ||
              current.uid != book.uid ||
              current.extractDir != book.extractDir ||
              current.format != book.format ||
              current.epubPath != book.epubPath ||
              current.chapterCount != book.chapterCount ||
              current.chaptersJson != book.chaptersJson ||
              deleted.contains(book.bookKey) ||
              !_needsRecovery(current)) {
            return false;
          }
          checkCanPlace?.call();
          final Directory target = Directory(p.normalize(current.extractDir));
          if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            // Sibling staging is on the same filesystem. Publish in one rename.
            Directory(stagePath).renameSync(target.path);
            return true;
          }

          // A managed folder may still contain local covers or annotation
          // sidecars. Add files only and leave every existing file untouched.
          _addMissingFiles(Directory(stagePath), target);
          return !_needsRecovery(current);
        }),
      );
    } finally {
      await _clean(staging);
      await _clean(transfer);
    }
  }

  static Future<List<EpubBookRow>> _scanMissing(List<EpubBookRow> books) =>
      Isolate.run(
        () => books.where((EpubBookRow book) {
          if (p.basename(p.dirname(p.normalize(book.extractDir))) !=
              'fushi_books') {
            return false;
          }
          try {
            return _needsRecovery(book);
          } on FileSystemException {
            // Unreadable storage is not evidence that the content is missing.
            return false;
          }
        }).toList(),
      );

  static Future<void> _stageInBackground(
    EpubBookRow book,
    String packagePath,
    String stagePath,
  ) => Isolate.run(() => _stage(book, packagePath, stagePath));

  static bool _isManagedChild(String path, String root) =>
      p.isAbsolute(path) && p.equals(p.dirname(p.normalize(path)), root);

  static bool _needsRecovery(EpubBookRow book) {
    final BookFormat? format = BookFormat.tryParse(book.format);
    if (book.extractDir.isEmpty ||
        book.bookKey.isEmpty ||
        book.uid.isEmpty ||
        book.chapterCount <= 0 ||
        format == null ||
        isLnReaderOnlineBookMetadata(book.sourceMetadata) ||
        (format == BookFormat.manga &&
            OnlineMangaLibraryEntry.tryParse(book.sourceMetadata) != null)) {
      return false;
    }

    final FileSystemEntityType type = FileSystemEntity.typeSync(
      book.extractDir,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      return false;
    }
    return switch (format) {
      BookFormat.epub => resolveExtractedEpubRoot(book.extractDir) == null,
      BookFormat.manga => !File(
        p.join(book.extractDir, kMangaPackageMarker),
      ).existsSync(),
      BookFormat.pdf =>
        _safePdfName(book.epubPath) &&
            !File(pdfBookFilePath(book)).existsSync(),
    };
  }

  static bool _safePdfName(String name) =>
      name.isNotEmpty &&
      p.basename(name) == name &&
      p.extension(name).toLowerCase() == '.pdf' &&
      !p.isAbsolute(name);

  static Future<void> _stage(
    EpubBookRow book,
    String packagePath,
    String stagePath,
  ) async {
    switch (BookFormat.parseOrEpub(book.format)) {
      case BookFormat.epub:
        final EpubBook parsed = EpubParser.parseSyncFromPath(
          packagePath,
          stagePath,
        );
        if (parsed.chapters.length != book.chapterCount ||
            (book.isbn != null && parsed.isbn != book.isbn) ||
            !_matchesChapterPaths(book.chaptersJson, parsed)) {
          throw const FormatException('EPUB does not match the existing book');
        }
      case BookFormat.manga:
        extractZipFileToDirectory(packagePath, stagePath, verifyCrc32: true);
        final MokuroPayload? payload = readExportableMangaPayload(stagePath);
        if (payload == null || payload.images.length != book.chapterCount) {
          throw const FormatException('Manga does not match the existing book');
        }
      case BookFormat.pdf:
        final File pdf = File(packagePath);
        if (!await isPdfFile(pdf)) {
          throw const FormatException('Expected a PDF book');
        }
        await pdf.copy(p.join(stagePath, book.epubPath));
    }
  }

  static bool _matchesChapterPaths(String encoded, EpubBook parsed) {
    final Object? chapters = jsonDecode(encoded);
    // Older chapter caches don't store per-chapter hrefs. Their count is
    // checked above; the caller still requires an unambiguous remote identity.
    if (chapters is! List<Object?> ||
        chapters.length != parsed.chapters.length) {
      return true;
    }
    for (final (int index, Object? entry) in chapters.indexed) {
      final Object? href = entry is Map<String, Object?> ? entry['href'] : null;
      if (href is String &&
          href.isNotEmpty &&
          p.posix.normalize(href) !=
              p.posix.normalize(parsed.chapters[index].href)) {
        return false;
      }
    }
    return true;
  }

  static void _addMissingFiles(Directory staging, Directory target) {
    final List<File> files = staging
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    // Publish the entry point after the body. A stopped sync can safely pick
    // up the same operation on its next run.
    for (final File file in files.where(
      (File f) => !_isEntryPoint(f, staging),
    )) {
      _addMissingFile(file, staging, target);
    }
    for (final File file in files.where(
      (File f) => _isEntryPoint(f, staging),
    )) {
      _addMissingFile(file, staging, target);
    }
  }

  static bool _isEntryPoint(File file, Directory staging) {
    final String relative = p.relative(file.path, from: staging.path);
    return relative == kMangaPackageMarker ||
        relative == p.join('META-INF', 'container.xml');
  }

  static void _addMissingFile(File file, Directory staging, Directory target) {
    final String relative = p.relative(file.path, from: staging.path);
    String parent = target.path;
    for (final String segment in p.split(p.dirname(relative))) {
      if (segment == '.') continue;
      parent = p.join(parent, segment);
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        parent,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        Directory(parent).createSync();
      } else if (type != FileSystemEntityType.directory) {
        throw FileSystemException('Conflicting path in book directory', parent);
      }
    }
    final String destination = p.join(target.path, relative);
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      destination,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      file.renameSync(destination);
    } else if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Conflicting path in book directory',
        destination,
      );
    }
  }

  static Future<void> _clean(Directory? directory) async {
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Temporary folders remain eligible for the ordinary import cleanup.
    }
  }
}
