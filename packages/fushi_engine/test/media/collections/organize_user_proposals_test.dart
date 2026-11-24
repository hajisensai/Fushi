// 用户 2026-11-24 拍板：「用户的合集整理器永远不能往外移成员 取消这个设定吧，我觉得
// 让用户显式同意就行了吧，用户可以永远拒绝」。动用户合集（移出成员 / 收敛并掉）一律
// 记成待确认建议：同意（以用户身份执行，可撤销、撤销复原位置与 pin）/ 这次不（本机
// 暂缓）/ 永远不（钉住相关成员，跨端生效）。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/organize_convergence.dart';
import 'package:test/test.dart';

void main() {
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

  /// 用户合集，成员按顺序由非用户路径放进来（不钉住）。
  Future<int> userCollection(String name, List<String> uids) async {
    final int id = await db.createMediaCollection(
      name,
      origin: CollectionOrigin.user,
    );
    for (final String u in uids) {
      await db.addToCollectionRaw(id, 'epub', u, userIntent: false);
    }
    return id;
  }

  Future<List<String>> order(int id) async => <String>[
    for (final MediaCollectionItemRow i in await db.getCollectionItems(id))
      i.entryKey,
  ];

  Future<Map<String, bool>> pins(int id) async => <String, bool>{
    for (final MediaCollectionItemRow i in await db.getCollectionItems(id))
      i.entryKey: i.pinnedByUser,
  };

  CollectionMemberKey key(String uid) => (mediaType: 'epub', entryKey: uid);

  Future<int> runCount() async =>
      (await db.select(db.libraryOrganizeRuns).get()).length;

  group('recordMemberRemovalProposals', () {
    test('自建运行；去重；钉住的成员剔除，剔空不记；标题快照', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String c = await book('C');
      final int col = await userCollection('Show', <String>[a, b, c]);
      await db.addToCollectionRaw(col, 'epub', c, pinnedByUser: true);

      final List<MemberRemovalProposal> ps = <MemberRemovalProposal>[
        MemberRemovalProposal(
          collectionId: col,
          members: <CollectionMemberKey>[key(b), key(c)],
          reasonCode: kMemberRemovalReasonDiscExtra,
        ),
      ];
      expect(
        await recordMemberRemovalProposals(
          db,
          trigger: 'disc_import',
          proposals: ps,
        ),
        1,
      );
      expect(await runCount(), 1);
      final LibraryOrganizeProposalView v = (await loadLibraryOrganizeProposals(
        db,
      )).single;
      expect(v.kind, OrganizeProposalKind.removeMembers);
      expect(v.targetName, 'Show');
      expect(v.reasonCode, kMemberRemovalReasonDiscExtra);
      expect(v.members.map((OrganizeProposalMember m) => m.entryKey), <String>[
        b,
      ], reason: '钉住的 C 剔除');
      expect(v.members.single.title, 'B');
      expect(v.toJson()['reasonCode'], kMemberRemovalReasonDiscExtra);

      // 同签名（成员顺序不同也算）在等确认：不重复记、不建空运行。
      expect(
        await recordMemberRemovalProposals(
          db,
          trigger: 'disc_import',
          proposals: <MemberRemovalProposal>[
            MemberRemovalProposal(
              collectionId: col,
              members: <CollectionMemberKey>[key(c), key(b)],
              reasonCode: kMemberRemovalReasonDiscExtra,
            ),
          ],
        ),
        0,
      );
      expect(await runCount(), 1);

      // 全是钉住的 / 不在合集里的：剔空不记。
      expect(
        await recordMemberRemovalProposals(
          db,
          trigger: 'disc_import',
          proposals: <MemberRemovalProposal>[
            MemberRemovalProposal(
              collectionId: col,
              members: <CollectionMemberKey>[key(c), key('nope')],
              reasonCode: kMemberRemovalReasonDiscExtra,
            ),
          ],
        ),
        0,
      );
    });

    test('这次不：暂缓期内同签名不再记、列表不显示；到期后可再提', () async {
      final String a = await book('A');
      final String b = await book('B');
      final int col = await userCollection('Show', <String>[a, b]);
      final List<MemberRemovalProposal> ps = <MemberRemovalProposal>[
        MemberRemovalProposal(
          collectionId: col,
          members: <CollectionMemberKey>[key(b)],
          reasonCode: kMemberRemovalReasonDiscExtra,
        ),
      ];
      await recordMemberRemovalProposals(db, trigger: 't', proposals: ps);
      final int id = (await loadLibraryOrganizeProposals(db)).single.id;
      expect(
        await resolveLibraryOrganizeProposal(
          db,
          id,
          decision: OrganizeProposalDecision.defer,
        ),
        OrganizeProposalState.deferred,
      );
      expect(await order(col), <String>[a, b], reason: '暂缓不执行');
      expect(await pins(col), <String, bool>{a: false, b: false});
      expect(await loadLibraryOrganizeProposals(db), isEmpty);
      final LibraryOrganizeProposalView deferred =
          (await loadLibraryOrganizeProposals(db, pendingOnly: false)).single;
      expect(deferred.state, OrganizeProposalState.deferred);
      final int now = DateTime.now().millisecondsSinceEpoch;
      expect(
        deferred.deferredUntil! - now,
        closeTo(kOrganizeProposalDeferDuration.inMilliseconds, 60000),
      );
      expect(
        await recordMemberRemovalProposals(db, trigger: 't', proposals: ps),
        0,
        reason: '暂缓期内',
      );

      // 把暂缓期拨到过去：同签名可再提。
      final LibraryOrganizeChangeRow row = await (db.select(
        db.libraryOrganizeChanges,
      )..where((t) => t.id.equals(id))).getSingle();
      await (db.update(
        db.libraryOrganizeChanges,
      )..where((t) => t.id.equals(id))).write(
        LibraryOrganizeChangesCompanion(
          payloadJson: Value<String>(
            row.payloadJson.replaceFirst(
              '"deferredUntil":${deferred.deferredUntil}',
              '"deferredUntil":1',
            ),
          ),
        ),
      );
      expect(
        await recordMemberRemovalProposals(db, trigger: 't', proposals: ps),
        1,
      );
      expect(await loadLibraryOrganizeProposals(db), hasLength(1));
    });
  });

  group('resolveLibraryOrganizeProposal / undoLibraryOrganizeProposal', () {
    test('永远不：成员被钉住、状态 rejected，同样的建议因钉住与签名都不再记', () async {
      final String a = await book('A');
      final String b = await book('B');
      final int col = await userCollection('Show', <String>[a, b]);
      final List<MemberRemovalProposal> ps = <MemberRemovalProposal>[
        MemberRemovalProposal(
          collectionId: col,
          members: <CollectionMemberKey>[key(b)],
          reasonCode: kMemberRemovalReasonDiscExtra,
        ),
      ];
      await recordMemberRemovalProposals(db, trigger: 't', proposals: ps);
      final int id = (await loadLibraryOrganizeProposals(db)).single.id;
      expect(
        await resolveLibraryOrganizeProposal(
          db,
          id,
          decision: OrganizeProposalDecision.rejectForever,
        ),
        OrganizeProposalState.rejected,
      );
      expect(await pins(col), <String, bool>{a: false, b: true});
      expect(await order(col), <String>[a, b]);
      expect(
        await recordMemberRemovalProposals(db, trigger: 't', proposals: ps),
        0,
      );
      expect(
        await resolveLibraryOrganizeProposal(
          db,
          id,
          decision: OrganizeProposalDecision.accept,
        ),
        isNull,
        reason: '已处理过',
      );
    });

    test('同意：移出（用户身份）；撤销：放回原位、pin 照旧、建议回到等确认', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String c = await book('C');
      final String d = await book('D');
      final int col = await userCollection('Show', <String>[a, b, c, d]);
      await recordMemberRemovalProposals(
        db,
        trigger: 't',
        proposals: <MemberRemovalProposal>[
          MemberRemovalProposal(
            collectionId: col,
            members: <CollectionMemberKey>[key(b), key(d)],
            reasonCode: kMemberRemovalReasonDiscExtra,
          ),
        ],
      );
      final int id = (await loadLibraryOrganizeProposals(db)).single.id;
      expect(
        await resolveLibraryOrganizeProposal(
          db,
          id,
          decision: OrganizeProposalDecision.accept,
        ),
        OrganizeProposalState.accepted,
      );
      expect(await order(col), <String>[a, c]);
      expect(await loadLibraryOrganizeProposals(db), isEmpty);

      expect(await undoLibraryOrganizeProposal(db, id), isTrue);
      expect(await order(col), <String>[a, b, c, d], reason: '按移出前位置插回');
      expect(await pins(col), <String, bool>{
        a: false,
        b: false,
        c: false,
        d: false,
      });
      expect(
        (await loadLibraryOrganizeProposals(db)).single.state,
        OrganizeProposalState.pending,
      );
      expect(
        await undoLibraryOrganizeProposal(db, id),
        isFalse,
        reason: '已是 pending，没有可撤的',
      );
    });

    test('同意时把合集移空 → 撤销按原来源重建', () async {
      final String a = await book('A');
      final int col = await userCollection('Solo', <String>[a]);
      await recordMemberRemovalProposals(
        db,
        trigger: 't',
        proposals: <MemberRemovalProposal>[
          MemberRemovalProposal(
            collectionId: col,
            members: <CollectionMemberKey>[key(a)],
            reasonCode: kMemberRemovalReasonDiscExtra,
          ),
        ],
      );
      final int id = (await loadLibraryOrganizeProposals(db)).single.id;
      await resolveLibraryOrganizeProposal(
        db,
        id,
        decision: OrganizeProposalDecision.accept,
      );
      expect(await db.getMediaCollectionById(col), isNull);
      expect(await undoLibraryOrganizeProposal(db, id), isTrue);
      final MediaCollectionRow back = (await db.getMediaCollectionByNaturalKey(
        'Solo',
        'collection',
      ))!;
      expect(back.origin, CollectionOrigin.user.dbValue);
      expect(await order(back.id), <String>[a]);
    });

    test('合并建议：同意后撤销把败方拆回；永远不 = 败方成员全钉住', () async {
      final String a = await book('A');
      final String b = await book('B');
      final String c = await book('C');
      final int one = await userCollection('One', <String>[a]);
      final int two = await userCollection('Two', <String>[b]);
      final int three = await userCollection('Three', <String>[c]);
      final int runId = await db
          .into(db.libraryOrganizeRuns)
          .insert(
            LibraryOrganizeRunsCompanion.insert(
              domain: 'all',
              trigger: 'convergence',
              startedAt: 1,
              status: 'done',
            ),
          );
      await recordOrganizeProposals(
        db,
        runId: runId,
        proposals: convergenceOrganizeProposals(<ConvergenceProposal>[
          ConvergenceProposal(targetId: one, sourceIds: <int>[two]),
          ConvergenceProposal(targetId: one, sourceIds: <int>[three]),
        ]),
      );
      final List<LibraryOrganizeProposalView> ps =
          await loadLibraryOrganizeProposals(db);
      final LibraryOrganizeProposalView mergeTwo = ps.firstWhere(
        (LibraryOrganizeProposalView p) => p.sourceNames.single == 'Two',
      );
      final LibraryOrganizeProposalView mergeThree = ps.firstWhere(
        (LibraryOrganizeProposalView p) => p.sourceNames.single == 'Three',
      );

      expect(
        await resolveLibraryOrganizeProposal(
          db,
          mergeTwo.id,
          decision: OrganizeProposalDecision.accept,
        ),
        OrganizeProposalState.accepted,
      );
      expect(await db.getMediaCollectionById(two), isNull);
      expect((await order(one)).toSet(), <String>{a, b});
      expect(await undoLibraryOrganizeProposal(db, mergeTwo.id), isTrue);
      final MediaCollectionRow twoBack = (await db
          .getMediaCollectionByNaturalKey('Two', 'collection'))!;
      expect(await order(twoBack.id), <String>[b]);
      expect(await order(one), <String>[a]);

      expect(
        await resolveLibraryOrganizeProposal(
          db,
          mergeThree.id,
          decision: OrganizeProposalDecision.rejectForever,
        ),
        OrganizeProposalState.rejected,
      );
      expect(await pins(three), <String, bool>{c: true});
      expect(await db.getMediaCollectionById(three), isNotNull);
    });
  });

  group('收敛：用户合集当败方只出建议', () {
    ConvergenceCollection c(
      int id,
      String name, {
      CollectionOrigin origin = CollectionOrigin.user,
      String? key = 'k',
      required List<String> members,
      List<String> pinned = const <String>[],
    }) => ConvergenceCollection(
      id: id,
      name: name,
      collectionType: 'collection',
      origin: origin,
      organizeKey: key,
      organizeAliases: const <String>{},
      memberWireKeys: <String>{for (final String m in members) 'epub\u0000$m'},
      pinnedMemberWireKeys: <String>{
        for (final String m in pinned) 'epub\u0000$m',
      },
    );

    test('两个同主键用户合集：产出建议、不产出合并；顺序无关、幂等', () {
      final List<ConvergenceCollection> input = <ConvergenceCollection>[
        c(1, 'U1', members: <String>['a']),
        c(2, 'U2', members: <String>['b']),
      ];
      final ConvergencePlan p1 = planOrganizeConvergenceWithProposals(input);
      final ConvergencePlan p2 = planOrganizeConvergenceWithProposals(
        input.reversed.toList(),
      );
      expect(p1.merges, isEmpty);
      expect(planOrganizeConvergence(input), isEmpty);
      expect(p1.proposals, hasLength(1));
      expect(p1.proposals.single.targetId, 1, reason: '同为用户合集按名字序');
      expect(p1.proposals.single.sourceIds, <int>[2]);
      expect(p2.proposals.single.targetId, p1.proposals.single.targetId);
      expect(p2.proposals.single.sourceIds, p1.proposals.single.sourceIds);
      final ConvergencePlan again = planOrganizeConvergenceWithProposals(input);
      expect(again.proposals.single.sourceIds, <int>[2]);
    });

    test('与整理器合集同组：整理器合集照常并进用户胜方，另一个用户合集出建议', () {
      final ConvergencePlan p = planOrganizeConvergenceWithProposals(
        <ConvergenceCollection>[
          c(1, 'A', origin: CollectionOrigin.ai, members: <String>['a']),
          c(2, 'U1', members: <String>['b']),
          c(3, 'U2', members: <String>['c']),
        ],
      );
      expect(p.merges.single.targetId, 2);
      expect(p.merges.single.sourceIds, <int>[1]);
      expect(p.proposals.single.targetId, 2);
      expect(p.proposals.single.sourceIds, <int>[3]);
    });

    test('败方成员全被钉住（永远不）后不再提；部分钉住照提', () {
      expect(
        planOrganizeConvergenceWithProposals(<ConvergenceCollection>[
          c(1, 'U1', members: <String>['a']),
          c(2, 'U2', members: <String>['b', 'c'], pinned: <String>['b', 'c']),
        ]).proposals,
        isEmpty,
      );
      expect(
        planOrganizeConvergenceWithProposals(<ConvergenceCollection>[
          c(1, 'U1', members: <String>['a']),
          c(2, 'U2', members: <String>['b', 'c'], pinned: <String>['b']),
        ]).proposals.single.sourceIds,
        <int>[2],
      );
    });

    test('convergeOrganizedCollections：记一条合并建议（trigger convergence），不并；'
        '再跑不重复；永远不后不再记', () async {
      final String a = await book('A');
      final String b = await book('B');
      final int u1 = await userCollection('U1', <String>[a]);
      final int u2 = await userCollection('U2', <String>[b]);
      for (final int id in <int>[u1, u2]) {
        await db.setMediaCollectionOrganizeState(
          id,
          origin: CollectionOrigin.user,
          organizeKey: 't:books:same',
          organizeAliases: const <String>{},
        );
      }
      expect(await convergeOrganizedCollections(db), 0);
      expect(await db.getMediaCollectionById(u2), isNotNull);
      final LibraryOrganizeProposalView p = (await loadLibraryOrganizeProposals(
        db,
      )).single;
      expect(p.kind, OrganizeProposalKind.merge);
      expect(p.targetName, 'U1');
      expect(p.sourceNames, <String>['U2']);
      final List<LibraryOrganizeRunRow> runs = await db
          .select(db.libraryOrganizeRuns)
          .get();
      expect(runs.single.trigger, kOrganizeConvergenceTrigger);

      await convergeOrganizedCollections(db);
      expect(await loadLibraryOrganizeProposals(db), hasLength(1));
      expect(await runCount(), 1, reason: '没有新建议不建空运行');

      await resolveLibraryOrganizeProposal(
        db,
        p.id,
        decision: OrganizeProposalDecision.rejectForever,
      );
      expect(await pins(u2), <String, bool>{b: true});
      await convergeOrganizedCollections(db);
      expect(await loadLibraryOrganizeProposals(db), isEmpty);
      expect(await runCount(), 1);
    });
  });
}
