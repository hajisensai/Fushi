import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/data/web_browser_store.dart';

/// [WebBrowserStore] 的共享契约测试：同一套断言跑在每个实现上（内存版 / Drift 版），
/// 防两份实现语义漂移。用法：在某个 `*_test.dart` 的 `main()` 里调用
/// [defineWebBrowserStoreContract]，传入按时钟构造实现的工厂。
///
/// 时钟由契约控制（`now` 可前移），实现必须把它用于 recordVisit / 删除时刻。
void defineWebBrowserStoreContract(
  String label, {
  required WebBrowserStore Function(DateTime Function() clock) create,
  Future<void> Function(WebBrowserStore store)? dispose,
}) {
  group('WebBrowserStore 契约（$label）', () {
    late DateTime now;
    late WebBrowserStore store;
    late int notifications;

    setUp(() {
      now = DateTime(2026, 10, 23, 12);
      store = create(() => now);
      notifications = 0;
      store.addListener(() => notifications++);
    });
    tearDown(() async {
      if (dispose != null) await dispose(store);
    });

    group('history', () {
      test('recordVisit merges the same url，每次写入恰好通知一次', () async {
        final Uri url = Uri.parse('https://example.com/a');
        await store.recordVisit(url: url, title: 'A');
        now = now.add(const Duration(minutes: 5));
        await store.recordVisit(url: url, title: 'A2');
        // 让实现可能异步送达的内部更新事件都跑完，再数通知次数。
        await Future<void>.delayed(Duration.zero);
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
        final DateTime base = now;
        now = base.subtract(const Duration(days: 3));
        await store.recordVisit(
          url: Uri.parse('https://old.com/'),
          title: 'old',
        );
        now = base;
        await store.recordVisit(
          url: Uri.parse('https://new.com/'),
          title: 'new',
        );
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
          unorderedEquals(<int>[a, inner]),
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
        expect(await store.bookmarks(parentId: folder), isEmpty);
        expect((await store.bookmarks()).last.id, a);
      });

      test('cannot move a folder into itself or a descendant', () async {
        final int outer = await store.addFolder(title: 'O');
        final int inner = await store.addFolder(title: 'I', parentId: outer);
        await store.updateBookmark(outer, parentId: inner);
        await store.updateBookmark(outer, parentId: outer);
        expect((await store.bookmarks()).single.id, outer);
        expect((await store.bookmarks(parentId: outer)).single.id, inner);
      });

      test('deleting a folder cascades', () async {
        final int outer = await store.addFolder(title: 'O');
        final int inner = await store.addFolder(title: 'I', parentId: outer);
        await store.addBookmark(
          title: 'deep',
          url: Uri.parse('https://deep.com/'),
          parentId: inner,
        );
        await store.addBookmark(
          title: 'keep',
          url: Uri.parse('https://k.com/'),
        );
        await store.deleteBookmark(outer);
        expect(
          (await store.allBookmarks()).map((WebBrowserBookmark b) => b.title),
          <String>['keep'],
        );
        expect(await store.bookmarks(parentId: inner), isEmpty);
      });
    });

    group('session and closed tabs', () {
      test('session round trip, overwrite keeps order', () async {
        expect(await store.loadSession(), isNull);
        await store.saveSession(
          WebBrowserSession(
            tabs: <WebBrowserSessionTab>[
              WebBrowserSessionTab(
                id: 't1',
                url: Uri.parse('https://a.com/'),
                title: 'A',
              ),
              WebBrowserSessionTab(
                id: 't2',
                url: Uri.parse('https://b.com/'),
                title: 'B',
              ),
            ],
            activeTabId: 't1',
          ),
        );
        await store.saveSession(
          WebBrowserSession(
            tabs: <WebBrowserSessionTab>[
              WebBrowserSessionTab(
                id: 't2',
                url: Uri.parse('https://b.com/'),
                title: 'B',
              ),
              WebBrowserSessionTab(
                id: 't1',
                url: Uri.parse('https://a.com/'),
                title: 'A',
              ),
            ],
            activeTabId: 't2',
          ),
        );
        final WebBrowserSession? s = await store.loadSession();
        expect(s?.activeTabId, 't2');
        expect(s?.tabs.map((WebBrowserSessionTab t) => t.id), <String>[
          't2',
          't1',
        ]);
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
        expect(list, hasLength(25));
        expect(list.first.title, 't29');
        expect(list.last.title, 't5');
        final WebBrowserClosedTab? popped = await store.popClosedTab();
        expect(popped?.title, 't29');
        expect(popped?.index, 29);
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
  });
}
