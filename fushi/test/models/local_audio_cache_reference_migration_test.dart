import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/models/local_audio_source_pref.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void _writeAudioDb(String filename) {
  File(filename).parent.createSync(recursive: true);
  final sqlite.Database db = sqlite.sqlite3.open(filename);
  db.execute(
    'CREATE TABLE entries '
    '(expression TEXT, reading TEXT, file TEXT, source TEXT)',
  );
  db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
  db.execute("INSERT INTO entries VALUES ('cat', '', 'cat.mp3', 'forvo')");
  db.execute("INSERT INTO android VALUES ('cat.mp3', 'forvo', X'010203')");
  db.dispose();
}

/// 在真实文件复制完成与路径提交之间插入另一个设置写入者。
class _ConcurrentEditAudioManager extends LocalAudioManager {
  _ConcurrentEditAudioManager({
    required super.prefsRepo,
    required super.databaseDirectory,
    required this.onCopied,
  });

  final Future<void> Function(String copiedPath) onCopied;

  @override
  Future<LocalAudioDbEntry> importFile(
    String sourcePath, {
    required String displayName,
    bool reference = false,
  }) async {
    final LocalAudioDbEntry copied = await super.importFile(
      sourcePath,
      displayName: displayName,
      reference: reference,
    );
    await onCopied(copied.path);
    return copied;
  }
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory root;
  late Directory temporary;
  late Directory store;
  late LocalAudioManager manager;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    root = Directory.systemTemp.createTempSync('local_audio_migration_');
    temporary = Directory(path.join(root.path, 'cache'))..createSync();
    store = Directory(path.join(root.path, 'database'))..createSync();
    manager = LocalAudioManager(prefsRepo: prefs, databaseDirectory: store);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    root.deleteSync(recursive: true);
  });

  Future<void> saveEntries(List<LocalAudioDbEntry> entries) async {
    await prefs.setPref(
      'local_audio_dbs',
      jsonEncode(entries.map((LocalAudioDbEntry e) => e.toJson()).toList()),
    );
    await prefs.setPref('audio_source_configs', <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'remoteAudio',
        'url': 'https://example.org/audio',
        'enabled': true,
      },
      for (final LocalAudioDbEntry e in entries)
        <String, dynamic>{
          'kind': 'localAudio',
          'path': e.path,
          'label': e.displayName,
          'enabled': e.enabled,
        },
    ]);
  }

  test(
    'moves cached DB while preserving both lists and survives cache removal',
    () async {
      final String cached = path.join(temporary.path, 'saf_pick', 'english.db');
      _writeAudioDb(cached);
      final List<int> original = File(cached).readAsBytesSync();
      final String external = path.join(root.path, 'cache-user', 'external.db');
      _writeAudioDb(external);
      await saveEntries(<LocalAudioDbEntry>[
        LocalAudioDbEntry(
          path: external,
          displayName: 'external',
          enabled: true,
        ),
        LocalAudioDbEntry(
          path: cached,
          displayName: 'English',
          sources: const <LocalAudioSourcePref>[
            LocalAudioSourcePref(name: 'forvo', enabled: false),
            LocalAudioSourcePref(name: 'other'),
          ],
        ),
      ]);
      final dynamic beforeSources = prefs.getPref('audio_source_configs');
      await manager.migrateTemporaryReferences(temporary);

      final List<LocalAudioDbEntry> migrated = manager.entries;
      expect(migrated.first.path, external);
      expect(migrated.last.displayName, 'English');
      expect(migrated.last.enabled, isFalse);
      expect(migrated.last.sources, const <LocalAudioSourcePref>[
        LocalAudioSourcePref(name: 'forvo', enabled: false),
        LocalAudioSourcePref(name: 'other'),
      ]);
      expect(path.isWithin(store.path, migrated.last.path), isTrue);
      expect(LocalAudioManager.isInternalCopyName(migrated.last.path), isTrue);
      final List<dynamic> expectedSources = List<dynamic>.from(
        beforeSources as List,
      );
      expectedSources[2] = <String, dynamic>{
        ...Map<String, dynamic>.from(expectedSources[2] as Map),
        'path': migrated.last.path,
      };
      expect(prefs.getPref('audio_source_configs'), expectedSources);
      expect(File(cached).existsSync(), isTrue);
      temporary.deleteSync(recursive: true);
      expect(File(migrated.last.path).readAsBytesSync(), original);
      await prefs.loadFromDb();
      await manager.migrateTemporaryReferences(temporary);
      expect(manager.entries.last.path, migrated.last.path);
      expect(store.listSync().whereType<File>().where(
          (File file) => LocalAudioManager.isInternalCopyName(file.path)),
          hasLength(1));
    },
  );

  test(
    'missing and invalid cached files preserve original configuration',
    () async {
      final String missing = path.join(
        temporary.path,
        'saf_pick',
        'missing.db',
      );
      final String invalid = path.join(temporary.path, 'invalid.db');
      File(invalid).writeAsStringSync('not sqlite');
      await saveEntries(<LocalAudioDbEntry>[
        LocalAudioDbEntry(path: missing, displayName: 'missing', enabled: true),
        LocalAudioDbEntry(path: invalid, displayName: 'invalid'),
      ]);
      await prefs.loadFromDb();
      final Map<String, String> before = prefs.prefsSnapshot;
      await manager.migrateTemporaryReferences(temporary);
      expect(prefs.prefsSnapshot, before);
      expect(store.listSync().whereType<File>().where(
          (File file) => LocalAudioManager.isInternalCopyName(file.path)), isEmpty);
      expect(File(invalid).readAsStringSync(), 'not sqlite');
    },
  );

  test('copy failure preserves preferences and source', () async {
    final String cached = path.join(temporary.path, 'saf_pick', 'english.db');
    _writeAudioDb(cached);
    await saveEntries(<LocalAudioDbEntry>[
      LocalAudioDbEntry(path: cached, displayName: 'English', enabled: true),
    ]);
    final Map<String, String> before = prefs.prefsSnapshot;
    store.deleteSync();
    File(store.path).writeAsStringSync('destination is a file');
    await manager.migrateTemporaryReferences(temporary);
    expect(prefs.prefsSnapshot, before);
    expect(File(cached).existsSync(), isTrue);
  });

  test(
    'second preference failure rolls back both DB paths and in-memory cache',
    () async {
      final String cached = path.join(temporary.path, 'saf_pick', 'english.db');
      _writeAudioDb(cached);
      await saveEntries(<LocalAudioDbEntry>[
        LocalAudioDbEntry(path: cached, displayName: 'English', enabled: true),
      ]);
      final String beforeEntries = prefs.getPref('local_audio_dbs') as String;
      final dynamic beforeSources = prefs.getPref('audio_source_configs');
      await db.customStatement(
        "CREATE TRIGGER reject_audio_migration BEFORE UPDATE ON preferences WHEN NEW.key = 'audio_source_configs' BEGIN SELECT RAISE(ABORT, 'test migration failure'); END",
      );
      await expectLater(
        manager.migrateTemporaryReferences(temporary),
        throwsA(isA<Exception>()),
      );
      expect(prefs.getPref('local_audio_dbs'), beforeEntries);
      expect(prefs.getPref('audio_source_configs'), beforeSources);
      await prefs.loadFromDb();
      expect(prefs.getPref('local_audio_dbs'), beforeEntries);
      expect(prefs.getPref('audio_source_configs'), beforeSources);
      expect(File(cached).existsSync(), isTrue);
    },
  );

  test('CAS rejects stale persisted values and refreshes the losing cache',
      () async {
    await prefs.setPref('local_audio_dbs', 'old');
    final Map<String, String> before = prefs.prefsSnapshot;
    final PreferencesRepository otherProcess = PreferencesRepository(db);
    addTearDown(otherProcess.dispose);
    await otherProcess.loadFromDb();
    await otherProcess.setPrefs(<String, dynamic>{
      'local_audio_dbs': 'user replacement',
      'audio_source_configs': <String>['new priority'],
    });

    final bool applied = await prefs.compareAndSetPrefs(
      expectedRaw: <String, String?>{
        'local_audio_dbs': before['local_audio_dbs'],
        'audio_source_configs': before['audio_source_configs'],
      },
      updates: <String, dynamic>{
        'local_audio_dbs': 'migration replacement',
        'audio_source_configs': <String>['old priority'],
      },
    );
    expect(applied, isFalse);
    expect(prefs.getPref('local_audio_dbs'), 'user replacement');
    expect(prefs.getPref('audio_source_configs'), <String>['new priority']);
    await otherProcess.loadFromDb();
    expect(otherProcess.getPref('local_audio_dbs'), 'user replacement');
  });

  test('configuration edited during copying wins over migration snapshot',
      () async {
    final String cached = path.join(temporary.path, 'saf_pick', 'english.db');
    _writeAudioDb(cached);
    await saveEntries(<LocalAudioDbEntry>[
      LocalAudioDbEntry(path: cached, displayName: 'English', enabled: true),
    ]);
    final PreferencesRepository otherProcess = PreferencesRepository(db);
    addTearDown(otherProcess.dispose);
    await otherProcess.loadFromDb();
    String? copiedPath;
    final String latestEntries = jsonEncode(<Map<String, dynamic>>[
      LocalAudioDbEntry(path: cached, displayName: 'User renamed').toJson(),
    ]);
    final List<Map<String, dynamic>> latestSources = <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'localAudio',
        'path': cached,
        'label': 'User renamed',
        'enabled': false,
      },
    ];
    final LocalAudioManager concurrentManager = _ConcurrentEditAudioManager(
      prefsRepo: prefs,
      databaseDirectory: store,
      onCopied: (String copied) async {
        copiedPath = copied;
        await otherProcess.setPrefs(<String, dynamic>{
          'local_audio_dbs': latestEntries,
          'audio_source_configs': latestSources,
        });
      },
    );
    await concurrentManager.migrateTemporaryReferences(temporary);

    expect(prefs.getPref('local_audio_dbs'), latestEntries);
    expect(prefs.getPref('audio_source_configs'), latestSources);
    expect(concurrentManager.entries.single.path, cached);
    expect(concurrentManager.entries.single.enabled, isFalse);
    expect(File(cached).existsSync(), isTrue);
    expect(copiedPath, isNotNull);
    expect(File(copiedPath!).existsSync(), isTrue);
    // CAS 失败只留下可回收副本，不重试并覆盖用户刚保存的配置。
    expect(store.listSync().whereType<File>().where(
        (File file) => LocalAudioManager.isInternalCopyName(file.path)),
        hasLength(1));
    await manager.pruneOrphans(concurrentManager.entries.map(
      (LocalAudioDbEntry entry) => entry.path,
    ));
    expect(File(copiedPath!).existsSync(), isFalse);
    expect(File(cached).existsSync(), isTrue);
    await prefs.loadFromDb();
    expect(prefs.getPref('local_audio_dbs'), latestEntries);
    expect(prefs.getPref('audio_source_configs'), latestSources);
  });

  test('prune waits for migration and protects its newly committed copy',
      () async {
    final String cached = path.join(temporary.path, 'saf_pick', 'english.db');
    _writeAudioDb(cached);
    await saveEntries(<LocalAudioDbEntry>[
      LocalAudioDbEntry(path: cached, displayName: 'English', enabled: true),
    ]);
    final Completer<String> copied = Completer<String>();
    final Completer<void> resumeMigration = Completer<void>();
    final LocalAudioManager migrating = _ConcurrentEditAudioManager(
      prefsRepo: prefs,
      databaseDirectory: store,
      onCopied: (String copiedPath) async {
        copied.complete(copiedPath);
        await resumeMigration.future;
      },
    );
    final PreferencesRepository pruningPrefs = PreferencesRepository(db);
    addTearDown(pruningPrefs.dispose);
    await pruningPrefs.loadFromDb();
    final LocalAudioManager pruning = LocalAudioManager(
      prefsRepo: pruningPrefs,
      databaseDirectory: store,
    );
    final Future<void> migration = migrating.migrateTemporaryReferences(temporary);
    final String newPath = await copied.future;
    bool pruneFinished = false;
    // 模拟另一个管理器以迁移前的旧列表请求清理。
    final Future<void> prune = pruning.pruneOrphans(<String>[cached]).then((_) {
      pruneFinished = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(pruneFinished, isFalse);
    expect(File(newPath).existsSync(), isTrue);
    resumeMigration.complete();
    await Future.wait(<Future<void>>[migration, prune]);

    expect(pruneFinished, isTrue);
    expect(pruning.entries.single.path, newPath);
    expect(File(newPath).existsSync(), isTrue);
    expect(File(newPath).readAsBytesSync(), File(cached).readAsBytesSync());
    expect(File(path.join(store.path, 'local_audio_migration.lock')).existsSync(),
        isTrue);
  });
}
