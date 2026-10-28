// 媒体对账读日志投影、不列目录（srs_media_sync.dart 的 locationId 路径，内核 store/sync2/media.rs，BUG-3867）：
// 一个位置全系统只完整列举一次；之后各设备从同步收到的 MediaAt 操作得知位置上有什么，只对不认识的名字逐个查；
// 投影说在、实际不在 → 记不在，持有它的设备下一轮补传。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000dd';
const String kLocation = 'drive:account/root';

/// 记下对媒体目录的列举次数。
class _CountingLocation implements SrsLocationStore {
  final SrsMemoryLocationStore inner = SrsMemoryLocationStore();
  int mediaLists = 0;
  int mediaExists = 0;

  @override
  Future<List<SrsLocationEntry>> list(String dir) {
    if (dir == kSrsMediaFolder) mediaLists++;
    return inner.list(dir);
  }

  @override
  Future<Uint8List?> get(String path) => inner.get(path);

  @override
  Future<bool> exists(String path) {
    if (path.startsWith('$kSrsMediaFolder/')) mediaExists++;
    return inner.exists(path);
  }

  @override
  Future<void> put(String path, Uint8List bytes) => inner.put(path, bytes);

  @override
  Future<void> delete(String path) => inner.delete(path);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  int t = DateTime.utc(2026, 10, 28, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 28, 9).millisecondsSinceEpoch;
    root = Directory.systemTemp.createTempSync('fushi_srs_presence_');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  Directory mediaDir(String name) =>
      Directory(p.join(root.path, name))..createSync(recursive: true);

  Future<SrsMediaSyncReport> media(
    SrsDbStore s,
    SrsLocationStore loc,
    Directory dir,
  ) {
    t += 1000;
    return srsSyncMedia(
      location: loc,
      store: s,
      mediaRoot: dir,
      locationId: kLocation,
    );
  }

  Future<void> note(SrsDbStore s, String expr, String picture) async {
    t += 1000;
    await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expr,
        srsLapisFieldId(kProfile, 'Picture'): picture,
      },
    );
  }

  test('位置只完整列举一次；别的设备经日志得知内容，不再列目录', () async {
    final _CountingLocation loc = _CountingLocation();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final Directory mediaA = mediaDir('a');
    final Directory mediaB = mediaDir('b');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1, 2, 3]);
    File(p.join(mediaA.path, 'dog.png')).writeAsBytesSync(<int>[4]);
    await note(a, '猫', '<img src="cat.png"><img src="dog.png">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc.inner);

    final SrsMediaSyncReport first = await media(a, loc, mediaA);
    expect(first.listedRemote, isTrue, reason: '日志里没有任何设备列举过这个位置');
    expect(first.uploaded, 2);
    expect(loc.mediaLists, 1);

    // A 的 MediaAt 操作随下一轮同步到 B。
    await srsSyncPeers(<SrsDbStore>[a, b], loc.inner);
    final SrsMediaSyncReport rb = await media(b, loc, mediaB);
    expect(rb.listedRemote, isFalse);
    expect(rb.downloaded, 2);
    expect(rb.missing, isEmpty);
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);

    final SrsMediaSyncReport again = await media(a, loc, mediaA);
    expect(again.listedRemote, isFalse);
    expect(again.uploaded, 0, reason: '日志说位置上已有，不重传');
    expect(loc.mediaLists, 1, reason: '列举之后再也不列媒体目录');
    expect(loc.mediaExists, 0, reason: '投影认识的名字不逐个查');
  });

  test('投影说在、实际被删：读的设备记不在，持有的设备下一轮补传', () async {
    final _CountingLocation loc = _CountingLocation();
    final SrsDbStore a = await device('a');
    final SrsDbStore c = await device('c');
    final Directory mediaA = mediaDir('a');
    final Directory mediaC = mediaDir('c');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[7]);
    await note(a, '猫', '<img src="cat.png">');
    await srsSyncPeers(<SrsDbStore>[a, c], loc.inner);
    await media(a, loc, mediaA);
    await srsSyncPeers(<SrsDbStore>[a, c], loc.inner);

    loc.inner.files.remove('$kSrsMediaFolder/cat.png');
    final SrsMediaSyncReport rc = await media(c, loc, mediaC);
    expect(rc.missing, <String>{'cat.png'});
    expect(
      (await media(a, loc, mediaA)).uploaded,
      0,
      reason: 'A 还没收到 C 记下的「不在」',
    );

    await srsSyncPeers(<SrsDbStore>[c, a], loc.inner);
    expect((await media(a, loc, mediaA)).uploaded, 1);
    await srsSyncPeers(<SrsDbStore>[a, c], loc.inner);
    expect((await media(c, loc, mediaC)).downloaded, 1);
    expect(loc.mediaLists, 1);
  });

  test('投影不认识的名字（老版本设备传的）逐个查一次，结果记进日志', () async {
    final _CountingLocation loc = _CountingLocation();
    final SrsDbStore a = await device('a');
    final Directory mediaA = mediaDir('a');
    await note(a, '鳥', '<img src="bird.png">');
    await srsSyncPeers(<SrsDbStore>[a], loc.inner);
    // 位置先被列举（空），之后老版本设备把 bird.png 直接放了上去、没记日志。
    expect((await media(a, loc, mediaA)).missing, <String>{'bird.png'});
    await loc.inner.put(
      '$kSrsMediaFolder/bird.png',
      Uint8List.fromList(<int>[9]),
    );
    // 已记为不在的名字不再逐个查——要等持有它的新版本设备记「在」。这里换成本机认不得的新名字验证逐个查。
    await note(a, '魚', '<img src="fish.png">');
    await loc.inner.put(
      '$kSrsMediaFolder/fish.png',
      Uint8List.fromList(<int>[5]),
    );
    final SrsMediaSyncReport r = await media(a, loc, mediaA);
    expect(r.listedRemote, isFalse);
    expect(r.downloaded, 1);
    expect(File(p.join(mediaA.path, 'fish.png')).readAsBytesSync(), <int>[5]);
    expect(r.missing, <String>{'bird.png'});
    expect(loc.mediaLists, 1);

    // fish.png 已记为在：下一轮不再查。
    final int before = loc.mediaExists;
    File(p.join(mediaA.path, 'fish.png')).deleteSync();
    await media(a, loc, mediaA);
    expect(loc.mediaExists, before);
  });
}
