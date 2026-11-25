// AI 库管家设计稿 §7 / §8（docs/specs/2026-11-18-ai-library-curator-design.md）：
// 分类 = 合集归属整理。AI 能把条目从任何非目录合集（含用户合集）移出——单独放或挪进
// 别的合集；pinned 的不移、同一对（合集, 成员）只移一次、移出用户合集必须带理由；
// 用户合集的合并 / 改名直接执行（AI 管库 v3 §2.2，自动只收 high）。全部可撤销，撤销移出 = 钉住。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';

OrganizeEntry _entry(String key, {List<int> inCollections = const <int>[]}) =>
    OrganizeEntry(
      mediaType: 'epub',
      entryKey: key,
      tombstoneKey: 'epub\u0000$key',
      item: AiOrganizeItem(title: key),
      collectionIds: inCollections,
    );

OrganizeCollectionFact _col(
  int id,
  CollectionOrigin origin, {
  Set<String> members = const <String>{},
  Set<String> pinned = const <String>{},
  Set<String> evicted = const <String>{},
  String type = 'playlist',
}) => OrganizeCollectionFact(
  id: id,
  name: 'col$id',
  collectionType: type,
  origin: origin,
  organizeKey: 'k$id',
  organizeAliases: const <String>{},
  memberKeys: <String>{for (final String m in members) 'epub\u0000$m'},
  sampleTitles: const <String>[],
  pinnedMemberKeys: <String>{for (final String m in pinned) 'epub\u0000$m'},
  aiEvictedMemberKeys: <String>{for (final String m in evicted) 'epub\u0000$m'},
);

({LibraryOrganizeFacts facts, OrganizeChunk chunk}) _world(
  List<OrganizeEntry> entries,
  List<OrganizeCollectionFact> collections,
) {
  final LibraryOrganizeFacts facts = LibraryOrganizeFacts(
    domain: CollectionShelfDomain.books,
    entries: entries,
    collections: collections,
    rejectedKeys: const <String>{},
    rejectedNames: const <String, String>{},
    takenNames: <String, Set<String>>{
      for (final OrganizeCollectionFact c in collections)
        '${c.name}\u0000${c.collectionType}': <String>{c.organizeKey!},
    },
  );
  return (
    facts: facts,
    chunk: OrganizeChunk(entries: entries, collections: collections),
  );
}

OrganizePlan _plan(
  ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w,
  AiOrganizeReply reply, {
  OrganizeTrigger trigger = OrganizeTrigger.manual,
}) => planOrganizeReply(
  facts: w.facts,
  chunk: w.chunk,
  reply: reply,
  trigger: trigger,
  tagPrefix: '系列:',
);

AiOrganizeReply _evict(
  int index, {
  String from = 'C0',
  String? into,
  String? reason = '另一部作品的第 3 卷',
  AiOrganizeConfidence confidence = AiOrganizeConfidence.high,
}) => AiOrganizeReply(
  evictions: <AiOrganizeEvictionProposal>[
    AiOrganizeEvictionProposal(
      collection: from,
      members: <int>[index],
      confidence: confidence,
      into: into,
      reason: reason,
    ),
  ],
);

void main() {
  group('planOrganizeReply：移出 / 挪走（origin × pinned × 已移出过）', () {
    for (final CollectionOrigin origin in <CollectionOrigin>[
      CollectionOrigin.ai,
      CollectionOrigin.rule,
      CollectionOrigin.user,
      CollectionOrigin.folder,
    ]) {
      for (final bool pinned in <bool>[false, true]) {
        for (final bool evictedBefore in <bool>[false, true]) {
          final bool expectEvict =
              origin != CollectionOrigin.folder && !pinned && !evictedBefore;
          test('${origin.name} 合集 · pinned=$pinned · 已移出过=$evictedBefore → '
              '${expectEvict ? '移出' : '不动'}', () {
            final OrganizePlan p = _plan(
              _world(
                <OrganizeEntry>[
                  _entry('a', inCollections: <int>[1]),
                ],
                <OrganizeCollectionFact>[
                  _col(
                    1,
                    origin,
                    members: <String>{'a', 'b'},
                    pinned: <String>{if (pinned) 'a'},
                    evicted: <String>{if (evictedBefore) 'a'},
                  ),
                ],
              ),
              _evict(0),
            );
            expect(p.actions, hasLength(expectEvict ? 1 : 0));
            if (expectEvict) {
              final OrganizeAction a = p.actions.single;
              expect(a.kind, OrganizeActionKind.evict);
              expect(a.targetCollectionId, 1);
              expect(a.reason, '另一部作品的第 3 卷');
            }
          });
        }
      }
    }

    test('移出用户合集必须带理由；整理器合集不强制', () {
      final OrganizePlan user = _plan(
        _world(
          <OrganizeEntry>[
            _entry('a', inCollections: <int>[1]),
          ],
          <OrganizeCollectionFact>[
            _col(1, CollectionOrigin.user, members: <String>{'a'}),
          ],
        ),
        _evict(0, reason: '  '),
      );
      expect(user.actions, isEmpty);
      final OrganizePlan ai = _plan(
        _world(
          <OrganizeEntry>[
            _entry('a', inCollections: <int>[1]),
          ],
          <OrganizeCollectionFact>[
            _col(1, CollectionOrigin.ai, members: <String>{'a'}),
          ],
        ),
        _evict(0, reason: null),
      );
      expect(ai.actions.single.kind, OrganizeActionKind.evict);
    });

    test('自动整理只收 high 的移出', () {
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w = _world(
        <OrganizeEntry>[
          _entry('a', inCollections: <int>[1]),
        ],
        <OrganizeCollectionFact>[
          _col(1, CollectionOrigin.user, members: <String>{'a'}),
        ],
      );
      expect(
        _plan(
          w,
          _evict(0, confidence: AiOrganizeConfidence.medium),
          trigger: OrganizeTrigger.auto,
        ).actions,
        isEmpty,
      );
      expect(
        _plan(w, _evict(0), trigger: OrganizeTrigger.auto).actions,
        hasLength(1),
      );
    });

    test('挪走：用户合集 → 另一个合集记成一处 move；去处已有它 → 只剩移出', () {
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w = _world(
        <OrganizeEntry>[
          _entry('a', inCollections: <int>[1]),
          _entry('b', inCollections: <int>[1, 2]),
        ],
        <OrganizeCollectionFact>[
          _col(1, CollectionOrigin.user, members: <String>{'a', 'b', 'c'}),
          _col(2, CollectionOrigin.ai, members: <String>{'b'}),
        ],
      );
      final OrganizePlan p = _plan(
        w,
        const AiOrganizeReply(
          evictions: <AiOrganizeEvictionProposal>[
            AiOrganizeEvictionProposal(
              collection: 'C0',
              members: <int>[0, 1],
              confidence: AiOrganizeConfidence.high,
              into: 'C1',
              reason: '是另一部作品',
            ),
          ],
        ),
      );
      final OrganizeAction move = p.actions.firstWhere(
        (OrganizeAction a) => a.kind == OrganizeActionKind.move,
      );
      expect(move.fromCollectionId, 1);
      expect(move.targetCollectionId, 2);
      expect(move.entries.map((OrganizeEntry e) => e.entryKey), <String>['a']);
      final OrganizeAction evict = p.actions.firstWhere(
        (OrganizeAction a) => a.kind == OrganizeActionKind.evict,
      );
      expect(evict.entries.map((OrganizeEntry e) => e.entryKey), <String>['b']);
    });

    test('挪进 AI 曾经把它移出过的合集：丢弃（不放回）', () {
      final OrganizePlan p = _plan(
        _world(
          <OrganizeEntry>[
            _entry('a', inCollections: <int>[1]),
          ],
          <OrganizeCollectionFact>[
            _col(1, CollectionOrigin.user, members: <String>{'a'}),
            _col(2, CollectionOrigin.ai, evicted: <String>{'a'}),
          ],
        ),
        _evict(0, into: 'C1'),
      );
      expect(p.actions, isEmpty);
    });

    test('从目录合集移出、挪进不存在的合集：丢弃', () {
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w = _world(
        <OrganizeEntry>[
          _entry('a', inCollections: <int>[1]),
        ],
        <OrganizeCollectionFact>[
          _col(1, CollectionOrigin.folder, members: <String>{'a'}),
        ],
      );
      expect(_plan(w, _evict(0)).actions, isEmpty);
      expect(_plan(w, _evict(0, into: 'C9')).actions, isEmpty);
    });

    test('分组并入：只在整理器合集里的成员记成 move；在用户合集里的成员不被分组带走', () {
      final OrganizePlan p = _plan(
        _world(
          <OrganizeEntry>[
            _entry('a', inCollections: <int>[1]),
            _entry('u', inCollections: <int>[3]),
            _entry('loose'),
          ],
          <OrganizeCollectionFact>[
            _col(1, CollectionOrigin.ai, members: <String>{'a', 'x'}),
            _col(2, CollectionOrigin.ai, members: <String>{'y'}),
            _col(3, CollectionOrigin.user, members: <String>{'u'}),
          ],
        ),
        const AiOrganizeReply(
          groups: <AiOrganizeGroupProposal>[
            AiOrganizeGroupProposal(
              members: <int>[0, 1, 2],
              into: 'C1',
              name: '',
              level: AiOrganizeLevel.work,
              confidence: AiOrganizeConfidence.high,
            ),
          ],
        ),
      );
      final List<String> touched = <String>[
        for (final OrganizeAction a in p.actions)
          for (final OrganizeEntry e in a.entries)
            '${a.kind.name}:${e.entryKey}',
      ];
      expect(touched, unorderedEquals(<String>['move:a', 'add:loose']));
    });

    test('分组新建：pinned 在整理器合集里的成员不动', () {
      final OrganizePlan p = _plan(
        _world(
          <OrganizeEntry>[
            _entry('a', inCollections: <int>[1]),
            _entry('b'),
            _entry('c'),
          ],
          <OrganizeCollectionFact>[
            _col(
              1,
              CollectionOrigin.ai,
              members: <String>{'a', 'x'},
              pinned: <String>{'a'},
            ),
          ],
        ),
        const AiOrganizeReply(
          groups: <AiOrganizeGroupProposal>[
            AiOrganizeGroupProposal(
              members: <int>[0, 1, 2],
              name: 'New',
              originalTitle: 'New',
              level: AiOrganizeLevel.work,
              confidence: AiOrganizeConfidence.high,
            ),
          ],
        ),
      );
      expect(p.actions.map((OrganizeAction a) => a.kind), <OrganizeActionKind>[
        OrganizeActionKind.create,
      ]);
      expect(
        p.actions.single.entries.map((OrganizeEntry e) => e.entryKey),
        <String>['b', 'c'],
      );
    });
  });

  group('planOrganizeReply：用户合集的合并 / 改名直接产成动作（AI 管库 v3 §2.2）', () {
    ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) world() => _world(
      <OrganizeEntry>[_entry('a')],
      <OrganizeCollectionFact>[
        _col(1, CollectionOrigin.user, members: <String>{'x'}),
        _col(2, CollectionOrigin.user, members: <String>{'y'}),
        _col(3, CollectionOrigin.user, members: <String>{'z'}),
      ],
    );
    AiOrganizeReply reply({
      AiOrganizeConfidence confidence = AiOrganizeConfidence.high,
    }) => AiOrganizeReply(
      merges: <AiOrganizeMergeProposal>[
        AiOrganizeMergeProposal(
          collections: const <String>['C0', 'C1'],
          confidence: confidence,
        ),
      ],
      renames: <AiOrganizeRenameProposal>[
        AiOrganizeRenameProposal(
          collection: 'C0',
          name: '涼宮ハルヒ',
          confidence: confidence,
          reason: '原名是乱码',
        ),
        AiOrganizeRenameProposal(
          collection: 'C2',
          name: 'col1', // 与 C0 撞名：不改。
          confidence: confidence,
        ),
        AiOrganizeRenameProposal(
          collection: 'C1', // 被并掉的败方：不改。
          name: '别的名字',
          confidence: confidence,
        ),
      ],
    );

    for (final OrganizeTrigger trigger in OrganizeTrigger.values) {
      test('${trigger.name} · high：合并 + 改名直接成动作，不出建议', () {
        final OrganizePlan p = _plan(world(), reply(), trigger: trigger);
        expect(
          p.actions.map((OrganizeAction a) => a.kind),
          <OrganizeActionKind>[
            OrganizeActionKind.merge,
            OrganizeActionKind.rename,
          ],
        );
        final OrganizeAction merge = p.actions.first;
        expect(merge.targetCollectionId, 1);
        expect(merge.sourceCollectionIds, <int>[2]);
        final OrganizeAction rename = p.actions.last;
        expect(rename.targetCollectionId, 1);
        expect(rename.name, '涼宮ハルヒ');
        expect(rename.reason, '原名是乱码');
      });

      test('${trigger.name} · medium：合集级改动同合并门槛，不落', () {
        final OrganizePlan p = _plan(
          world(),
          reply(confidence: AiOrganizeConfidence.medium),
          trigger: trigger,
        );
        expect(p.actions, isEmpty);
      });
    }
  });

  group('回复解析与提示词', () {
    test('evictions 带 into / reason；into 引用不存在的合集整条丢弃；renames 可解析', () {
      final AiOrganizeReply? r = parseAiLibraryOrganizeReply(
        jsonEncode(<String, Object?>{
          'evictions': <Object?>[
            <String, Object?>{
              'collection': 'C0',
              'members': <int>[0],
              'into': 'C1',
              'reason': 'x',
              'confidence': 'high',
            },
            <String, Object?>{
              'collection': 'C0',
              'members': <int>[1],
              'into': 'C9',
              'confidence': 'high',
            },
            <String, Object?>{
              'collection': 'C0',
              'members': <int>[1],
              'into': null,
              'confidence': 'high',
            },
          ],
          'renames': <Object?>[
            <String, Object?>{
              'collection': 'C1',
              'name': 'N',
              'confidence': 'medium',
            },
            <String, Object?>{'collection': 'C1', 'confidence': 'high'},
          ],
        }),
        itemCount: 2,
        collectionIds: <String>{'C0', 'C1'},
      );
      expect(r, isNotNull);
      expect(r!.evictions, hasLength(2));
      expect(r.evictions.first.into, 'C1');
      expect(r.evictions.first.reason, 'x');
      expect(r.evictions.last.into, isNull);
      expect(r.renames.single.name, 'N');
    });

    test('条目事实带所在合集、pinned 与已被 AI 移出过的合集', () {
      final OrganizeEntry e = _entry('a', inCollections: <int>[1, 2]);
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w = _world(
        <OrganizeEntry>[e],
        <OrganizeCollectionFact>[
          _col(
            1,
            CollectionOrigin.user,
            members: <String>{'a'},
            pinned: <String>{'a'},
          ),
          _col(2, CollectionOrigin.ai, members: <String>{'a'}),
          _col(3, CollectionOrigin.ai, evicted: <String>{'a'}),
        ],
      );
      final String prompt = buildAiLibraryOrganizeUserPrompt(
        organizeRequestOf(w.facts, w.chunk, 'ja'),
      );
      expect(prompt, contains('"in":["C0","C1"]'));
      expect(prompt, contains('"pinned_in":["C0"]'));
      expect(prompt, contains('"evicted_from":["C2"]'));
      expect(prompt, contains('"user_owned":true'));
      expect(
        buildAiLibraryOrganizeSystemPrompt('books'),
        contains('"pinned_in"'),
      );
    });
  });

  group('落盘与撤销（真 Drift 内存库）', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
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

    Future<Map<String, bool>> members(int collectionId) async => <String, bool>{
      for (final MediaCollectionItemRow m in await db.getCollectionItems(
        collectionId,
      ))
        m.entryKey: m.pinnedByUser,
    };

    OrganizeEntry entry(String key) => OrganizeEntry(
      mediaType: 'epub',
      entryKey: key,
      tombstoneKey: 'epub\u0000$key',
      item: AiOrganizeItem(title: key),
    );

    test('挪走：用户合集 → AI 合集，一处记录；整轮撤销 = 回到来处并钉住、去处写墓碑不钉', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String c = await book('C');
      final int user = await db.createMediaCollection('Mine');
      await db.addToCollection(user, MediaKind.epub, b);
      await db.addToCollectionRaw(user, 'epub', a, userIntent: false);
      final int ai = await db.createMediaCollection(
        'Other',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-o',
      );
      await db.addToCollection(ai, MediaKind.epub, c, userIntent: false);
      final int runId = await run();

      await applyOrganizeActions(
        db,
        runId: runId,
        actions: <OrganizeAction>[
          OrganizeAction(
            kind: OrganizeActionKind.move,
            source: 'ai',
            confidence: AiOrganizeConfidence.high,
            fromCollectionId: user,
            targetCollectionId: ai,
            entries: <OrganizeEntry>[entry(a), entry(b)],
            reason: '是另一部作品',
          ),
        ],
      );
      expect(await members(user), <String, bool>{b: true}, reason: 'pinned 不挪');
      expect(await members(ai), <String, bool>{c: false, a: false});
      expect((await db.getMediaCollectionById(user))!.origin, 'user');
      final LibraryOrganizeChangeRow change =
          (await db.select(db.libraryOrganizeChanges).get()).single;
      expect(change.kind, 'move');
      expect(change.collectionName, 'Other');
      final Map<String, Object?> payload =
          jsonDecode(change.payloadJson) as Map<String, Object?>;
      expect(payload['reason'], '是另一部作品');
      expect((payload['from']! as Map<String, Object?>)['name'], 'Mine');

      expect(await undoLibraryOrganizeRun(db, runId), 1);
      expect(await members(user), <String, bool>{b: true, a: true});
      expect(await members(ai), <String, bool>{c: false});
      expect((await db.getMediaCollectionById(ai))!.origin, 'ai');
      expect(
        await db.collectionMemberTombstoneKeysFor('Other', 'collection'),
        isNotEmpty,
        reason: '去处写成员墓碑，AI 不再放回',
      );
    });

    test('从用户合集移空：合集随移空自删；撤销按记录重建成用户合集并钉住', () async {
      final String a = await book('A');
      final int user = await db.createMediaCollection('Solo');
      await db.addToCollectionRaw(user, 'epub', a, userIntent: false);
      final int runId = await run();
      await applyOrganizeActions(
        db,
        runId: runId,
        actions: <OrganizeAction>[
          OrganizeAction(
            kind: OrganizeActionKind.evict,
            source: 'ai',
            confidence: AiOrganizeConfidence.high,
            targetCollectionId: user,
            entries: <OrganizeEntry>[entry(a)],
            reason: '单独一部',
          ),
        ],
      );
      expect(await db.getMediaCollectionById(user), isNull);
      expect(await undoLibraryOrganizeRun(db, runId), 1);
      final MediaCollectionRow back = (await db.getMediaCollectionByNaturalKey(
        'Solo',
        'collection',
      ))!;
      expect(back.origin, 'user');
      expect(await members(back.id), <String, bool>{a: true});
    });

    test('事实：用户合集成员进条目；pinned 与本机移出记录进合集事实；目录合集成员不进', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String f = await book('F');
      final int user = await db.createMediaCollection('Mine');
      await db.addToCollection(user, MediaKind.epub, a);
      await db.addToCollectionRaw(user, 'epub', b, userIntent: false);
      final int folder = await db.createMediaCollection(
        'Dir',
        origin: CollectionOrigin.folder,
      );
      await db.addToCollection(folder, MediaKind.epub, f, userIntent: false);
      // 本机记录：AI 曾把 b 从 Mine 移出过（之后被非用户路径并回）。
      await db
          .into(db.libraryOrganizeChanges)
          .insert(
            LibraryOrganizeChangesCompanion.insert(
              runId: await run(),
              kind: 'evict',
              collectionName: 'Mine',
              collectionType: 'collection',
              source: 'ai',
              confidence: 'high',
              payloadJson: jsonEncode(<String, Object?>{
                'members': <Map<String, String>>[
                  <String, String>{'t': 'epub', 'k': b},
                ],
              }),
            ),
          );
      final LibraryOrganizeFacts facts = await loadLibraryOrganizeFacts(
        db,
        CollectionShelfDomain.books,
      );
      expect(
        facts.entries.map((OrganizeEntry e) => e.entryKey),
        unorderedEquals(<String>[a, b]),
      );
      expect(
        facts.entries.firstWhere((OrganizeEntry e) => e.entryKey == a).memberOf,
        <int>[user],
      );
      final OrganizeCollectionFact mine = facts.collections.firstWhere(
        (OrganizeCollectionFact c) => c.id == user,
      );
      expect(mine.canRelease('epub\u0000$a'), isFalse, reason: 'pinned');
      expect(mine.canRelease('epub\u0000$b'), isFalse, reason: '已移出过一次');
      expect(
        facts.collections
            .firstWhere((OrganizeCollectionFact c) => c.id == folder)
            .isFolder,
        isTrue,
      );
    });

    test('待确认建议：记账不算改动、不进整理记录、不被撤销；接受以用户身份合并；拒绝后不再提', () async {
      final String a = await book('A');
      final String b = await book('B');
      final int one = await db.createMediaCollection('One');
      final int two = await db.createMediaCollection('Two');
      await db.addToCollection(one, MediaKind.epub, a);
      await db.addToCollection(two, MediaKind.epub, b);
      final int runId = await run();
      final List<OrganizeProposal> proposals = <OrganizeProposal>[
        OrganizeProposal(
          kind: OrganizeProposalKind.merge,
          targetCollectionId: one,
          sourceCollectionIds: <int>[two],
          confidence: AiOrganizeConfidence.high,
        ),
        OrganizeProposal(
          kind: OrganizeProposalKind.rename,
          targetCollectionId: one,
          newName: 'Renamed',
          confidence: AiOrganizeConfidence.high,
        ),
      ];
      expect(
        await recordOrganizeProposals(db, runId: runId, proposals: proposals),
        2,
      );
      expect(
        await recordOrganizeProposals(db, runId: runId, proposals: proposals),
        0,
        reason: '同样的建议还在等确认：不重复记',
      );
      expect(await undoLibraryOrganizeRun(db, runId), 0);
      expect(
        (await loadLibraryOrganizeHistory(db)).single.changes,
        isEmpty,
        reason: '建议不是改动',
      );
      final List<LibraryOrganizeProposalView> pending =
          await loadLibraryOrganizeProposals(db);
      expect(pending, hasLength(2));
      final LibraryOrganizeProposalView merge = pending.firstWhere(
        (LibraryOrganizeProposalView p) => p.kind == OrganizeProposalKind.merge,
      );
      final LibraryOrganizeProposalView rename = pending.firstWhere(
        (LibraryOrganizeProposalView p) =>
            p.kind == OrganizeProposalKind.rename,
      );
      expect(merge.sourceNames, <String>['Two']);

      expect(
        await resolveLibraryOrganizeProposal(
          db,
          merge.id,
          decision: OrganizeProposalDecision.accept,
        ),
        OrganizeProposalState.accepted,
      );
      expect(await db.getMediaCollectionById(two), isNull);
      expect(await members(one), <String, bool>{a: true, b: true});
      expect(
        await resolveLibraryOrganizeProposal(
          db,
          merge.id,
          decision: OrganizeProposalDecision.accept,
        ),
        isNull,
        reason: '已处理过',
      );

      expect(
        await resolveLibraryOrganizeProposal(
          db,
          rename.id,
          decision: OrganizeProposalDecision.rejectForever,
        ),
        OrganizeProposalState.rejected,
      );
      expect((await db.getMediaCollectionById(one))!.name, 'One');
      expect(await loadLibraryOrganizeProposals(db), isEmpty);
      expect(
        await recordOrganizeProposals(
          db,
          runId: runId,
          proposals: <OrganizeProposal>[proposals.last],
        ),
        0,
        reason: '拒绝过的不再提',
      );
    });

    test('改名建议：新名字落地前被占了 → stale，不动合集', () async {
      final int one = await db.createMediaCollection('One');
      await db.addToCollection(one, MediaKind.epub, await book('A'));
      await recordOrganizeProposals(
        db,
        runId: await run(),
        proposals: <OrganizeProposal>[
          OrganizeProposal(
            kind: OrganizeProposalKind.rename,
            targetCollectionId: one,
            newName: 'Taken',
            confidence: AiOrganizeConfidence.high,
          ),
        ],
      );
      await db.createMediaCollection('Taken');
      final LibraryOrganizeProposalView p = (await loadLibraryOrganizeProposals(
        db,
      )).single;
      expect(
        await resolveLibraryOrganizeProposal(
          db,
          p.id,
          decision: OrganizeProposalDecision.accept,
        ),
        OrganizeProposalState.stale,
      );
      expect((await db.getMediaCollectionById(one))!.name, 'One');
    });
  });
}
