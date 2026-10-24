import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000cc';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fushi_srs_media_'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
    );
  }

  test('媒体按内容名上传 / 下载；写入者目录被清理后由仍持有它的设备补传', () async {
    final LocalDirectoryAssetStore backend = LocalDirectoryAssetStore(
      Directory(p.join(root.path, 'remote'))..createSync(),
    );
    final Directory mediaA = Directory(p.join(root.path, 'a'))..createSync();
    final Directory mediaB = Directory(p.join(root.path, 'b'))..createSync();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1, 2, 3]);
    File(p.join(mediaA.path, 'meow.mp3')).writeAsBytesSync(<int>[4, 5]);
    await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '猫',
        srsLapisFieldId(kProfile, 'Picture'): '<img src="cat.png">',
        srsLapisFieldId(kProfile, 'ExpressionAudio'): '[sound:meow.mp3]',
      },
    );
    Future<void> events(SrsDbStore s) => SrsSyncEngine(
      directoryKey: 'test',
      directory: SrsAssetStoreDirectory(store: backend, profileUid: kProfile),
      replica: s,
    ).syncOnce();
    await events(a);
    await events(b);

    final SrsMediaSyncReport ra = await srsSyncMedia(
      backend: backend,
      store: a,
      mediaRoot: mediaA,
    );
    expect(ra.uploaded, 2);
    final SrsMediaSyncReport rb = await srsSyncMedia(
      backend: backend,
      store: b,
      mediaRoot: mediaB,
    );
    expect(rb.downloaded, 2);
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);
    expect(
      (await srsSyncMedia(
        backend: backend,
        store: a,
        mediaRoot: mediaA,
      )).uploaded,
      0,
    );

    // c 在 a 的目录被清理之前拿到了事件（真实协议里，目录只在被活跃快照覆盖后才删）。
    final Directory mediaC = Directory(p.join(root.path, 'c'))..createSync();
    final SrsDbStore c = await device('c');
    await events(c);

    // a 的写入者目录被当作退役清理：b 下一轮发现同步目录里没有了，补传自己的副本。
    Directory(
      p.join(root.path, 'remote', kSrsSyncNamespace, kProfile, a.writerId),
    ).deleteSync(recursive: true);
    expect(
      (await srsSyncMedia(
        backend: backend,
        store: b,
        mediaRoot: mediaB,
      )).uploaded,
      2,
    );
    expect(
      (await srsSyncMedia(
        backend: backend,
        store: c,
        mediaRoot: mediaC,
      )).downloaded,
      2,
    );
  });
}
