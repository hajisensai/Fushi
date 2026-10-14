import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000bb';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fushi_srs_sync_'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<SrsDbStore> device(String id) => SrsDbStore.open(
    db: FushiDatabase.forTesting(NativeDatabase.memory()),
    profileUid: kProfile,
    deviceId: id,
  );

  test('两台设备经文件系统同步后端收敛；cursor 文件覆盖不留副本', () async {
    final LocalDirectoryAssetStore backend = LocalDirectoryAssetStore(root);
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    SrsSyncEngine engineOf(SrsDbStore s) => SrsSyncEngine(
      directory: SrsAssetStoreDirectory(store: backend, profileUid: kProfile),
      replica: s,
    );
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '雪',
      },
    );
    for (int i = 0; i < 2; i++) {
      final SrsSyncReport ra = await engineOf(a).syncOnce();
      expect(ra.error, isNull);
      final SrsSyncReport rb = await engineOf(b).syncOnce();
      expect(rb.error, isNull);
    }
    final SrsNoteView? n = await b.note(noteId);
    expect(n!.field(srsLapisFieldId(kProfile, 'Expression')), '雪');
    expect((await b.cardsOfNote(noteId)), hasLength(1));
    final Directory writerDir = Directory(
      '${root.path}${Platform.pathSeparator}$kSrsSyncNamespace'
      '${Platform.pathSeparator}$kProfile${Platform.pathSeparator}${a.writerId}',
    );
    final List<String> names = writerDir
        .listSync()
        .map((FileSystemEntity e) => e.uri.pathSegments.last)
        .toList();
    expect(names.where((String n) => n == srsCursorName), hasLength(1));
    expect(names, contains(srsBatchName(1)));
  });
}
