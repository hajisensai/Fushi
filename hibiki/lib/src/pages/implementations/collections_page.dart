import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
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

    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  void _openBook(_CollectionItem item) {
    final int? ttuId = item.ttuBookId;
    if (ttuId == null || ttuId <= 0) return;

    final int port = ReaderTtuSource.instance
        .getPortForLanguage(appModel.targetLanguage);
    final String title = item.bookTitle ?? '';
    final String url =
        'http://localhost:$port/b.html?id=$ttuId&title=${Uri.encodeComponent(title)}';

    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderTtuSourcePage(
          item: MediaItem(
            mediaIdentifier: url,
            title: title,
            mediaTypeIdentifier:
                ReaderTtuSource.instance.mediaType.uniqueKey,
            mediaSourceIdentifier: ReaderTtuSource.instance.uniqueKey,
            position: 0,
            duration: 1,
            canDelete: false,
            canEdit: true,
          ),
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
