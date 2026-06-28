import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory directory;
  late LocalAudioManager manager;

  setUp(() async {
    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    directory = Directory.systemTemp.createTempSync('hibiki_local_audio_mgr');
    manager = LocalAudioManager(
      prefsRepo: prefs,
      databaseDirectory: directory,
    );
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('reorder persists source order', () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one'),
      LocalAudioDbEntry(path: '/tmp/two.db', displayName: 'two'),
      LocalAudioDbEntry(path: '/tmp/three.db', displayName: 'three'),
    ]);

    await manager.reorder(0, 3);

    expect(
      manager.entries.map((LocalAudioDbEntry entry) => entry.displayName),
      <String>['two', 'three', 'one'],
    );
  });

  test('new local audio DB entries default to disabled', () {
    const LocalAudioDbEntry entry = LocalAudioDbEntry(
      path: '/tmp/off.db',
      displayName: 'off',
    );

    expect(entry.enabled, isFalse);
  });

  test('legacy local audio DB JSON without enabled stays enabled', () {
    expect(
      LocalAudioDbEntry.fromJson(const <String, dynamic>{
        'path': '/tmp/old.db',
        'displayName': 'old',
      }).enabled,
      isTrue,
    );
  });

  test('LocalAudioDbEntry round trips its source prefs through json', () {
    const LocalAudioDbEntry entry = LocalAudioDbEntry(
      path: '/tmp/a.db',
      displayName: 'a',
      enabled: true,
      sources: <LocalAudioSourcePref>[
        LocalAudioSourcePref(name: 'nhk16'),
        LocalAudioSourcePref(name: 'forvo', enabled: false),
      ],
    );
    final LocalAudioDbEntry restored =
        LocalAudioDbEntry.fromJson(entry.toJson());
    expect(restored.sources, entry.sources);
  });

  test('entry without sources omits the key and decodes to empty', () {
    const LocalAudioDbEntry entry =
        LocalAudioDbEntry(path: '/tmp/b.db', displayName: 'b');
    expect(entry.toJson().containsKey('sources'), isFalse);
    expect(
      LocalAudioDbEntry.fromJson(const <String, dynamic>{
        'path': '/tmp/b.db',
        'displayName': 'b',
      }).sources,
      isEmpty,
    );
  });

  test('setSourcesFor updates only the matching db, leaving others intact',
      () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one', enabled: true),
      LocalAudioDbEntry(path: '/tmp/two.db', displayName: 'two', enabled: true),
    ]);

    await manager.setSourcesFor('/tmp/two.db', const <LocalAudioSourcePref>[
      LocalAudioSourcePref(name: 'forvo'),
      LocalAudioSourcePref(name: 'nhk16', enabled: false),
    ]);

    final List<LocalAudioDbEntry> after = manager.entries;
    expect(after.firstWhere((e) => e.path == '/tmp/one.db').sources, isEmpty);
    expect(
      after.firstWhere((e) => e.path == '/tmp/two.db').sources,
      const <LocalAudioSourcePref>[
        LocalAudioSourcePref(name: 'forvo'),
        LocalAudioSourcePref(name: 'nhk16', enabled: false),
      ],
    );
  });

  test('setSourcesFor on an unknown path is a no-op', () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one'),
    ]);
    await manager.setSourcesFor('/tmp/missing.db', const <LocalAudioSourcePref>[
      LocalAudioSourcePref(name: 'x'),
    ]);
    expect(manager.entries.single.sources, isEmpty);
  });

  test('reorder ignores out-of-range indexes', () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one'),
      LocalAudioDbEntry(path: '/tmp/two.db', displayName: 'two'),
    ]);
    final String before = prefs.getPref('local_audio_dbs', defaultValue: '');

    await manager.reorder(-1, 0);
    await manager.reorder(0, 9);

    expect(prefs.getPref('local_audio_dbs', defaultValue: ''), before);
    expect(
      jsonDecode(before) as List<dynamic>,
      hasLength(2),
    );
  });

  test('importFile copies into store and does NOT persist prefs', () async {
    final Directory src = await Directory.systemTemp.createTemp('src');
    final File source = File('${src.path}/nhk.db');
    await source.writeAsString('sqlite-bytes');

    final LocalAudioDbEntry entry =
        await manager.importFile(source.path, displayName: 'nhk');

    expect(entry.displayName, 'nhk');
    expect(File(entry.path).existsSync(), isTrue);
    expect(entry.path.startsWith(directory.path), isTrue);
    expect(manager.entries, isEmpty); // not persisted
    await src.delete(recursive: true);
  });

  // BUG-446：源文件不存在时旧实现静默跳过 copy，返回指向空 internalPath 的 entry
  // （「假成功」）。修复后必须显式抛 FileSystemException，让上层记录真因并反馈用户。
  test('importFile throws when the source file does not exist (BUG-446)',
      () async {
    expect(
      () => manager.importFile('/no/such/file/missing.db', displayName: 'x'),
      throwsA(isA<FileSystemException>()),
    );
    // 未在库目录留下任何空副本。
    final List<FileSystemEntity> leftover = directory.listSync();
    expect(leftover, isEmpty);
  });

  test('deleteFiles removes db + wal + shm', () async {
    final File dbf = File('${directory.path}/x.db')..writeAsStringSync('a');
    final File wal = File('${directory.path}/x.db-wal')..writeAsStringSync('b');
    final File shm = File('${directory.path}/x.db-shm')..writeAsStringSync('c');

    await LocalAudioManager.deleteFiles(dbf.path);

    expect(dbf.existsSync(), isFalse);
    expect(wal.existsSync(), isFalse);
    expect(shm.existsSync(), isFalse);
  });

  test('pruneOrphans deletes unreferenced local_audio_*.db files only',
      () async {
    // a referenced db we keep
    final File keep = File('${directory.path}/local_audio_1.db')
      ..writeAsStringSync('k');
    // an orphan copied db + sidecars
    final File orphan = File('${directory.path}/local_audio_2.db')
      ..writeAsStringSync('o');
    final File orphanWal = File('${directory.path}/local_audio_2.db-wal')
      ..writeAsStringSync('w');
    // an unrelated file that must NOT be touched
    final File other = File('${directory.path}/hibiki.db')
      ..writeAsStringSync('h');

    await manager.pruneOrphans(<String>[keep.path]);

    expect(keep.existsSync(), isTrue); // referenced -> kept
    expect(orphan.existsSync(), isFalse); // unreferenced -> deleted
    expect(orphanWal.existsSync(), isFalse);
    expect(other.existsSync(), isTrue); // not a local_audio_* file -> untouched
  });
}
