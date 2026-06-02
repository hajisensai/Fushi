import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';

class LocalAudioDbEntry {
  const LocalAudioDbEntry({
    required this.path,
    required this.displayName,
    this.enabled = false,
  });

  factory LocalAudioDbEntry.fromJson(Map<String, dynamic> json) =>
      LocalAudioDbEntry(
        path: json['path'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );

  final String path;
  final String displayName;
  final bool enabled;

  LocalAudioDbEntry copyWith({String? displayName, bool? enabled}) =>
      LocalAudioDbEntry(
        path: path,
        displayName: displayName ?? this.displayName,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'displayName': displayName,
        'enabled': enabled,
      };
}

class LocalAudioManager {
  LocalAudioManager({
    required PreferencesRepository prefsRepo,
    required Directory databaseDirectory,
  })  : _prefsRepo = prefsRepo,
        _databaseDirectory = databaseDirectory;

  final PreferencesRepository _prefsRepo;
  final Directory _databaseDirectory;

  bool get localAudioEnabled =>
      _prefsRepo.getPref('local_audio_enabled', defaultValue: false);

  List<LocalAudioDbEntry> get entries {
    final String raw = _prefsRepo.getPref('local_audio_dbs', defaultValue: '');
    if (raw.isEmpty) {
      final String oldPath =
          _prefsRepo.getPref('local_audio_db_path', defaultValue: '');
      if (oldPath.isNotEmpty) {
        final String oldName =
            _prefsRepo.getPref('local_audio_db_display_name', defaultValue: '');
        return [LocalAudioDbEntry(path: oldPath, displayName: oldName)];
      }
      return [];
    }
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((dynamic e) =>
              LocalAudioDbEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> setEntries(List<LocalAudioDbEntry> dbs) async {
    await _prefsRepo.setPref(
        'local_audio_dbs', jsonEncode(dbs.map((e) => e.toJson()).toList()));
    await _prefsRepo.setPref('local_audio_db_path', '');
    await _prefsRepo.setPref('local_audio_db_display_name', '');
    await TtsChannel.instance.setLocalAudioDbs(
        dbs.where((e) => e.enabled).map((e) => e.path).toList());
  }

  Future<void> toggleEnabled(int index) async {
    final dbs = List<LocalAudioDbEntry>.of(entries);
    if (index < 0 || index >= dbs.length) return;
    dbs[index] = dbs[index].copyWith(enabled: !dbs[index].enabled);
    await setEntries(dbs);
  }

  /// 把外部 [sourcePath] 拷贝进库目录，返回指向内部副本的 entry（默认启用），
  /// 但不写 prefs、不通知 native。持久化交给 setEntries / setAudioSourceConfigs。
  Future<LocalAudioDbEntry> importFile(
    String sourcePath, {
    required String displayName,
  }) async {
    final String internalName =
        'local_audio_${DateTime.now().millisecondsSinceEpoch}.db';
    final String internalPath =
        path.join(_databaseDirectory.path, internalName);
    final File sourceFile = File(sourcePath);
    if (await sourceFile.exists()) {
      await sourceFile.copy(internalPath);
    }
    return LocalAudioDbEntry(
      path: internalPath,
      displayName: displayName,
      enabled: true,
    );
  }

  /// 删除一个本地库的主文件及其 -wal / -shm 旁文件。
  static Future<void> deleteFiles(String dbPath) async {
    if (dbPath.isEmpty) return;
    for (final String suffix in <String>['', '-wal', '-shm']) {
      final File f = File('$dbPath$suffix');
      if (await f.exists()) await f.delete();
    }
  }

  Future<void> add(String sourcePath, {required String displayName}) async {
    final LocalAudioDbEntry entry =
        await importFile(sourcePath, displayName: displayName);
    final dbs = List<LocalAudioDbEntry>.of(entries)..add(entry);
    await setEntries(dbs);
  }

  Future<void> remove(int index) async {
    final dbs = List<LocalAudioDbEntry>.of(entries);
    if (index < 0 || index >= dbs.length) return;
    final entry = dbs.removeAt(index);
    await deleteFiles(entry.path);
    await setEntries(dbs);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final dbs = List<LocalAudioDbEntry>.of(entries);
    if (oldIndex < 0 || oldIndex >= dbs.length) return;
    if (newIndex < 0 || newIndex > dbs.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final entry = dbs.removeAt(oldIndex);
    dbs.insert(newIndex, entry);
    await setEntries(dbs);
  }

  Future<void> toggleLocalAudio(VoidCallback notifyListeners) async {
    await _prefsRepo.setPref('local_audio_enabled', !localAudioEnabled);
    if (localAudioEnabled) {
      final paths = entries.where((e) => e.enabled).map((e) => e.path).toList();
      if (paths.isNotEmpty) {
        TtsChannel.instance.setLocalAudioDbs(paths);
      }
    } else {
      TtsChannel.instance.setLocalAudioDbs(<String>[]);
    }
    notifyListeners();
  }

  Future<void> setLocalAudioEnabled(bool value) async {
    await _prefsRepo.setPref('local_audio_enabled', value);
    if (value) {
      await TtsChannel.instance.setLocalAudioDbs(
        entries.where((e) => e.enabled).map((e) => e.path).toList(),
      );
    } else {
      await TtsChannel.instance.setLocalAudioDbs(<String>[]);
    }
  }

  Future<void> bindForNativeHandler({bool clearMissingPath = false}) async {
    if (!localAudioEnabled) return;
    final dbs = entries;
    if (dbs.isEmpty) return;

    final validPaths = <String>[];
    for (final entry in dbs) {
      if (!entry.enabled) continue;
      if (await File(entry.path).exists()) {
        validPaths.add(entry.path);
      } else {
        debugPrint('[hibiki-audio] DB missing, skipping: ${entry.path}');
      }
    }
    if (validPaths.isNotEmpty) {
      await TtsChannel.instance.setLocalAudioDbs(validPaths);
    }
  }
}
