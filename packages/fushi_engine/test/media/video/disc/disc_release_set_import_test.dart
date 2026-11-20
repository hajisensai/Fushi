// 只有「全部播放」的蓝光剧集盘入库：按集建行、同一发布的几张盘并成一个合集、
// 存量「一卷一个条目」的迁移与清理、以及刮削计划拿到的连续集号。
// 设计见 docs/specs/2026-11-15-bluray-playitem-episodes.md。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/disc/disc_library_import.dart';
import 'package:fushi_engine/media/video/disc/disc_release_set.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../bluray/bluray_episode_fixture.dart';
import '../bluray/bluray_fixture.dart';

void main() {
  late FushiDatabase db;
  late Directory temp;
  late String disc1;
  late String disc2;
  late DiscLibraryImporter importer;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('fushi-disc-set-');
    disc1 = p.join(temp.path, 'Majo no Tabitabi [BDMV]', 'Disc 1');
    disc2 = p.join(temp.path, 'Majo no Tabitabi [BDMV]', 'Disc 2');
    writeEpisodicDisc(disc1, episodes: 6, discName: '魔女の旅々　上巻');
    writeEpisodicDisc(disc2, episodes: 6, discName: '魔女の旅々　下巻');
    importer = DiscLibraryImporter(db);
  });

  tearDown(() async {
    await db.close();
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄占用；临时目录留给系统清。
    }
  });

  Future<DiscLibraryImportReport> import(List<String> roots, {int? sourceId}) =>
      importer.importBlurayDiscs(
        roots,
        sourceId: sourceId,
        restoreDissolvedGroups: false,
      );

  /// 合集 [id] 的成员路径，按合集内顺序。
  Future<List<String>> memberPaths(int id) async => <String>[
    for (final MediaCollectionItemRow item in await db.getCollectionItems(id))
      (await db.getVideoBookByBookUid(item.entryKey))!.videoPath,
  ];

  List<String> allEpisodePaths() => <String>[
    for (int i = 1; i <= 6; i++) episodePath(disc1, i),
    for (int i = 1; i <= 6; i++) episodePath(disc2, i),
  ];

  test('分组：上巻 / 下巻并成一组，名字去卷标，按卷号排', () async {
    final List<BlurayDisc> discs = <BlurayDisc>[
      (await readBlurayDisc(disc2))!,
      (await readBlurayDisc(disc1))!,
    ];
    final BlurayReleaseSet set = planBlurayReleaseSets(discs).single;
    expect(set.episodic, isTrue);
    expect(set.name, '魔女の旅々');
    expect(set.discs.map((BlurayDisc d) => d.rootPath), <String>[disc1, disc2]);
  });

  test('卷标：上中下与数字卷号；没有盘内标题时取发布目录名', () async {
    expect(discVolumeNumber('魔女の旅々　下巻'), 3);
    expect(discVolumeNumber('Show Vol.2'), 2);
    expect(discVolumeNumber('Disc 10'), 10);
    expect(discVolumeNumber('最終楽章 前編'), isNull);

    final String plain1 = p.join(temp.path, 'Plain Show', 'Disc 1');
    final String plain2 = p.join(temp.path, 'Plain Show', 'Disc 2');
    writeEpisodicDisc(plain1, episodes: 3);
    writeEpisodicDisc(plain2, episodes: 3);
    final BlurayReleaseSet set = planBlurayReleaseSets(<BlurayDisc>[
      (await readBlurayDisc(plain1))!,
      (await readBlurayDisc(plain2))!,
    ]).single;
    expect(set.name, 'Plain Show');
    expect(set.discs, hasLength(2));
  });

  test('两张盘 → 一个合集、12 集、按盘序 × 集序；重跑幂等', () async {
    final List<(int, String)> ready = <(int, String)>[];
    final DiscLibraryImportReport first = await importer.importBlurayDiscs(
      <String>[disc1, disc2],
      sourceId: null,
      restoreDissolvedGroups: false,
      onCollectionReady: (int id, String root) async => ready.add((id, root)),
    );
    expect(first.imported, 1);
    expect(first.discs.map((DiscLibraryImportedDisc d) => d.name), <String>[
      '魔女の旅々',
      '魔女の旅々',
    ]);
    final int collectionId = first.discs.first.collectionId;
    expect(first.discs.last.collectionId, collectionId);
    expect(ready, <(int, String)>[(collectionId, disc1)]);
    expect(await memberPaths(collectionId), allEpisodePaths());
    final MediaCollectionRow collection =
        (await db.getAllMediaCollections()).single;
    expect(collection.name, '魔女の旅々');
    expect(collection.collectionType, 'playlist');
    // 12 集 + 每张盘一条特典；菜单循环与整条播放列表都不进库。
    expect(await db.allVideoBooks(), hasLength(14));

    final DiscLibraryImportReport again = await import(<String>[disc1, disc2]);
    expect(again.imported, 0);
    expect(again.discs.first.collectionId, collectionId);
    expect(await memberPaths(collectionId), allEpisodePaths());
    expect(await db.getAllMediaCollections(), hasLength(1));
    expect(await db.allVideoBooks(), hasLength(14));
  });

  test('下巻先入库、上巻后到：并进同一个合集并排到前面', () async {
    final DiscLibraryImportReport first = await import(<String>[disc2]);
    final int collectionId = first.discs.single.collectionId;
    expect(first.discs.single.name, '魔女の旅々', reason: '只有一张盘也用作品名');

    final DiscLibraryImportReport second = await import(<String>[disc1]);
    expect(second.imported, 0);
    expect(second.discs.single.collectionId, collectionId);
    expect(await memberPaths(collectionId), allEpisodePaths());
    expect(await db.getAllMediaCollections(), hasLength(1));
  });

  test('本轮没读到的那张盘的各集不动', () async {
    final int collectionId = (await import(<String>[
      disc1,
      disc2,
    ])).discs.first.collectionId;
    await import(<String>[disc1]);
    expect(await memberPaths(collectionId), allEpisodePaths());
  });

  test('存量迁移：整卷行就地变第 1 集、断点折到对应那一集，旧合集与菜单循环行回收', () async {
    // 修前的库：每卷一个合集，成员是整条 00001.mpls 与被误选成标题的菜单循环。
    final String whole = p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls');
    final String loop = p.join(disc1, 'BDMV', 'PLAYLIST', '00008.mpls');
    // 第 1、2 集共 1442 + 1422 = 2864 秒；断点在第 3 集的第 100 秒。
    const int positionMs = (2864 + 100) * 1000;
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/00001 (13)'),
        title: const Value<String>('魔女の旅々　上巻 - 01'),
        videoPath: Value<String>(whole),
        lastPositionMs: const Value<int>(positionMs),
        lastPlayedAt: const Value<int?>(1794318869583),
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/00008 (5)'),
        title: const Value<String>('魔女の旅々　上巻 - 02'),
        videoPath: Value<String>(loop),
      ),
    );
    final int oldCollection = await db.createMediaCollection(
      '魔女の旅々　上巻',
      collectionType: 'playlist',
    );
    for (final String uid in <String>['video/00001 (13)', 'video/00008 (5)']) {
      await db.addToCollection(
        oldCollection,
        MediaKind.video,
        uid,
        userIntent: false,
      );
    }

    final DiscLibraryImportReport report = await import(<String>[disc1, disc2]);
    final int collectionId = report.discs.first.collectionId;
    expect(collectionId, isNot(oldCollection));
    expect(await db.getMediaCollectionById(oldCollection), isNull);
    expect(await memberPaths(collectionId), allEpisodePaths());

    final VideoBookRow first = (await db.getVideoBookByBookUid(
      'video/00001 (13)',
    ))!;
    expect(first.videoPath, episodePath(disc1, 1), reason: '同一行，身份不变');
    expect(first.title, '魔女の旅々　上巻 - 01');
    expect(first.lastPositionMs, 0);
    expect(first.completedAt, isNotNull);
    expect(await db.getVideoBookByBookUid('video/00008 (5)'), isNull);

    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{
      for (final VideoBookRow row in await db.allVideoBooks())
        row.videoPath: row,
    };
    expect(byPath[episodePath(disc1, 2)]!.completedAt, isNotNull);
    final VideoBookRow third = byPath[episodePath(disc1, 3)]!;
    expect(third.lastPositionMs, 100 * 1000);
    expect(third.lastPlayedAt, 1794318869583);
    expect(third.completedAt, isNull);
    expect(byPath[episodePath(disc1, 4)]!.lastPositionMs, 0);
    expect(byPath.containsKey(whole), isFalse);
    expect(byPath.containsKey(loop), isFalse);
  });

  test('菜单重新建出来的整卷行：下次入库把断点补给对应那一集后回收', () async {
    final int collectionId = (await import(<String>[
      disc1,
    ])).discs.single.collectionId;
    final String whole = p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls');
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/00001'),
        title: const Value<String>('魔女の旅々　上巻 - 00001'),
        videoPath: Value<String>(whole),
        lastPositionMs: const Value<int>(600 * 1000),
      ),
    );
    await import(<String>[disc1]);
    expect(await db.getVideoBookByBookUid('video/00001'), isNull);
    final List<String> members = await memberPaths(collectionId);
    expect(members, <String>[
      for (int i = 1; i <= 6; i++) episodePath(disc1, i),
    ]);
    final VideoBookRow first = (await db.allVideoBooks()).singleWhere(
      (VideoBookRow row) => row.videoPath == episodePath(disc1, 1),
    );
    expect(first.lastPositionMs, 600 * 1000);
  });

  test('菜单整卷行上的断点比分集行新：折算时覆盖那一集的旧断点（新者胜）', () async {
    await import(<String>[disc1]);
    final VideoBookRow third = (await db.allVideoBooks()).singleWhere(
      (VideoBookRow row) => row.videoPath == episodePath(disc1, 3),
    );
    // 早先在分集行上看到第 3 集的第 300 秒。
    await db.updateVideoBookPosition(
      third.bookUid,
      300 * 1000,
      playedAt: 1794318000000,
    );
    // 之后从原盘菜单「本編再生」播整卷，看到第 3 集的第 900 秒。
    final String whole = p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls');
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/00001'),
        title: const Value<String>('魔女の旅々　上巻 - 00001'),
        videoPath: Value<String>(whole),
        lastPositionMs: const Value<int>((2864 + 900) * 1000),
        lastPlayedAt: const Value<int?>(1794318869583),
      ),
    );
    await import(<String>[disc1]);
    expect(await db.getVideoBookByBookUid('video/00001'), isNull);
    final VideoBookRow after = (await db.getVideoBookByBookUid(third.bookUid))!;
    expect(after.lastPositionMs, 900 * 1000);
    expect(after.lastPlayedAt, 1794318869583);
  });

  test('菜单整卷行上的断点比分集行旧：分集行自己的断点不被覆盖', () async {
    await import(<String>[disc1]);
    final VideoBookRow third = (await db.allVideoBooks()).singleWhere(
      (VideoBookRow row) => row.videoPath == episodePath(disc1, 3),
    );
    await db.updateVideoBookPosition(
      third.bookUid,
      300 * 1000,
      playedAt: 1794318869583,
    );
    final String whole = p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls');
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/00001'),
        title: const Value<String>('魔女の旅々　上巻 - 00001'),
        videoPath: Value<String>(whole),
        lastPositionMs: const Value<int>((2864 + 900) * 1000),
        lastPlayedAt: const Value<int?>(1794318000000),
      ),
    );
    await import(<String>[disc1]);
    final VideoBookRow after = (await db.getVideoBookByBookUid(third.bookUid))!;
    expect(after.lastPositionMs, 300 * 1000);
    expect(after.lastPlayedAt, 1794318869583);
  });

  test('用户删过的旧单盘合集（墓碑在旧盘名下）：并组改名后这张盘也不复活', () async {
    // 修前的库：上巻一个单盘合集，用户把它删了（成员行留着、合集名记了墓碑）。
    final String whole = p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls');
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/00001 (13)'),
        title: const Value<String>('魔女の旅々　上巻 - 01'),
        videoPath: Value<String>(whole),
      ),
    );
    final int oldCollection = await db.createMediaCollection(
      '魔女の旅々　上巻',
      collectionType: 'playlist',
    );
    await db.addToCollection(
      oldCollection,
      MediaKind.video,
      'video/00001 (13)',
      userIntent: false,
    );
    await db.deleteMediaCollection(oldCollection);

    final DiscLibraryImportReport report = await import(<String>[disc1, disc2]);
    expect(
      report.discs.map((DiscLibraryImportedDisc d) => d.rootPath),
      <String>[disc2],
    );
    final int collectionId = report.discs.single.collectionId;
    expect(await memberPaths(collectionId), <String>[
      for (int i = 1; i <= 6; i++) episodePath(disc2, i),
    ]);
    final VideoBookRow untouched = (await db.getVideoBookByBookUid(
      'video/00001 (13)',
    ))!;
    expect(untouched.videoPath, whole, reason: '被删的那张盘一行都不碰');
    expect(
      (await db.allVideoBooks()).where(
        (VideoBookRow row) => row.videoPath.startsWith(disc1),
      ),
      hasLength(1),
    );

    // 下载入库（恢复已解散分组）照旧把它并回来。
    final DiscLibraryImportReport restored = await importer.importBlurayDiscs(
      <String>[disc1, disc2],
      sourceId: null,
      restoreDissolvedGroups: true,
    );
    expect(restored.discs, hasLength(2));
    expect(await memberPaths(collectionId), allEpisodePaths());
  });

  test('盘不完整：缺片段的剧集盘重扫，分集行、进度与合集成员都不变', () async {
    final int collectionId = (await import(<String>[
      disc1,
    ])).discs.single.collectionId;
    final VideoBookRow third = (await db.allVideoBooks()).singleWhere(
      (VideoBookRow row) => row.videoPath == episodePath(disc1, 3),
    );
    await db.updateVideoBookPosition(
      third.bookUid,
      300 * 1000,
      playedAt: 1794318869583,
    );
    // 第 3 集的片段还没拷过来：00001 这一轮选不成标题，只剩 90 秒的 00002。
    File(p.join(disc1, 'BDMV', 'STREAM', '00005.m2ts')).deleteSync();

    final DiscLibraryImportReport report = await import(<String>[disc1]);
    expect(report.unreadable, <String>[disc1]);
    expect(report.discs, isEmpty);
    expect(await memberPaths(collectionId), <String>[
      for (int i = 1; i <= 6; i++) episodePath(disc1, i),
    ]);
    final VideoBookRow after = (await db.getVideoBookByBookUid(third.bookUid))!;
    expect(after.videoPath, episodePath(disc1, 3));
    expect(after.lastPositionMs, 300 * 1000);
    expect(await db.allVideoBooks(), hasLength(7));
  });

  test('切集判据改为不切：第 1 集的行保留原 uid 回到整卷路径，进度折回整卷，其余分集行解绑不删', () async {
    final int collectionId = (await import(<String>[
      disc1,
    ])).discs.single.collectionId;
    final List<VideoBookRow> before = await db.allVideoBooks();
    String uidAt(String path) =>
        before.singleWhere((VideoBookRow row) => row.videoPath == path).bookUid;
    final String firstUid = uidAt(episodePath(disc1, 1));
    final String thirdUid = uidAt(episodePath(disc1, 3));
    await db.markVideoCompleted(firstUid, DateTime(2026, 11, 1));
    await db.markVideoCompleted(
      uidAt(episodePath(disc1, 2)),
      DateTime(2026, 11, 2),
    );
    await db.updateVideoBookPosition(
      thirdUid,
      100 * 1000,
      playedAt: 1794318869583,
    );
    // 同一条 00001，但各集开头不再有章节点（只剩第一段开头那个）：切集判据给出
    // 「不切」，整条重新被选成标题。
    File(p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls')).writeAsBytesSync(
      buildMplsFixture(
        playItems: <FixturePlayItem>[
          for (int i = 0; i < 6; i++)
            wholeClipItem(
              (i + 3).toString().padLeft(5, '0'),
              i.isEven ? 1442 : 1422,
            ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: kFixtureClipStartTicks),
        ],
      ),
    );

    await import(<String>[disc1]);
    final String whole = p.join(disc1, 'BDMV', 'PLAYLIST', '00001.mpls');
    final VideoBookRow reverted = (await db.getVideoBookByBookUid(firstUid))!;
    expect(reverted.videoPath, whole, reason: '同一行，身份不变');
    expect(reverted.title, '魔女の旅々　上巻');
    expect(reverted.completedAt, isNull, reason: '第 1 集看完不等于整卷看完');
    // 第 1、2 集共 1442 + 1422 = 2864 秒，断点在第 3 集的第 100 秒。
    expect(reverted.lastPositionMs, (2864 + 100) * 1000);
    expect(reverted.lastPlayedAt, 1794318869583);

    final VideoBookRow third = (await db.getVideoBookByBookUid(thirdUid))!;
    expect(third.videoPath, episodePath(disc1, 3));
    expect(third.lastPositionMs, 100 * 1000);
    // 6 行分集里 1 行改回整卷、5 行留着，加 1 条特典：一行都没删。
    expect(await db.allVideoBooks(), hasLength(7));
    expect(await db.getMediaCollectionById(collectionId), isNull);
    final MediaCollectionRow collection =
        (await db.getAllMediaCollections()).single;
    expect(await memberPaths(collection.id), <String>[whole]);
  });
}
