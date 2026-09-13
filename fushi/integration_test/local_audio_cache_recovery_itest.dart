import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi/utils.dart' show UpdateChecker;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/test_app_launcher.dart';

/// Android 平台链路验收：真实 SQLite、MethodChannel 查询/提取、MediaPlayer 启播。
/// 不操作 SAF UI，也不把启播成功当作扬声器输出已被人耳或录音验证。
Uint8List _toneWav() {
  const int rate = 16000;
  const int samples = rate ~/ 4;
  final ByteData bytes = ByteData(44 + samples * 2);
  void ascii(int offset, String value) {
    for (int i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  ascii(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, samples * 2, Endian.little);
  for (int i = 0; i < samples; i++) {
    bytes.setInt16(44 + i * 2,
        (4000 * math.sin(2 * math.pi * 440 * i / rate)).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void _writeAudioDb(File file, String term, Uint8List wav) {
  final sqlite.Database db = sqlite.sqlite3.open(file.path);
  try {
    db.execute('CREATE TABLE entries '
        '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    db.execute('INSERT INTO entries VALUES (?, ?, ?, ?)',
        <Object?>[term, '', '$term.wav', 'cache-recovery-itest']);
    db.execute('INSERT INTO android VALUES (?, ?, ?)',
        <Object?>['$term.wav', 'cache-recovery-itest', wav]);
  } finally {
    db.dispose();
  }
}

Future<void> _verifyNativeAudio(
    String term, Uint8List wav, Set<String> extractedFiles) async {
  final TtsChannel channel = TtsChannel.instance;
  final Map<String, dynamic>? result = await channel.queryLocalAudio(term, '');
  expect(result, isNotNull, reason: 'Android native query must find fixture');
  final String? extracted = await channel.extractLocalAudio(
    result!['file'] as String,
    result['source'] as String,
    dbIndex: (result['dbIndex'] as num).toInt(),
  );
  expect(extracted, isNotNull);
  extractedFiles.add(extracted!);
  expect(await File(extracted).readAsBytes(), orderedEquals(wav));
  expect(await channel.playFile(extracted), isTrue,
      reason: 'Real Android MediaPlayer must prepare and start valid WAV');
  await channel.stop();
  // 下一轮必须重新从库读取 BLOB，不能靠之前提取的文件证明恢复成功。
  await File(extracted).delete();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'Android local audio survives cache removal and migrates old refs',
      (WidgetTester tester) async {
    expect(Platform.isAndroid, isTrue,
        reason: 'Run this platform verification only on an Android emulator');
    final bool previousAutoCheck = UpdateChecker.disableAutoCheckForTesting;
    UpdateChecker.disableAutoCheckForTesting = true;
    await launchFushiTestApp();
    for (int i = 0;
        i < 120 && find.byType(MaterialApp).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final AppModel appModel = await readyAppModel(tester);
    final LocalAudioManager manager = LocalAudioManager(
      prefsRepo: appModel.prefsRepo,
      databaseDirectory: appModel.databaseDirectory,
    );
    final Map<String, String> snapshot = appModel.prefsRepo.prefsSnapshot;
    const List<String> changedKeys = <String>[
      'local_audio_dbs',
      'local_audio_db_path',
      'local_audio_db_display_name',
      'audio_source_configs',
      'audio_sources',
    ];
    final Directory fixture = await appModel.temporaryDirectory
        .createTemp('local_audio_cache_recovery_itest_');
    final Set<String> generatedDbs = <String>{};
    final Set<String> extractedFiles = <String>{};
    final Uint8List wav = _toneWav();
    final String suffix = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      // 本测试会触发生产 pruneOrphans，故仅允许干净的模拟器音频库配置。
      expect(appModel.localAudioDbs, isEmpty,
          reason:
              'Use an isolated emulator with no user local audio databases');
      final File source = File(path.join(fixture.path, 'copied.db'));
      final String copyTerm = 'cachecopy$suffix';
      _writeAudioDb(source, copyTerm, wav);
      final LocalAudioDbEntry imported = await appModel.importLocalAudioDbFile(
          source.path,
          displayName: 'cache-copy-itest-$suffix',
          reference: false);
      generatedDbs.add(imported.path);
      expect(path.isWithin(appModel.databaseDirectory.path, imported.path),
          isTrue);
      await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
        AudioSourceConfig.localAudio(
            label: imported.displayName, path: imported.path, enabled: true),
      ]);
      await _verifyNativeAudio(copyTerm, wav, extractedFiles);
      await source.delete();
      await appModel.prefsRepo.loadFromDb();
      await manager.bindForNativeHandler();
      await _verifyNativeAudio(copyTerm, wav, extractedFiles);

      final File legacy = File(path.join(fixture.path, 'legacy.db'));
      final String legacyTerm = 'cachelegacy$suffix';
      _writeAudioDb(legacy, legacyTerm, wav);
      final LocalAudioDbEntry legacyEntry = LocalAudioDbEntry(
          path: legacy.path,
          displayName: 'cache-legacy-itest-$suffix',
          enabled: true,
          sources: const <LocalAudioSourcePref>[
            LocalAudioSourcePref(name: 'cache-recovery-itest'),
          ]);
      // 直接播种旧版本持久化形状；不能用新导入函数提前消除旧缓存引用。
      await appModel.prefsRepo.setPrefs(<String, dynamic>{
        'local_audio_dbs': jsonEncode(<Map<String, dynamic>>[
          imported.toJson(),
          legacyEntry.toJson(),
        ]),
        'audio_source_configs': <Map<String, dynamic>>[
          AudioSourceConfig.localAudio(
                  label: imported.displayName,
                  path: imported.path,
                  enabled: true)
              .toJson(),
          AudioSourceConfig.localAudio(
                  label: legacyEntry.displayName,
                  path: legacy.path,
                  enabled: true)
              .toJson(),
        ],
      });
      await manager.migrateTemporaryReferences(appModel.temporaryDirectory);
      final LocalAudioDbEntry migrated = manager.entries.last;
      generatedDbs.add(migrated.path);
      expect(migrated.path, isNot(legacy.path));
      expect(migrated.sources, legacyEntry.sources);
      expect(
          appModel.audioSourceConfigs
              .where((AudioSourceConfig source) =>
                  source.kind == AudioSourceKind.localAudio)
              .last
              .path,
          migrated.path);
      expect(await legacy.exists(), isTrue);
      await legacy.delete();
      await appModel.prefsRepo.loadFromDb();
      await manager.migrateTemporaryReferences(appModel.temporaryDirectory);
      expect(manager.entries.last.path, migrated.path);
      await manager.bindForNativeHandler();
      await _verifyNativeAudio(legacyTerm, wav, extractedFiles);
    } finally {
      await TtsChannel.instance.stop();
      await TtsChannel.instance.setLocalAudioDbs(const <LocalAudioDbConfig>[]);
      await appModel.database.setPrefs(<String, String>{
        for (final String key in changedKeys)
          if (snapshot.containsKey(key)) key: snapshot[key]!,
      });
      for (final String key in changedKeys) {
        if (!snapshot.containsKey(key)) await appModel.database.deletePref(key);
      }
      await appModel.prefsRepo.loadFromDb();
      await manager.bindForNativeHandler();
      for (final String filename in generatedDbs) {
        if (path.isWithin(appModel.databaseDirectory.path, filename)) {
          await LocalAudioManager.deleteFiles(filename);
        }
      }
      for (final String filename in extractedFiles) {
        if (await File(filename).exists()) await File(filename).delete();
      }
      if (await fixture.exists()) await fixture.delete(recursive: true);
      UpdateChecker.disableAutoCheckForTesting = previousAutoCheck;
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
