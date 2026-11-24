// 手动「合并进共享复习库」（组合阶段 5，设计 §4.3）：真主库 + 真内核。
//
// - 合并后：只在独立库的笔记进了共享库，同 guid 的冲突默认保留共享库、选了独立库就取它；独立库的媒体拷进共享库、
//   原目录删掉；组合的 `srs.library` 恢复继承（不再有可合并的独立库）；墓碑收尾干净。
// - 复习页正看着独立库：合并在那份副本最后一段独占区里做，之后副本作废。
// - 内核并完、组合还没恢复继承就中断：`finishPending` 补做。
// - 确认框：冲突逐条选（默认共享库），确认把选择交给合并；失败在框里报错、不关框。
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_library_merge_dialog.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart'
    show FushiComboNode;
import 'package:fushi/src/profile/combo/srs_library_resolver.dart';
import 'package:fushi/src/srs/srs_library_merge.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_collection_merge.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

void main() {
  late FushiDatabase db;
  late SrsStorage storage;
  late int defaultId;
  late int mangaId;
  late String sharedUid;
  late String ownUid;
  late SrsDbStore shared;
  late SrsDbStore own;
  late Directory support;
  late ComboRepository combos;
  final List<String> released = <String>[];

  Future<void> put(int id, String key, String value) => db.upsertProfileSetting(
    ProfileSettingsCompanion.insert(
      profileId: id,
      category: kComboSyntheticCategory,
      key: key,
      value: value,
    ),
  );

  Future<int> profile(String name, ComboRole role) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int id = await db.insertProfile(
      ProfilesCompanion.insert(name: name, createdAt: now, updatedAt: now),
    );
    await put(id, kComboRoleKey, role.wire);
    return id;
  }

  Future<String> note(SrsDbStore s, String guid, String expression) =>
      s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(s.profileUid, 'Expression'): expression,
        },
        guid: guid,
      );

  SrsLibraryMerger merger({required SrsDbStore? active}) => SrsLibraryMerger(
    SrsLibraryMergeDeps(
      storage: () async => storage,
      activeStore: () async => active,
      releaseForeign: (String uid) async => released.add(uid),
      supportRoot: () async => support,
      libraries: () => loadComboSrsLibraries(db),
      profiles: db.getAllProfiles,
    ),
  );

  Future<void> restore() =>
      combos.restoreInheritanceOf(mangaId, FushiComboNode.srsLibrary);

  late String sharedNote;

  setUp(() async {
    released.clear();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    defaultId = await profile('Default', ComboRole.defaults);
    mangaId = await profile('Manga', ComboRole.named);
    sharedUid = await db.profileUidOf(defaultId);
    ownUid = await db.profileUidOf(mangaId);
    await put(defaultId, kComboSrsSharedUidKey, sharedUid);
    await put(mangaId, kComboSrsLibrarySplitKey, '1');
    await put(mangaId, kComboSrsLibrarySettingKey, kComboSrsLibraryOwnValue);
    combos = ComboRepository(
      db,
      liveSettings: ({Set<String>? categories}) async =>
          const <SettingKey, String>{},
      activeProfileId: () async => defaultId,
    );
    storage = await openSrsTestStorage();
    shared = await SrsDbStore.open(
      core: storage.core,
      profileUid: sharedUid,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
    );
    own = await SrsDbStore.open(
      core: storage.core,
      profileUid: ownUid,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
    );
    sharedNote = await note(shared, 'g-shared', '鳥');
    await note(own, 'g-shared', '鯨');
    await note(own, 'g-own', '猫');
    support = Directory.systemTemp.createTempSync('fushi_srs_merge_');
    final File media = File(
      '${SrsMediaStore.directoryFor(support, ownUid).path}/a.png',
    );
    await media.parent.create(recursive: true);
    await media.writeAsBytes(<int>[1, 2, 3]);
    addTearDown(() {
      try {
        support.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄滞后。
      }
    });
  });

  tearDown(() => db.close());

  test('合并：冲突默认保留共享库，独立库的笔记 / 媒体进共享库，组合恢复继承', () async {
    final SrsLibraryMerger m = merger(active: shared);
    final SrsLibraryMergePlan plan = (await m.plan(mangaId))!;
    expect(plan.fromUid, ownUid);
    expect(plan.intoUid, sharedUid);
    expect(plan.profileName, 'Manga');
    expect(plan.preview.shared, 1);
    expect(plan.preview.added, 1);
    expect(plan.preview.conflicts, hasLength(1));
    final SrsMergeConflict c = plan.preview.conflicts.single;
    expect(c.note, sharedNote);
    expect(c.fields.single.shared, '鳥');
    expect(c.fields.single.merged, '鯨');
    // 两档模型下的 RWKV 快照：独立库的都删、共享库的不动。
    File snap(String dir, String uid) =>
        File('${support.path}/srs_rwkv/$dir/rwkv-$uid-m.snap')
          ..createSync(recursive: true);
    final List<File> ownSnaps = <File>[
      snap('state', ownUid),
      snap('state-tiny', ownUid),
    ];
    final File sharedSnap = snap('state-tiny', sharedUid);

    final SrsMergeResult r = await m.merge(
      plan,
      const <String, SrsMergeChoice>{},
      restoreInheritance: restore,
    );
    expect(r.merged, isTrue);
    expect(r.conflicts, 1);
    expect(r.keptMerged, 0);
    expect(released, contains(ownUid));
    expect(shared.isUsable, isTrue);
    expect((await shared.note(sharedNote))!.fields.values, contains('鳥'));
    expect(await shared.note(shared.kernelIds.note('g-own')), isNotNull);
    expect(
      File(
        '${SrsMediaStore.directoryFor(support, sharedUid).path}/a.png',
      ).existsSync(),
      isTrue,
    );
    expect(SrsMediaStore.directoryFor(support, ownUid).existsSync(), isFalse);
    expect(ownSnaps.where((File f) => f.existsSync()), isEmpty);
    expect(sharedSnap.existsSync(), isTrue);
    expect(
      SrsLibraryMerger.endpointsOf(await loadComboSrsLibraries(db), mangaId),
      isNull,
    );
    expect(await srsPendingCollectionMerges(storage.core), isEmpty);
  });

  test('复习页正看着独立库：在它的独占区里并、之后它作废；选了独立库就取它的值', () async {
    final SrsLibraryMerger m = merger(active: own);
    final SrsLibraryMergePlan plan = (await m.plan(mangaId))!;
    final SrsMergeResult r = await m.merge(plan, <String, SrsMergeChoice>{
      sharedNote: SrsMergeChoice.merged,
    }, restoreInheritance: restore);
    expect(r.keptMerged, 1);
    expect(own.isUsable, isFalse);
    expect(released, contains(sharedUid));
    expect((await shared.note(sharedNote))!.fields.values, contains('鯨'));
  });

  test('预览之后归属变了：报过时，什么都不改', () async {
    final SrsLibraryMerger m = merger(active: shared);
    final SrsLibraryMergePlan plan = (await m.plan(mangaId))!;
    await restore();
    await expectLater(
      m.merge(
        plan,
        const <String, SrsMergeChoice>{},
        restoreInheritance: restore,
      ),
      throwsA(isA<SrsLibraryMergeStaleException>()),
    );
    expect(await shared.note(shared.kernelIds.note('g-own')), isNull);
  });

  test('内核并完、组合还没恢复继承就中断：进配置管理页时补做', () async {
    await srsCollectionMerge(
      storage.core,
      from: ownUid,
      into: sharedUid,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(await srsPendingCollectionMerges(storage.core), hasLength(1));
    final List<int> restored = <int>[];
    final int n = await merger(active: shared).finishPending(
      restoreInheritance: (int id) async {
        restored.add(id);
        await combos.restoreInheritanceOf(id, FushiComboNode.srsLibrary);
      },
    );
    expect(n, 1);
    expect(restored, <int>[mangaId]);
    expect(await srsPendingCollectionMerges(storage.core), isEmpty);
    expect(
      SrsLibraryMerger.endpointsOf(await loadComboSrsLibraries(db), mangaId),
      isNull,
    );
    expect(await resolveSrsLibraryUid(db, baseProfileId: mangaId), sharedUid);
  });

  group('确认框', () {
    SrsLibraryMergePlan planOf(SrsMergePreview p) => SrsLibraryMergePlan(
      profileId: 2,
      profileName: 'Manga',
      fromUid: 'from',
      intoUid: 'into',
      preview: p,
    );

    final SrsMergePreview preview = SrsMergePreview.fromJson(<String, Object?>{
      'bound': true,
      'from': <String, Object?>{'notes': 2, 'cards': 2, 'reviews': 3},
      'shared': 1,
      'added': 1,
      'conflicts': <Object?>[
        <String, Object?>{
          'note': 'n1',
          'guid': 'g',
          'newer': 'from',
          'typeDiffers': false,
          'deletedDiffers': false,
          'into': <String, Object?>{
            'type': 't',
            'typeName': 'Lapis',
            'deleted': false,
            'sort': '鳥',
            'updated': 1,
          },
          'from': <String, Object?>{
            'type': 't',
            'typeName': 'Lapis',
            'deleted': false,
            'sort': '鯨',
            'updated': 2,
          },
          'fields': <Object?>[
            <String, Object?>{
              'field': 'f',
              'name': 'Expression',
              'into': '鳥',
              'from': '鯨',
            },
          ],
        },
      ],
    });

    Future<void> pump(WidgetTester tester, Widget dialog) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: dialog)));
      await tester.pumpAndSettle();
    }

    testWidgets('默认保留共享库；改选后确认把选择交给合并', (WidgetTester tester) async {
      Map<String, SrsMergeChoice>? got;
      await pump(
        tester,
        SrsLibraryMergeDialog(
          plan: planOf(preview),
          run: (Map<String, SrsMergeChoice> r) async {
            got = r;
            return const SrsMergeResult(
              merged: true,
              conflicts: 1,
              rewritten: 1,
              keptMerged: 1,
            );
          },
          errorText: (Object e) => '$e',
        ),
      );
      expect(find.text(t.srs_library_merge_conflicts(n: '1')), findsOneWidget);
      final Finder mergedSegment = find.text(
        t.srs_library_merge_side_newer(side: t.srs_library_merge_keep_merged),
      );
      await tester.ensureVisible(mergedSegment);
      await tester.pumpAndSettle();
      await tester.tap(mergedSegment);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_library_merge_confirm')),
      );
      await tester.pumpAndSettle();
      expect(got, <String, SrsMergeChoice>{'n1': SrsMergeChoice.merged});
    });

    testWidgets('不改选直接确认：选择为空（全保留共享库）；失败在框里报错', (WidgetTester tester) async {
      final List<Map<String, SrsMergeChoice>> calls =
          <Map<String, SrsMergeChoice>>[];
      await pump(
        tester,
        SrsLibraryMergeDialog(
          plan: planOf(preview),
          run: (Map<String, SrsMergeChoice> r) async {
            calls.add(r);
            throw StateError('boom');
          },
          errorText: (Object e) => 'failed: $e',
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_library_merge_confirm')),
      );
      await tester.pumpAndSettle();
      expect(calls.single, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('srs_library_merge_error')),
        findsOneWidget,
      );
      expect(find.byType(SrsLibraryMergeDialog), findsOneWidget);
    });

    testWidgets('合并在跑时系统返回 / 点遮罩关不掉框；跑完带结果关框', (WidgetTester tester) async {
      final Completer<SrsMergeResult> running = Completer<SrsMergeResult>();
      SrsMergeResult? popped;
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  popped = await showDialog<SrsMergeResult>(
                    context: context,
                    builder: (BuildContext _) => SrsLibraryMergeDialog(
                      plan: planOf(preview),
                      run: (Map<String, SrsMergeChoice> r) => running.future,
                      errorText: (Object e) => '$e',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_library_merge_confirm')),
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(SrsLibraryMergeDialog), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.byType(SrsLibraryMergeDialog), findsOneWidget);
      const SrsMergeResult result = SrsMergeResult(
        merged: true,
        conflicts: 1,
        rewritten: 0,
        keptMerged: 0,
      );
      running.complete(result);
      await tester.pumpAndSettle();
      expect(find.byType(SrsLibraryMergeDialog), findsNothing);
      expect(popped, same(result));
    });
  });
}
