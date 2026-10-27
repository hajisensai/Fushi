// 复习同步的 profile 关联，真数据库 + 真同步引擎（用户报「Fushi SRS 无法通过互联同步」的根因）：
// 两台设备各自打开复习模块时 profileUid 各自随机生成（FushiDatabase.profileUidOf），同步目录按
// uid 分区（fushi-srs/<uid>/），以前两台设备「同步成功」却各写各的目录、谁也看不到谁的卡。
//
// 这里按 SrsSyncScheduler 的顺序跑：关联（link）→ 同步 v2 的一轮（srsSync2Round）→ 发布说明文件（publish）。
// 互联传输本身（WebDAV PROPFIND / PUT）另由 fushi/test/sync/interconnect_srs_two_way_sync_test.dart
// 用真 host + 真互联客户端验证。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:fushi_srs/fushi_srs.dart' show SrsNoteView;
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
  Future<SrsSync2Report> sync(LocalDirectoryAssetStore dir) async {
    final SrsProfileLinkOutcome link = await linker.link(dir, store);
    store = link.store;
    final List<SrsRemoteProfile>? choose = link.choose;
    if (choose != null) {
      unlinked.addAll(choose.map((SrsRemoteProfile c) => c.displayName));
    }
    final SrsSync2Report r = await _round(dir, store);
    if (r.error == null) await linker.publish(dir, store, 'interconnect:host');
    return r;
  }

  Future<String> addNote(String expression) => store.createNote(
    noteTypeId: store.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(store.profileUid, 'Expression'): expression,
    },
  );

  Future<String?> expressionOf(String noteId) async => (await store.note(
    noteId,
  ))?.field(srsLapisFieldId(store.profileUid, 'Expression'));
}

/// 不经关联、直接对 [dir] 上 [store] 自己 uid 的集合根跑一轮同步 v2。
Future<SrsSync2Report> _round(LocalDirectoryAssetStore dir, SrsDbStore store) =>
    srsSync2Round(
      host: store,
      location: SrsAssetLocationStore(store: dir, profileUid: store.profileUid),
      locationId: 'interconnect:host',
      nowMs: () => store.now().$1,
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  late LocalDirectoryAssetStore dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_srs_link_sync_');
    dir = LocalDirectoryAssetStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('复现：不关联时两台设备 uid 不同，同步各自成功但卡片不互通', () async {
    final _Device host = await _Device.open('host');
    final _Device phone = await _Device.open('phone');
    expect(host.store.profileUid, isNot(phone.store.profileUid));
    final String fromHost = await host.addNote('雪');
    Future<SrsSync2Report> raw(_Device d) => _round(dir, d.store);
    for (int i = 0; i < 2; i++) {
      expect((await raw(host)).error, isNull);
      expect((await raw(phone)).error, isNull);
    }
    expect(await phone.expressionOf(fromHost), isNull);
  });

  test('没有笔记的一边（已同步发布过自己的目录）采用对方 uid 后双向互通，旧目录清掉', () async {
    final _Device host = await _Device.open('host');
    final _Device phone = await _Device.open('phone');
    final String phoneOldUid = phone.store.profileUid;

    // 手机先单独同步过（自己的操作已传到它自己 uid 下的 v2 目录）。
    expect((await phone.sync(dir)).error, isNull);
    expect(
      await srsCanAdoptProfileUid(phone.srs, phoneOldUid),
      isFalse,
      reason: '传到过同步位置：备份合并不会再改它的 uid（同步路径的关联照样可以）',
    );

    final String fromHost = await host.addNote('雪');
    for (int i = 0; i < 3; i++) {
      expect((await host.sync(dir)).error, isNull, reason: 'host $i');
      expect((await phone.sync(dir)).error, isNull, reason: 'phone $i');
    }
    expect(phone.store.profileUid, host.store.profileUid);
    expect(await phone.db.profileUidOf(phone.profileId), host.store.profileUid);
    expect(await phone.expressionOf(fromHost), '雪');
    expect(
      Directory('${root.path}/$kSrsSync2Namespace/$phoneOldUid').existsSync(),
      isFalse,
    );

    final String fromPhone = await phone.addNote('雨');
    for (int i = 0; i < 3; i++) {
      expect((await phone.sync(dir)).error, isNull);
      expect((await host.sync(dir)).error, isNull);
    }
    expect(await host.expressionOf(fromPhone), '雨');
    // host 有笔记、目录里已有别的设备：不会被反过来改 uid。
    expect(await host.db.profileUidOf(host.profileId), host.store.profileUid);
    expect(host.unlinked, isEmpty);
    expect(phone.unlinked, isEmpty);
  });

  test('两边都有用户笔记：不自动关联、不改任何一边的 uid，报告对方 profile 名', () async {
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    await a.addNote('雪');
    await b.addNote('雨');
    final String aUid = a.store.profileUid;
    final String bUid = b.store.profileUid;
    for (int i = 0; i < 2; i++) {
      expect((await a.sync(dir)).error, isNull);
      expect((await b.sync(dir)).error, isNull);
    }
    expect(a.store.profileUid, aUid);
    expect(b.store.profileUid, bUid);
    expect(b.unlinked, contains('Default'));
  });

  // 反馈：电脑与 iPhone 各自随机生成 uid、都叫 Default、都有笔记，只弹一条「无法自动关联」toast 就没了下文。
  test('两边都有笔记：用户在 B 上选 A 那份 → B 并入 A，两边看到全部笔记，B 的旧目录被清掉', () async {
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    final String snow = await a.addNote('雪');
    await b.addNote('雨');
    final String bOldUid = b.store.profileUid;
    for (int i = 0; i < 2; i++) {
      expect((await a.sync(dir)).error, isNull);
      expect((await b.sync(dir)).error, isNull);
    }
    final SrsProfileLinkOutcome before = await b.linker.link(dir, b.store);
    expect(before.choose?.map((SrsRemoteProfile c) => c.uid), <String>[
      a.store.profileUid,
    ]);
    expect(before.localHasNotes, isTrue);

    b.store = await b.linker.adopt(b.store, a.store.profileUid);
    expect(b.store.profileUid, a.store.profileUid);
    for (int i = 0; i < 3; i++) {
      expect((await b.sync(dir)).error, isNull, reason: 'b $i');
      expect((await a.sync(dir)).error, isNull, reason: 'a $i');
    }
    expect(await b.expressionOf(snow), '雪');
    final Set<String> aWords = <String>{
      for (final SrsNoteView? n in (await a.store.notes(<String>[
        for (final SrsNoteCacheRow r in await a.store.listNotes()) r.id,
      ])).values)
        if (n != null)
          n.field(srsLapisFieldId(a.store.profileUid, 'Expression')),
    };
    expect(aWords, containsAll(<String>['雪', '雨']), reason: 'B 的笔记并入后到了 A');
    expect(
      Directory('${root.path}/$kSrsSync2Namespace/$bOldUid').existsSync(),
      isFalse,
      reason: 'B 的旧 uid 目录只有它自己写过：清掉，别的设备不再把它当候选',
    );
    // 已经关联上：之后不再要选。
    expect((await a.linker.link(dir, a.store)).choose, isNull);
    expect((await b.linker.link(dir, b.store)).choose, isNull);
  });

  test('两边都只有内置行：只有一边采用，最终同一个 uid', () async {
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    for (int i = 0; i < 3; i++) {
      expect((await a.sync(dir)).error, isNull);
      expect((await b.sync(dir)).error, isNull);
    }
    expect(a.store.profileUid, b.store.profileUid);
  });
}
