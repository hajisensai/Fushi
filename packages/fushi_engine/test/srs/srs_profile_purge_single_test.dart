// 「删掉一个 profile 在复习库里的本机数据」只有一份实现（BUG-4292）。协议 3 时代采用（srsAdoptProfileUid / 关联改
// uid）删旧 uid 时经 Rust `profile_purge`；新代（G9-5）里关联与备份合并都不再改 profile uid，「采用」是内核
// `collection_adopt` 认领对方的集合：本机是空集合就在同一个事务里丢掉它（`discard.rs` `discard_collection`，表清单
// 现查）、换绑过去；不是空集合就按 D27 并入，本机数据不丢。`profile_purge` 只剩删 profile 一条路（srs_profile_cleanup）。
//
// 这里经关联器（[SrsDbProfileLinker.adopt]）在一个假的位置目录上认领，看库里留下什么：
// - 认领：本机改绑到对方的集合，原来的集合标识不再绑着、不留第二个集合，主库 uid 不变。打开过的 profile 日志里已有
//   内置实体的记录（[SrsDbStore.ensureBuiltins]），内核不把它当成可丢的空集合（只认只有 `Salts` 的），按 D27 改绑过去、
//   本机身份与内置记录随身份带过去；真正的空集合丢弃由 Rust `discard.rs` / `identity.rs` 的测试覆盖；
// - 与在途写入交错：不管谁先，写下的笔记都在（写入先落 = 不是空集合，按 D27 并入；认领先做 = 写进新集合）；
// - 认领目标已是本机另一个 profile 的集合：拒绝，什么都不动。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart' show kSrs4Root;
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsCore;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';
import 'support/srs_raw_sql.dart';

/// 位置上另一个集合的目录名：比任何按时间生成的 profile uid（UUIDv7）都小，本机按 D27 是改绑过去的一方。
const String _kForeignDir = '00000000-0000-7000-8000-000000000000';

/// 那个集合的标识。
const String _kForeignCollection = '0193a1b2-0000-7000-8000-00000000cafe';

/// 在 [root] 的同步位置上放一个只有 `v4/meta.json` 的集合目录 [dirName]（集合标识 [collection]）。
void _plantCollection(Directory root, String dirName, String collection) {
  final Directory v4 = Directory(
    '${root.path}/$kSrsSync2Namespace/$dirName/$kSrs4Root',
  )..createSync(recursive: true);
  File('${v4.path}/meta.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'collection': collection,
      'fmt': 'fushi-srs-meta/4',
      'minReader': 4,
      'v': 4,
    }),
  );
}

/// 库里集合标识 [collection] 的绑定行数。
Future<int> _collectionRows(SrsCore db, String collection) async =>
    (await db
            .customSelect(
              'SELECT COUNT(*) AS c FROM collections WHERE lower(hex(collection)) = ?',
              variables: <Variable<Object>>[
                Variable<String>(collection.replaceAll('-', '').toLowerCase()),
              ],
            )
            .getSingle())
        .read<int>('c');

/// 库里绑定的集合总数。
Future<int> _allCollections(SrsCore db) async =>
    (await db.customSelect('SELECT COUNT(*) AS c FROM collections').getSingle())
        .read<int>('c');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FushiDatabase main;
  late SrsStorage srs;
  late int profileId;
  late String uid;
  late Directory root;
  late LocalDirectoryAssetStore location;

  setUp(() async {
    main = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(main.close);
    srs = await openTestSrsStorage();
    final int now = DateTime.now().millisecondsSinceEpoch;
    profileId = await main.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    uid = await main.profileUidOf(profileId);
    root = Directory.systemTemp.createTempSync('fushi_srs_purge_single_');
    addTearDown(() => root.deleteSync(recursive: true));
    location = LocalDirectoryAssetStore(root);
  });

  Future<SrsDbStore> open(String profileUid) => SrsDbStore.open(
    core: srs.core,
    profileUid: profileUid,
    deviceId: 'devA',
    engine: const SrsFakeEngine(),
  );

  SrsDbProfileLinker linkerFor(SrsDbStore Function() current) =>
      SrsDbProfileLinker(
        db: main,
        activeProfileId: () async => profileId,
        reopenStore: () async => current(),
      );

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  test('认领：本机改绑到对方集合，原来的集合标识不再绑着、不留第二个集合，主库 uid 不变', () async {
    final SrsDbStore store = await open(uid);
    final String oldCollection = store.sync2Collection!;
    expect(await _collectionRows(srs.core, oldCollection), 1);
    _plantCollection(root, _kForeignDir, _kForeignCollection);

    final SrsProfileAdoptResult result = await linkerFor(
      () => store,
    ).adopt(store, _kForeignDir, within: location);

    expect(result.store.sync2Collection, _kForeignCollection);
    expect(result.store.sync2Dir, _kForeignDir);
    expect(result.store.profileUid, uid);
    expect(await main.profileUidOf(profileId), uid, reason: '主库 uid 不变');
    expect(await _collectionRows(srs.core, oldCollection), 0);
    expect(await _collectionRows(srs.core, _kForeignCollection), 1);
    expect(await _allCollections(srs.core), 1, reason: '不留第二个集合');
  });

  for (final bool writeFirst in <bool>[true, false]) {
    test('认领与在途写入交错：不管谁先，写下的笔记都在（${writeFirst ? '写入先发' : '认领先发'}）', () async {
      final SrsDbStore store = await open(uid);
      _plantCollection(root, _kForeignDir, _kForeignCollection);
      late final Future<String> writing;
      late final Future<SrsProfileAdoptResult> adopting;
      if (writeFirst) {
        writing = addNote(store, '在途');
        adopting = linkerFor(
          () => store,
        ).adopt(store, _kForeignDir, within: location);
      } else {
        adopting = linkerFor(
          () => store,
        ).adopt(store, _kForeignDir, within: location);
        writing = addNote(store, '在途');
      }
      final String note = await writing;
      await adopting;

      expect(store.sync2Collection, _kForeignCollection);
      expect(
        (await store.note(
          note,
        ))?.field(srsLapisFieldId(store.profileUid, 'Expression')),
        '在途',
      );
    });
  }

  test('认领目标已是本机另一个 profile 的集合：拒绝，什么都不动', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int otherId = await main.insertProfile(
      ProfilesCompanion.insert(name: 'Other', createdAt: now, updatedAt: now),
    );
    final SrsDbStore other = await open(await main.profileUidOf(otherId));
    final SrsDbStore store = await open(uid);
    final String before = store.sync2Collection!;
    _plantCollection(root, other.sync2Dir!, other.sync2Collection!);

    await expectLater(
      linkerFor(() => store).adopt(store, other.sync2Dir!, within: location),
      throwsStateError,
    );
    expect(store.sync2Collection, before);
    expect(other.sync2Collection, isNot(before));
    expect(await _collectionRows(srs.core, before), 1);
  });
}
