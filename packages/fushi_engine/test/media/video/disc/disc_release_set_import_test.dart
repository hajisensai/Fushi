// 只有「全部播放」的蓝光剧集盘入库：按集建行、同一发布的几张盘并成一个合集、
// 存量「一卷一个条目」的迁移与清理、以及刮削计划拿到的连续集号。
// 设计见 docs/specs/2026-11-15-bluray-playitem-episodes.md。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/organize_convergence.dart'
    show convergeOrganizedCollections;
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/disc/disc_library_import.dart';
import 'package:fushi_engine/media/video/disc/disc_release_set.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart'
    show discOrdinalEpisodeOverrides;
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart'
    show parsedEpisodeNumbersOf;
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

  /// 待确认的「移出成员」建议（原盘入库记的）。
  Future<List<LibraryOrganizeProposalView>> pendingRemovals() async =>
      <LibraryOrganizeProposalView>[
        for (final LibraryOrganizeProposalView v
            in await loadLibraryOrganizeProposals(db))
          if (v.kind == OrganizeProposalKind.removeMembers) v,
      ];

  /// 用户逐条点「移出」。
  Future<void> acceptAll(List<LibraryOrganizeProposalView> proposals) async {
    for (final LibraryOrganizeProposalView v in proposals) {
      expect(
        await resolveLibraryOrganizeProposal(
          db,
          v.id,
          decision: OrganizeProposalDecision.accept,
        ),
        OrganizeProposalState.accepted,
      );
    }
  }

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
    expect(await memberPaths(collectionId), allEpisodePaths());
    // 修前导入器建的合集都是 `user`：单盘合集不直接拆，记成待确认建议（用户
    // 2026-11-24 拍板），用户同意后移空自删。
    final LibraryOrganizeProposalView proposal =
        (await pendingRemovals()).single;
    expect(proposal.targetName, '魔女の旅々　上巻');
    expect(proposal.reasonCode, kMemberRemovalReasonDiscSuperseded);
    expect(await db.getMediaCollectionById(oldCollection), isNotNull);
    await acceptAll(<LibraryOrganizeProposalView>[proposal]);
    expect(await db.getMediaCollectionById(oldCollection), isNull);

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

  group('BUG-5251：盘根外包着 BD 目录、META 盘名带裸卷号的多卷发布', () {
    // 用户库的真实布局：`<发布>/ぼっち・ざ・ろっく！ vol.N/BD/BDMV`，盘内 META 名是
    // `BOCCHI THE ROCK! N`。修前按「盘根上一层 + 去显式卷标的盘名」并组，上一层是
    // 各卷自己的 `vol.N` 目录、盘名尾部的裸数字也不算卷标，六卷各成一个合集。
    late String release;

    String volume(int n) => p.join(release, 'ぼっち・ざ・ろっく！ vol.$n', 'BD');

    setUp(() {
      release = p.join(temp.path, 'ぼっち・ざ・ろっく！ [BDMV] (2022)');
      for (int n = 1; n <= 3; n++) {
        writeEpisodicDisc(
          volume(n),
          episodes: 2,
          discName: 'BOCCHI THE ROCK! $n',
        );
      }
    });

    List<String> episodesOf(List<int> volumes) => <String>[
      for (final int n in volumes)
        for (int i = 1; i <= 2; i++) episodePath(volume(n), i),
    ];

    test('规划：跳过 BD 包装目录，三卷并成一组、名字去裸卷号、按卷号排', () async {
      final BlurayReleaseSet set = planBlurayReleaseSets(<BlurayDisc>[
        (await readBlurayDisc(volume(3)))!,
        (await readBlurayDisc(volume(1)))!,
        (await readBlurayDisc(volume(2)))!,
      ]).single;
      expect(set.episodic, isTrue);
      expect(set.name, 'BOCCHI THE ROCK!');
      expect(set.parentPath, p.normalize(release));
      expect(set.discs.map((BlurayDisc d) => d.rootPath), <String>[
        volume(1),
        volume(2),
        volume(3),
      ]);
      expect(discFolderPath(volume(2)), p.join(release, 'ぼっち・ざ・ろっく！ vol.2'));
      expect(discDirectoryVolumeOrder(volume(2)), 2);
    });

    test('裸数字只在与盘目录卷号相同时才剥：番名里的数字不动', () async {
      final String other = p.join(
        temp.path,
        'Area Show',
        'Area Show vol.1',
        'BD',
      );
      writeEpisodicDisc(other, episodes: 2, discName: 'AREA 86');
      final BlurayDisc disc = (await readBlurayDisc(other))!;
      expect(blurayReleaseStem(disc), 'AREA 86');
      final String plain = p.join(temp.path, 'Two Show', 'BD');
      writeEpisodicDisc(plain, episodes: 2, discName: 'TWO SHOW 2');
      expect(blurayReleaseStem((await readBlurayDisc(plain))!), 'TWO SHOW 2');
    });

    test('入库：三卷一个合集；后到的一卷并进同一个合集', () async {
      final DiscLibraryImportReport first = await import(<String>[
        volume(2),
        volume(1),
      ]);
      expect(first.imported, 1);
      final int collectionId = first.discs.first.collectionId;
      expect(first.discs.last.collectionId, collectionId);
      expect(await memberPaths(collectionId), episodesOf(<int>[1, 2]));

      final DiscLibraryImportReport second = await import(<String>[volume(3)]);
      expect(second.imported, 0);
      expect(second.discs.single.collectionId, collectionId);
      expect(await memberPaths(collectionId), episodesOf(<int>[1, 2, 3]));
      final List<MediaCollectionRow> all = await db.getAllMediaCollections();
      expect(all, hasLength(1));
      expect(all.single.name, 'BOCCHI THE ROCK!');
    });

    test('存量迁移：修前一卷一个的盘合集重扫后并成一个，旧合集移空自删', () async {
      final List<int> legacy = <int>[];
      for (int n = 1; n <= 3; n++) {
        final int id = await db.createMediaCollection(
          'BOCCHI THE ROCK! $n',
          collectionType: 'playlist',
        );
        legacy.add(id);
        for (int i = 1; i <= 2; i++) {
          final String uid = 'video/legacy-$n-$i';
          await db.upsertVideoBook(
            VideoBooksCompanion(
              bookUid: Value<String>(uid),
              title: Value<String>('BOCCHI THE ROCK! $n - 0$i'),
              videoPath: Value<String>(episodePath(volume(n), i)),
            ),
          );
          await db.addToCollection(id, MediaKind.video, uid, userIntent: false);
        }
      }
      await db.markVideoCompleted('video/legacy-2-1', DateTime(2026, 11, 20));
      await db.updateVideoBookPosition(
        'video/legacy-2-2',
        300 * 1000,
        playedAt: 1794318869583,
      );

      final DiscLibraryImportReport report = await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ]);
      final int collectionId = report.discs.first.collectionId;
      expect(
        report.discs.map((DiscLibraryImportedDisc d) => d.collectionId).toSet(),
        <int>{collectionId},
      );
      expect(await memberPaths(collectionId), episodesOf(<int>[1, 2, 3]));
      // 旧单盘合集是 `user`：不直接移，记三条建议；重跑不重复记。
      final List<LibraryOrganizeProposalView> proposals =
          await pendingRemovals();
      expect(proposals, hasLength(3));
      expect(
        proposals.map((LibraryOrganizeProposalView v) => v.reasonCode).toSet(),
        <String>{kMemberRemovalReasonDiscSuperseded},
      );
      await import(<String>[volume(1), volume(2), volume(3)]);
      expect(await pendingRemovals(), hasLength(3));
      await acceptAll(proposals);
      for (final int id in legacy) {
        expect(await db.getMediaCollectionById(id), isNull);
      }
      expect(await db.getAllMediaCollections(), hasLength(1));
      expect(
        await db.getVideoBookByBookUid('video/legacy-2-1'),
        isNotNull,
        reason: '沿用原行，进度与统计不丢',
      );
      final VideoBookRow watched = (await db.getVideoBookByBookUid(
        'video/legacy-2-1',
      ))!;
      expect(watched.completedAt, isNotNull, reason: '看完标记随原行保留');
      final VideoBookRow resumed = (await db.getVideoBookByBookUid(
        'video/legacy-2-2',
      ))!;
      expect(resumed.lastPositionMs, 300 * 1000, reason: '断点随原行保留');
      expect(resumed.lastPlayedAt, 1794318869583);
    });

    test('BUG-5391：长特典不进合集、不占集号；存量「- 03」行改回特典名，残留的集号刮削行清掉', () async {
      // 真实盘：每卷 `00001` 串着两集，另有一条 9～95 分钟的采访 / Live 整播放列表。
      // 修前它被选成第 3 个标题：合集里每卷三项，刮削按合集顺序编号，第 3 集成了
      // vol.1 的采访、vol.2 的第 1 集成了第 4 集。
      writeFixturePlaylist(volume(1), '00005', const <(String, int)>[
        ('00060', 1970),
      ]);
      writeFixturePlaylist(volume(2), '00003', const <(String, int)>[
        ('00061', 270),
        ('00062', 234),
        ('00063', 269),
        ('00064', 255),
        ('00065', 370),
        ('00066', 338),
      ]);
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'bd',
          mediaKind: 'video',
          rootPath: release,
          createdAt: 1,
        ),
      );
      final String interview = p.join(
        volume(1),
        'BDMV',
        'PLAYLIST',
        '00005.mpls',
      );
      final String live = p.join(volume(2), 'BDMV', 'PLAYLIST', '00003.mpls');
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('video/interview'),
          title: const Value<String>('BOCCHI THE ROCK! 1 - 03'),
          videoPath: Value<String>(interview),
          sourceId: Value<int?>(sourceId),
        ),
      );
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('video/live'),
          title: const Value<String>('用户改过的名字'),
          videoPath: Value<String>(live),
          sourceId: Value<int?>(sourceId),
        ),
      );
      // 修前的发布组合集：第 1 集、第 3 个「标题」（采访）、vol.2 的 Live。
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('video/legacy-ep1'),
          title: const Value<String>('BOCCHI THE ROCK! 1 - 01'),
          videoPath: Value<String>(episodePath(volume(1), 1)),
          sourceId: Value<int?>(sourceId),
        ),
      );
      final int legacy = await db.createMediaCollection(
        'BOCCHI THE ROCK!',
        collectionType: 'playlist',
      );
      for (final String uid in <String>[
        'video/legacy-ep1',
        'video/interview',
        'video/live',
      ]) {
        await db.addToCollection(
          legacy,
          MediaKind.video,
          uid,
          userIntent: false,
        );
      }
      await db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: 'video/interview',
          source: 'anidb',
          subjectId: '259958',
          title: '馳せサンズ',
          episodeNumber: const Value<int?>(3),
          scrapedAt: DateTime(2026, 11, 20),
        ),
      );

      final DiscLibraryImportReport report = await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ], sourceId: sourceId);
      final int collectionId = report.discs.first.collectionId;
      expect(collectionId, legacy, reason: '修前的无键合集按成员认领');
      final MediaCollectionRow adopted = (await db.getMediaCollectionById(
        legacy,
      ))!;
      expect(adopted.organizeKey, startsWith('d:video:set:'));
      expect(adopted.origin, CollectionOrigin.user.dbValue, reason: '认领不改来源');
      // 用户的合集：特典不直接移出，记成一条待确认建议；分集照常补进来、按卷序排。
      expect(await memberPaths(collectionId), <String>[
        episodePath(volume(1), 1),
        episodePath(volume(1), 2),
        interview,
        episodePath(volume(2), 1),
        episodePath(volume(2), 2),
        live,
        ...episodesOf(<int>[3]),
      ]);
      final LibraryOrganizeProposalView proposal =
          (await pendingRemovals()).single;
      expect(proposal.reasonCode, kMemberRemovalReasonDiscExtra);
      expect(
        proposal.members.map((OrganizeProposalMember m) => m.entryKey).toSet(),
        <String>{'video/interview', 'video/live'},
      );
      // 特典留在合集里时详情页 / 播放器的分栏与集号：特典进 PV·特典、不占号。
      final List<String> paths = await memberPaths(collectionId);
      expect(collectionGroupKeysForPaths(paths), <String>[
        's1',
        's1',
        kCollectionExtrasGroupKey,
        's1',
        's1',
        kCollectionExtrasGroupKey,
        's1',
        's1',
      ]);
      expect(discEpisodeOrdinalsOf(paths), <int?>[
        1,
        2,
        null,
        3,
        4,
        null,
        5,
        6,
      ]);
      expect(
        (await db.getVideoBookByBookUid('video/interview'))!.title,
        'BOCCHI THE ROCK! 1 - 00005',
        reason: '自动名改成特典的 MPLS 号形状，不再读成第 3 集',
      );
      expect((await db.getVideoBookByBookUid('video/live'))!.title, '用户改过的名字');

      final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
      final VideoSourceScrapeWork work = (await VideoSourceWorkPlanner(
        db,
      ).plan(source)).single;
      final Map<String, (int, int)> overrides = discOrdinalEpisodeOverrides(
        work,
      );
      expect(
        <(int, int)?>[
          for (final VideoBookRow member in work.members)
            overrides[member.bookUid],
        ],
        <(int, int)>[for (int i = 1; i <= 6; i++) (1, i)],
        reason: '集号按卷序 × 盘内集序连续编，特典不占号',
      );

      await VideoSourceMetadataIndexer(db).index(source);
      expect(
        await db.getVideoScrapeMeta('video/interview'),
        isNull,
        reason: '特典身上修前刮来的「第 3 集」不再顶着正片集名',
      );

      await acceptAll(<LibraryOrganizeProposalView>[proposal]);
      expect(await memberPaths(collectionId), episodesOf(<int>[1, 2, 3]));
      await import(<String>[volume(1), volume(2), volume(3)]);
      expect(await pendingRemovals(), isEmpty, reason: '移出之后重扫不再提');
    });

    test('新建的发布组合集 origin=rule 带键；改名后重扫按键认回，不另建', () async {
      final int id = (await import(<String>[
        volume(1),
        volume(2),
      ])).discs.first.collectionId;
      final MediaCollectionRow created = (await db.getMediaCollectionById(id))!;
      expect(created.origin, CollectionOrigin.rule.dbValue);
      expect(created.organizeKey, startsWith('d:video:set:'));
      await db.renameMediaCollection(id, '孤独摇滚！');

      final DiscLibraryImportReport again = await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ]);
      expect(again.imported, 0);
      expect(again.discs.first.collectionId, id);
      expect(await db.getAllMediaCollections(), hasLength(1));
      expect(await memberPaths(id), episodesOf(<int>[1, 2, 3]));
    });

    test('键已有主时不再认领无键合集：拆分时保留原合集拆出来的「第 1 季」不挂键、不被收敛并掉原合集', () async {
      final int id = (await import(<String>[
        volume(1),
        volume(2),
      ])).discs.first.collectionId;
      // 合集详情页「拆分」并勾「保留原合集」：拆出来的是用户的无键 playlist 合集，
      // 成员与原合集逐个相同。
      final int split = await db.createMediaCollection(
        '第 1 季',
        collectionType: 'playlist',
      );
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        id,
      )) {
        await db.addToCollection(split, MediaKind.video, item.entryKey);
      }

      final DiscLibraryImportReport again = await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ]);
      expect(again.discs.first.collectionId, id);
      final MediaCollectionRow kept = (await db.getMediaCollectionById(split))!;
      expect(kept.organizeKey, isNull, reason: '键已归原合集，拆出来的合集不认领');
      expect(await memberPaths(split), episodesOf(<int>[1, 2]));
      expect(await memberPaths(id), episodesOf(<int>[1, 2, 3]));

      expect(await convergeOrganizedCollections(db), 0);
      expect(await db.getMediaCollectionById(id), isNotNull);
      expect(await db.getMediaCollectionById(split), isNotNull);
    });

    test('被 AI 并进别的合集（键进别名）：重扫认回那个合集', () async {
      final int id = (await import(<String>[
        volume(1),
        volume(2),
      ])).discs.first.collectionId;
      final MediaCollectionRow disc = (await db.getMediaCollectionById(id))!;
      final int ai = await db.createMediaCollection(
        'ぼっち・ざ・ろっく！',
        collectionType: 'playlist',
        origin: CollectionOrigin.ai,
        organizeKey: 't:video:ぼっちざろっく!',
      );
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        id,
      )) {
        await db.addToCollection(
          ai,
          MediaKind.video,
          item.entryKey,
          userIntent: false,
        );
      }
      await db.absorbOrganizeIdentity(targetId: ai, source: disc);
      await db.deleteMediaCollection(id);

      final DiscLibraryImportReport again = await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ]);
      expect(again.discs.first.collectionId, ai);
      expect(await db.getAllMediaCollections(), hasLength(1));
      expect(await memberPaths(ai), episodesOf(<int>[1, 2, 3]));
    });

    test('用户加进来的普通视频不动；用户合集里的特典只记建议', () async {
      final int id = (await import(<String>[
        volume(1),
        volume(2),
      ])).discs.first.collectionId;
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('video/bonus-mp4'),
          title: const Value<String>('Bocchi the Rock! - S01E13'),
          videoPath: Value<String>(
            p.join(temp.path, 'loose', 'Bocchi the Rock! - S01E13.mp4'),
          ),
        ),
      );
      // 用户亲手加：合集转为用户的。
      await db.addToCollection(id, MediaKind.video, 'video/bonus-mp4');
      expect(
        (await db.getMediaCollectionById(id))!.origin,
        CollectionOrigin.user.dbValue,
      );
      // 修前混进来的特典（非用户亲手加）。
      writeFixturePlaylist(volume(1), '00005', const <(String, int)>[
        ('00060', 1970),
      ]);
      final String interview = p.join(
        volume(1),
        'BDMV',
        'PLAYLIST',
        '00005.mpls',
      );
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('video/interview'),
          title: const Value<String>('BOCCHI THE ROCK! 1 - 03'),
          videoPath: Value<String>(interview),
        ),
      );
      await db.addToCollection(
        id,
        MediaKind.video,
        'video/interview',
        userIntent: false,
      );

      await import(<String>[volume(1), volume(2), volume(3)]);
      final List<String> paths = await memberPaths(id);
      expect(paths, contains(interview), reason: '用户的合集不直接移');
      expect(
        paths,
        contains(p.join(temp.path, 'loose', 'Bocchi the Rock! - S01E13.mp4')),
      );
      final LibraryOrganizeProposalView proposal =
          (await pendingRemovals()).single;
      expect(
        proposal.members.map((OrganizeProposalMember m) => m.entryKey),
        <String>['video/interview'],
        reason: '用户亲手加的普通视频不进建议',
      );
    });

    test('混进普通视频（用户拍板：要支持）：不提议移出；原盘按顺位、普通视频按文件名定号，撞号相邻排', () async {
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'bd',
          mediaKind: 'video',
          rootPath: temp.path,
          createdAt: 1,
        ),
      );
      final int id = (await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ], sourceId: sourceId)).discs.first.collectionId;
      String loose(String name) => p.join(temp.path, 'loose', name);
      for (final (String uid, String name) v in <(String, String)>[
        ('video/e03', 'Bocchi the Rock! - S01E03.mkv'),
        ('video/e13', 'Bocchi the Rock! - S01E13.mkv'),
        ('video/making', 'Making of.mkv'),
      ]) {
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(v.$1),
            title: Value<String>(v.$2),
            videoPath: Value<String>(loose(v.$2)),
            sourceId: Value<int?>(sourceId),
          ),
        );
        await db.addToCollection(id, MediaKind.video, v.$1);
      }

      await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ], sourceId: sourceId);
      expect(await pendingRemovals(), isEmpty, reason: '普通视频不提议移出');
      final List<String> paths = await memberPaths(id);
      expect(paths, contains(loose('Making of.mkv')), reason: '解不出集号的留在原位');
      expect(
        paths.where((String path) => path != loose('Making of.mkv')).toList(),
        <String>[
          episodePath(volume(1), 1),
          episodePath(volume(1), 2),
          episodePath(volume(2), 1),
          loose('Bocchi the Rock! - S01E03.mkv'),
          episodePath(volume(2), 2),
          episodePath(volume(3), 1),
          episodePath(volume(3), 2),
          loose('Bocchi the Rock! - S01E13.mkv'),
        ],
        reason: '撞号的两个都留着、相邻排（原盘在前）；超出原盘集数的排在最后一集后面',
      );
      // 展示：原盘按顺位、普通视频按文件名（与刮削同口径），都在第 1 季。
      final List<int?> ordinals = discEpisodeOrdinalsOf(paths);
      final List<int?> parsed = parsedEpisodeNumbersOf(paths);
      expect(
        <int?>[
          for (int i = 0; i < paths.length; i++)
            if (paths[i] != loose('Making of.mkv')) ordinals[i] ?? parsed[i],
        ],
        <int?>[1, 2, 3, 3, 4, 5, 6, 13],
      );
      expect(collectionGroupKeysForPaths(paths).toSet(), <String>{
        's1',
        kCollectionExtrasGroupKey,
      }, reason: '只有解不出集号的普通视频进 PV·特典');

      // 刮削计划：原盘只在原盘成员之间编号，普通视频不占原盘的号。
      final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
      final VideoSourceScrapeWork work = (await VideoSourceWorkPlanner(db).plan(
        source,
      )).singleWhere((VideoSourceScrapeWork w) => w.collection?.id == id);
      final Map<String, (int, int)> overrides = discOrdinalEpisodeOverrides(
        work,
      );
      expect(overrides.keys, isNot(contains('video/e03')));
      expect(overrides.values.toList(), <(int, int)>[
        for (int i = 1; i <= 6; i++) (1, i),
      ]);
      expect(
        work.members.map((VideoBookRow m) => m.bookUid),
        containsAll(<String>['video/e03', 'video/e13']),
      );
    });

    test('几个修前的无键合集：认领本轮标题最多的那个，其余单盘合集记建议', () async {
      Future<int> legacy(String name, List<int> volumes) async {
        final int id = await db.createMediaCollection(
          name,
          collectionType: 'playlist',
        );
        for (final int n in volumes) {
          for (int i = 1; i <= 2; i++) {
            final String uid = 'video/$name-$n-$i';
            await db.upsertVideoBook(
              VideoBooksCompanion(
                bookUid: Value<String>(uid),
                title: Value<String>('$name $n-$i'),
                videoPath: Value<String>(episodePath(volume(n), i)),
              ),
            );
            await db.addToCollection(
              id,
              MediaKind.video,
              uid,
              userIntent: false,
            );
          }
        }
        return id;
      }

      final int small = await legacy('A', <int>[1]);
      final int big = await legacy('B', <int>[2, 3]);
      final DiscLibraryImportReport report = await import(<String>[
        volume(1),
        volume(2),
        volume(3),
      ]);
      expect(report.discs.first.collectionId, big);
      expect(report.imported, 0);
      expect((await db.getMediaCollectionById(small))!.organizeKey, isNull);
      expect(
        (await pendingRemovals()).map(
          (LibraryOrganizeProposalView v) => v.targetName,
        ),
        <String>['A'],
      );
    });

    test('切集判据改为不切（盘根外包 BD 目录）：其余分集行也从发布组合集解绑', () async {
      // 解绑判「合集是不是这个发布目录的」与并组同一判据：修前解绑仍按盘根上一层
      // （`… vol.1`）比，而合集成员的发布目录已跳过 `BD`，对不上，其余分集行留在
      // 旧的发布组合集里。
      final String solo = p.join(temp.path, 'Solo Release', 'Solo vol.1', 'BD');
      writeEpisodicDisc(solo, episodes: 6, discName: 'SOLO 1');
      final int collectionId = (await import(<String>[
        solo,
      ])).discs.single.collectionId;
      File(p.join(solo, 'BDMV', 'PLAYLIST', '00001.mpls')).writeAsBytesSync(
        buildMplsFixture(
          playItems: <FixturePlayItem>[
            for (int i = 0; i < 6; i++)
              wholeClipItem(
                (i + 3).toString().padLeft(5, '0'),
                i.isEven ? 1442 : 1422,
              ),
          ],
          marks: const <FixtureMark>[
            FixtureMark(
              playItemIndex: 0,
              timestampTicks: kFixtureClipStartTicks,
            ),
          ],
        ),
      );

      await import(<String>[solo]);
      expect(await db.getMediaCollectionById(collectionId), isNull);
      final MediaCollectionRow collection =
          (await db.getAllMediaCollections()).single;
      expect(await memberPaths(collection.id), <String>[
        p.join(solo, 'BDMV', 'PLAYLIST', '00001.mpls'),
      ]);
    });
  });
}
