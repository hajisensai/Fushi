import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/add_to_collection_dialog.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/mining/galgame_library.dart' show GalgameEntry;
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show isGameCollectionMemberVisible;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:material_ui/material_ui.dart';

/// BUG-3361（反馈 ow9_1sxU16「合集数和实际合集数量不一致」）：「加入合集」弹窗按
/// 成员表**原始行数**写「N 项」，合集详情页只画得出库页上真实存在的成员。成员表
/// 没有指向媒体的外键——删掉的书、配对有声书的伴生行都会留行——于是弹窗写「10 项」、
/// 点进去只有 6 本。修复后弹窗按调用方给的可见性判据计数（与详情页同一判据）。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<({FushiDatabase db, String visibleUid, String targetUid})>
  seed() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    Future<String> book(String key) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/tmp/$key.epub',
          extractDir: '/tmp',
          chapterCount: 1,
          chaptersJson: '["a"]',
          importedAt: 0,
          format: const Value<String>('epub'),
        ),
      );
      return (await db.resolveEpubBookUid(key))!;
    }

    final String visibleUid = await book('vol1');
    final String targetUid = await book('vol6');
    final int col = await db.createMediaCollection('やはり俺の青春');
    await db.addToCollection(col, MediaKind.epub, visibleUid);
    // 画不出来的行：已删除的书（孤儿 uid）与配对有声书的伴生 srt 行。
    await db.addToCollection(col, MediaKind.epub, 'deleted-book-uid');
    await db.addToCollection(col, MediaKind.srt, 'srtbook_epub_vol1');
    return (db: db, visibleUid: visibleUid, targetUid: targetUid);
  }

  Future<void> openDialog(
    WidgetTester tester,
    FushiDatabase db,
    String entryKey,
    CollectionMemberVisibility? isMemberVisible,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showAddToCollectionDialog(
                  context: context,
                  database: db,
                  mediaType: MediaKind.epub,
                  entryKey: entryKey,
                  isMemberVisible: isMemberVisible,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('弹窗成员数只数库页画得出来的成员（与详情页同口径）', (WidgetTester tester) async {
    late ({FushiDatabase db, String visibleUid, String targetUid}) s;
    await tester.runAsync(() async => s = await seed());
    await openDialog(
      tester,
      s.db,
      s.targetUid,
      (String mediaType, String entryKey) =>
          mediaType == MediaKind.epub.dbValue && entryKey == s.visibleUid,
    );
    expect(find.text(t.series_item_count(n: 1)), findsOneWidget);
    expect(find.text(t.series_item_count(n: 3)), findsNothing);
  });

  testWidgets('不给判据时保持原始行数（调用方没有可见性判据的旧行为）', (WidgetTester tester) async {
    late ({FushiDatabase db, String visibleUid, String targetUid}) s;
    await tester.runAsync(() async => s = await seed());
    await openDialog(tester, s.db, s.targetUid, null);
    expect(find.text(t.series_item_count(n: 3)), findsOneWidget);
  });

  test('书架 / 游戏库把详情页同一判据交给「加入合集」与「移到其他合集」（源码守卫）', () {
    final String shelf = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_history/books.part.dart',
    ).readAsStringSync();
    final String games = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();
    expect(
      'isMemberVisible: _isCollectionMemberVisible'.allMatches(shelf).length,
      2,
      reason: '书卡「加入合集」+ 合集详情页（移到其他合集）',
    );
    expect(
      books.contains('isMemberVisible: _isCollectionMemberVisible'),
      isTrue,
      reason: '字幕书卡「加入合集」',
    );
    expect(
      'isMemberVisible: _isGameCollectionMemberVisible'
          .allMatches(games)
          .length,
      2,
    );
    expect(
      shelf.contains('_resolveCollectionMember(mediaType, entryKey);'),
      isTrue,
      reason: '成员卡与可见性判据必须共用同一个解析函数，不得各写一份',
    );
  });

  // ── 跨域补漏：视频库「加入合集」与游戏详情页「加入合集」 ──────────────────

  group('视频域：弹窗计数与合集详情页 loadCollectionEpisodeSlots 同口径', () {
    late FushiDatabase db;
    late VideoBookRepository repo;
    late int col;

    RemoteVideoInfo episode(String id, int ep) => RemoteVideoInfo(
      id: id,
      title: 'Frieren S01E${ep.toString().padLeft(2, '0')} Ep $ep',
    );

    // 远端清单：jf-1 与本地第 1 集是同一集（归并）、jf-3 只在远端。
    final List<RemoteVideoInfo> remoteList = <RemoteVideoInfo>[
      episode('jf-1', 1),
      episode('jf-3', 3),
    ];

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = VideoBookRepository(db);
      col = await db.createMediaCollection('Frieren');
      for (final int ep in <int>[1, 2]) {
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>('video/local$ep'),
            title: Value<String>('Frieren - 0$ep'),
            videoPath: Value<String>('/anime/Frieren/Frieren - 0$ep.mkv'),
          ),
        );
      }
      for (final String key in <String>[
        'video/local1',
        'video/local2',
        'jf-1', // 本地第 1 集的远端副本：详情页并成一槽
        'jf-3', // 只在远端：在线时占一槽
        'video/deleted', // 已删视频的孤儿行
      ]) {
        await db.addToCollection(col, MediaKind.video, key);
      }
      // 混合合集里的书行：视频详情页不画。
      await db.addToCollection(col, MediaKind.epub, 'some-book');
    });

    tearDown(() => db.close());

    Future<int> visibleCount({required bool online}) async {
      final List<VideoBookRow> local = await repo.listForShelf();
      final List<RemoteVideoInfo> remote = online
          ? remoteList
          : const <RemoteVideoInfo>[];
      final Map<String, int> primary = <String, int>{
        for (final MediaCollectionItemRow item
            in await db.getAllCollectionItems())
          if (item.mediaType == MediaKind.video.dbValue)
            MediaKind.video.compositeKey(item.entryKey): item.collectionId,
      };
      final Map<int, int> counts = countVisibleCollectionMembers(
        await db.getAllCollectionItems(),
        videoCollectionMemberVisibility(
          localBookUids: <String>{
            for (final VideoBookRow b in local) b.bookUid,
          },
          remoteOnlyIds: <String>{for (final RemoteVideoInfo v in remote) v.id},
          mirroredRemoteIds: remoteEpisodesMirroredLocally(
            local: local,
            remote: remote,
            collectionOfEntry: (String key) =>
                primary[MediaKind.video.compositeKey(key)],
          ),
        ),
      );
      return counts[col] ?? 0;
    }

    test('在线：本地 2 + 远端独有 1 = 3，与详情页槽数一致（原始行数 6）', () async {
      final List<CollectionEpisodeSlot> slots =
          await loadCollectionEpisodeSlots(
            repository: repo,
            collectionId: col,
            loadRemoteVideos: () async => remoteList,
          );
      expect(slots.length, 3);
      expect(await visibleCount(online: true), slots.length);
      expect(
        countVisibleCollectionMembers(
          await db.getAllCollectionItems(),
          null,
        )[col],
        6,
      );
    });

    test('离线 / 无远端上下文：远端占位行不数，与详情页一致', () async {
      final List<CollectionEpisodeSlot> slots =
          await loadCollectionEpisodeSlots(repository: repo, collectionId: col);
      expect(slots.length, 2);
      expect(await visibleCount(online: false), slots.length);
    });
  });

  test('游戏域：孤儿引用与混合合集里的非 game 行不算可见成员', () {
    final List<GalgameEntry> games = <GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'g1',
        exePath: 'C:/g1/g1.exe',
        workdir: 'C:/g1',
        addedAt: DateTime(2026),
      ),
    ];
    bool visible(String mediaType, String key) => isGameCollectionMemberVisible(
      games: games,
      mediaType: mediaType,
      entryKey: key,
    );
    expect(visible(MediaKind.game.dbValue, 'g1'), isTrue);
    expect(visible(MediaKind.game.dbValue, 'removed-game'), isFalse);
    expect(visible(MediaKind.epub.dbValue, 'g1'), isFalse);
  });

  test('视频库 / 游戏详情页「加入合集」接上可见判据（源码守卫）', () {
    final String video = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    final String gameDetail = File(
      'lib/src/pages/implementations/galgame_detail_page.dart',
    ).readAsStringSync();
    final String games = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();
    expect(
      video.contains('isMemberVisible: _videoCollectionMemberVisibility()'),
      isTrue,
    );
    expect(
      video.contains('return videoCollectionMemberVisibility('),
      isTrue,
      reason: '视频判据必须走 collection_episode_slot.dart 的共享实现',
    );
    expect(
      RegExp(
        r'isMemberVisible: \(String mediaType, String entryKey\) =>\s+'
        r'isGameCollectionMemberVisible\(',
      ).hasMatch(gameDetail),
      isTrue,
    );
    expect(
      games.contains('isGameCollectionMemberVisible(\n        games: _games,'),
      isTrue,
      reason: '游戏库与游戏详情页共用同一判据，不得各写一份',
    );
  });
}
