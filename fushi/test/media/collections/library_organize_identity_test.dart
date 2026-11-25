// BUG-5461：整理器把合集移空 / 并掉 / 挪空后撤销，合集按原 id 回来，挂在 id 上的
// 作品图谱连接、标签、AniList id 一并回来（以前按名字重建成新 id，旧 id 上的连接成了
// 「不在库中」的死卡）。真 Drift 内存库，开外键（cascade 与生产一致）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/library_agent/library_changeset.dart';

void main() {
  late FushiDatabase db;
  setUp(
    () => db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    ),
  );
  tearDown(() => db.close());

  Future<String> book(String title) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: title,
        title: title,
        epubPath: '/m/$title',
        extractDir: '/m/$title',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    return (await db.resolveEpubBookUid(title))!;
  }

  Future<int> run() => db
      .into(db.libraryOrganizeRuns)
      .insert(
        LibraryOrganizeRunsCompanion.insert(
          domain: 'books',
          trigger: 'manual',
          startedAt: 1,
          status: 'done',
        ),
      );

  OrganizeEntry entry(String key) => OrganizeEntry(
    mediaType: 'epub',
    entryKey: key,
    tombstoneKey: 'epub\u0000$key',
    item: AiOrganizeItem(title: key),
  );

  Future<List<MediaLinkRow>> links(int collectionId) =>
      db.mediaLinksForEndpoint(MediaLinkKind.videoCollection, '$collectionId');

  /// 合集 [id] 挂上「按 id 认人」的数据：AI 生效的同一作品连接（同用户库里那 12 条）、
  /// 一条手动连接、一个标签、AniList id。返回标签 id。
  Future<int> decorate(int id) async {
    await db.applyAiMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: (kind: MediaLinkKind.book, key: 'vol1'),
      to: (kind: MediaLinkKind.videoCollection, key: '$id'),
      source: 'ai',
    );
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: (kind: MediaLinkKind.book, key: 'vol2'),
      to: (kind: MediaLinkKind.videoCollection, key: '$id'),
    );
    final int tagId = await db.getOrCreateTagByName('fav');
    await db.addTagToCollection(id, tagId);
    await db.setMediaCollectionAnilistId(id, 124080);
    return tagId;
  }

  Future<void> expectIdentityBack(int id, int tagId) async {
    final MediaCollectionRow row = (await db.getMediaCollectionById(id))!;
    expect(row.anilistId, 124080);
    expect(await links(id), hasLength(2), reason: '作品图谱连接随原 id 回来');
    expect(
      (await db.getTagsForCollection(id)).map((BookTagRow t) => t.id),
      <int>[tagId],
    );
    expect(
      (await db.select(db.mediaCollections).get()).where(
        (MediaCollectionRow c) => c.name == row.name,
      ),
      hasLength(1),
      reason: '不另建同名新合集',
    );
  }

  test('移空用户合集 → 合集随移空自删、连接一并清掉；撤销 = 原 id 回来，成员钉住', () async {
    final String a = await book('A');
    final String b = await book('B');
    final int col = await db.createMediaCollection(
      'Horimiya',
      collectionType: 'playlist',
    );
    await db.addToCollectionRaw(col, 'epub', a, userIntent: false);
    await db.addToCollectionRaw(col, 'epub', b, userIntent: false);
    final int tagId = await decorate(col);
    final int runId = await run();

    await applyOrganizeActions(
      db,
      runId: runId,
      actions: <OrganizeAction>[
        OrganizeAction(
          kind: OrganizeActionKind.evict,
          source: 'ai',
          confidence: AiOrganizeConfidence.high,
          targetCollectionId: col,
          entries: <OrganizeEntry>[entry(a), entry(b)],
          reason: 'not the same series',
        ),
      ],
    );
    expect(await db.getMediaCollectionById(col), isNull);
    expect(await links(col), isEmpty, reason: 'BUG-5462：不留死连接');
    final Map<String, Object?> payload =
        jsonDecode(
              (await db.select(db.libraryOrganizeChanges).get())
                  .single
                  .payloadJson,
            )
            as Map<String, Object?>;
    expect(payload['identity'], isA<Map<String, Object?>>());

    expect(await undoLibraryOrganizeRun(db, runId), 1);
    await expectIdentityBack(col, tagId);
    final MediaCollectionRow back = (await db.getMediaCollectionById(col))!;
    expect(back.origin, 'user');
    expect(back.collectionType, 'playlist');
    expect(
      <String, bool>{
        for (final MediaCollectionItemRow m in await db.getCollectionItems(col))
          m.entryKey: m.pinnedByUser,
      },
      <String, bool>{a: true, b: true},
    );
  });

  test('没移空的移出不记身份快照', () async {
    final String a = await book('A');
    final String b = await book('B');
    final int col = await db.createMediaCollection('Keep');
    await db.addToCollectionRaw(col, 'epub', a, userIntent: false);
    await db.addToCollectionRaw(col, 'epub', b, userIntent: false);
    final int runId = await run();
    await applyOrganizeActions(
      db,
      runId: runId,
      actions: <OrganizeAction>[
        OrganizeAction(
          kind: OrganizeActionKind.evict,
          source: 'ai',
          confidence: AiOrganizeConfidence.high,
          targetCollectionId: col,
          entries: <OrganizeEntry>[entry(a)],
        ),
      ],
    );
    final Map<String, Object?> payload =
        jsonDecode(
              (await db.select(db.libraryOrganizeChanges).get())
                  .single
                  .payloadJson,
            )
            as Map<String, Object?>;
    expect(payload.containsKey('identity'), isFalse);
  });

  test('挪空来处 → 撤销：来处按原 id 回来', () async {
    final String a = await book('A');
    final int from = await db.createMediaCollection('From');
    await db.addToCollectionRaw(from, 'epub', a, userIntent: false);
    final int tagId = await decorate(from);
    final int to = await db.createMediaCollection(
      'To',
      origin: CollectionOrigin.ai,
    );
    await db.addToCollectionRaw(to, 'epub', await book('Z'), userIntent: false);
    final int runId = await run();

    await applyOrganizeActions(
      db,
      runId: runId,
      actions: <OrganizeAction>[
        OrganizeAction(
          kind: OrganizeActionKind.move,
          source: 'ai',
          confidence: AiOrganizeConfidence.high,
          fromCollectionId: from,
          targetCollectionId: to,
          entries: <OrganizeEntry>[entry(a)],
          reason: 'belongs there',
        ),
      ],
    );
    expect(await db.getMediaCollectionById(from), isNull);
    expect(await undoLibraryOrganizeRun(db, runId), 1);
    await expectIdentityBack(from, tagId);
  });

  test('合并 → 撤销：败方按原 id 回来（转成用户的），连接回到败方', () async {
    final String a = await book('A');
    final String b = await book('B');
    final int winner = await db.createMediaCollection(
      'Winner',
      origin: CollectionOrigin.ai,
      organizeKey: 'k-w',
    );
    await db.addToCollectionRaw(winner, 'epub', a, userIntent: false);
    final int loser = await db.createMediaCollection(
      'Loser',
      origin: CollectionOrigin.ai,
      organizeKey: 'k-l',
    );
    await db.addToCollectionRaw(loser, 'epub', b, userIntent: false);
    final int tagId = await decorate(loser);
    final int runId = await run();

    await applyOrganizeActions(
      db,
      runId: runId,
      actions: <OrganizeAction>[
        OrganizeAction(
          kind: OrganizeActionKind.merge,
          source: 'ai',
          confidence: AiOrganizeConfidence.high,
          targetCollectionId: winner,
          sourceCollectionIds: <int>[loser],
        ),
      ],
    );
    expect(await db.getMediaCollectionById(loser), isNull);
    expect(await links(loser), isEmpty);

    expect(await undoLibraryOrganizeRun(db, runId), 1);
    await expectIdentityBack(loser, tagId);
    expect((await db.getMediaCollectionById(loser))!.origin, 'user');
    expect(
      (await db.getCollectionItems(
        loser,
      )).map((MediaCollectionItemRow m) => m.entryKey),
      <String>[b],
    );
    expect(
      (await db.getCollectionItems(
        winner,
      )).map((MediaCollectionItemRow m) => m.entryKey),
      <String>[a],
    );
  });

  test('接受「移出成员」建议把合集移空 → 撤销建议：原 id 回来', () async {
    final String a = await book('A');
    final int col = await db.createMediaCollection('Show');
    await db.addToCollection(col, MediaKind.epub, a, userIntent: false);
    final int tagId = await decorate(col);
    await recordMemberRemovalProposals(
      db,
      trigger: 'disc_import',
      proposals: <MemberRemovalProposal>[
        MemberRemovalProposal(
          collectionId: col,
          members: <CollectionMemberKey>[(mediaType: 'epub', entryKey: a)],
          reasonCode: kMemberRemovalReasonDiscExtra,
        ),
      ],
    );
    final LibraryOrganizeProposalView p = (await loadLibraryOrganizeProposals(
      db,
    )).single;
    expect(
      await resolveLibraryOrganizeProposal(
        db,
        p.id,
        decision: OrganizeProposalDecision.accept,
      ),
      OrganizeProposalState.accepted,
    );
    expect(await db.getMediaCollectionById(col), isNull);

    expect(await undoLibraryOrganizeProposal(db, p.id), isTrue);
    await expectIdentityBack(col, tagId);
    expect(
      (await db.getCollectionItems(
        col,
      )).map((MediaCollectionItemRow m) => m.entryKey),
      <String>[a],
    );
  });

  test('旧记录（没有身份快照）照旧按名字重建', () async {
    final int runId = await run();
    await db
        .into(db.libraryOrganizeChanges)
        .insert(
          LibraryOrganizeChangesCompanion.insert(
            runId: runId,
            kind: 'evict',
            collectionName: 'Legacy',
            collectionType: 'collection',
            source: 'ai',
            confidence: 'high',
            payloadJson: jsonEncode(<String, Object?>{
              'members': <Object?>[
                <String, String>{'t': 'epub', 'k': await book('A')},
              ],
              'origin': 'user',
            }),
          ),
        );
    expect(await undoLibraryOrganizeRun(db, runId), 1);
    expect(
      await db.getMediaCollectionByNaturalKey('Legacy', 'collection'),
      isNotNull,
    );
  });

  test('变更集：先连上合集、再把它移空；整份撤销 = 连接退回连之前（不被还原的合集带回来）', () async {
    final String a = await book('A');
    await book('vol9');
    final int col = await db.createMediaCollection('Horimiya');
    await db.addToCollectionRaw(col, 'epub', a, userIntent: false);
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: (kind: MediaLinkKind.book, key: 'vol1'),
      to: (kind: MediaLinkKind.videoCollection, key: '$col'),
    );
    final LibraryChangesetOutcome o = await applyLibraryChangeset(
      db,
      parseLibraryChangeset(<String, Object?>{
        'changes': <Object?>[
          <String, Object?>{
            'op': 'link',
            'from': 'book:vol9',
            'to': 'video_collection:$col',
            'relation': 'same_work',
            'why': 'same title',
          },
          <String, Object?>{
            'op': 'move',
            'items': <String>['epub:$a'],
            'from': 'C$col',
            'to': 'standalone',
            'why': 'not part of it',
          },
        ],
      }),
    );
    expect(o.skipped, isEmpty);
    expect(await db.getMediaCollectionById(col), isNull);
    expect(await links(col), isEmpty);

    await undoLibraryChangeset(
      db,
      (jsonDecode(jsonEncode(o.undo)) as Map<Object?, Object?>)
          .cast<String, Object?>(),
    );
    expect(await db.getMediaCollectionById(col), isNotNull);
    final List<MediaLinkRow> back = await links(col);
    expect(
      back.map((MediaLinkRow l) => '${l.fromKey}|${l.toKey}'),
      unorderedEquals(<String>['vol1|$col']),
      reason: '用户原有的连接回来；AI 这次连上的退回（否决墓碑不显示）',
    );
  });
}
