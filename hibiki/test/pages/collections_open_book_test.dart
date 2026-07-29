import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

MediaItem _liveBook(String source) {
  return MediaItem(
    id: 99,
    mediaIdentifier: 'hoshi://book/live-book',
    title: 'Live DB title',
    mediaTypeIdentifier: 'reader_media_type',
    mediaSourceIdentifier: source,
    position: 12,
    duration: 34,
    canDelete: false,
    canEdit: true,
    base64Image: 'base64',
    imageUrl: 'image',
    audioUrl: 'audio',
    author: 'author',
    authorIdentifier: 'author-id',
    extraUrl: 'extra-url',
    extra: 'extra',
    sourceMetadata: 'metadata',
  );
}

void main() {
  test('_openBook bypasses stale provider cache and routes the resolved item',
      () {
    final String source = File(
      'lib/src/pages/implementations/collections_page.dart',
    ).readAsStringSync();
    final int start = source.indexOf('Future<void> _openBook(');
    final int end = source.indexOf(
      'Future<void> _openVideoSentence(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);

    expect(
      body,
      contains('ReaderHibikiSource.instance.getBooksFromDb('),
      reason: 'format 更新不改变 bookKey，hibikiBooksProvider 会因 distinct 保留旧 source',
    );
    expect(body, isNot(contains('hibikiBooksProvider')));
    expect(body, contains('isMounted: () => mounted'));
    expect(body, contains('resolvedItem.getMediaSource(appModel: appModel)'));
  });

  test('EPUB, Manga, and PDF preserve live routing, title, and Bookmark',
      () async {
    for (final String source in <String>[
      'reader_ttu',
      'reader_manga',
      'reader_pdf',
    ]) {
      final Bookmark bookmark = Bookmark(
        sectionIndex: 3,
        normCharOffset: 0,
        charAnchor: 456,
        charAnchorLength: 12,
        preserveSavedPosition: true,
        label: '',
        createdAt: DateTime(2026, 7, 29),
      );
      MediaItem? opened;
      Bookmark? openedBookmark;

      await openCollectionBookFromLiveItems(
        bookKey: 'live-book',
        title: 'Collection display title',
        bookmark: bookmark,
        loadLiveItems: () async => <MediaItem>[_liveBook(source)],
        isMounted: () => true,
        open: (MediaItem item, Bookmark? jump) async {
          opened = item;
          openedBookmark = jump;
        },
      );

      expect(opened, isNotNull);
      expect(opened!.mediaIdentifier, 'hoshi://book/live-book');
      expect(opened!.mediaSourceIdentifier, source,
          reason: '跳回原文必须保留 live format 对应的 source 路由');
      expect(opened!.mediaTypeIdentifier, 'reader_media_type');
      expect(opened!.title, 'Collection display title');
      expect(opened!.id, 99);
      expect(opened!.base64Image, 'base64');
      expect(opened!.imageUrl, 'image');
      expect(opened!.audioUrl, 'audio');
      expect(opened!.author, 'author');
      expect(opened!.authorIdentifier, 'author-id');
      expect(opened!.extraUrl, 'extra-url');
      expect(opened!.extra, 'extra');
      expect(opened!.sourceMetadata, 'metadata');
      expect(openedBookmark, same(bookmark));
    }
  });

  test('deleted live book returns without opening', () async {
    bool opened = false;
    await openCollectionBookFromLiveItems(
      bookKey: 'deleted',
      title: 'Snapshot title',
      bookmark: null,
      loadLiveItems: () async => <MediaItem>[],
      isMounted: () => true,
      open: (MediaItem item, Bookmark? jump) async {
        opened = true;
      },
    );
    expect(opened, isFalse);
  });

  test('unmounted after awaiting live rows returns without opening', () async {
    final Completer<List<MediaItem>> loader = Completer<List<MediaItem>>();
    bool mounted = true;
    bool opened = false;
    final Future<void> pending = openCollectionBookFromLiveItems(
      bookKey: 'live-book',
      title: 'Snapshot title',
      bookmark: null,
      loadLiveItems: () => loader.future,
      isMounted: () => mounted,
      open: (MediaItem item, Bookmark? jump) async {
        opened = true;
      },
    );

    mounted = false;
    loader.complete(<MediaItem>[_liveBook('reader_manga')]);
    await pending;

    expect(opened, isFalse);
  });
}
