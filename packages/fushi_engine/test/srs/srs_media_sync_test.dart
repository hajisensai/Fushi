// SRS 媒体同步（srs_media_sync.dart，docs/specs/2026-10-25-srs-sync-v2-design.md §6.4、§10.5）：集合根下一个
// 内容寻址的 `media/` 目录；缺的从位置下载、位置缺的上传；被删笔记的媒体保留 90 天后才从位置上清，删除只凭
// 正面证据（本机不认识的文件不删）；归档位置永不删；旧格式按写入者分目录的媒体只读兜底。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000cc';
const int kDay = 24 * 60 * 60 * 1000;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  int t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;
    root = Directory.systemTemp.createTempSync('fushi_srs_media_');
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

  void writeMedia(Directory d, String name, List<int> bytes) =>
      File(p.join(d.path, name)).writeAsBytesSync(bytes);

  Future<String> addNote(SrsDbStore s, String expr, String picture) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expr,
        srsLapisFieldId(kProfile, 'Picture'): picture,
      },
    );
  }

  Future<SrsMediaSyncReport> media(
    SrsDbStore s,
    SrsLocationStore loc,
    Directory dir, {
    bool archive = false,
    SrsLegacyMediaReader? legacy,
  }) => srsSyncMedia(
    location: loc,
    store: s,
    mediaRoot: dir,
    archive: archive,
    legacy: legacy,
  );

  Set<String> remoteMedia(SrsMemoryLocationStore loc) => <String>{
    for (final String path in loc.files.keys)
      if (path.startsWith('$kSrsMediaFolder/'))
        path.substring(kSrsMediaFolder.length + 1),
  };

  test('按内容名上传 / 下载；位置上丢了的由仍持有它的设备补传', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final Directory mediaA = mediaDir('a');
    final Directory mediaB = mediaDir('b');
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    writeMedia(mediaA, 'cat.png', <int>[1, 2, 3]);
    writeMedia(mediaA, 'meow.mp3', <int>[4, 5]);
    t += 1000;
    await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '猫',
        srsLapisFieldId(kProfile, 'Picture'): '<img src="cat.png">',
        srsLapisFieldId(kProfile, 'ExpressionAudio'): '[sound:meow.mp3]',
      },
    );
    await srsSyncPeers(<SrsDbStore>[a, b], loc);

    final SrsMediaSyncReport ra = await media(a, loc, mediaA);
    expect(ra.uploaded, 2);
    expect(remoteMedia(loc), <String>{'cat.png', 'meow.mp3'});
    final SrsMediaSyncReport rb = await media(b, loc, mediaB);
    expect(rb.downloaded, 2);
    expect(rb.missing, isEmpty);
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);
    expect((await media(a, loc, mediaA)).uploaded, 0, reason: '位置上已有，不重传');

    // 位置上的文件丢了（换了网盘 / 被别的工具删了）：持有它的设备下一轮补传，第三台照常拿到。
    loc.files.remove('$kSrsMediaFolder/cat.png');
    expect((await media(b, loc, mediaB)).uploaded, 1);
    final SrsDbStore c = await device('c');
    await srsSyncOnce(c, loc);
    final Directory mediaC = mediaDir('c');
    expect((await media(c, loc, mediaC)).downloaded, 2);
  });

  test('引用了但位置与本机都没有：报缺失，等持有它的设备上线', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    await addNote(a, '犬', '<img src="dog.png">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    final SrsMediaSyncReport r = await media(b, loc, mediaDir('b'));
    expect(r.downloaded, 0);
    expect(r.missing, <String>{'dog.png'});
  });

  test('被删笔记的媒体：90 天内位置上保留、还能下载；过期后清掉独占的，共享的与本机不认识的不删', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final Directory mediaA = mediaDir('a');
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    writeMedia(mediaA, 'only.png', <int>[1]);
    writeMedia(mediaA, 'shared.png', <int>[2]);
    final String gone = await addNote(
      a,
      '雪',
      '<img src="only.png"><img src="shared.png">',
    );
    await addNote(a, '雨', '<img src="shared.png">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect((await media(a, loc, mediaA)).uploaded, 2);
    // 别的设备的新笔记的媒体：本机还没收到那条笔记，不认识它。
    await loc.put(
      '$kSrsMediaFolder/stranger.png',
      Uint8List.fromList(<int>[9]),
    );

    t += 1000;
    await a.deleteNote(gone);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    t += 89 * kDay;
    SrsMediaSyncReport r = await media(a, loc, mediaA);
    expect(r.deleted, 0, reason: '保留期内不删');
    expect(remoteMedia(loc), contains('only.png'));
    // 保留期内恢复笔记媒体还在：新设备照样下载被删笔记的媒体。
    final SrsDbStore c = await device('c');
    await srsSyncOnce(c, loc);
    final Directory mediaC = mediaDir('c');
    expect((await media(c, loc, mediaC)).downloaded, 2);
    expect(File(p.join(mediaC.path, 'only.png')).existsSync(), isTrue);

    t += 2 * kDay;
    r = await media(a, loc, mediaA);
    expect(r.deleted, 1);
    expect(remoteMedia(loc), <String>{'shared.png', 'stranger.png'});
    expect(
      (await media(b, loc, mediaDir('b'))).uploaded,
      0,
      reason: '看得到删除的设备不会把过期的文件再传上来',
    );
    expect(remoteMedia(loc), isNot(contains('only.png')));
  });

  test('归档位置永不删：过期的媒体照样留着', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final Directory mediaA = mediaDir('a');
    final SrsDbStore a = await device('a');
    writeMedia(mediaA, 'only.png', <int>[1]);
    final String gone = await addNote(a, '雪', '<img src="only.png">');
    expect((await media(a, loc, mediaA, archive: true)).uploaded, 1);
    t += 1000;
    await a.deleteNote(gone);
    t += 365 * kDay;
    final SrsMediaSyncReport r = await media(a, loc, mediaA, archive: true);
    expect(r.deleted, 0);
    expect(remoteMedia(loc), <String>{'only.png'});
    // 同一份过期状态对普通同步 / 媒体位置就会清。
    expect((await media(a, loc, mediaA)).deleted, 1);
  });

  test('旧格式（按写入者分目录）的媒体只读兜底：下载到本机并补传进 v2 目录，旧目录不动', () async {
    final Directory remote = Directory(p.join(root.path, 'remote'))
      ..createSync();
    final LocalDirectoryAssetStore backend = LocalDirectoryAssetStore(remote);
    final File legacyFile = File(
      p.join(
        remote.path,
        kSrsSync2Namespace,
        kProfile,
        'a#1',
        kSrsMediaFolder,
        'old.png',
      ),
    )..createSync(recursive: true);
    legacyFile.writeAsBytesSync(<int>[7, 7]);
    final SrsLocationStore loc = SrsAssetLocationStore(
      store: backend,
      profileUid: kProfile,
    );
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    await addNote(a, '古', '<img src="old.png">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);

    final Directory mediaB = mediaDir('b');
    expect((await media(b, loc, mediaB)).missing, <String>{
      'old.png',
    }, reason: '没给兜底就只是缺失');
    final SrsMediaSyncReport r = await media(
      b,
      loc,
      mediaB,
      legacy: srsLegacyMediaReader(backend, kProfile),
    );
    expect(r.downloaded, 1);
    expect(r.uploaded, 1);
    expect(File(p.join(mediaB.path, 'old.png')).readAsBytesSync(), <int>[7, 7]);
    expect(await loc.get('$kSrsMediaFolder/old.png'), <int>[7, 7]);
    expect(legacyFile.existsSync(), isTrue, reason: '旧目录不自动删');
    // 之后不需要兜底：第三台直接从 v2 目录拿。
    final SrsDbStore c = await device('c');
    await srsSyncOnce(c, loc);
    expect((await media(c, loc, mediaDir('c'))).downloaded, 1);
  });
}
