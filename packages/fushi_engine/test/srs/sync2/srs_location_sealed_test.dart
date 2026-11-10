// BUG-4284：没有密钥的设备不得向一个已经有加密数据的位置写明文（docs/specs/2026-10-25-srs-sync-v2-design.md §9）。
//
// 本机一旦见过「这个位置是加密的」（读到带 kdf 的 meta.json、用密钥收发过、拉段时遇到密封的段）就记进内核
// （native/fushi_fsrs/src/store/sync2/sealed.rs），之后不论 meta.json 怎么样都不写明文，报错让用户输入口令：
// (a) meta.json 被旧版本 / 别的设备整份重写丢了 kdf；
// (b) meta.json 缺失、最终一致的网盘把整个位置暂时列成空的；
// (c) 一台设备先按明文写过、另一台后开加密，而前者读到的还是旧 meta；
// (d) 本机用密钥同步过，之后密钥被清掉（又碰上 kdf 丢失）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f4';

/// 记下每次写入；[blind] 时整个位置看起来是空的（最终一致的网盘列不到、读不到任何东西），[staleMeta] 给了就把
/// meta.json 读成这份旧内容（读到的是别的设备开加密之前的 meta）。
class _Store extends SrsMemoryLocationStore {
  final List<String> writes = <String>[];
  bool blind = false;
  Uint8List? staleMeta;

  @override
  Future<List<SrsLocationEntry>> list(String dir) async =>
      blind ? <SrsLocationEntry>[] : super.list(dir);

  @override
  Future<Uint8List?> get(String path) async {
    if (blind) return null;
    if (path == 'meta.json' && staleMeta != null) return staleMeta;
    return super.get(path);
  }

  @override
  Future<bool> exists(String path) async => !blind && await super.exists(path);

  @override
  Future<void> put(String path, Uint8List bytes) async {
    writes.add(path);
    await super.put(path, bytes);
  }

  @override
  Future<void> putNew(String path, Uint8List bytes) async {
    writes.add(path);
    await super.putNew(path, bytes);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: FfiFsrsEngine.tryCreate(),
    );
  }

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{srsLapisFieldId(kProfile, 'Expression'): text},
  );

  Future<SrsSync2Report> round(
    SrsDbStore s,
    SrsLocationStore loc, {
    SrsLocationKey? key,
  }) => srsSync2Round(
    host: s,
    location: loc,
    locationId: 'loc',
    nowMs: () => s.now().$1,
    key: key,
  );

  Map<String, Object?> meta(SrsMemoryLocationStore loc) =>
      jsonDecode(utf8.decode(loc.files['meta.json']!)) as Map<String, Object?>;

  void putMeta(SrsMemoryLocationStore loc, Map<String, Object?> m) =>
      loc.files['meta.json'] = Uint8List.fromList(utf8.encode(jsonEncode(m)));

  /// 这一轮往位置上写了明文的东西（段 / head / 转发件 / 明文媒体 / meta.json）。
  List<String> plaintextWrites(_Store loc) => <String>[
    for (final String w in loc.writes)
      if (w.startsWith('devices/') ||
          w.startsWith('media/') ||
          w == 'meta.json')
        w,
  ];

  /// A 开加密并传了段：位置上的 meta.json 带 kdf，段都是密文。
  Future<(SrsDbStore, SrsLocationKey)> encryptedBy(_Store loc) async {
    final SrsDbStore a = await device('A');
    await addNote(a, '一');
    final SrsLocationKey pending = await srsDeriveLocationKey(
      a,
      'pw',
      pendingEnable: true,
    );
    expect((await round(a, loc, key: pending)).encryptionEnabled, isTrue);
    return (a, pending.enabled());
  }

  test('(a) meta.json 被整份重写丢了 kdf：见过 kdf 的无密钥设备报要口令、不写明文', () async {
    final _Store loc = _Store();
    final (SrsDbStore _, SrsLocationKey ka) = await encryptedBy(loc);
    final SrsDbStore b = await device('B');
    await addNote(b, 'B 的笔记');
    // B 没有口令：先看到的是带 kdf 的 meta（要口令，记下）。
    final SrsSync2Report first = await round(b, loc);
    expect(first.error, kSrsSync2NeedsKey);

    // 旧版本把 meta.json 整份重写成没有 kdf 的样子。
    putMeta(loc, meta(loc)..remove('kdf'));
    loc.writes.clear();
    final SrsSync2Report r = await round(b, loc);
    expect(r.error, kSrsSync2NeedsKey, reason: '本机记得 kdf：让用户照它输入口令');
    expect(r.kdf?.saltHex, ka.kdf.saltHex);
    expect(r.encrypted, isFalse);
    expect(plaintextWrites(loc), isEmpty, reason: '一个明文段 / head / meta 都不写');
  });

  test('(a) 从没见过 kdf 的新设备：拉到密文段就停下，不发明文', () async {
    final _Store loc = _Store();
    await encryptedBy(loc);
    putMeta(loc, meta(loc)..remove('kdf'));
    final SrsDbStore b = await device('B');
    await addNote(b, 'B 的笔记');
    loc.writes.clear();
    final SrsSync2Report r = await round(b, loc);
    expect(r.error, kSrsSync2EncryptionMissing);
    expect(plaintextWrites(loc), isEmpty);
    // 下一轮在拉段之前就拦下（事实已持久化）。
    loc.writes.clear();
    expect((await round(b, loc)).error, kSrsSync2EncryptionMissing);
    expect(plaintextWrites(loc), isEmpty);
  });

  test('(b) meta.json 缺失且位置暂时列成空的：见过加密的无密钥设备不建明文 meta、不写段', () async {
    final _Store loc = _Store();
    await encryptedBy(loc);
    final SrsDbStore b = await device('B');
    await addNote(b, 'B 的笔记');
    expect((await round(b, loc)).error, kSrsSync2NeedsKey);

    loc
      ..blind = true
      ..writes.clear();
    final SrsSync2Report r = await round(b, loc);
    expect(r.error, kSrsSync2NeedsKey);
    expect(plaintextWrites(loc), isEmpty, reason: '不盖掉其实还在的加密 meta，也不传明文');
    loc.blind = false;
    expect(meta(loc)['kdf'], isNotNull);
  });

  test('(c) 先明文写过的设备读到旧 meta 时，另一台已开加密：拉到密文段就停，不再发明文', () async {
    final _Store loc = _Store();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    await addNote(a, 'A 明文');
    expect((await round(a, loc)).error, isNull);
    final Uint8List plainMeta = loc.files['meta.json']!;
    expect((await round(b, loc)).error, isNull);

    // B 开加密（写上 kdf，全部段按密钥重传），之后又记了一条（A 没有的密文段）。
    final SrsLocationKey pending = await srsDeriveLocationKey(
      b,
      'pw',
      pendingEnable: true,
    );
    expect((await round(b, loc, key: pending)).encryptionEnabled, isTrue);
    await addNote(b, 'B 密文');
    expect((await round(b, loc, key: pending.enabled())).error, isNull);

    // A 这一刻读到的还是开加密之前的 meta（最终一致 / 并发），又记了一条。
    await addNote(a, 'A 新的');
    loc
      ..staleMeta = plainMeta
      ..writes.clear();
    final SrsSync2Report r = await round(a, loc);
    expect(r.error, kSrsSync2EncryptionMissing);
    expect(plaintextWrites(loc), isEmpty, reason: 'A 的新操作不按明文发出去');
  });

  test('(d) 本机用密钥同步过、密钥被清掉、kdf 又丢了：不降级成明文；照记下的 kdf 输入口令可恢复', () async {
    final _Store loc = _Store();
    final (SrsDbStore a, SrsLocationKey ka) = await encryptedBy(loc);
    putMeta(loc, meta(loc)..remove('kdf'));
    await addNote(a, '二');
    loc.writes.clear();
    final SrsSync2Report r = await round(a, loc);
    expect(r.error, kSrsSync2NeedsKey);
    expect(r.kdf?.saltHex, ka.kdf.saltHex);
    expect(plaintextWrites(loc), isEmpty);

    // 照记下的 kdf 输错口令：报口令不对，不拿错密钥去「恢复加密设置」。
    final SrsLocationKey wrong = await srsDeriveLocationKey(
      a,
      'nope',
      kdf: r.kdf,
    );
    expect((await round(a, loc, key: wrong)).error, kSrsSync2WrongKey);
    // 输对：kdf 不在位置上 → 报加密设置丢失；用户点「恢复加密设置」后写回同一份 kdf。
    final SrsLocationKey right = await srsDeriveLocationKey(
      a,
      'pw',
      kdf: r.kdf,
    );
    expect(right.keyHex, ka.keyHex);
    expect((await round(a, loc, key: right)).error, kSrsSync2EncryptionMissing);
    final SrsSync2Report back = await round(
      a,
      loc,
      key: SrsLocationKey(
        keyHex: right.keyHex,
        kdf: right.kdf,
        pendingEnable: true,
      ),
    );
    expect(back.error, isNull);
    expect(back.encrypted, isTrue);
    expect((meta(loc)['kdf']! as Map)['check'], ka.check);
  });

  test('从没见过加密的明文位置照常按明文同步', () async {
    final _Store loc = _Store();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final String n = await addNote(a, '明文');
    expect((await round(a, loc)).error, isNull);
    expect((await round(b, loc)).error, isNull);
    expect(await b.note(n), isNotNull);
    expect(
      (await srsLocationSealed(b, 'loc')).sealed,
      isFalse,
      reason: '明文段不算见过加密',
    );
  });
}
