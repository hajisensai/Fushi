import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/activity_feed.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/utils/misc/dashboard_remote_merge.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 「继续/活动也走 hibiki 互联」守卫：
///
/// 1. host listBooks 内联阅读进度（percent 与本地首页同算 = MediaItems.position/
///    duration；时刻 = reader_positions.updatedAt），additive 字段 roundtrip。
/// 2. host `/api/library/activity` 端点下发最近活动事件；老 host（无库服务）404，
///    client `listRemoteActivity` 优雅降级空表。
/// 3. 纯函数混排：远端「继续」候选只补本地没有的条目；活动混排按时刻倒序截断；
///    聚合按设备来源分组不合并且带设备标签（「标明设备来源」）。
AppModelLibraryHostService _makeService({
  required HibikiDatabase db,
  required Directory tmp,
}) {
  final Directory dictRoot = Directory(p.join(tmp.path, 'dicts'))
    ..createSync(recursive: true);
  return AppModelLibraryHostService(
    db: db,
    dictionaryResourceRoot: dictRoot,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    videoSubtitleLangCode: 'ja',
  );
}

ActivityEventRow _row({
  required String title,
  required int timestampMs,
  String eventType = 'read',
  String dateKey = '2026-07-20',
  int id = 1,
}) =>
    ActivityEventRow(
      id: id,
      eventType: eventType,
      mediaType: 'book',
      title: title,
      mediaKey: null,
      dateKey: dateKey,
      timestampMs: timestampMs,
      durationMs: 60000,
      charsDelta: 100,
    );

void main() {
  group('host listBooks 内联阅读进度', () {
    late Directory tmp;
    late HibikiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hbk_dash_feed');
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('在读书带 percent + updatedAt；未读书为 0', () async {
      final Directory extract = Directory(p.join(tmp.path, 'b1'))
        ..createSync(recursive: true);
      Future<void> seed(String key) => db.insertEpubBook(
            EpubBooksCompanion.insert(
              bookKey: key,
              title: key,
              epubPath: p.join(extract.path, '$key.epub'),
              extractDir: extract.path,
              chapterCount: 1,
              chaptersJson: '["ch1"]',
              importedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      await seed('reading');
      await seed('untouched');
      await db.upsertMediaItem(MediaItemsCompanion.insert(
        mediaIdentifier: 'hoshi://book/reading',
        title: 'reading',
        mediaTypeIdentifier: 'reader',
        mediaSourceIdentifier: 'hibiki',
        uniqueKey: 'reader/hibiki/hoshi://book/reading',
        position: 760,
        duration: 1000,
        canDelete: true,
        canEdit: false,
      ));
      await db.upsertReaderPosition(ReaderPositionsCompanion.insert(
        bookKey: 'reading',
        sectionIndex: 3,
        normCharOffset: 7600,
        updatedAt: 123456789,
      ));

      final List<RemoteBookInfo> books =
          await _makeService(db: db, tmp: tmp).listBooks();
      final RemoteBookInfo reading =
          books.singleWhere((RemoteBookInfo b) => b.title == 'reading');
      expect(reading.progressPercent, 76,
          reason: 'percent 必须与本地首页同算（position/duration）');
      expect(reading.progressUpdatedAtMs, 123456789);
      final RemoteBookInfo untouched =
          books.singleWhere((RemoteBookInfo b) => b.title == 'untouched');
      expect(untouched.progressPercent, 0);
      expect(untouched.progressUpdatedAtMs, 0);

      // additive roundtrip：老 client 忽略、新 client 解回同值。
      final RemoteBookInfo decoded = RemoteBookInfo.fromJson(reading.toJson());
      expect(decoded.progressPercent, 76);
      expect(decoded.progressUpdatedAtMs, 123456789);
      expect(RemoteBookInfo.fromJson(untouched.toJson()).progressPercent, 0);
    });
  });

  group('activity 端点', () {
    const String token = 'dash-feed-token';

    test('GET /api/library/activity 下发 host 最近事件（JSON roundtrip）', () async {
      final HibikiDatabase hostDb =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(hostDb.close);
      final Directory tmp = Directory.systemTemp.createTempSync('hbk_act_srv');
      addTearDown(() => tmp.delete(recursive: true));
      await hostDb.addActivityEvent(
        eventType: 'watch',
        mediaType: 'video',
        title: 'S01E01',
        dateKey: '2026-07-20',
        timestampMs: 1700000000000,
        mediaKey: 'video/s01e01',
        durationMs: 1200000,
      );
      final HibikiSyncServer server = HibikiSyncServer(
        syncDataDir: p.join(tmp.path, 'sync'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _makeService(db: hostDb, tmp: tmp),
      );
      await server.start();
      addTearDown(server.stop);

      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/library/activity'));
      req.headers.set('authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      final List<dynamic> arr =
          jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
      c.close(force: true);
      expect(arr, hasLength(1));
      final RemoteActivityEvent e = RemoteActivityEvent.fromJson(
          (arr.single as Map).cast<String, Object?>());
      expect(e.eventType, 'watch');
      expect(e.title, 'S01E01');
      expect(e.timestampMs, 1700000000000);
      expect(e.durationMs, 1200000);
    });

    test('老 host 无端点 → client listRemoteActivity 降级空表', () async {
      final HibikiSyncServer server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_act_old').path,
        port: 0,
        token: token,
        allowLan: false,
      );
      await server.start();
      addTearDown(server.stop);

      final HibikiDatabase clientDb =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(clientDb.close);
      final SyncRepository repo = SyncRepository(clientDb);
      await repo.setHibikiClientUrls(<HibikiClientUrl>[
        HibikiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
      ]);
      await repo.setHibikiClientToken(token);
      final HibikiClientSyncBackend backend = HibikiClientSyncBackend.withProbe(
          (String url, String tok) async => true);
      await backend.restoreAuth(repo);

      expect(await backend.listRemoteActivity(), isEmpty,
          reason: '老 host 404 必须优雅降级，不能让首页互联加载抛异常');
    });
  });

  group('纯函数混排', () {
    test('remoteContinueCandidates：只补本地没有的在读书/在看视频', () {
      final List<RemoteContinueCandidate> out = remoteContinueCandidates(
        localBookKeys: <String>{'local-book'},
        localVideoUids: <String>{'video/local'},
        remoteBooks: <RemoteBookInfo>[
          const RemoteBookInfo(
              title: 'remote-only',
              hasContent: true,
              bookKey: 'remote-only',
              progressPercent: 42,
              progressUpdatedAtMs: 5),
          const RemoteBookInfo(
              title: 'local-book',
              hasContent: true,
              bookKey: 'local-book',
              progressPercent: 50,
              progressUpdatedAtMs: 9),
          const RemoteBookInfo(
              title: 'finished',
              hasContent: true,
              bookKey: 'finished',
              progressPercent: 100),
          const RemoteBookInfo(
              title: 'untouched', hasContent: true, bookKey: 'untouched'),
        ],
        remoteVideos: <RemoteVideoInfo>[
          const RemoteVideoInfo(
              id: 'video/remote',
              title: 'R',
              positionMs: 90000,
              positionUpdatedAtMs: 7),
          const RemoteVideoInfo(
              id: 'video/local', title: 'L', positionMs: 90000),
          const RemoteVideoInfo(id: 'video/unwatched', title: 'U'),
        ],
      );
      expect(out.map((RemoteContinueCandidate c) => c.id),
          <String>['remote-only', 'video/remote'],
          reason: '本地已有同 key/uid 以本地为准；读完/未动过的不进「继续」');
      expect(out.first.percent, 42);
      expect(out.first.recentMs, 5);
    });

    test('mergeActivityEvents：按时刻倒序混排并截断', () {
      final List<ActivityEventRow> merged = mergeActivityEvents(
        <ActivityEventRow>[_row(title: 'a', timestampMs: 100)],
        <ActivityEventRow>[
          _row(title: 'b', timestampMs: 300, id: 0),
          _row(title: 'c', timestampMs: 200, id: 0),
        ],
        limit: 2,
      );
      expect(merged.map((ActivityEventRow e) => e.title), <String>['b', 'c']);
    });

    test('聚合按设备来源分组：远端与本机同标题不合并、各带标签', () {
      final ActivityEventRow local = _row(title: '同一本书', timestampMs: 100);
      final ActivityEventRow remote =
          _row(title: '同一本书', timestampMs: 200, id: 0);
      final Set<ActivityEventRow> remoteSet = Set<ActivityEventRow>.identity()
        ..add(remote);
      final List<ActivityDateGroup> groups = aggregateActivityEvents(
        <ActivityEventRow>[local, remote],
        sourceDeviceOf: (ActivityEventRow e) =>
            remoteSet.contains(e) ? '客厅电脑' : null,
      );
      expect(groups, hasLength(1));
      final List<ActivityEntry> entries = groups.single.entries;
      expect(entries, hasLength(2), reason: '标明设备来源后双端 session 不得混并成一条');
      expect(entries.map((ActivityEntry e) => e.sourceDevice).toSet(),
          <String?>{null, '客厅电脑'});
      // 不带 sourceDeviceOf 时保持旧行为：同键合并为一条。
      expect(
          aggregateActivityEvents(<ActivityEventRow>[local, remote])
              .single
              .entries,
          hasLength(1));
    });
  });
}
