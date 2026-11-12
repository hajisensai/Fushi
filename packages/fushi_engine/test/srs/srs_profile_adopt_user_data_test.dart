// 采用对端 uid 的「有数据」判据（BUG 文档见 docs/bugs/，回归）：以前同步路径的关联（SrsDbProfileLinker.link）与
// 备份恢复的改 uid（srsCanAdoptProfileUid）只看有没有笔记。只建了牌组 / 改了预设、还没有笔记的 profile 被当成空的，
// 自动采用对方 uid，经 profile_purge 删掉旧 uid 的全部行：自建牌组与预设一起没了。
//
// 真数据库 + 真同步引擎，按 SrsSyncScheduler 的顺序跑：关联（link）→ 同步 v2 的一轮 → 发布说明文件（publish）。
import 'dart:io';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart'
    show srsCanAdoptProfileUid;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsEntityKind, SrsFieldKeys;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

class _Device {
  _Device._(this.db, this.srs, this.deviceId, this.profileId);

  final FushiDatabase db;
  final SrsStorage srs;
  final String deviceId;
  final int profileId;
  late SrsDbStore store;
  late final SrsDbProfileLinker linker;
  final List<String> unlinked = <String>[];

  static Future<_Device> open(String deviceId) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SrsStorage srs = await openTestSrsStorage();
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int profileId = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    final _Device d = _Device._(db, srs, deviceId, profileId);
    d.store = await d._openStore();
    d.linker = SrsDbProfileLinker(
      db: db,
      activeProfileId: () async => profileId,
      reopenStore: () async => d.store = await d._openStore(),
      writeLock: SrsCurrentStoreWriteLock(() => d.store),
    );
    return d;
  }

  Future<SrsDbStore> _openStore() async => SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: await db.profileUidOf(profileId),
    deviceId: deviceId,
  );

  /// 与 SrsSyncScheduler 同序：关联 → 同步 v2 的一轮 → 发布说明文件。
  Future<void> sync(LocalDirectoryAssetStore dir) async {
    final SrsProfileLinkOutcome link = await linker.link(dir, store);
    store = link.store;
    final List<SrsRemoteProfile>? choose = link.choose;
    if (choose != null) {
      unlinked.addAll(choose.map((SrsRemoteProfile c) => c.uid));
    }
    final SrsSync2Report r = await srsSync2Round(
      host: store,
      location: SrsAssetLocationStore(store: dir, profileUid: store.profileUid),
      locationId: 'interconnect:host',
      nowMs: () => store.now().$1,
    );
    expect(r.error, isNull, reason: '$deviceId sync');
    await linker.publish(dir, store, 'interconnect:host');
  }

  Future<String> addNote(String expression) => store.createNote(
    noteTypeId: store.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(store.profileUid, 'Expression'): expression,
    },
  );

  /// 当前 profile 的牌组名（含内置默认牌组）。
  Future<Set<String>> deckNames() async => <String>{
    for (final String id in await store.entityIds(SrsEntityKind.deck))
      if ((await store.entityEdits(
            SrsEntityKind.deck,
            id,
          ))[SrsFieldKeys.name]?.winner?.value
          case final String name)
        name,
  };

  /// 当前 profile 内置默认牌组上写过的保留率（预设）。
  Future<Object?> defaultDeckRetention() async => (await store.entityEdits(
    SrsEntityKind.deck,
    store.defaultDeckId,
  ))[SrsFieldKeys.deckRetention]?.winner?.value;

  Future<int> rows(String table, String uid) async =>
      (await srs.db
              .customSelect(
                'SELECT COUNT(*) AS c FROM "$table" WHERE profile_uid = ?',
                variables: <Variable<Object>>[Variable<String>(uid, srsIdType)],
              )
              .getSingle())
          .read<int>('c');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  late LocalDirectoryAssetStore dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_srs_adopt_data_');
    dir = LocalDirectoryAssetStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('hasUserData', () {
    test('刚打开（只有内置行）为假；自建牌组 / 改预设 / 改内置笔记类型 / 改日界任一项为真', () async {
      Future<_Device> fresh() => _Device.open('d');
      final _Device a = await fresh();
      expect(await a.store.hasUserNotes(), isFalse);
      expect(await a.store.hasUserData(), isFalse, reason: '只有内置行');

      await a.store.createDeck('自建');
      expect(await a.store.hasUserNotes(), isFalse);
      expect(await a.store.hasUserData(), isTrue, reason: '自建牌组');

      final _Device b = await fresh();
      await b.store.editField(
        SrsEntityKind.deck,
        b.store.defaultDeckId,
        SrsFieldKeys.deckRetention,
        0.85,
      );
      expect(await b.store.hasUserData(), isTrue, reason: '内置牌组改了预设');

      final _Device c = await fresh();
      await c.store.editField(
        SrsEntityKind.noteType,
        c.store.lapisNoteTypeId,
        SrsFieldKeys.css,
        '.card { color: red; }',
      );
      expect(await c.store.hasUserData(), isTrue, reason: '内置笔记类型改了样式');

      final _Device e = await fresh();
      await e.store.setDayRolloverHour(6);
      expect(await e.store.hasUserData(), isTrue, reason: '用户改过日界');
    });

    test('备份恢复的改 uid：只有自建牌组、没有笔记的 profile 不能直接采用', () async {
      final _Device a = await _Device.open('d');
      expect(await srsCanAdoptProfileUid(a.srs, a.store.profileUid), isTrue);
      await a.store.createDeck('自建');
      expect(await srsCanAdoptProfileUid(a.srs, a.store.profileUid), isFalse);
    });
  });

  test('复现：对方有笔记、本机只建了牌组并改了预设（没有笔记）时同步，不得自动采用删掉本机牌组 / 预设，改为交给用户选', () async {
    // 操作序列（修复前丢数据）：
    // 1. 电脑（host）建了笔记、开了同步；
    // 2. 手机（phone）新装，先在复习里建了牌组「自建」、把默认牌组保留率改成 0.85，还没加任何笔记；
    // 3. 手机开同步：关联判「本机没有笔记、目录里恰好一个有数据的 profile」→ 自动采用电脑的 uid →
    //    profile_purge 删掉手机旧 uid 的全部行，「自建」与 0.85 一起没了。
    final _Device host = await _Device.open('host');
    final _Device phone = await _Device.open('phone');
    await host.addNote('雪');
    await host.sync(dir);

    await phone.store.createDeck('自建');
    await phone.store.editField(
      SrsEntityKind.deck,
      phone.store.defaultDeckId,
      SrsFieldKeys.deckRetention,
      0.85,
    );
    final String phoneUid = phone.store.profileUid;
    await phone.sync(dir);

    expect(phone.store.profileUid, phoneUid, reason: '不自动采用');
    expect(await phone.db.profileUidOf(phone.profileId), phoneUid);
    expect(await phone.deckNames(), contains('自建'));
    expect(await phone.defaultDeckRetention(), 0.85);
    expect(phone.unlinked, contains(host.store.profileUid), reason: '交给用户选');

    // 用户在冲突里选电脑那份：本机有数据 → 并入，牌组与预设都带过去，电脑也收到。
    final SrsProfileAdoptResult adopted = await phone.linker.adopt(
      phone.store,
      host.store.profileUid,
    );
    phone.store = adopted.store;
    expect(phone.store.profileUid, host.store.profileUid);
    expect(await phone.deckNames(), contains('自建'));
    for (int i = 0; i < 3; i++) {
      await phone.sync(dir);
      await host.sync(dir);
    }
    expect(await host.deckNames(), contains('自建'));
  });

  test('对方只建了牌组（没有笔记）也报有数据：空设备采用它，不各自保持悄悄分叉', () async {
    final _Device decks = await _Device.open('decks');
    final _Device empty = await _Device.open('empty');
    await decks.store.createDeck('自建');
    await decks.sync(dir);
    await empty.sync(dir);
    expect(empty.store.profileUid, decks.store.profileUid);
    for (int i = 0; i < 2; i++) {
      await empty.sync(dir);
      await decks.sync(dir);
    }
    expect(await empty.deckNames(), contains('自建'));
    expect(decks.store.profileUid, isNot(isEmpty));
    expect(await decks.deckNames(), contains('自建'));
  });

  test('空设备经关联采用对方 uid 后，旧 uid 的 sync2_ops / sync2_self 行数为 0', () async {
    final _Device host = await _Device.open('host');
    final _Device phone = await _Device.open('phone');
    await host.addNote('雪');
    await host.sync(dir);
    final String oldUid = phone.store.profileUid;
    expect(await phone.rows('sync2_ops', oldUid), greaterThan(0));
    await phone.sync(dir);
    expect(phone.store.profileUid, host.store.profileUid);
    expect(await phone.rows('sync2_ops', oldUid), 0);
    expect(await phone.rows('sync2_self', oldUid), 0);
    expect(await phone.rows('srs_entities', oldUid), 0);
  });
}
