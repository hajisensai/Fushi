import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';

void main() {
  late DateTime now;
  late MemoryWebBrowserStore store;
  late int notifications;

  setUp(() {
    now = DateTime(2026, 10, 23, 12);
    store = MemoryWebBrowserStore(clock: () => now);
    notifications = 0;
    store.addListener(() => notifications++);
  });

  group('history', () {
    test('recordVisit merges the same url', () async {
      final Uri url = Uri.parse('https://example.com/a');
      await store.recordVisit(url: url, title: 'A');
      now = now.add(const Duration(minutes: 5));
      await store.recordVisit(url: url, title: 'A2');
      final List<WebBrowserHistoryEntry> list = await store.history();
      expect(list, hasLength(1));
      expect(list.single.visitCount, 2);
      expect(list.single.title, 'A2');
      expect(list.single.lastVisitedAt, now);
      expect(notifications, 2);
    });

    test('newest first, query filters title and url, paging', () async {
      await store.recordVisit(url: Uri.parse('https://a.com/'), title: '漫画');
      now = now.add(const Duration(minutes: 1));
      await store.recordVisit(url: Uri.parse('https://b.com/'), title: 'Bee');
      final List<WebBrowserHistoryEntry> all = await store.history();
      expect(all.map((WebBrowserHistoryEntry e) => e.title), <String>[
        'Bee',
        '漫画',
      ]);
      expect((await store.history(query: '漫画')).single.title, '漫画');
      expect((await store.history(query: 'b.com')).single.title, 'Bee');
      expect((await store.history(limit: 1, offset: 1)).single.title, '漫画');
    });

    test('deleteHistory and clearHistory(since)', () async {
      store.seedHistory(
        url: Uri.parse('https://old.com/'),
        title: 'old',
        lastVisitedAt: now.subtract(const Duration(days: 3)),
      );
      await store.recordVisit(url: Uri.parse('https://new.com/'), title: 'new');
      await store.clearHistory(since: now.subtract(const Duration(hours: 1)));
      final List<WebBrowserHistoryEntry> left = await store.history();
      expect(left.single.title, 'old');
      await store.deleteHistory(<int>[left.single.id]);
      expect(await store.history(), isEmpty);
      await store.recordVisit(url: Uri.parse('https://x.com/'), title: 'x');
      await store.clearHistory();
      expect(await store.history(), isEmpty);
    });
  });

  group('bookmarks', () {
    test('folders, ordering, lookup by url', () async {
      final int folder = await store.addFolder(title: 'F');
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.com/'),
      );
      final int inner = await store.addBookmark(
        title: 'In',
        url: Uri.parse('https://in.com/'),
        parentId: folder,
      );
      final List<WebBrowserBookmark> root = await store.bookmarks();
      expect(root.map((WebBrowserBookmark b) => b.id), <int>[folder, a]);
      expect(root.first.isFolder, isTrue);
      expect((await store.bookmarks(parentId: folder)).single.id, inner);
      expect(
        (await store.allBookmarks()).map((WebBrowserBookmark b) => b.id),
        <int>[a, inner],
      );
      expect(
        (await store.bookmarkForUrl(Uri.parse('https://in.com/')))?.id,
        inner,
      );
      expect(
        await store.bookmarkForUrl(Uri.parse('https://none.com/')),
        isNull,
      );
    });

    test('updateBookmark moves, reorders, and moves to root', () async {
      final int folder = await store.addFolder(title: 'F');
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.com/'),
      );
      final int b = await store.addBookmark(
        title: 'B',
        url: Uri.parse('https://b.com/'),
      );
      await store.updateBookmark(b, position: 0);
      expect(
        (await store.bookmarks()).map((WebBrowserBookmark x) => x.id),
        <int>[b, folder, a],
      );
      await store.updateBookmark(a, parentId: folder, title: 'A!');
      final WebBrowserBookmark moved = (await store.bookmarks(
        parentId: folder,
      )).single;
      expect(moved.title, 'A!');
      await store.updateBookmark(a, moveToRoot: true);
      expect((await store.bookmarks(parentId: folder)), isEmpty);
      expect((await store.bookmarks()).last.id, a);
    });

    test('cannot move a folder into itself or a descendant', () async {
      final int outer = await store.addFolder(title: 'O');
      final int inner = await store.addFolder(title: 'I', parentId: outer);
      await store.updateBookmark(outer, parentId: inner);
      await store.updateBookmark(outer, parentId: outer);
      expect((await store.bookmarks()).single.id, outer);
    });

    test('deleting a folder cascades', () async {
      final int outer = await store.addFolder(title: 'O');
      final int inner = await store.addFolder(title: 'I', parentId: outer);
      await store.addBookmark(
        title: 'deep',
        url: Uri.parse('https://deep.com/'),
        parentId: inner,
      );
      await store.addBookmark(title: 'keep', url: Uri.parse('https://k.com/'));
      await store.deleteBookmark(outer);
      expect(
        (await store.allBookmarks()).map((WebBrowserBookmark b) => b.title),
        <String>['keep'],
      );
      expect(await store.bookmarks(parentId: inner), isEmpty);
    });
  });

  group('session and closed tabs', () {
    test('session round trip', () async {
      expect(await store.loadSession(), isNull);
      await store.saveSession(
        WebBrowserSession(
          tabs: <WebBrowserSessionTab>[
            WebBrowserSessionTab(
              id: 't1',
              url: Uri.parse('https://a.com/'),
              title: 'A',
            ),
          ],
          activeTabId: 't1',
        ),
      );
      final WebBrowserSession? s = await store.loadSession();
      expect(s?.activeTabId, 't1');
      expect(s?.tabs.single.title, 'A');
    });

    test('closed tabs keep at most 25, newest first, pop newest', () async {
      for (int i = 0; i < 30; i++) {
        await store.pushClosedTab(
          WebBrowserClosedTab(
            url: Uri.parse('https://t$i.com/'),
            title: 't$i',
            closedAt: now,
            index: i,
          ),
        );
      }
      final List<WebBrowserClosedTab> list = await store.closedTabs();
      expect(list, hasLength(MemoryWebBrowserStore.closedTabsLimit));
      expect(list.first.title, 't29');
      expect(list.last.title, 't5');
      expect((await store.popClosedTab())?.title, 't29');
      expect((await store.closedTabs()).first.title, 't28');
    });

    test('pop on empty returns null', () async {
      expect(await store.popClosedTab(), isNull);
    });
  });

  group('downloads', () {
    test('add assigns id, update merges, delete removes', () async {
      final int id = await store.addDownload(
        WebBrowserDownload(
          id: 0,
          url: Uri.parse('https://a.com/f.zip'),
          fileName: 'f.zip',
          startedAt: now,
        ),
      );
      expect(id, greaterThan(0));
      await store.updateDownload(
        id,
        receivedBytes: 50,
        totalBytes: 100,
        state: WebBrowserDownloadState.completed,
        savedPath: '/tmp/f.zip',
      );
      final WebBrowserDownload d = (await store.downloads()).single;
      expect(d.id, id);
      expect(d.receivedBytes, 50);
      expect(d.totalBytes, 100);
      expect(d.state, WebBrowserDownloadState.completed);
      expect(d.savedPath, '/tmp/f.zip');
      await store.deleteDownload(id);
      expect(await store.downloads(), isEmpty);
    });

    test('newest first', () async {
      await store.addDownload(
        WebBrowserDownload(
          id: 0,
          url: Uri.parse('https://a.com/1'),
          fileName: '1',
          startedAt: now,
        ),
      );
      await store.addDownload(
        WebBrowserDownload(
          id: 0,
          url: Uri.parse('https://a.com/2'),
          fileName: '2',
          startedAt: now.add(const Duration(seconds: 1)),
        ),
      );
      expect(
        (await store.downloads()).map((WebBrowserDownload d) => d.fileName),
        <String>['2', '1'],
      );
    });
  });
}
