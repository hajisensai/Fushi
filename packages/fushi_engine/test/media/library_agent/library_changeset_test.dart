// AI 管库 v3 批量变更集（docs/specs/2026-11-22-ai-library-agent-design.md §2.2 / §3.3）：
// 解析、逐条校验（原因码）、AI 身份落库、一条整理记录 + 关系回执、整份撤销回到原样
// （撤销留下的钉住 / 墓碑是设计如此）；relink 的旧行是「被取代」不是否决，新关系扛得住
// 否决不变量；dryRun 不写库。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/library_agent/library_changeset.dart';
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<String> book(String title, {bool manga = false}) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: title,
        title: title,
        epubPath: '/m/$title',
        extractDir: '/m/$title',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: Value<String>(manga ? 'manga' : 'epub'),
      ),
    );
    return (await db.resolveEpubBookUid(title))!;
  }

  /// 库的合集归属快照：合集名 → (来源, 成员 uid 集合)。
  Future<Map<String, ({String origin, Set<String> members})>> library() async =>
      <String, ({String origin, Set<String> members})>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.name: (
            origin: c.origin,
            members: <String>{
              for (final MediaCollectionItemRow i
                  in await db.getCollectionItems(c.id))
                i.entryKey,
            },
          ),
      };

  Future<Map<String, bool>> pins(int collectionId) async => <String, bool>{
    for (final MediaCollectionItemRow i in await db.getCollectionItems(
      collectionId,
    ))
      i.entryKey: i.pinnedByUser,
  };

  Future<LibraryChangesetOutcome> apply(
    List<Map<String, Object?>> changes, {
    bool dryRun = false,
  }) => applyLibraryChangeset(
    db,
    parseLibraryChangeset(<String, Object?>{
      'changes': changes,
      'dryRun': dryRun,
    }),
  );

  /// 撤销载荷过一遍 JSON（操作记录按文本存）再撤销。
  Future<int> undo(LibraryChangesetOutcome o) => undoLibraryChangeset(
    db,
    (jsonDecode(jsonEncode(o.undo)) as Map<Object?, Object?>)
        .cast<String, Object?>(),
  );

  group('解析', () {
    test('顶层结构不对抛 FormatException；单条不对进 skipped(invalid)', () async {
      expect(
        () => parseLibraryChangeset(<String, Object?>{}),
        throwsFormatException,
      );
      expect(
        () => parseLibraryChangeset(<String, Object?>{
          'changes': <Object?>[],
          'dryRun': 'yes',
        }),
        throwsFormatException,
      );
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{'op': 'explode'},
        <String, Object?>{'op': 'move', 'to': 'C1'},
        <String, Object?>{'op': 'link', 'from': 'book:a', 'to': 'book:b'},
      ]);
      expect(o.applied, isEmpty);
      expect(
        o.skipped.map((Map<String, Object?> s) => (s['i'], s['reason'])),
        <(Object?, Object?)>[
          (0, LibraryChangeSkip.invalid),
          (1, LibraryChangeSkip.invalid),
          (2, LibraryChangeSkip.invalid),
        ],
      );
      expect(o.runId, isNull);
    });
  });

  group('合集', () {
    test('move：隐式来处 = 全部非目录合集；整份撤销回到原样（来处钉住）', () async {
      final String a = await book('A');
      final String b = await book('B');
      final int user = await db.createMediaCollection('Mine');
      await db.addToCollection(user, MediaKind.epub, b);
      final int ai = await db.createMediaCollection(
        'Wrong',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-w',
      );
      await db.addToCollection(ai, MediaKind.epub, a, userIntent: false);
      final int ai2 = await db.createMediaCollection(
        'Wrong2',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-w2',
      );
      await db.addToCollection(ai2, MediaKind.epub, a, userIntent: false);
      await db.addToCollection(ai2, MediaKind.epub, b, userIntent: false);
      final Map<String, ({String origin, Set<String> members})> before =
          await library();

      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$a'],
          'to': 'C$user',
          'why': '同一系列',
        },
      ]);
      expect(o.skipped, isEmpty);
      expect(o.applied.single['items'], <String>['epub:$a']);
      expect(o.runId, isNotNull);
      final LibraryOrganizeRunRow run = await (db.select(
        db.libraryOrganizeRuns,
      )..where((t) => t.id.equals(o.runId!))).getSingle();
      expect(run.trigger, kLibraryChangesetTrigger);
      expect(run.status, 'done');
      expect(run.domain, 'books');
      final Map<String, ({String origin, Set<String> members})> after =
          await library();
      expect(after['Mine']!.members, <String>{a, b});
      // 用户合集仍是用户的，AI 加进来的成员不钉。
      expect(after['Mine']!.origin, CollectionOrigin.user.dbValue);
      expect((await pins(user))[a], isFalse);
      expect(after.containsKey('Wrong'), isFalse, reason: '移空自删');
      expect(after['Wrong2']!.members, <String>{b});

      expect(await undo(o), greaterThan(0));
      final Map<String, ({String origin, Set<String> members})> restored =
          await library();
      expect(
        <String, Set<String>>{
          for (final MapEntry<String, ({String origin, Set<String> members})> e
              in restored.entries)
            e.key: e.value.members,
        },
        <String, Set<String>>{
          for (final MapEntry<String, ({String origin, Set<String> members})> e
              in before.entries)
            e.key: e.value.members,
        },
      );
    });

    test('move：new:<名字> 建 AI 合集；standalone 只移出；撤销删掉新建的', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String c = await book('C');
      final int user = await db.createMediaCollection('Mixed');
      await db.addToCollection(user, MediaKind.epub, a, userIntent: false);
      await db.addToCollection(user, MediaKind.epub, b, userIntent: false);
      await db.addToCollection(user, MediaKind.epub, c, userIntent: false);
      final Map<String, ({String origin, Set<String> members})> before =
          await library();

      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$a', 'epub:$b'],
          'to': 'new:Saga',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$c'],
          'to': 'standalone',
        },
      ]);
      expect(o.skipped, isEmpty);
      final Map<String, ({String origin, Set<String> members})> after =
          await library();
      expect(after['Saga']!.members, <String>{a, b});
      expect(after['Saga']!.origin, CollectionOrigin.ai.dbValue);
      expect(after.containsKey('Mixed'), isFalse);
      expect(
        o.applied.first['to'],
        'C${(await db.getMediaCollectionByNaturalKey('Saga', 'playlist'))!.id}',
      );

      await undo(o);
      final Map<String, ({String origin, Set<String> members})> restored =
          await library();
      expect(restored.keys.toSet(), before.keys.toSet());
      expect(restored['Mixed']!.members, <String>{a, b, c});
    });

    test('move：钉住 / 目录合集 / 跨域 / 未知引用 / 用户移出过', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String m = await book('M', manga: true);
      final String v = await book('V');
      final int pinned = await db.createMediaCollection('Pinned');
      await db.addToCollection(pinned, MediaKind.epub, a); // 用户放的 = 钉住
      final int folder = await db.createMediaCollection(
        'Dir',
        origin: CollectionOrigin.folder,
      );
      await db.addToCollection(folder, MediaKind.epub, b, userIntent: false);
      final int books = await db.createMediaCollection('Books');
      await db.addToCollection(books, MediaKind.epub, b, userIntent: false);
      // 用户从 Books 移出过 v（成员墓碑）。
      await db.addToCollection(books, MediaKind.epub, v);
      await db.removeFromCollectionRaw(books, 'epub', v);

      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$a'],
          'to': 'standalone',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$a'],
          'to': 'C$folder',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$m'],
          'to': 'C$books',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:nope'],
          'to': 'C$books',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$v'],
          'to': 'C$books',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$b'],
          'from': 'C$folder',
          'to': 'standalone',
        },
      ]);
      expect(o.applied, isEmpty);
      expect(o.skipped.map((Map<String, Object?> s) => s['reason']), <String>[
        LibraryChangeSkip.pinnedByUser,
        LibraryChangeSkip.folderCollection,
        LibraryChangeSkip.crossDomain,
        LibraryChangeSkip.unknownRef,
        LibraryChangeSkip.vetoed,
        LibraryChangeSkip.folderCollection,
      ]);
      expect(o.runId, isNull, reason: '一处没落不留空记录');
      expect(await db.select(db.libraryOrganizeRuns).get(), isEmpty);
    });

    test('merge / rename / dissolve 用户合集直接执行；撤销回到原样', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String c = await book('C');
      final String d = await book('D');
      final int one = await db.createMediaCollection('One');
      final int two = await db.createMediaCollection('Two');
      final int three = await db.createMediaCollection('Three');
      await db.addToCollection(one, MediaKind.epub, a, userIntent: false);
      await db.addToCollection(two, MediaKind.epub, b, userIntent: false);
      await db.addToCollection(three, MediaKind.epub, c, userIntent: false);
      await db.addToCollection(three, MediaKind.epub, d); // 钉住
      final Map<String, ({String origin, Set<String> members})> before =
          await library();

      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'merge',
          'into': 'C$one',
          'from': <String>['C$two'],
          'why': '同一作品',
        },
        <String, Object?>{
          'op': 'rename',
          'collection': 'C$one',
          'name': 'Saga',
        },
        <String, Object?>{'op': 'dissolve', 'collection': 'C$three'},
      ]);
      expect(o.skipped, isEmpty);
      expect(o.applied[2]['keptPinned'], 1);
      final Map<String, ({String origin, Set<String> members})> after =
          await library();
      expect(after.keys.toSet(), <String>{'Saga', 'Three'});
      expect(after['Saga']!.members, <String>{a, b});
      expect(after['Saga']!.origin, CollectionOrigin.user.dbValue);
      expect(after['Three']!.members, <String>{d});

      await undo(o);
      final Map<String, ({String origin, Set<String> members})> restored =
          await library();
      expect(
        <String, Set<String>>{
          for (final MapEntry<String, ({String origin, Set<String> members})> e
              in restored.entries)
            e.key: e.value.members,
        },
        <String, Set<String>>{
          for (final MapEntry<String, ({String origin, Set<String> members})> e
              in before.entries)
            e.key: e.value.members,
        },
      );
    });

    test('rename：AI 合集改名不转所有权；撞名 / 目录合集拒绝；撤销改回', () async {
      final String a = await book('A');
      final int ai = await db.createMediaCollection(
        'Old',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-old',
      );
      await db.addToCollection(ai, MediaKind.epub, a, userIntent: false);
      await db.createMediaCollection('Taken', collectionType: 'playlist');
      await db.createMediaCollection('Taken');
      final int folder = await db.createMediaCollection(
        'Dir',
        origin: CollectionOrigin.folder,
      );

      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'rename',
          'collection': 'C$ai',
          'name': 'Taken',
        },
        <String, Object?>{
          'op': 'rename',
          'collection': 'C$folder',
          'name': 'X',
        },
        <String, Object?>{'op': 'rename', 'collection': 'C$ai', 'name': 'New'},
      ]);
      expect(o.skipped.map((Map<String, Object?> s) => s['reason']), <String>[
        LibraryChangeSkip.nameTaken,
        LibraryChangeSkip.folderCollection,
      ]);
      final MediaCollectionRow renamed = (await db.getMediaCollectionById(ai))!;
      expect(renamed.name, 'New');
      expect(renamed.origin, CollectionOrigin.ai.dbValue);
      final List<LibraryOrganizeChangeRow> changes = await db
          .select(db.libraryOrganizeChanges)
          .get();
      expect(changes.single.kind, 'rename');
      expect(jsonDecode(changes.single.payloadJson)['from'], 'Old');

      await undo(o);
      expect((await db.getMediaCollectionById(ai))!.name, 'Old');
    });

    test('改名后用户移出过的成员仍算否决（成员墓碑随合集改名搬走）', () async {
      final String a = await book('A');
      final String b = await book('B');
      final int col = await db.createMediaCollection('Before');
      await db.addToCollection(col, MediaKind.epub, a);
      await db.addToCollection(col, MediaKind.epub, b, userIntent: false);
      await db.removeFromCollectionRaw(col, 'epub', a);
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'rename',
          'collection': 'C$col',
          'name': 'After',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$a'],
          'to': 'C$col',
        },
      ]);
      expect(o.applied.single['op'], 'rename');
      expect(o.skipped.single['reason'], LibraryChangeSkip.vetoed);
      expect(
        await db.collectionMemberTombstoneKeysFor('After', 'collection'),
        contains('epub A'),
      );
    });

    test('dryRun：报告会做什么，一行不写', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String x = await book('X');
      final String y = await book('Y');
      final int one = await db.createMediaCollection('One');
      final int two = await db.createMediaCollection('Two');
      await db.addToCollection(one, MediaKind.epub, a, userIntent: false);
      await db.addToCollection(two, MediaKind.epub, b, userIntent: false);
      final Map<String, ({String origin, Set<String> members})> before =
          await library();

      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$a'],
          'to': 'new:Fresh',
        },
        // 推演：上一条已把 One 移空，再并它就是 unknown_ref。
        <String, Object?>{
          'op': 'merge',
          'into': 'C$two',
          'from': <String>['C$one'],
        },
        <String, Object?>{'op': 'rename', 'collection': 'C$two', 'name': 'Z'},
        <String, Object?>{
          'op': 'link',
          'from': 'book:X',
          'to': 'book:Y',
          'relation': 'sequel',
        },
      ], dryRun: true);
      expect(o.dryRun, isTrue);
      expect(o.applied.map((Map<String, Object?> s) => s['op']), <String>[
        'move',
        'rename',
        'link',
      ]);
      expect(o.skipped.single['reason'], LibraryChangeSkip.unknownRef);
      expect(o.runId, isNull);
      expect(
        <String, Object?>{
          for (final MapEntry<String, ({String origin, Set<String> members})> e
              in (await library()).entries)
            e.key: <Object?>[e.value.origin, e.value.members],
        },
        <String, Object?>{
          for (final MapEntry<String, ({String origin, Set<String> members})> e
              in before.entries)
            e.key: <Object?>[e.value.origin, e.value.members],
        },
      );
      expect(await db.select(db.libraryOrganizeRuns).get(), isEmpty);
      expect(await db.select(db.libraryOrganizeChanges).get(), isEmpty);
      expect(await db.allMediaLinks(), isEmpty);
      expect(x.isNotEmpty && y.isNotEmpty, isTrue);
    });
  });

  group('关系', () {
    const MediaLinkEndpoint x = (kind: MediaLinkKind.book, key: 'X');
    const MediaLinkEndpoint y = (kind: MediaLinkKind.book, key: 'Y');

    setUp(() async {
      await book('X');
      await book('Y');
    });

    Future<MediaLinkRow?> row(
      MediaLinkRelation r,
      MediaLinkEndpoint f,
      MediaLinkEndpoint t,
    ) => db.mediaLinkById(mediaLinkIdFor(r, f, t));

    test('link → AI 生效；撤销 = 否决墓碑', () async {
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'link',
          'from': 'book:X',
          'to': 'book:Y',
          'relation': 'sequel',
          'why': '续作',
        },
      ]);
      expect(o.skipped, isEmpty);
      final MediaLinkRow live = (await row(MediaLinkRelation.sequel, x, y))!;
      expect(mediaLinkConfirmerOf(live), MediaLinkConfirmer.ai);
      expect(live.reason, '续作');
      expect(o.runId, isNull);

      expect(await undo(o), 1);
      final MediaLinkRow gone = (await row(MediaLinkRelation.sequel, x, y))!;
      expect(gone.deletedAt, isNotNull);
      expect(await db.mediaLinkPairVetoed(x, y), isTrue);
    });

    test('relink：旧行「被取代」不算否决，新关系扛得住否决不变量；撤销还原旧关系', () async {
      // 旧关系：AI 生效的 adaptation X → Y。
      await db.applyAiMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: x,
        to: y,
        source: MediaLinkSource.ai,
      );
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'relink',
          'from': 'book:Y',
          'to': 'book:X',
          'relation': 'sequel',
        },
      ]);
      expect(o.skipped, isEmpty);
      expect(o.applied.single['superseded'], 1);
      final MediaLinkRow old = (await row(MediaLinkRelation.adaptation, x, y))!;
      expect(old.deletedAt, isNotNull);
      expect(old.source, MediaLinkSource.superseded);
      expect(mediaLinkIsVetoTombstone(old), isFalse);
      expect(await db.mediaLinkPairVetoed(x, y), isFalse);
      // 同步 / 备份合并完都会跑一遍：新行不能被收掉。
      expect(await db.enforceMediaLinkVetoes(), 0);
      final MediaLinkRow fresh = (await row(MediaLinkRelation.sequel, y, x))!;
      expect(fresh.deletedAt, isNull);
      expect(mediaLinkConfirmerOf(fresh), MediaLinkConfirmer.ai);

      expect(await undo(o), 1);
      final MediaLinkRow back = (await row(
        MediaLinkRelation.adaptation,
        x,
        y,
      ))!;
      expect(back.deletedAt, isNull);
      expect(mediaLinkConfirmerOf(back), MediaLinkConfirmer.ai);
      expect(back.source, MediaLinkSource.ai);
      final MediaLinkRow retired = (await row(MediaLinkRelation.sequel, y, x))!;
      expect(retired.deletedAt, isNotNull);
      expect(retired.source, MediaLinkSource.superseded);
      expect(await db.enforceMediaLinkVetoes(), 0);
      expect(
        (await row(MediaLinkRelation.adaptation, x, y))!.deletedAt,
        isNull,
      );

      // 改回去再改过来：「被取代」的行能复活（时钟压过那条墓碑）。
      final LibraryChangesetOutcome again = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'relink',
          'from': 'book:Y',
          'to': 'book:X',
          'relation': 'sequel',
        },
      ]);
      expect(again.skipped, isEmpty);
      final MediaLinkRow revived = (await row(MediaLinkRelation.sequel, y, x))!;
      expect(revived.deletedAt, isNull);
      expect(revived.updatedAt, greaterThan(retired.updatedAt));
    });

    test('relink 把建议换成新关系；之后用户否决新关系 → 整对否决', () async {
      await db.proposeMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: x,
        to: y,
        source: MediaLinkSource.mal,
      );
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'relink',
          'from': 'book:X',
          'to': 'book:Y',
          'relation': 'side_story',
        },
      ]);
      expect(o.skipped, isEmpty);
      final MediaLinkId fresh = mediaLinkIdFor(
        MediaLinkRelation.sideStory,
        x,
        y,
      );
      await db.removeMediaLink(fresh);
      expect(await db.mediaLinkPairVetoed(x, y), isTrue);
      // 撤销：新行已被用户否决 → 已被后续修改覆盖，不动。
      expect(await undo(o), 0);
      expect((await db.mediaLinkById(fresh))!.deletedAt, isNotNull);
    });

    test('用户确认 / 否决过的一对不动；link 遇到别的关系要求 relink', () async {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: x,
        to: y,
      );
      final LibraryChangesetOutcome user = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'relink',
          'from': 'book:X',
          'to': 'book:Y',
          'relation': 'sequel',
        },
        <String, Object?>{'op': 'unlink', 'from': 'book:X', 'to': 'book:Y'},
        <String, Object?>{
          'op': 'link',
          'from': 'book:X',
          'to': 'book:Y',
          'relation': 'sequel',
        },
      ]);
      expect(
        user.skipped.map((Map<String, Object?> s) => s['reason']),
        <String>[
          LibraryChangeSkip.userConfirmed,
          LibraryChangeSkip.userConfirmed,
          LibraryChangeSkip.userConfirmed,
        ],
      );
      await db.removeMediaLink(
        mediaLinkIdFor(MediaLinkRelation.adaptation, x, y),
      );
      final LibraryChangesetOutcome vetoed = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'link',
          'from': 'book:X',
          'to': 'book:Y',
          'relation': 'sequel',
        },
        <String, Object?>{
          'op': 'link',
          'from': 'book:X',
          'to': 'book:nope',
          'relation': 'sequel',
        },
      ]);
      expect(
        vetoed.skipped.map((Map<String, Object?> s) => s['reason']),
        <String>[LibraryChangeSkip.vetoed, LibraryChangeSkip.unknownRef],
      );
    });

    test('unlink：AI 生效 → 否决墓碑；建议 → 拒绝；撤销逐行还原', () async {
      await db.applyAiMediaLink(
        relation: MediaLinkRelation.sequel,
        from: x,
        to: y,
        source: MediaLinkSource.ai,
      );
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'unlink',
          'from': 'book:Y',
          'to': 'book:X',
          'relation': 'sequel',
        },
      ]);
      expect(o.applied.single['removed'], 1);
      expect(await db.mediaLinkPairVetoed(x, y), isTrue);
      expect(await undo(o), 1);
      final MediaLinkRow back = (await row(MediaLinkRelation.sequel, x, y))!;
      expect(back.deletedAt, isNull);
      expect(mediaLinkConfirmerOf(back), MediaLinkConfirmer.ai);
      expect(await db.mediaLinkPairVetoed(x, y), isFalse);
    });

    test('主题曲方向按端点种类定（音乐 → 作品）', () async {
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'link',
          'from': 'book:X',
          'to': 'music_album:nope',
          'relation': 'theme_song',
        },
      ]);
      // 专辑不在库：未知引用（方向换算不影响校验）。
      expect(o.skipped.single['reason'], LibraryChangeSkip.unknownRef);
    });
  });
}
