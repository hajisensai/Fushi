import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// Restart-safe, non-sensitive descriptor stored in
/// [EpubBookRow.sourceMetadata] for a Mihon-backed shelf entry.
class MihonLibraryEntry {
  const MihonLibraryEntry({
    required this.extensionPackage,
    required this.sourceId,
    required this.manga,
    required this.chapters,
    this.currentChapterIndex,
  });

  static const String marker = 'hibiki-mihon';
  static const int version = 1;

  final String extensionPackage;
  final String sourceId;
  final MihonManga manga;
  final List<MihonChapter> chapters;
  final int? currentChapterIndex;

  MihonChapter? get currentChapter {
    final int? index = currentChapterIndex;
    if (index == null || index < 0 || index >= chapters.length) return null;
    return chapters[index];
  }

  MihonLibraryEntry copyWith({
    MihonManga? manga,
    List<MihonChapter>? chapters,
    int? currentChapterIndex,
    bool keepCurrentChapter = true,
  }) =>
      MihonLibraryEntry(
        extensionPackage: extensionPackage,
        sourceId: sourceId,
        manga: manga ?? this.manga,
        chapters: chapters ?? this.chapters,
        currentChapterIndex: keepCurrentChapter
            ? currentChapterIndex ?? this.currentChapterIndex
            : null,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'type': marker,
        'version': version,
        'extensionPackage': extensionPackage,
        // sourceId stays a string: Mihon IDs may exceed JavaScript's exact
        // integer range.
        'sourceId': sourceId,
        'manga': manga.toJson(),
        'chapters': <Map<String, Object?>>[
          for (final MihonChapter chapter in chapters) chapter.toJson(),
        ],
        'currentChapterIndex': currentChapterIndex,
      };

  String encode() => jsonEncode(toJson());

  static MihonLibraryEntry? tryParse(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(value);
      if (decoded is! Map<Object?, Object?> ||
          decoded['type'] != marker ||
          (decoded['version'] as num?)?.toInt() != version) {
        return null;
      }
      final Object? rawManga = decoded['manga'];
      final Object? rawChapters = decoded['chapters'];
      if (rawManga is! Map<Object?, Object?> || rawChapters is! List<Object?>) {
        return null;
      }
      return MihonLibraryEntry(
        extensionPackage: decoded['extensionPackage']?.toString() ?? '',
        sourceId: decoded['sourceId']?.toString() ?? '',
        manga: MihonManga.fromJson(rawManga.cast<String, Object?>()),
        chapters: rawChapters
            .whereType<Map<Object?, Object?>>()
            .map(
              (Map<Object?, Object?> value) =>
                  MihonChapter.fromJson(value.cast<String, Object?>()),
            )
            .toList(growable: false),
        currentChapterIndex: (decoded['currentChapterIndex'] as num?)?.toInt(),
      );
    } on Object {
      return null;
    }
  }
}

class MihonLibraryService {
  const MihonLibraryService(this.manager);

  final MihonManager manager;

  static String bookKeyFor(
    MihonSourceContext context,
    MihonManga manga,
  ) {
    final String identity = <String>[
      context.extension.packageName,
      context.source.id,
      manga.url,
    ].join('\u0000');
    final String digest = sha256.convert(utf8.encode(identity)).toString();
    return 'mihon-${digest.substring(0, 32)}';
  }

  Future<EpubBookRow?> find(
    MihonSourceContext context,
    MihonManga manga,
  ) =>
      manager.database.getEpubBook(bookKeyFor(context, manga));

  Future<EpubBookRow> add({
    required MihonSourceContext context,
    required MihonManga manga,
    required List<MihonChapter> chapters,
  }) async {
    final String bookKey = bookKeyFor(context, manga);
    final EpubBookRow? existing = await manager.database.getEpubBook(bookKey);
    if (existing != null) {
      await refresh(
        bookKey: bookKey,
        existing: MihonLibraryEntry.tryParse(existing.sourceMetadata),
        manga: manga,
        chapters: chapters,
      );
      return (await manager.database.getEpubBook(bookKey))!;
    }

    final Directory directory =
        Directory(p.join(manager.rootDirectory.path, 'library', bookKey));
    await Directory(p.join(directory.path, 'chapters')).create(recursive: true);
    final File placeholder = File(p.join(directory.path, 'manga.json'));
    await _writeAtomic(placeholder, '{"pages":[]}');

    String? coverPath;
    final String? coverUrl = manga.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      try {
        final List<int> bytes = await manager.runtime.fetchSourceImage(
          context.extension,
          context.source,
          coverUrl,
          preferences: context.preferences,
        );
        final String extension = _imageExtension(bytes);
        final File cover = File(p.join(directory.path, 'cover$extension'));
        await cover.writeAsBytes(bytes, flush: true);
        coverPath = p.basename(cover.path);
      } on Object {
        // A cover failure must not prevent following the manga. The source is
        // still queried through its authenticated runtime on the detail page.
      }
    }

    final MihonLibraryEntry entry = MihonLibraryEntry(
      extensionPackage: context.extension.packageName,
      sourceId: context.source.id,
      manga: manga,
      chapters: List<MihonChapter>.unmodifiable(chapters),
    );
    await manager.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: manga.title,
        author: Value<String?>(manga.author ?? manga.artist),
        coverPath: Value<String?>(coverPath),
        epubPath: p.basename(placeholder.path),
        extractDir: directory.path,
        chapterCount: chapters.length,
        chaptersJson: jsonEncode(
          <Map<String, Object?>>[
            for (final MihonChapter chapter in chapters) chapter.toJson(),
          ],
        ),
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    return (await manager.database.getEpubBook(bookKey))!;
  }

  Future<void> refresh({
    required String bookKey,
    required MihonLibraryEntry? existing,
    required MihonManga manga,
    required List<MihonChapter> chapters,
  }) async {
    if (existing == null) return;
    int? nextIndex;
    final MihonChapter? selected = existing.currentChapter;
    if (selected != null) {
      final int found =
          chapters.indexWhere((MihonChapter item) => item.url == selected.url);
      if (found >= 0) nextIndex = found;
    }
    final MihonLibraryEntry updated = MihonLibraryEntry(
      extensionPackage: existing.extensionPackage,
      sourceId: existing.sourceId,
      manga: manga,
      chapters: List<MihonChapter>.unmodifiable(chapters),
      currentChapterIndex: nextIndex,
    );
    await manager.database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: chapters.length,
      chaptersJson: jsonEncode(
        <Map<String, Object?>>[
          for (final MihonChapter chapter in chapters) chapter.toJson(),
        ],
      ),
    );
  }

  Future<MihonLibraryEntry> selectChapter({
    required String bookKey,
    required MihonLibraryEntry entry,
    required int chapterIndex,
  }) async {
    if (chapterIndex < 0 || chapterIndex >= entry.chapters.length) {
      throw RangeError.index(chapterIndex, entry.chapters, 'chapterIndex');
    }
    final MihonLibraryEntry updated = MihonLibraryEntry(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
      manga: entry.manga,
      chapters: entry.chapters,
      currentChapterIndex: chapterIndex,
    );
    await manager.database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: updated.chapters.length,
      chaptersJson: jsonEncode(
        <Map<String, Object?>>[
          for (final MihonChapter chapter in updated.chapters) chapter.toJson(),
        ],
      ),
    );
    // v82：位置键 = 书 uid。此处只有 bookKey（调用方有的持行、有的只持键），
    // 统一 resolve 一次；书不在库（不应发生——上面刚更新过该行）则跳过置零，
    // 沿 resolveEpubBookUid 的 no-op 契约。
    final String? bookUid = await manager.database.resolveEpubBookUid(bookKey);
    if (bookUid != null) {
      await ReaderPositionRepository(manager.database).save(
        bookUid: bookUid,
        sectionIndex: 0,
        normCharOffset: 0,
        charOffset: 0,
      );
    }
    return updated;
  }

  Directory chapterDirectory(String bookKey, MihonChapter chapter) {
    final String digest =
        sha256.convert(utf8.encode(chapter.url)).toString().substring(0, 24);
    return Directory(
      p.join(
        manager.rootDirectory.path,
        'reader-cache',
        'chapters',
        bookKey,
        digest,
      ),
    );
  }

  static int initialChapterIndex(MihonLibraryEntry entry) {
    final int? selected = entry.currentChapterIndex;
    if (selected != null && selected >= 0 && selected < entry.chapters.length) {
      return selected;
    }
    // Mihon sources conventionally return newest first. A new reader starts
    // from the oldest available chapter.
    return entry.chapters.isEmpty ? -1 : entry.chapters.length - 1;
  }

  static Future<void> _writeAtomic(File target, String contents) async {
    await target.parent.create(recursive: true);
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  static String _imageExtension(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
      return '.webp';
    }
    if (bytes.length >= 6 && String.fromCharCodes(bytes.take(3)) == 'GIF') {
      return '.gif';
    }
    return '.jpg';
  }
}
