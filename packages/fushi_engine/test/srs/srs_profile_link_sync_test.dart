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
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
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

  /// 关联器经 `onError` 记下的非致命错误（只记位置描述）。
  final List<String> errors = <String>[];

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
      onError: (String where, Object error, StackTrace stack) =>
          d.errors.add(where),
    );
    return d;
  }

  Future<SrsDbStore> _openStore() async => SrsDbStore.open(
    core: srs.core,
    profileUid: await db.profileUidOf(profileId),
    deviceId: deviceId,
  );

  /// 与 SrsSyncScheduler 同序：关联 → 同步 v2 的一轮 → 发布说明文件。[key] 是位置键（调度器每个位置一个）。
  Future<SrsSync2Report> sync(
    LocalDirectoryAssetStore dir, {
    String key = 'interconnect:host',
  }) async {
    final SrsProfileLinkOutcome link = await linker.link(dir, store);
    store = link.store;
    final List<SrsRemoteProfile>? choose = link.choose;
    if (choose != null) {
      unlinked.addAll(choose.map((SrsRemoteProfile c) => c.displayName));
    }
    final SrsSync2Report r = await _round(dir, store, key: key);
    if (r.error == null) await linker.publish(dir, store, key);
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

/// 不经关联、直接对 [dir] 上 [store] 现在绑定的集合目录（内核 `identity` 的 `dir`）跑一轮同步，与生产同一个入口
/// （[srsRunLocationRound]：新根 `v4/`、旧根 `v3/` 的围栏与墓碑 head 都照生产写）。
Future<SrsSync2Report> _round(
  LocalDirectoryAssetStore dir,
  SrsDbStore store, {
  String key = 'interconnect:host',
}) => srsRunLocationRound(SrsLocationBackend(dir), store, key);

/// [a] 与 [b] 绑在同一个集合、同一个位置目录上（新代的「关联上了」：profile uid 各是各的）。
void _sameCollection(_Device a, _Device b) {
  expect(a.store.sync2Collection, b.store.sync2Collection);
  expect(a.store.sync2Dir, b.store.sync2Dir);
}

/// [s] 现在绑定的集合日志里的 `Join`（内核 `collection_info` 的 `joins`）。
Future<List<Object?>> _joins(SrsDbStore s) async =>
    ((await s.sync2Command(<String, Object?>{
          'op': 'collection_info',
        })).map['joins']
        as List<Object?>?) ??
    const <Object?>[];

/// 位置上目录 [dirName] 里还列着哪些写入者（说明文件所在的设备目录）；目录不在为空。
Future<List<String>> _writersIn(
  LocalDirectoryAssetStore dir,
  String dirName,
) async => <String>[
  for (final SrsRemoteProfile r in await srsListRemoteProfiles(dir))
    if (r.uid == dirName) ...r.writers,
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  late LocalDirectoryAssetStore dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_srs_link_sync_');
    dir = LocalDirectoryAssetStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  // 复核：判定里「已经并进本机的集合」只认受信作者写的 Join，与内核 `AlreadyJoined` 同口径。
  test('已并入的集合只认受信的 Join（未受信的、形状不对的跳过）', () {
    expect(
      srsTrustedJoins(<Object?>[
        <String, Object?>{'from': 'c-ok', 'dir': 'd-ok', 'trusted': true},
        <String, Object?>{'from': 'c-untrusted', 'dir': 'd', 'trusted': false},
        <String, Object?>{'from': 'c-nodir', 'trusted': true},
        <String, Object?>{'dir': 'd', 'trusted': true},
        'junk',
      ]),
      <({String from, String? dir})>[
        (from: 'c-ok', dir: 'd-ok'),
        (from: 'c-nodir', dir: null),
      ],
    );
    expect(srsTrustedJoins(null), isEmpty);
  });

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

  test('没有笔记的一边（已同步发布过自己的目录）认领对方集合后双向互通，旧目录里不再列着它', () async {
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
    _sameCollection(phone, host);
    expect(phone.store.profileUid, phoneOldUid, reason: '新代认领不改 profile uid');
    expect(await phone.db.profileUidOf(phone.profileId), phoneOldUid);
    expect(await phone.expressionOf(fromHost), '雪');
    // 旧目录的 `v4/` 根（meta.json）永远留着（srsRemoveOwnProfileFolder），但本机的说明文件目录删了：别的设备不再
    // 把它当成又一个候选。
    expect(await _writersIn(dir, phoneOldUid), isEmpty);

    final String fromPhone = await phone.addNote('雨');
    for (int i = 0; i < 3; i++) {
      expect((await phone.sync(dir)).error, isNull);
      expect((await host.sync(dir)).error, isNull);
    }
    expect(await host.expressionOf(fromPhone), '雨');
    // host 有笔记、目录里已有别的设备：不会被反过来换集合。
    expect(await host.db.profileUidOf(host.profileId), host.store.profileUid);
    expect(host.store.sync2Dir, host.store.profileUid);
    expect(host.unlinked, isEmpty);
    expect(phone.unlinked, isEmpty);
  });

  // 规划 §6 合并条件「新设备关联已有集合，结论 bound、不产生 Join」（第五波 G9 身份收尾）：app 里的全新设备开库就写了
  // 内置种子（`SrsDbStore.ensureBuiltins`），以前「空集合」只认 `Salts`，这样的设备关联已有集合一律 `joined` + `Join`。
  // 现在与首次信任同一个判据（内核 `library_fresh`）：只有内置种子不算用户内容，换绑过去（`bound`），两边都没有 `Join`。
  test('全新设备（开库已写内置种子、从没同步过）关联已有集合：bound，两边日志里都没有 Join', () async {
    final _Device host = await _Device.open('host');
    final String fromHost = await host.addNote('雪');
    expect((await host.sync(dir)).error, isNull);
    final _Device phone = await _Device.open('phone');
    // D27：换绑只在「本机目录名更大、本机并入对方」的方向上（反方向照设计吸收对方）。profile uid 是 UUIDv7，后开的大。
    expect(
      phone.store.sync2Dir!.compareTo(host.store.sync2Dir!),
      greaterThan(0),
    );
    expect(await _joins(phone.store), isEmpty);
    expect((await phone.sync(dir)).error, isNull);
    _sameCollection(phone, host);
    expect(await phone.expressionOf(fromHost), '雪');
    expect(await _joins(phone.store), isEmpty, reason: 'bound 不写 Join');
    expect((await host.sync(dir)).error, isNull);
    expect(await _joins(host.store), isEmpty);
  });

  test('两边都有用户笔记：不自动关联、不换任何一边的集合，报告对方 profile 名', () async {
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
    expect(a.store.sync2Dir, aUid);
    expect(b.store.sync2Dir, bUid);
    expect(b.unlinked, contains('Default'));
  });

  // 反馈 dOv8AdJ6yV：冲突弹窗只有「Default · 01a13df1」，看不出是哪台设备的、有多少数据，没法选。
  test('两边都有笔记：候选带着对方的设备名与笔记数，本机笔记数一并给出', () async {
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    await a.store.sync2DeviceInfo(model: 'Boox Note Air');
    await a.addNote('雪');
    await a.addNote('霜');
    await b.addNote('雨');
    for (int i = 0; i < 2; i++) {
      expect((await a.sync(dir)).error, isNull);
      expect((await b.sync(dir)).error, isNull);
    }
    final SrsProfileLinkOutcome before = await b.linker.link(dir, b.store);
    final SrsRemoteProfile candidate = before.choose!.single;
    expect(candidate.uid, a.store.profileUid);
    expect(candidate.devices, <String>['Boox Note Air']);
    expect(candidate.noteCount, 2);
    expect(before.localNoteCount, 1);
  });

  // 反馈：电脑与 iPhone 各自随机生成 uid、都叫 Default、都有笔记，只弹一条「无法自动关联」toast 就没了下文。
  test('两边都有笔记：用户在 B 上选 A 那份 → B 并入 A，两边看到全部笔记，B 的旧目录里不再列着它', () async {
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

    b.store = (await b.linker.adopt(
      b.store,
      a.store.sync2Dir!,
      within: dir,
    )).store;
    // B 的目录名大：按 D27 是 B 改绑到 A（写一条 Join），profile uid 不变。
    _sameCollection(b, a);
    expect(b.store.profileUid, bOldUid);
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
      await _writersIn(dir, bOldUid),
      isEmpty,
      reason: 'B 的旧目录只有它自己写过：说明文件目录清掉，别的设备不再把它当候选',
    );
    // 已经关联上：之后不再要选。
    expect((await a.linker.link(dir, a.store)).choose, isNull);
    expect((await b.linker.link(dir, b.store)).choose, isNull);
  });

  // 审查 PR #2593：孤儿目录清理只认「本设备换 uid 时离开的」旧 uid。删掉的 profile（srs_profile_cleanup.dart 约定
  // 远端已同步的集合不动、只删本机）、恢复旧备份前的 uid 同样「只有本设备写过、本机没有这个 uid」，同步目录里那份
  // 可能是唯一的副本，绝不能顺手删掉。
  test('只有本设备写过、本机没有的 uid 目录：不是本设备换 uid 留下的就不删', () async {
    final _Device a = await _Device.open('a');
    await a.addNote('雪');
    expect((await a.sync(dir)).error, isNull);
    // 本设备旧写入者（`<deviceId>#<化身号>`）写过的、本机已不存在的 profile（例如被删掉的那个）。
    const String goneUid = 'deleted-profile-uid';
    final Directory gone = Directory(
      '${root.path}/$kSrsSync2Namespace/$goneUid/a#1',
    )..createSync(recursive: true);
    File(
      '${gone.path}/$kSrsProfileInfoName',
    ).writeAsStringSync('{"name":"Old","hasNotes":true}');
    File('${gone.path}/batch-1').writeAsStringSync('payload');
    for (int i = 0; i < 2; i++) {
      expect((await a.sync(dir)).error, isNull);
    }
    expect(
      File('${gone.path}/batch-1').existsSync(),
      isTrue,
      reason: '不是换 uid 留下的孤儿：同步目录里的那份不动',
    );
  });

  test('两边都只有内置行：只有目录名大的一边认领，最终同一个集合', () async {
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    final String aDir = a.store.sync2Dir!;
    for (int i = 0; i < 3; i++) {
      expect((await a.sync(dir)).error, isNull);
      expect((await b.sync(dir)).error, isNull);
    }
    _sameCollection(a, b);
    expect(a.store.sync2Dir, aDir, reason: 'a 先开、目录名小：它不动');
  });

  // D27 吸收方向（G9-5 续）：本机目录名小、对方并进本机时，那条 Join 在本机集合的根里，对方集合的设备只读自己的根。
  // 本机在对方目录里放并入提示，对方设备据此再问一次用户（D25）——即使它的集合里已有别的设备（「已关联」）。
  test('A 吸收 B：B 的设备（已关联）经并入提示再确认一次，确认后三台收敛到 A', () async {
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    final _Device b2 = await _Device.open('b2');
    final String snow = await a.addNote('雪');
    final String rain = await b.addNote('雨');
    // B 先单独同步；b2 是空设备、目录名比 b 大：自动认领 B 的集合，B 从此「已关联」。
    expect((await b.sync(dir)).error, isNull);
    expect((await b2.sync(dir)).error, isNull);
    _sameCollection(b2, b);
    expect((await b.sync(dir)).error, isNull);
    final String fromB2 = await b2.addNote('霜');
    expect((await b2.sync(dir)).error, isNull);
    expect((await b.sync(dir)).error, isNull);
    expect(await b.expressionOf(fromB2), '霜');

    // A 有笔记、独自一个：B 是候选，用户在 A 上选它。A 的目录名小 → B 并进 A（A 的绑定不动）。
    final String aDir = a.store.sync2Dir!;
    final String bDir = b.store.sync2Dir!;
    expect(aDir.compareTo(bDir), lessThan(0));
    final SrsProfileLinkOutcome atA = await a.linker.link(dir, a.store);
    expect(atA.choose?.map((SrsRemoteProfile c) => c.uid), <String>[bDir]);
    await a.linker.adopt(a.store, bDir, within: dir);
    expect(a.store.sync2Dir, aDir, reason: '吸收方向：A 不改绑');
    expect(
      (await a.linker.link(dir, a.store)).choose,
      isNull,
      reason: '已经并进 A 的集合不再算候选',
    );
    expect(
      File(
        '${root.path}/$kSrsSync2Namespace/$bDir/'
        '$kSrsJoinHintPrefix${a.store.sync2Collection}.json',
      ).existsSync(),
      isTrue,
      reason: 'B 的目录里放了并入提示',
    );
    expect((await a.sync(dir)).error, isNull);

    // B 的设备：自己的集合里有别的设备（已关联），没有提示时只会保持；有提示就把 A 交给用户再确认一次。
    for (final _Device d in <_Device>[b, b2]) {
      final SrsProfileLinkOutcome o = await d.linker.link(dir, d.store);
      expect(o.choose?.map((SrsRemoteProfile c) => c.uid), <String>[
        aDir,
      ], reason: '${d.deviceId}：提示指向的 A 交给用户确认');
      d.store = (await d.linker.adopt(d.store, aDir, within: dir)).store;
      _sameCollection(d, a);
    }
    for (int i = 0; i < 3; i++) {
      for (final _Device d in <_Device>[b, b2, a]) {
        expect((await d.sync(dir)).error, isNull, reason: '${d.deviceId} $i');
      }
    }
    for (final _Device d in <_Device>[a, b, b2]) {
      expect(await d.expressionOf(snow), '雪', reason: d.deviceId);
      expect(await d.expressionOf(rain), '雨', reason: d.deviceId);
      expect(await d.expressionOf(fromB2), '霜', reason: d.deviceId);
      expect((await d.linker.link(dir, d.store)).choose, isNull);
    }
    // 三台设备、十几轮同步：默认 30 秒在满载的机器上不够。
  }, timeout: const Timeout(Duration(minutes: 3)));

  // 复核：提示原来只在认领那一刻写一次、失败只记日志，之后再没有代码补——被吸收方的设备永远不会被问，同步悄悄变成单向。
  // 提示改成从本机集合日志里的 `Join` 派生，每轮发布时补写缺的。
  test('A 吸收 B 时提示第一次没写成：之后 A 的同步轮次补上，B 的设备随后被问', () async {
    final _FlakyHintStore flaky = _FlakyHintStore(root, failures: 1);
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    final _Device b2 = await _Device.open('b2');
    await a.addNote('雪');
    await b.addNote('雨');
    expect((await b.sync(dir)).error, isNull);
    expect((await b2.sync(dir)).error, isNull);
    _sameCollection(b2, b);
    expect((await b.sync(dir)).error, isNull);
    final String aDir = a.store.sync2Dir!;
    final String bDir = b.store.sync2Dir!;
    expect(aDir.compareTo(bDir), lessThan(0));
    expect((await a.linker.link(flaky, a.store)).choose?.single.uid, bDir);
    await a.linker.adopt(a.store, bDir, within: flaky);
    expect(flaky.failed, 1, reason: '第一次写提示失败了');
    final File hint = File(
      '${root.path}/$kSrsSync2Namespace/$bDir/'
      '$kSrsJoinHintPrefix${a.store.sync2Collection}.json',
    );
    expect(hint.existsSync(), isFalse);
    expect((await b.linker.link(dir, b.store)).choose, isNull, reason: '还没有提示');
    expect((await a.sync(flaky)).error, isNull);
    expect(hint.existsSync(), isTrue, reason: 'A 的下一轮发布按 Join 补写了提示');
    final SrsProfileLinkOutcome atB = await b.linker.link(dir, b.store);
    expect(atB.choose?.map((SrsRemoteProfile c) => c.uid), <String>[aDir]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // 吸收的反方向（设计 §5.4 第 3 条不分谁发起）：x 改绑进 A 之后，旧集合 X 里还有别的设备（「已关联」）——它们靠 x
  // 在 X 目录里留的提示发现 A。
  test('x 改绑进 A：X 里留下的设备经提示被问，确认后跟过来', () async {
    final _Device a = await _Device.open('a');
    final _Device x = await _Device.open('x');
    final _Device x2 = await _Device.open('x2');
    final _Device x3 = await _Device.open('x3');
    final String snow = await a.addNote('雪');
    final String rain = await x.addNote('雨');
    expect((await a.sync(dir)).error, isNull);
    expect((await x.sync(dir)).error, isNull);
    for (final _Device d in <_Device>[x2, x3]) {
      d.store = (await d.linker.adopt(
        d.store,
        x.store.sync2Dir!,
        within: dir,
      )).store;
      _sameCollection(d, x);
      expect((await d.sync(dir)).error, isNull);
    }
    final String aDir = a.store.sync2Dir!;
    final String xDir = x.store.sync2Dir!;
    expect(aDir.compareTo(xDir), lessThan(0));
    // x2 在 X 里有别的设备（x3）：已关联，没有提示时不会被问。
    expect((await x2.linker.link(dir, x2.store)).choose, isNull);

    x.store = (await x.linker.adopt(x.store, aDir, within: dir)).store;
    _sameCollection(x, a);
    expect(
      File(
        '${root.path}/$kSrsSync2Namespace/$xDir/'
        '$kSrsJoinHintPrefix${a.store.sync2Collection}.json',
      ).existsSync(),
      isTrue,
      reason: 'x 离开的 X 目录里留了指向 A 的提示',
    );
    for (final _Device d in <_Device>[x2, x3]) {
      final SrsProfileLinkOutcome o = await d.linker.link(dir, d.store);
      expect(o.choose?.map((SrsRemoteProfile c) => c.uid), <String>[
        aDir,
      ], reason: d.deviceId);
      d.store = (await d.linker.adopt(d.store, aDir, within: dir)).store;
      _sameCollection(d, a);
    }
    for (int i = 0; i < 3; i++) {
      for (final _Device d in <_Device>[x, x2, x3, a]) {
        expect((await d.sync(dir)).error, isNull, reason: '${d.deviceId} $i');
      }
    }
    for (final _Device d in <_Device>[a, x, x2, x3]) {
      expect(await d.expressionOf(snow), '雪', reason: d.deviceId);
      expect(await d.expressionOf(rain), '雨', reason: d.deviceId);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  // 复核（第四轮）：发布的进程内缓存原来把「目录此刻不在这个位置上」记成已补齐，之后不再列目录——B 的设备后来才开始
  // 同步第二个位置，那里的 B 目录就一直没有提示。缓存改成连同「此刻在的旧目录」一起记，旧目录一出现就重新补。
  test('B 的目录在 A 首次发布之后才出现在第二个位置：A 之后的发布补上那里的提示', () async {
    final Directory root2 = Directory.systemTemp.createTempSync(
      'fushi_srs_link_sync_l2_',
    );
    addTearDown(() => root2.deleteSync(recursive: true));
    final LocalDirectoryAssetStore l2 = LocalDirectoryAssetStore(root2);
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    await a.addNote('雪');
    await b.addNote('雨');
    expect((await a.sync(dir)).error, isNull);
    expect((await b.sync(dir)).error, isNull);
    final String aDir = a.store.sync2Dir!;
    final String bDir = b.store.sync2Dir!;
    expect(aDir.compareTo(bDir), lessThan(0));
    expect((await a.linker.link(dir, a.store)).choose?.single.uid, bDir);
    await a.linker.adopt(a.store, bDir, within: dir);
    expect(a.store.sync2Dir, aDir, reason: '吸收方向：A 不改绑');

    // A 先在第二个位置上同步并发布：那里还没有 B 的目录。
    expect((await a.sync(l2, key: 'l2')).error, isNull);
    final Directory bOnL2 = Directory(
      '${root2.path}/$kSrsSync2Namespace/$bDir',
    );
    expect(bOnL2.existsSync(), isFalse);
    // B 的设备随后也开始同步第二个位置（两边都有数据：不自动关联，B 的目录留在那里）。
    expect((await b.sync(l2, key: 'l2')).error, isNull);
    expect(b.store.sync2Dir, bDir);
    expect(bOnL2.existsSync(), isTrue);
    // 同一个进程里 A 的下一轮发布：B 的目录出现了，补上提示。
    expect((await a.sync(l2, key: 'l2')).error, isNull);
    expect(
      File(
        '${bOnL2.path}/$kSrsJoinHintPrefix${a.store.sync2Collection}.json',
      ).existsSync(),
      isTrue,
      reason: '第二个位置上 B 的目录里有指向 A 的提示',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  // 复核（第四轮）：B 的目录在、但 meta.json 一时读不出（云盘瞬时失败），原来同样被记成已补齐、同一进程不再补写。
  test('B 目录的 meta.json 一时读不出：这一轮不算补齐，下一轮发布补上提示', () async {
    final _FlakyHintStore flaky = _FlakyHintStore(root, failures: 1);
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    await a.addNote('雪');
    await b.addNote('雨');
    expect((await a.sync(dir)).error, isNull);
    expect((await b.sync(dir)).error, isNull);
    final String aDir = a.store.sync2Dir!;
    final String bDir = b.store.sync2Dir!;
    expect(aDir.compareTo(bDir), lessThan(0));
    await a.linker.adopt(a.store, bDir, within: flaky);
    expect(flaky.failed, 1, reason: '认领时写提示失败了');
    final File hint = File(
      '${root.path}/$kSrsSync2Namespace/$bDir/'
      '$kSrsJoinHintPrefix${a.store.sync2Collection}.json',
    );
    expect(hint.existsSync(), isFalse);

    flaky.failMetaUnder = bDir;
    await a.linker.publish(flaky, a.store, 'k');
    expect(hint.existsSync(), isFalse, reason: '集合标识读不出：不写提示');
    flaky.failMetaUnder = null;
    await a.linker.publish(flaky, a.store, 'k');
    expect(hint.existsSync(), isTrue, reason: '上一轮不确定、没记缓存：这一轮补上');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // 复核（第四轮）：提示一直写不成的位置（权限、配额）每轮都重试，但同一个失败只记一次日志，发布本身不因此失败。
  test('提示一直写不成：每轮发布都重试，同一个失败只记一次日志', () async {
    final _FlakyHintStore flaky = _FlakyHintStore(root, failures: 1000);
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    await a.addNote('雪');
    await b.addNote('雨');
    expect((await a.sync(dir)).error, isNull);
    expect((await b.sync(dir)).error, isNull);
    final String bDir = b.store.sync2Dir!;
    expect(a.store.sync2Dir!.compareTo(bDir), lessThan(0));
    await a.linker.adopt(a.store, bDir, within: flaky);
    for (int i = 0; i < 3; i++) {
      await a.linker.publish(flaky, a.store, 'k');
    }
    expect(flaky.failed, 4, reason: '认领一次 + 每轮发布各重试一次');
    expect(
      a.errors.where((String w) => w.contains('joinHint k ')),
      hasLength(1),
      reason: '同一位置、同一目录、同一错误只记一次',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 写并入提示的前 [failures] 次抛 [FileSystemException]（云盘 / 互联写失败），其余照常；[failMetaUnder] 见下。
class _FlakyHintStore extends LocalDirectoryAssetStore {
  _FlakyHintStore(super.root, {required this.failures});

  int failures;
  int failed = 0;

  /// 非 null 时，读这个目录下的 `meta.json`（新根 / 旧根的集合标识）一律失败（云盘瞬时读失败）。
  String? failMetaUnder;

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final String? under = failMetaUnder;
    if (under != null &&
        assetId.contains(under) &&
        assetId.endsWith('meta.json')) {
      throw FileSystemException('injected meta read failure', assetId);
    }
    return super.getAsset(assetId, destination, onProgress: onProgress);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    if (name.startsWith(kSrsJoinHintPrefix) && failures > 0) {
      failures--;
      failed++;
      throw FileSystemException('injected hint write failure', name);
    }
    return super.putAsset(namespaceId, name, file, onProgress: onProgress);
  }
}
