import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// v125 内置浏览器历史 / 书签的备份合并导入（真实 ATTACH + [BackupMergeEngine.merge]）：
/// 历史按 url 并集、书签按 uid LWW 且父子按 uid 还原；本机删过的不从旧备份复活；
/// 会话 / 最近关闭 / 下载是设备本地，绝不并入。
void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late FushiDatabase target;
  setUp(() => target = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => target.close());

  Future<String> buildBackup(
    Future<void> Function(FushiDatabase db) seed,
  ) async {
    final Directory dir = await Directory.systemTemp.createTemp('web_merge_');
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase src = FushiDatabase(dir.path);
    await seed(src);
    await src.close();
    return p.join(dir.path, 'fushi.db');
  }

  Future<void> attachAndMerge(String srcPath) async {
    final String safe = srcPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    try {
      await BackupMergeEngine(target).merge();
    } finally {
      await target.customStatement('DETACH DATABASE mergesrc');
    }
  }

  test('历史并集、书签树按 uid 还原、设备本地表不并入、重复合并幂等', () async {
    final String src = await buildBackup((FushiDatabase db) async {
      await db.recordWebBrowserVisit(
        url: 'https://a/',
        title: 'A',
        visitedAt: 10,
      );
      await db.recordWebBrowserVisit(
        url: 'https://a/',
        title: 'A',
        visitedAt: 20,
      );
      final int folder = await db.insertWebBrowserBookmark(
        uid: 'f',
        title: 'Folder',
        url: null,
        parentId: null,
        now: 5,
      );
      await db.insertWebBrowserBookmark(
        uid: 'c',
        title: 'Child',
        url: 'https://c/',
        parentId: folder,
        now: 6,
      );
      await db.replaceWebBrowserSession(
        <({String tabId, String url, String title})>[
          (tabId: 't', url: 'https://s/', title: 's'),
        ],
        activeTabId: 't',
      );
      await db.pushWebBrowserClosedTab(
        url: 'https://closed/',
        title: 'c',
        closedAt: 1,
        tabIndex: 0,
      );
    });
    await target.recordWebBrowserVisit(
      url: 'https://a/',
      title: 'Local',
      visitedAt: 30,
    );

    await attachAndMerge(src);
    await attachAndMerge(src);

    final WebBrowserHistoryRow a = (await target.getWebBrowserHistory()).single;
    expect(a.visitCount, 2, reason: '次数取大，不累加（重复合并幂等）');
    expect(a.lastVisitedAt, 30);
    expect(a.title, 'Local');

    final List<WebBrowserBookmarkRow> bms = await target
        .getAllWebBrowserBookmarks();
    expect(bms, hasLength(2));
    final WebBrowserBookmarkRow folder = bms.firstWhere(
      (WebBrowserBookmarkRow r) => r.uid == 'f',
    );
    final WebBrowserBookmarkRow child = bms.firstWhere(
      (WebBrowserBookmarkRow r) => r.uid == 'c',
    );
    expect(folder.url, isNull);
    expect(child.parentId, folder.id);

    expect(await target.getWebBrowserSession(), isEmpty);
    expect(await target.getWebBrowserClosedTabs(), isEmpty);
    expect(
      mergeSkippedDeviceLocalTableNames(),
      containsAll(<String>[
        'web_browser_session_tabs',
        'web_browser_closed_tabs',
        'web_browser_downloads',
      ]),
    );
  });

  test('本机删过的历史 / 书签不从旧备份复活', () async {
    final String src = await buildBackup((FushiDatabase db) async {
      await db.recordWebBrowserVisit(
        url: 'https://gone/',
        title: 'g',
        visitedAt: 10,
      );
      await db.insertWebBrowserBookmark(
        uid: 'dead',
        title: 'Dead',
        url: 'https://d/',
        parentId: null,
        now: 10,
      );
    });
    await target.clearWebBrowserHistory(deletedAt: 100);
    await target.writeSyncDeletionTombstone(
      SyncTombstoneKind.webbookmark.dbValue,
      'dead',
      100,
    );

    await attachAndMerge(src);

    expect(await target.getWebBrowserHistory(), isEmpty);
    expect(await target.getAllWebBrowserBookmarks(), isEmpty);
  });
}
