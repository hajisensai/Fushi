import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_episode_binding_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 集级 UserVerified（Shoko）：集卡菜单「手动指定季集」→ 选季 / 集 → 写覆盖表 +
/// 立刻改绑分集行；再打开可清除。
void main() {
  Future<(int workId, int seasonId)> seed(FushiDatabase db) async {
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('f'),
        title: Value<String>('Show 03'),
        videoPath: Value<String>('D:/Show/Show 03.mkv'),
      ),
    );
    final int collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'f');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
    final int seasonId = await db.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
        workId: workId,
        seasonNumber: 1,
        updatedAt: 1,
      ),
    );
    for (int n = 1; n <= 3; n++) {
      await db.upsertVideoMetadataEpisode(
        VideoMetadataEpisodesCompanion.insert(
          seasonId: seasonId,
          episodeNumber: n,
          title: Value<String?>('Title $n'),
          bookUid: Value<String?>(n == 3 ? 'f' : null),
          updatedAt: 1,
        ),
      );
    }
    return (workId, seasonId);
  }

  Future<bool?> open(WidgetTester tester, FushiDatabase db, int workId) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await pinVideoEpisodeBinding(
                  context: context,
                  database: db,
                  workId: workId,
                  bookUid: 'f',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('picking an episode writes the pin and rebinds the row now', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final (int workId, int seasonId) = await seed(db);

    await open(tester, db, workId);
    expect(find.text(t.collection_episode_link_hint), findsOneWidget);
    // 初值是当前绑定的第 3 集；改成第 2 集。
    await tester.tap(
      find.byKey(const ValueKey<String>('video-episode-link-episode')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .text('${t.collection_episode_link_episode(number: 2)} · Title 2')
          .last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    final VideoEpisodeBindingOverrideRow? pin = await db
        .getVideoEpisodeBindingOverride('f');
    expect(pin?.seasonNumber, 1);
    expect(pin?.episodeNumber, 2);
    final Map<int, String?> bound = <int, String?>{
      for (final VideoMetadataEpisodeRow row
          in await db.getVideoMetadataEpisodes(seasonId))
        row.episodeNumber: row.bookUid,
    };
    expect(bound, <int, String?>{1: null, 2: 'f', 3: null});
    expect(
      (await db.getVideoMetadataEpisodesByBook('f')).single.anidbMatchRating,
      'userVerified',
    );

    // 再打开：有「清除手动指定」；清掉后覆盖表空，行绑定保持（下次刮削回自动）。
    await open(tester, db, workId);
    await tester.tap(find.text(t.collection_episode_link_clear));
    await tester.pumpAndSettle();
    expect(await db.getVideoEpisodeBindingOverride('f'), isNull);
    expect(
      (await db.getVideoMetadataEpisodesByBook('f')).single.episodeNumber,
      2,
    );
  });

  testWidgets('no scraped seasons → toast, no dialog', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('f'),
        title: Value<String>('Show 03'),
        videoPath: Value<String>('D:/Show/Show 03.mkv'),
      ),
    );
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('f'),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
    final bool? result = await open(tester, db, workId);
    expect(result, isFalse);
    expect(find.text(t.collection_episode_link_hint), findsNothing);
  });
}
