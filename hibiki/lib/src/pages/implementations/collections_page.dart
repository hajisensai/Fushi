import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/favorite_sentence_repository.dart';
import 'package:hibiki/src/media/audiobook/collection_audio_matcher.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/pages/base_page.dart';

enum _CollectionType { bookmark, sentence }

MediaItem buildCollectionReaderMediaItem({
  required int ttuId,
  required String title,
}) {
  return MediaItem(
    mediaIdentifier: ReaderHoshiSource.mediaIdentifierFor(ttuId),
    title: title,
    mediaTypeIdentifier: ReaderHoshiSource.instance.mediaType.uniqueKey,
    mediaSourceIdentifier: ReaderHoshiSource.instance.uniqueKey,
    position: 0,
    duration: 1,
    canDelete: false,
    canEdit: true,
  );
}

class _CollectionItem {
  _CollectionItem({
    required this.type,
    required this.createdAt,
    this.bookTitle,
    this.ttuBookId,
    this.label,
    this.text,
    this.chapterLabel,
    this.sectionIndex,
    this.normCharOffset,
    this.normCharLength,
    this.favoriteId,
  });

  final _CollectionType type;
  final DateTime createdAt;
  final String? bookTitle;
  final int? ttuBookId;
  final String? label;
  final String? text;
  final String? chapterLabel;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;
  final String? favoriteId;
}

class CollectionsPage extends BasePage {
  const CollectionsPage({super.key});

  @override
  BasePageState<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends BasePageState<CollectionsPage> {
  bool _loading = true;
  List<_CollectionItem> _items = [];
  Map<int, String> _bookTitleMap = {};
  Map<int, List<AudioCue>> _cueMap = {};
  Map<int, List<File>> _audioFileMap = {};
  bool _playingAudio = false;
  final _dateFmt = DateFormat('MM/dd HH:mm');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final db = appModel.database;
    final bookmarkRepo = BookmarkRepository(db);
    final favoriteRepo = FavoriteSentenceRepository(db);
    final srtBookRepo = SrtBookRepository(db);
    final abRepo = AudiobookRepository(db);

    final allBookmarks = await bookmarkRepo.getAllBookmarks();
    final allFavorites = await favoriteRepo.getAll();

    final srtBooks = await srtBookRepo.listAll();
    final bookTitleMap = <int, String>{};
    for (final b in srtBooks) {
      if (b.ttuBookId > 0) {
        bookTitleMap[b.ttuBookId] = b.title;
      }
    }

    final items = <_CollectionItem>[];

    for (final bm in allBookmarks) {
      items.add(_CollectionItem(
        type: _CollectionType.bookmark,
        createdAt: bm.createdAt,
        bookTitle: bm.bookTitle ?? bookTitleMap[bm.ttuBookId],
        ttuBookId: bm.ttuBookId,
        label: bm.label,
        sectionIndex: bm.sectionIndex,
        normCharOffset: bm.normCharOffset,
      ));
    }

    for (final fav in allFavorites) {
      items.add(_CollectionItem(
        type: _CollectionType.sentence,
        createdAt: fav.createdAt,
        bookTitle: fav.bookTitle,
        ttuBookId: fav.ttuBookId,
        text: fav.text,
        chapterLabel: fav.chapterLabel,
        sectionIndex: fav.sectionIndex,
        normCharOffset: fav.normCharOffset,
        normCharLength: fav.normCharLength,
        favoriteId: fav.id,
      ));
    }

    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final allTtuIds = <int>{};
    for (final bm in allBookmarks) {
      if (bm.ttuBookId != null && bm.ttuBookId! > 0) {
        allTtuIds.add(bm.ttuBookId!);
      }
    }
    for (final fav in allFavorites) {
      if (fav.ttuBookId != null && fav.ttuBookId! > 0) {
        allTtuIds.add(fav.ttuBookId!);
      }
    }

    final cueMap = <int, List<AudioCue>>{};
    final audioFileMap = <int, List<File>>{};

    final audiobookByTtuId = await abRepo.buildTtuBookIdMap();

    for (final ttuId in allTtuIds) {
      // SrtBook
      final srtBook = await srtBookRepo.findByTtuBookId(ttuId);
      if (srtBook != null) {
        final cues = await srtBookRepo.cuesFor(srtBook.uid);
        if (cues.isNotEmpty) {
          final audioFiles = await _resolveAudioFiles(
            audioPaths: srtBook.audioPaths,
            audioRoot: srtBook.audioRoot,
          );
          if (audioFiles.isNotEmpty) {
            cueMap[ttuId] = cues;
            audioFileMap[ttuId] = audioFiles;
            continue;
          }
        }
      }

      // Audiobook (Sasayaki)
      final ab = audiobookByTtuId[ttuId];
      if (ab == null) continue;

      final cues = await abRepo.cuesForBook(ab.bookUid);
      if (cues.isEmpty) continue;

      final audioFiles = await _resolveAudioFiles(
        audioPaths: ab.audioPaths,
        audioRoot: ab.audioRoot,
      );
      if (audioFiles.isEmpty) continue;

      cueMap[ttuId] = cues;
      audioFileMap[ttuId] = audioFiles;
    }

    if (mounted) {
      setState(() {
        _items = items;
        _bookTitleMap = bookTitleMap;
        _cueMap = cueMap;
        _audioFileMap = audioFileMap;
        _loading = false;
      });
    }
  }

  void _openBook(_CollectionItem item) {
    final int? ttuId = item.ttuBookId;
    if (ttuId == null || ttuId <= 0) return;

    final String title =
        _bookTitleMap[ttuId] ?? item.bookTitle ?? '';

    final MediaItem mediaItem = buildCollectionReaderMediaItem(
      ttuId: ttuId,
      title: title,
    );

    final Bookmark? bookmark = item.sectionIndex != null
        ? Bookmark(
            sectionIndex: item.sectionIndex!,
            normCharOffset: item.normCharOffset ?? 0,
            label: item.label ?? '',
            createdAt: item.createdAt,
          )
        : null;

    appModel.openMedia(
      ref: ref,
      mediaSource: ReaderHoshiSource.instance,
      item: mediaItem,
      initialBookmarkJump: bookmark,
    );
  }

  Future<List<File>> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) async {
    if (audioPaths != null && audioPaths.isNotEmpty) {
      final files = <File>[];
      for (final p in audioPaths) {
        final f = File(p);
        if (await f.exists()) files.add(f);
      }
      return files;
    }
    if (audioRoot != null) {
      final dir = Directory(audioRoot);
      if (!await dir.exists()) return [];
      final entries = await dir.list().toList();
      final files = entries.whereType<File>().where((f) {
        final ext = f.path.toLowerCase();
        return ext.endsWith('.mp3') ||
            ext.endsWith('.m4a') ||
            ext.endsWith('.ogg') ||
            ext.endsWith('.aac') ||
            ext.endsWith('.wav') ||
            ext.endsWith('.mp4');
      }).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return files;
    }
    return [];
  }

  Future<void> _playItemAudio(_CollectionItem item) async {
    final int? ttuId = item.ttuBookId;
    if (ttuId == null || ttuId <= 0) return;

    final List<File>? audioFiles = _audioFileMap[ttuId];
    if (audioFiles == null || audioFiles.isEmpty) return;

    final List<AudioCue>? cues = _cueMap[ttuId];
    if (cues == null || cues.isEmpty) return;

    final AudioPlaybackRange? range = CollectionAudioMatcher.findPlaybackRange(
      cues: cues,
      sectionIndex: item.sectionIndex,
      normCharOffset: item.normCharOffset,
      normCharLength: item.normCharLength,
      text: item.text,
    );
    if (range == null) return;
    if (range.audioFileIndex < 0 || range.audioFileIndex >= audioFiles.length) {
      return;
    }

    setState(() => _playingAudio = true);
    try {
      final String inputPath = audioFiles[range.audioFileIndex].path;
      final Directory tmpDir = await getTemporaryDirectory();
      final String outputPath =
          p.join(tmpDir.path, 'collections_audio_segment.aac');

      final String? result = await TtsChannel.instance.extractAudioSegment(
        inputPath: inputPath,
        startMs: range.startMs,
        endMs: range.endMs,
        outputPath: outputPath,
      );
      if (result != null) {
        await TtsChannel.instance.playFile(result);
      }
    } finally {
      if (mounted) setState(() => _playingAudio = false);
    }
  }

  Future<void> _deleteItem(_CollectionItem item) async {
    final db = appModel.database;
    if (item.type == _CollectionType.bookmark) {
      final ttuId = item.ttuBookId;
      if (ttuId == null || ttuId <= 0) return;
      final repo = BookmarkRepository(db);
      final bookmarks = await repo.getBookmarks(ttuId);
      final idx = bookmarks.indexWhere((Bookmark b) =>
          b.sectionIndex == item.sectionIndex &&
          b.normCharOffset == item.normCharOffset &&
          b.createdAt == item.createdAt);
      if (idx >= 0) {
        await repo.removeBookmark(ttuId, idx);
      }
    } else {
      final id = item.favoriteId;
      if (id == null) return;
      await FavoriteSentenceRepository(db).removeById(id);
    }
    setState(() => _items.remove(item));
  }

  bool _hasAudio(_CollectionItem item) {
    return _cueMap.containsKey(item.ttuBookId) &&
        _audioFileMap.containsKey(item.ttuBookId);
  }

  Future<void> _showItemDialog(_CollectionItem item) async {
    final isBookmark = item.type == _CollectionType.bookmark;
    final canNavigate = item.ttuBookId != null && item.ttuBookId! > 0;
    final hasAudio = _hasAudio(item);
    final displayTitle = isBookmark ? (item.label ?? '') : (item.text ?? '');
    final cs = Theme.of(context).colorScheme;

    await showAppDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: SelectableText(
          displayTitle,
          maxLines: 3,
        ),
        content: item.bookTitle != null
            ? Text(item.bookTitle!, style: textTheme.bodyMedium)
            : null,
        actions: [
          if (hasAudio)
            TextButton.icon(
              icon: Icon(
                _playingAudio ? Icons.hourglass_top : Icons.volume_up,
                size: 18,
              ),
              label: Text(t.dialog_play),
              onPressed: _playingAudio
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _playItemAudio(item);
                    },
            ),
          if (!isBookmark && item.text != null)
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: Text(t.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.text!));
                Navigator.pop(ctx);
              },
            ),
          TextButton.icon(
            icon: Icon(Icons.delete, size: 18, color: cs.error),
            label: Text(t.dialog_delete, style: TextStyle(color: cs.error)),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteItem(item);
            },
          ),
          if (canNavigate)
            FilledButton.icon(
              icon: const Icon(Icons.menu_book, size: 18),
              label: Text(t.dialog_read),
              onPressed: () {
                Navigator.pop(ctx);
                _openBook(item);
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.collections),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Text(
                    t.no_collections,
                    style: textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, index) => _buildItem(_items[index]),
                ),
    );
  }

  Widget _buildItem(_CollectionItem item) {
    final isBookmark = item.type == _CollectionType.bookmark;
    final icon = isBookmark ? Icons.bookmark : Icons.format_quote;
    final typeLabel =
        isBookmark ? t.collection_bookmark : t.collection_sentence;

    final String title;
    final String? subtitle;

    if (isBookmark) {
      title = item.label ?? '';
      subtitle = item.bookTitle;
    } else {
      title = item.text ?? '';
      subtitle = [
        item.bookTitle,
        item.chapterLabel,
      ].where((s) => s != null && s.isNotEmpty).join(' · ');
    }

    final canNavigate = item.ttuBookId != null && item.ttuBookId! > 0;

    final key = isBookmark
        ? 'bm_${item.ttuBookId}_${item.createdAt.microsecondsSinceEpoch}'
        : 'fav_${item.favoriteId}';

    return Dismissible(
      key: Key(key),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Theme.of(context).colorScheme.error,
        child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onError),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text(isBookmark
                ? '${t.collection_bookmark}: ${item.label ?? ""}'
                : item.text ?? ''),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.dialog_close),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  t.dialog_delete,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ),
        ) ?? false;
      },
      onDismissed: (_) => _deleteItem(item),
      child: ListTile(
        leading: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 20,
                color: isBookmark
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.tertiary),
            Text(
              typeLabel,
              style: textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ],
        ),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            if (subtitle != null && subtitle.isNotEmpty) subtitle,
            _dateFmt.format(item.createdAt),
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_hasAudio(item))
              IconButton(
                icon: Icon(
                  _playingAudio ? Icons.hourglass_top : Icons.volume_up,
                  size: 18,
                ),
                onPressed: _playingAudio ? null : () => _playItemAudio(item),
                visualDensity: VisualDensity.compact,
              ),
            if (!isBookmark && item.text != null)
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: item.text!));
                },
                visualDensity: VisualDensity.compact,
              ),
            if (canNavigate)
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          ],
        ),
        onTap: canNavigate ? () => _openBook(item) : null,
        onLongPress: () => _showItemDialog(item),
      ),
    );
  }
}
