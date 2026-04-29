import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/favorite_sentence_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';

enum _CollectionType { bookmark, sentence }

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
  Map<int, MediaItem> _mediaItemMap = {};
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

    final allBookmarks = await bookmarkRepo.getAllBookmarks();
    final allFavorites = await favoriteRepo.getAll();

    final srtBooks = await srtBookRepo.listAll();
    final bookTitleMap = <int, String>{};
    for (final b in srtBooks) {
      if (b.ttuBookId > 0) {
        bookTitleMap[b.ttuBookId] = b.title;
      }
    }

    final mediaItemMap = <int, MediaItem>{};
    final sourceId = ReaderTtuSource.instance.uniqueKey;
    final rows = await db.getMediaItemsBySource(sourceId);
    for (final row in rows) {
      final uri = Uri.tryParse(row.mediaIdentifier);
      final ttuId = int.tryParse(uri?.queryParameters['id'] ?? '');
      if (ttuId != null && ttuId > 0) {
        mediaItemMap.putIfAbsent(ttuId, () => MediaItem(
          mediaIdentifier: row.mediaIdentifier,
          title: row.title,
          mediaTypeIdentifier: row.mediaTypeIdentifier,
          mediaSourceIdentifier: row.mediaSourceIdentifier,
          position: row.position,
          duration: row.duration,
          canDelete: row.canDelete,
          canEdit: row.canEdit,
        ));
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
      ));
    }

    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final sentenceTtuIds = allFavorites
        .where((f) => f.ttuBookId != null && f.ttuBookId! > 0)
        .map((f) => f.ttuBookId!)
        .toSet();

    final cueMap = <int, List<AudioCue>>{};
    final audioFileMap = <int, List<File>>{};

    for (final ttuId in sentenceTtuIds) {
      final srtBook = await srtBookRepo.findByTtuBookId(ttuId);
      if (srtBook == null) continue;

      final cues = await srtBookRepo.cuesFor(srtBook.uid);
      if (cues.isEmpty) continue;

      final audioFiles = await _resolveAudioFiles(
        audioPaths: srtBook.audioPaths,
        audioRoot: srtBook.audioRoot,
      );
      if (audioFiles.isEmpty) continue;

      cueMap[ttuId] = cues;
      audioFileMap[ttuId] = audioFiles;
    }

    if (mounted) {
      setState(() {
        _items = items;
        _bookTitleMap = bookTitleMap;
        _mediaItemMap = mediaItemMap;
        _cueMap = cueMap;
        _audioFileMap = audioFileMap;
        _loading = false;
      });
    }
  }

  void _openBook(_CollectionItem item) {
    final int? ttuId = item.ttuBookId;
    if (ttuId == null || ttuId <= 0) return;

    final MediaItem? original = _mediaItemMap[ttuId];

    final MediaItem mediaItem;
    if (original != null) {
      mediaItem = original;
    } else {
      final int port = ReaderTtuSource.instance
          .getPortForLanguage(appModel.targetLanguage);
      final String title = _bookTitleMap[ttuId] ?? item.bookTitle ?? '';
      final String url =
          'http://localhost:$port/b.html?id=$ttuId&title=${Uri.encodeComponent(title)}';
      mediaItem = MediaItem(
        mediaIdentifier: url,
        title: title,
        mediaTypeIdentifier: ReaderTtuSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: ReaderTtuSource.instance.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );
    }

    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderTtuSourcePage(
          item: mediaItem,
          initialBookmarkJump: item.sectionIndex != null
              ? Bookmark(
                  sectionIndex: item.sectionIndex!,
                  normCharOffset: item.normCharOffset ?? 0,
                  label: item.label ?? '',
                  createdAt: item.createdAt,
                )
              : null,
        ),
      ),
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
      final files = entries
          .whereType<File>()
          .where((f) {
            final ext = f.path.toLowerCase();
            return ext.endsWith('.mp3') ||
                ext.endsWith('.m4a') ||
                ext.endsWith('.ogg') ||
                ext.endsWith('.aac') ||
                ext.endsWith('.wav') ||
                ext.endsWith('.mp4');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return files;
    }
    return [];
  }

  Future<void> _playSentenceAudio(_CollectionItem item) async {
    final ttuId = item.ttuBookId;
    if (ttuId == null || ttuId <= 0) return;

    final cues = _cueMap[ttuId];
    final audioFiles = _audioFileMap[ttuId];
    if (cues == null || cues.isEmpty || audioFiles == null || audioFiles.isEmpty) return;

    final text = item.text ?? '';
    if (text.isEmpty) return;

    AudioCue? match;
    for (final cue in cues) {
      if (cue.text == text) {
        match = cue;
        break;
      }
    }
    match ??= cues.cast<AudioCue?>().firstWhere(
      (c) => c!.text.contains(text) || text.contains(c.text),
      orElse: () => null,
    );
    if (match == null) return;

    if (match.audioFileIndex < 0 || match.audioFileIndex >= audioFiles.length) return;

    setState(() => _playingAudio = true);
    try {
      final inputPath = audioFiles[match.audioFileIndex].path;
      final tmpDir = await getTemporaryDirectory();
      final outputPath = p.join(tmpDir.path, 'collections_audio_segment.m4a');

      final result = await TtsChannel.instance.extractAudioSegment(
        inputPath: inputPath,
        startMs: match.startMs,
        endMs: match.endMs,
        outputPath: outputPath,
      );
      if (result != null) {
        await TtsChannel.instance.playFile(result);
      }
    } finally {
      if (mounted) setState(() => _playingAudio = false);
    }
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
                  itemBuilder: (context, index) =>
                      _buildItem(_items[index]),
                ),
    );
  }

  Widget _buildItem(_CollectionItem item) {
    final isBookmark = item.type == _CollectionType.bookmark;
    final icon = isBookmark ? Icons.bookmark : Icons.format_quote;
    final typeLabel = isBookmark ? t.collection_bookmark : t.collection_sentence;

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

    return ListTile(
      leading: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: isBookmark
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
          if (!isBookmark && item.text != null && item.text!.isNotEmpty &&
              _cueMap.containsKey(item.ttuBookId))
            IconButton(
              icon: Icon(
                _playingAudio ? Icons.hourglass_top : Icons.volume_up,
                size: 18,
              ),
              onPressed: _playingAudio ? null : () => _playSentenceAudio(item),
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
    );
  }
}
