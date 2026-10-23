import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/data/drift_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late DriftWebBrowserStore store;
  late int now;
  int uidSeq = 0;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    now = 1000;
    uidSeq = 0;
    store = DriftWebBrowserStore(
      db,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      newUid: () => 'uid-${uidSeq++}',
    );
  });
  tearDown(() async {
    store.dispose();
    await db.close();
  });

  Future<Map<String, int>> tombstonesOf(SyncTombstoneKind kind) async =>
      <String, int>{
        for (final SyncDeletionTombstoneRow r
            in await db.getSyncDeletionTombstonesOfType(kind.dbValue))
          r.itemKey: r.deletedAt,
      };

  group('历史', () {
    test('同 url 合并：次数累加、标题取最近、最近访问前移', () async {
      final Uri a = Uri.parse('https://a.example/');
      await store.recordVisit(url: a, title: 'A1');
      now = 2000;
      await store.recordVisit(url: a, title: 'A2');
      now = 3000;
      await store.recordVisit(url: Uri.parse('https://b.example/'), title: 'B');

      final List<WebBrowserHistoryEntry> h = await store.history();
      expect(h.map((WebBrowserHistoryEntry e) => e.title), <String>['B', 'A2']);
      expect(h.last.visitCount, 2);
      expect(h.last.lastVisitedAt.millisecondsSinceEpoch, 2000);
    });

    test('空标题的访问不覆盖已有标题', () async {
      final Uri a = Uri.parse('https://a.example/');
      await store.recordVisit(url: a, title: 'Title');
      await store.recordVisit(url: a, title: '');
      expect((await store.history()).single.title, 'Title');
    });

    test('搜索走统一归一化（全角 / 大小写 / 标点）且匹配地址', () async {
      await store.recordVisit(
        url: Uri.parse('https://news.example.com/x'),
        title: 'ニュース速報',
      );
      await store.recordVisit(
        url: Uri.parse('https://other.org/'),
        title: 'Other',
      );
      expect((await store.history(query: 'にゅーす')).single.title, 'ニュース速報');
      expect((await store.history(query: 'ＮＥＷＳ')).single.title, 'ニュース速報');
      expect((await store.history(query: 'other.org')).single.title, 'Other');
      expect(await store.history(query: 'zzz'), isEmpty);
    });

    test('分页 limit / offset', () async {
      for (int i = 0; i < 5; i++) {
        now = 1000 + i;
        await store.recordVisit(
          url: Uri.parse('https://e$i.example/'),
          title: 'e$i',
        );
      }
      final List<WebBrowserHistoryEntry> page = await store.history(
        limit: 2,
        offset: 1,
      );
      expect(page.map((WebBrowserHistoryEntry e) => e.title), <String>[
        'e3',
        'e2',
      ]);
    });

    test('删除写逐条墓碑；再访问同一 url 清掉墓碑', () async {
      final Uri a = Uri.parse('https://a.example/');
      await store.recordVisit(url: a, title: 'A');
      now = 5000;
      await store.deleteHistory(<int>[(await store.history()).single.id]);
      expect(await store.history(), isEmpty);
      expect(await tombstonesOf(SyncTombstoneKind.webhistory), <String, int>{
        'https://a.example/': 5000,
      });

      now = 6000;
      await store.recordVisit(url: a, title: 'A');
      expect(await tombstonesOf(SyncTombstoneKind.webhistory), isEmpty);
    });

    test('clearHistory(since) 只删之后的访问，写一条区间墓碑', () async {
      now = 100;
      await store.recordVisit(
        url: Uri.parse('https://old.example/'),
        title: 'old',
      );
      now = 500;
      await store.recordVisit(
        url: Uri.parse('https://new.example/'),
        title: 'new',
      );
      now = 900;
      await store.clearHistory(since: DateTime.fromMillisecondsSinceEpoch(300));
      expect((await store.history()).single.title, 'old');
      expect(await tombstonesOf(SyncTombstoneKind.webhistory), <String, int>{
        webHistoryClearTombstoneKey(300): 900,
      });

      await store.clearHistory();
      expect(await store.history(), isEmpty);
      expect(
        (await tombstonesOf(SyncTombstoneKind.webhistory)).keys,
        contains(webHistoryClearTombstoneKey(0)),
      );
    });
  });

  group('书签', () {
    test('增删改查 + 文件夹混排 + bookmarkForUrl / allBookmarks 不含文件夹', () async {
      final int folder = await store.addFolder(title: 'F');
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.example/'),
      );
      final int inner = await store.addBookmark(
        title: 'In',
        url: Uri.parse('https://in.example/'),
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
        (await store.bookmarkForUrl(Uri.parse('https://in.example/')))!.id,
        inner,
      );
      expect(await store.bookmarkForUrl(Uri.parse('https://none/')), isNull);

      await store.updateBookmark(a, title: 'A2', url: Uri.parse('https://a2/'));
      final WebBrowserBookmark updated = (await store.bookmarks()).last;
      expect(updated.title, 'A2');
      expect(updated.url.toString(), 'https://a2/');
    });

    test('移动与重排：换父级落末尾、给序位重排 0..n-1、moveToRoot', () async {
      final int f = await store.addFolder(title: 'F');
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a/'),
      );
      final int b = await store.addBookmark(
        title: 'B',
        url: Uri.parse('https://b/'),
      );
      final int c = await store.addBookmark(
        title: 'C',
        url: Uri.parse('https://c/'),
      );

      await store.updateBookmark(c, position: 0);
      expect(
        (await store.bookmarks()).map((WebBrowserBookmark x) => x.id),
        <int>[c, f, a, b],
      );
      expect(
        (await store.bookmarks()).map((WebBrowserBookmark x) => x.position),
        <int>[0, 1, 2, 3],
      );

      await store.updateBookmark(a, parentId: f);
      expect((await store.bookmarks(parentId: f)).single.id, a);
      expect(
        (await store.bookmarks()).map((WebBrowserBookmark x) => x.id),
        <int>[c, f, b],
      );

      await store.updateBookmark(a, moveToRoot: true, position: 0);
      expect((await store.bookmarks()).first.id, a);
      expect(await store.bookmarks(parentId: f), isEmpty);
    });

    test('不能把文件夹移进自己的后代（静默忽略）', () async {
      final int outer = await store.addFolder(title: 'Outer');
      final int inner = await store.addFolder(title: 'Inner', parentId: outer);
      await store.updateBookmark(outer, parentId: inner);
      expect((await store.bookmarks()).single.id, outer);
      expect((await store.bookmarks(parentId: outer)).single.id, inner);
    });

    test('删文件夹级联删全部后代，每条写墓碑（itemKey = uid）', () async {
      final int f = await store.addFolder(title: 'F'); // uid-0
      final int sub = await store.addFolder(title: 'Sub', parentId: f); // uid-1
      await store.addBookmark(
        title: 'x',
        url: Uri.parse('https://x/'),
        parentId: sub,
      ); // uid-2
      final int keep = await store.addBookmark(
        title: 'keep',
        url: Uri.parse('https://k/'),
      ); // uid-3
      now = 7000;
      await store.deleteBookmark(f);

      expect((await store.bookmarks()).single.id, keep);
      expect(await db.getAllWebBrowserBookmarks(), hasLength(1));
      expect(await tombstonesOf(SyncTombstoneKind.webbookmark), <String, int>{
        'uid-0': 7000,
        'uid-1': 7000,
        'uid-2': 7000,
      });
    });
  });

  group('会话 / 最近关闭', () {
    test('saveSession 整份覆盖并保序，loadSession 还原激活标签', () async {
      expect(await store.loadSession(), isNull);
      await store.saveSession(
        WebBrowserSession(
          tabs: <WebBrowserSessionTab>[
            WebBrowserSessionTab(
              id: 't1',
              url: Uri.parse('https://1/'),
              title: '1',
            ),
            WebBrowserSessionTab(
              id: 't2',
              url: Uri.parse('https://2/'),
              title: '2',
            ),
          ],
          activeTabId: 't2',
        ),
      );
      await store.saveSession(
        WebBrowserSession(
          tabs: <WebBrowserSessionTab>[
            WebBrowserSessionTab(
              id: 't3',
              url: Uri.parse('https://3/'),
              title: '3',
            ),
            WebBrowserSessionTab(
              id: 't1',
              url: Uri.parse('https://1/'),
              title: '1',
            ),
          ],
          activeTabId: 't1',
        ),
      );
      final WebBrowserSession s = (await store.loadSession())!;
      expect(s.tabs.map((WebBrowserSessionTab t) => t.id), <String>[
        't3',
        't1',
      ]);
      expect(s.activeTabId, 't1');

      await store.saveSession(
        const WebBrowserSession(
          tabs: <WebBrowserSessionTab>[],
          activeTabId: null,
        ),
      );
      expect(await store.loadSession(), isNull);
    });

    test('最近关闭最多 25 条、最新在前、pop 取最新', () async {
      for (int i = 0; i < 30; i++) {
        await store.pushClosedTab(
          WebBrowserClosedTab(
            url: Uri.parse('https://c$i/'),
            title: 'c$i',
            closedAt: DateTime.fromMillisecondsSinceEpoch(i),
            index: i,
          ),
        );
      }
      final List<WebBrowserClosedTab> list = await store.closedTabs();
      expect(list, hasLength(kWebBrowserClosedTabsLimit));
      expect(list.first.title, 'c29');
      expect(list.last.title, 'c5');

      final WebBrowserClosedTab popped = (await store.popClosedTab())!;
      expect(popped.title, 'c29');
      expect(popped.index, 29);
      expect(await store.closedTabs(), hasLength(24));
    });
  });

  group('下载记录', () {
    test('增改查删，状态往返', () async {
      final int id = await store.addDownload(
        WebBrowserDownload(
          id: 0,
          url: Uri.parse('https://dl/file.zip'),
          fileName: 'file.zip',
          startedAt: DateTime.fromMillisecondsSinceEpoch(10),
          mimeType: 'application/zip',
        ),
      );
      await store.updateDownload(
        id,
        receivedBytes: 50,
        totalBytes: 100,
        state: WebBrowserDownloadState.completed,
        savedPath: '/tmp/file.zip',
      );
      final WebBrowserDownload d = (await store.downloads()).single;
      expect(d.id, id);
      expect(d.receivedBytes, 50);
      expect(d.totalBytes, 100);
      expect(d.state, WebBrowserDownloadState.completed);
      expect(d.savedPath, '/tmp/file.zip');
      expect(d.mimeType, 'application/zip');

      await store.deleteDownload(id);
      expect(await store.downloads(), isEmpty);
    });
  });

  test('写入后 notifyListeners', () async {
    int calls = 0;
    store.addListener(() => calls++);
    await store.recordVisit(url: Uri.parse('https://a/'), title: 'a');
    expect(calls, greaterThan(0));
    final int before = calls;
    await store.addFolder(title: 'F');
    expect(calls, greaterThan(before));
  });
}
