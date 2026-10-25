// 存储位置加密的加固（审查 P0-1 / P1-5 / P2-7，docs/specs/2026-10-25-srs-sync-v2-design.md §9）：
// - 本机开过加密而位置上的 kdf 不见了：报错停下，一个段也不传，绝不降级成明文；用本机密钥能把 kdf 写回去。
// - meta.json 读不到（最终一致 / 被删）或解析不了，而位置上已经有数据：不重写它。
// - 两台设备同时开加密、后写的 kdf 胜出：先开的那台换上正确口令后进度归零、全部段与媒体按新密钥重传，
//   另一台收得到。
// - meta.json 里的 KDF 参数越界：报错，不派生。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e7';

/// 记下每次写入的路径（检查「一个段也没传」）。
class _RecordingStore extends SrsMemoryLocationStore {
  final List<String> writes = <String>[];

  @override
  Future<void> put(String path, Uint8List bytes) async {
    writes.add(path);
    await super.put(path, bytes);
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

  bool uploadedOps(_RecordingStore loc) =>
      loc.writes.any((String w) => w.startsWith('devices/'));

  test('本机开过加密、位置上的 kdf 被删：报错停下不传明文；用本机密钥写回 kdf 后恢复', () async {
    final _RecordingStore loc = _RecordingStore();
    final SrsDbStore a = await device('A');
    await addNote(a, '一');
    final SrsLocationKey pending = await srsDeriveLocationKey(
      a,
      'pw',
      pendingEnable: true,
    );
    expect((await round(a, loc, key: pending)).encryptionEnabled, isTrue);
    final SrsLocationKey ka = pending.enabled();

    // 别的（旧）版本把 meta.json 整份重写成没有 kdf 的样子。
    final Map<String, Object?> stripped = meta(loc)..remove('kdf');
    putMeta(loc, stripped);
    await addNote(a, '二');
    loc.writes.clear();
    final SrsSync2Report r = await round(a, loc, key: ka);
    expect(r.error, kSrsSync2EncryptionMissing);
    expect(r.encrypted, isFalse);
    expect(uploadedOps(loc), isFalse, reason: '一个段 / head 也不传');
    expect(loc.writes, isEmpty, reason: 'meta.json 也不被悄悄改写');
    expect(meta(loc).containsKey('kdf'), isFalse);

    // 用户点「恢复加密设置」：同一把密钥重新标成待开启，下一轮把同一份 kdf 写回去。
    final SrsSync2Report back = await round(
      a,
      loc,
      key: SrsLocationKey(keyHex: ka.keyHex, kdf: ka.kdf, pendingEnable: true),
    );
    expect(back.error, isNull);
    expect(back.encrypted, isTrue);
    expect((meta(loc)['kdf']! as Map)['check'], ka.check);
    expect((meta(loc)['kdf']! as Map)['salt'], ka.kdf.saltHex);
  });

  test('meta.json 读不到 / 解析不了而位置上已有数据：不重写、不同步；全新位置才建（有密钥就连 kdf 一起写）', () async {
    final _RecordingStore loc = _RecordingStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    await addNote(a, '一');
    final SrsLocationKey pending = await srsDeriveLocationKey(
      a,
      'pw',
      pendingEnable: true,
    );
    // 全新位置 + 本机已有密钥：第一份 meta.json 就带 kdf，从来没有明文 meta。
    await round(a, loc, key: pending);
    expect(loc.writes.first, 'meta.json');
    expect(meta(loc)['kdf'], isNotNull);
    final Uint8List original = loc.files['meta.json']!;

    // 最终一致的网盘暂时列不到 meta.json：A（有密钥）与 B（没密钥）都不能重写它。
    loc.files.remove('meta.json');
    for (final (SrsDbStore s, SrsLocationKey? k)
        in <(SrsDbStore, SrsLocationKey?)>[(a, pending.enabled()), (b, null)]) {
      loc.writes.clear();
      final SrsSync2Report r = await round(s, loc, key: k);
      expect(r.error, kSrsSync2MetaUnavailable);
      expect(loc.writes, isEmpty);
    }
    // 解析不了：同样不动。
    loc.files['meta.json'] = Uint8List.fromList(utf8.encode('{"v":1,'));
    loc.writes.clear();
    expect((await round(b, loc)).error, kSrsSync2MetaUnavailable);
    expect(loc.writes, isEmpty);
    // 恢复后照常。
    loc.files['meta.json'] = original;
    expect((await round(a, loc, key: pending.enabled())).error, isNull);
  });

  test('两台设备同时开加密、后写的 kdf 胜出：输掉的那台换上正确口令后全部重传，对方收得到', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final Directory ma = Directory.systemTemp.createTempSync('srs_race_a_');
    final Directory mb = Directory.systemTemp.createTempSync('srs_race_b_');
    addTearDown(() {
      for (final Directory d in <Directory>[ma, mb]) {
        try {
          d.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄滞后（Windows）。
        }
      }
    });
    File('${ma.path}/a.png').writeAsBytesSync(utf8.encode('A-picture'));
    final String fromA = await addNote(a, '甲<img src="a.png">');

    // 两台都在「位置上还没有 kdf」时开了加密（同一个口令、各自的盐）。A 先写完 meta 并用 kA 传了段与媒体。
    final SrsLocationKey pa = await srsDeriveLocationKey(
      a,
      'same passphrase',
      pendingEnable: true,
    );
    final SrsLocationKey pb = await srsDeriveLocationKey(
      b,
      'same passphrase',
      pendingEnable: true,
    );
    expect((await round(a, loc, key: pa)).encryptionEnabled, isTrue);
    await srsSyncMedia(
      location: loc,
      store: a,
      mediaRoot: ma,
      cipher: SrsMediaCipher(a, pa.keyHex),
    );
    // B 的那次写 meta 后到、盖掉了 A 的 kdf（两边读 meta 时都还没有 kdf）。
    final Map<String, Object?> m = meta(loc);
    putMeta(loc, <String, Object?>{
      ...m,
      'kdf': <String, Object?>{...pb.kdf.toJson(), 'check': pb.check},
    });
    final SrsLocationKey kb = pb.enabled();
    expect((await round(b, loc, key: kb)).error, isNull);

    // A 下一轮：口令不对（kdf 换了）。用户在 A 上输入同一个口令，按位置上的 kdf 派生出 B 那把密钥。
    final SrsSync2Report wrong = await round(a, loc, key: pa.enabled());
    expect(wrong.error, kSrsSync2WrongKey);
    final SrsLocationKey ka2 = await srsDeriveLocationKey(
      a,
      'same passphrase',
      kdf: wrong.kdf,
    );
    expect(ka2.keyHex, kb.keyHex);
    expect(
      srsLocationProgressId('loc', ka2.keyHex),
      isNot(srsLocationProgressId('loc', pa.keyHex)),
    );
    final SrsSync2Report again = await round(a, loc, key: ka2);
    expect(again.error, isNull);
    expect(again.uploaded, greaterThan(0), reason: '换了密钥 = 新的进度身份，全部重传');
    await srsSyncMedia(
      location: loc,
      store: a,
      mediaRoot: ma,
      cipher: SrsMediaCipher(a, ka2.keyHex),
    );

    for (int i = 0; i < 2; i++) {
      await round(b, loc, key: kb);
    }
    expect(await b.note(fromA), isNotNull, reason: 'B 解得开 A 重传的段');
    final SrsMediaSyncReport media = await srsSyncMedia(
      location: loc,
      store: b,
      mediaRoot: mb,
      cipher: SrsMediaCipher(b, kb.keyHex),
    );
    expect(media.missing, isEmpty);
    expect(File('${mb.path}/a.png').readAsStringSync(), 'A-picture');
  });

  test('meta.json 里的 KDF 参数越界：报错不派生；内核同样拒绝', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    await round(a, loc);
    final SrsKdf good = SrsKdf.fresh();
    for (final Map<String, Object?> bad in <Map<String, Object?>>[
      <String, Object?>{...good.toJson(), 'm': 4 << 20},
      <String, Object?>{...good.toJson(), 'm': 64},
      <String, Object?>{...good.toJson(), 't': 1000000},
      <String, Object?>{...good.toJson(), 'p': 0},
      <String, Object?>{...good.toJson(), 'salt': 'abcd'},
      <String, Object?>{...good.toJson(), 'm': '65536'},
    ]) {
      expect(() => SrsKdf.fromJson(bad), throwsFormatException, reason: '$bad');
      putMeta(loc, <String, Object?>{
        ...meta(loc),
        'kdf': <String, Object?>{...bad, 'check': 'x'},
      });
      final SrsSync2Report r = await round(a, loc);
      expect(r.error, kSrsSync2BadKdf, reason: '$bad');
      expect(r.kdf, isNull);
    }
    // 内核：越界参数直接拒绝（不截断、不派生）。
    await expectLater(
      a.sync2Command(<String, Object?>{
        'op': 'derive_key',
        'passphrase': 'pw',
        'salt': good.saltHex,
        'm': 4 << 20,
        't': 3,
        'p': 1,
      }),
      throwsA(anything),
    );
  });
}
