import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

/// 游戏库仓储守卫：`galgameEntryFromRow` 的合成（纯函数）+ 仓储对 Drift 表的
/// 增删改与聚合读取。真相源自 v54 起是表，不再是偏好 JSON。
void main() {
  GalgameRow row({
    String id = 'g1',
    String name = 'game',
    String? customDataJson,
    int playStatus = 0,
    String? releaseDate,
    String? primarySource,
    String launchArgs = '',
    String upscalingMode = '',
  }) {
    return GalgameRow(
      id: id,
      name: name,
      exePath: r'Z:\g\game.exe',
      workdir: r'Z:\g',
      launchArgs: launchArgs,
      upscalingMode: upscalingMode,
      addedAt: DateTime(2026).millisecondsSinceEpoch,
      playStatus: playStatus,
      primarySource: primarySource,
      releaseDate: releaseDate,
      customDataJson: customDataJson,
      sortOrder: 0,
    );
  }

  GalgameSourceRow sourceRow(
    GalgameMetadataSource source,
    GalgameMetadataDraft draft, {
    String gameId = 'g1',
  }) {
    return GalgameSourceRow(
      gameId: gameId,
      source: source.key,
      externalId: draft.externalId,
      dataJson: draft.encode(),
      score: draft.score,
      rank: draft.rank,
      fetchedAt: 0,
    );
  }

  group('galgameEntryFromRow（纯函数）', () {
    test('无源无覆盖层时回落本地字段', () {
      final GalgameEntry entry = galgameEntryFromRow(row());
      expect(entry.displayName, 'game');
      expect(entry.playStatus, GalgamePlayStatus.unset);
      expect(entry.tags, isEmpty);
      expect(entry.totalPlaySeconds, 0);
      expect(entry.sessionCount, 0);
      expect(entry.lastPlayedMs, 0);
      expect(entry.hasLocalExe, isTrue);
    });

    test('多源按契约 §2.4 合并：developer 反向优先，标签取并集', () {
      final GalgameEntry entry = galgameEntryFromRow(
        row(),
        sources: <GalgameSourceRow>[
          sourceRow(
            GalgameMetadataSource.bgm,
            const GalgameMetadataDraft(
              name: 'bgm name',
              nameCn: '中文名',
              developer: 'bgm dev',
              tags: <String>['a'],
              score: 8.0,
              rank: 42,
            ),
          ),
          sourceRow(
            GalgameMetadataSource.vndb,
            const GalgameMetadataDraft(
              name: 'vndb name',
              developer: 'vndb dev',
              tags: <String>['b'],
              averageHours: 30,
            ),
          ),
        ],
      );
      expect(entry.displayName, '中文名');
      expect(entry.developer, 'vndb dev');
      expect(entry.tags, <String>['a', 'b']);
      expect(entry.siteScore, 8.0);
      expect(entry.metadata.rank, 42);
      expect(entry.metadata.averageHours, 30);
    });

    test('用户改名压过刮削中文名', () {
      final GalgameEntry entry = galgameEntryFromRow(
        row(customDataJson: const GalgameCustomData(name: '我的名字').encode()),
        sources: <GalgameSourceRow>[
          sourceRow(GalgameMetadataSource.bgm,
              const GalgameMetadataDraft(nameCn: '中文名')),
        ],
      );
      expect(entry.displayName, '我的名字');
    });

    test('未知 source 值被跳过而不是崩', () {
      final GalgameEntry entry = galgameEntryFromRow(
        row(),
        sources: <GalgameSourceRow>[
          const GalgameSourceRow(
            gameId: 'g1',
            source: 'ymgal',
            dataJson: '{"name":"future"}',
            fetchedAt: 0,
          ),
        ],
      );
      expect(entry.metadata.name, isNull);
    });

    test('游玩聚合落到视图字段', () {
      final GalgameEntry entry =
          galgameEntryFromRow(row(), playTotals: (7200, 3, 1750000000000));
      expect(entry.totalPlaySeconds, 7200);
      expect(entry.sessionCount, 3);
      expect(entry.lastPlayedMs, 1750000000000);
    });

    test('companion 往返：空覆盖层写 null 而不是 {}', () {
      final GalgameEntry entry = galgameEntryFromRow(row());
      final GalgamesCompanion companion = galgamesCompanionFromEntry(entry);
      expect(companion.customDataJson.value, isNull);
      final GalgameEntry withCustom = entry.copyWith(
        customData: const GalgameCustomData(userRating: 9),
        playStatus: GalgamePlayStatus.playing,
      );
      final GalgamesCompanion companion2 =
          galgamesCompanionFromEntry(withCustom);
      expect(companion2.customDataJson.value, contains('userRating'));
      expect(companion2.playStatus.value, 3);
    });
  });

  group('GalgameRepository（内存 DB）', () {
    late HibikiDatabase db;
    late GalgameRepository repo;

    setUp(() {
      // 生产开库在 `_openWithRecovery` 里 `PRAGMA foreign_keys = ON`；内存测试库
      // 必须自己打开，否则 cascade 断言测的是一个 app 里不存在的行为。
      db = HibikiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      repo = GalgameRepository(db);
    });

    tearDown(() => db.close());

    GalgameEntry newEntry(String id, {String name = 'game'}) => GalgameEntry(
          id: id,
          name: name,
          exePath: 'Z:${id}game.exe',
          workdir: 'Z:$id',
          addedAt: DateTime(2026, 1, int.parse(id.substring(1))),
        );

    test('setGames 整表覆写：缺失 id 视为删除', () async {
      await repo.setGames(<GalgameEntry>[newEntry('g1'), newEntry('g2')]);
      expect(repo.games.map((GalgameEntry g) => g.id), <String>['g1', 'g2']);

      await repo.setGames(<GalgameEntry>[newEntry('g2')]);
      expect(repo.games.map((GalgameEntry g) => g.id), <String>['g2']);
    });

    test('addAll / remove / setPlayStatus / setCustomData / setCoverPath',
        () async {
      await repo.addAll(<GalgameEntry>[newEntry('g1')]);
      expect(repo.byId('g1'), isNotNull);

      await repo.setPlayStatus('g1', GalgamePlayStatus.playing);
      expect(repo.byId('g1')!.playStatus, GalgamePlayStatus.playing);

      await repo.setCustomData(
          'g1', const GalgameCustomData(name: '改名', userRating: 8.5));
      expect(repo.byId('g1')!.displayName, '改名');
      expect(repo.byId('g1')!.userRating, 8.5);

      await repo.setCoverPath('g1', r'Z:\cover.png');
      expect(repo.byId('g1')!.coverPath, r'Z:\cover.png');
      await repo.setCoverPath('g1', '');
      expect(repo.byId('g1')!.coverPath, isNull);

      await repo.remove('g1');
      expect(repo.games, isEmpty);
    });

    test('saveScrapeResult 落源快照 + 回写主显示源与发行日', () async {
      await repo.addAll(<GalgameEntry>[newEntry('g1')]);
      await repo.saveScrapeResult(
        gameId: 'g1',
        source: GalgameMetadataSource.bgm,
        draft: const GalgameMetadataDraft(
          name: 'name',
          nameCn: '中文名',
          releaseDate: '2013-05-24',
          score: 8.1,
          rank: 12,
          externalId: '4885',
        ),
        primarySource: GalgameMetadataSource.bgm.key,
      );
      final GalgameEntry entry = repo.byId('g1')!;
      expect(entry.displayName, '中文名');
      expect(entry.effectiveReleaseDate, '2013-05-24');
      expect(entry.primarySource, 'bgm');
      expect(entry.siteScore, 8.1);

      final List<GalgameSourceRow> sources = await repo.sourcesOf('g1');
      expect(sources.single.externalId, '4885');
      expect(sources.single.rank, 12);

      await repo.removeSource('g1', GalgameMetadataSource.bgm);
      expect(await repo.sourcesOf('g1'), isEmpty);
      // 源没了，展示名回落本地默认名。
      expect(repo.byId('g1')!.displayName, 'game');
    });

    test('会话聚合：总时长 / 次数 / 最后游玩 + 删单条', () async {
      await repo.addAll(<GalgameEntry>[newEntry('g1')]);
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: 1000,
          endMs: 61000,
          durationSeconds: 60,
          dateKey: '2026-07-01',
        ),
      );
      final int second = await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: 100000,
          endMs: 400000,
          durationSeconds: 300,
          dateKey: '2026-07-02',
        ),
      );
      await repo.load();
      expect(repo.byId('g1')!.totalPlaySeconds, 360);
      expect(repo.byId('g1')!.sessionCount, 2);
      expect(repo.byId('g1')!.lastPlayedMs, 400000);

      final Map<String, int> daily = await repo.dailySeconds(
        'g1',
        fromDateKey: '2026-07-01',
        toDateKey: '2026-07-31',
      );
      expect(daily['2026-07-01'], 60);
      expect(daily['2026-07-02'], 300);

      await repo.deleteSession(second);
      expect(repo.byId('g1')!.totalPlaySeconds, 60);
      expect(repo.byId('g1')!.sessionCount, 1);
    });

    test('remove 删游戏同时清其全部合集引用；移空的合集自删', () async {
      await repo.addAll(<GalgameEntry>[newEntry('g1'), newEntry('g2')]);
      // 混合合集：g1 + g2；另一个合集只有 g1。
      final int mixed = await db.createMediaCollection('mixed');
      await db.addToCollection(mixed, MediaKind.game, 'g1');
      await db.addToCollection(mixed, MediaKind.game, 'g2');
      final int solo = await db.createMediaCollection('solo');
      await db.addToCollection(solo, MediaKind.game, 'g1');

      await repo.remove('g1');

      // 混合合集：g1 引用行消失，成员数从 2 回到 1（不虚高）。
      final List<MediaCollectionItemRow> rest =
          await db.getCollectionItems(mixed);
      expect(
        rest.map((MediaCollectionItemRow m) => m.entryKey).toList(),
        <String>['g2'],
      );
      // 只剩 g1 的合集被清空后自删（与书/视频同语义）。
      expect(await db.getMediaCollectionById(solo), isNull);
    });

    test('setGames 整表覆写删掉的 id 也清合集引用，不留孤儿成员', () async {
      await repo.setGames(<GalgameEntry>[newEntry('g1'), newEntry('g2')]);
      final int c = await db.createMediaCollection('c');
      await db.addToCollection(c, MediaKind.game, 'g1');
      await db.addToCollection(c, MediaKind.game, 'g2');

      await repo.setGames(<GalgameEntry>[newEntry('g2')]);

      expect(
        (await db.getCollectionItems(c))
            .map((MediaCollectionItemRow m) => m.entryKey)
            .toList(),
        <String>['g2'],
      );
      // 全库无任何 g1 孤儿引用。
      expect(
        (await db.getAllCollectionItems())
            .where((MediaCollectionItemRow m) => m.entryKey == 'g1'),
        isEmpty,
      );
    });

    test('删游戏时源快照与会话经 FK cascade 连带清理', () async {
      await repo.addAll(<GalgameEntry>[newEntry('g1')]);
      await repo.saveScrapeResult(
        gameId: 'g1',
        source: GalgameMetadataSource.vndb,
        draft: const GalgameMetadataDraft(name: 'x', externalId: 'v1'),
        primarySource: GalgameMetadataSource.vndb.key,
      );
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: 1,
          endMs: 2,
          durationSeconds: 1,
          dateKey: '2026-07-01',
        ),
      );
      await repo.remove('g1');
      expect(await repo.sourcesOf('g1'), isEmpty);
      expect(await repo.sessions('g1'), isEmpty);
    });
  });
}
