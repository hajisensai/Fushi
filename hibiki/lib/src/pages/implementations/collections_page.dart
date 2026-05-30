import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/pages/base_page.dart';

enum _CollectionType { bookmark, sentence }

MediaItem buildCollectionReaderMediaItem({
  required int ttuId,
  required String title,
}) {
  return MediaItem(
    mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(ttuId),
    title: title,
    mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
    mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
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
    this.bookmarkId,
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
  final int? bookmarkId;
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
        bookmarkId: bm.id,
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

    final String title = _bookTitleMap[ttuId] ?? item.bookTitle ?? '';

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
      mediaSource: ReaderHibikiSource.instance,
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
      for (final path in audioPaths) {
        final f = File(path);
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
            ext.endsWith('.m4b') ||
            ext.endsWith('.ogg') ||
            ext.endsWith('.aac') ||
            ext.endsWith('.wav') ||
            ext.endsWith('.mp4') ||
            ext.endsWith('.flac') ||
            ext.endsWith('.opus') ||
            ext.endsWith('.wma') ||
            ext.endsWith('.ac3') ||
            ext.endsWith('.eac3');
      }).toList()
        ..sort((a, b) => compareAudioFilePath(a.path, b.path));
      return files;
    }
    return [];
  }

  Future<void> _playItemAudio(_CollectionItem item) async {
    final int? ttuId = item.ttuBookId;
    if (ttuId == null || ttuId <= 0) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }

    final List<File>? audioFiles = _audioFileMap[ttuId];
    if (audioFiles == null || audioFiles.isEmpty) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }

    final List<AudioCue>? cues = _cueMap[ttuId];
    if (cues == null || cues.isEmpty) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }

    final AudioPlaybackRange? range = CollectionAudioMatcher.findPlaybackRange(
      cues: cues,
      sectionIndex: item.sectionIndex,
      normCharOffset: item.normCharOffset,
      normCharLength: item.normCharLength,
      text: item.text,
    );
    if (range == null) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }
    if (range.audioFileIndex < 0 || range.audioFileIndex >= audioFiles.length) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
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
      final bookmarkId = item.bookmarkId;
      if (bookmarkId != null) {
        await repo.removeBookmarkById(bookmarkId);
      } else {
        await repo.removeBookmarkMatching(
          ttuId,
          sectionIndex: item.sectionIndex ?? 0,
          normCharOffset: item.normCharOffset ?? 0,
          createdAt: item.createdAt,
        );
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
      builder: (ctx) => CollectionItemDialogFrame(
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
                _playingAudio ? Icons.hourglass_top : Icons.volume_up_outlined,
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
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: Text(t.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.text!));
                Navigator.pop(ctx);
              },
            ),
          TextButton.icon(
            icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
            label: Text(t.dialog_delete, style: TextStyle(color: cs.error)),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteItem(item);
            },
          ),
          if (canNavigate)
            FilledButton.icon(
              icon: const Icon(Icons.menu_book_outlined, size: 18),
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
    return HibikiPageScaffold(
      title: t.collections,
      body: _loading
          ? Center(child: adaptiveIndicator(context: context))
          : _items.isEmpty
              ? Center(
                  child: HibikiPlaceholderMessage(
                    icon: Icons.collections_bookmark_outlined,
                    message: t.no_collections,
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, index) => _buildItem(_items[index]),
                ),
    );
  }

  Widget _buildItem(_CollectionItem item) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final isBookmark = item.type == _CollectionType.bookmark;
    final icon =
        isBookmark ? Icons.bookmark_outline : Icons.format_quote_outlined;
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
        padding: EdgeInsets.only(
          right: tokens.spacing.card + tokens.spacing.gap / 2,
        ),
        color: Theme.of(context).colorScheme.error,
        child: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.onError),
      ),
      confirmDismiss: (_) async {
        final String message = isBookmark
            ? '${t.collection_bookmark}: ${item.label ?? ""}'
            : item.text ?? '';
        return await showAppDialog<bool>(
              context: context,
              builder: (ctx) => CollectionDeleteDialog(
                message: message,
                onConfirm: () => Navigator.pop(ctx, true),
              ),
            ) ??
            false;
      },
      onDismissed: (_) => _deleteItem(item),
      child: GestureDetector(
        onLongPress: () => _showItemDialog(item),
        child: HibikiListItem(
          leading: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon,
                  size: 20,
                  color: isBookmark
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.tertiary),
              Text(
                typeLabel,
                style: textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_hasAudio(item))
                IconButton(
                  icon: Icon(
                    _playingAudio
                        ? Icons.hourglass_top
                        : Icons.volume_up_outlined,
                    size: 18,
                  ),
                  onPressed: _playingAudio ? null : () => _playItemAudio(item),
                  visualDensity: VisualDensity.compact,
                ),
              if (!isBookmark && item.text != null)
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 18),
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
        ),
      ),
    );
  }
}

@visibleForTesting
class CollectionItemDialogFrame extends StatelessWidget {
  const CollectionItemDialogFrame({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.78,
      child: HibikiModalSheetFrame(
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
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DefaultTextStyle.merge(
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
              child: title,
            ),
            if (content != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              DefaultTextStyle.merge(
                style: tokens.type.listSubtitle,
                child: content!,
              ),
            ],
          ],
        ),
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
class CollectionDeleteDialog extends StatelessWidget {
  const CollectionDeleteDialog({
    required this.message,
    required this.onConfirm,
    super.key,
  });

  final String message;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
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
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: EdgeInsets.all(tokens.spacing.gap),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: tokens.radii.controlRadius,
              ),
              child: Icon(
                Icons.delete_outline,
                color: colors.onErrorContainer,
                size: 20,
              ),
            ),
            SizedBox(width: tokens.spacing.gap + 4),
            Expanded(
              child: Text(
                message,
                style: tokens.type.listSubtitle,
              ),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_close),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: onConfirm,
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}
