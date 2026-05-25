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
    this.enabled = true,
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

  LocalAudioDbEntry copyWith({bool? enabled}) => LocalAudioDbEntry(
        path: path,
        displayName: displayName,
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

  Future<void> add(String sourcePath, {required String displayName}) async {
    final internalName =
        'local_audio_${DateTime.now().millisecondsSinceEpoch}.db';
    final internalPath = path.join(_databaseDirectory.path, internalName);
    final sourceFile = File(sourcePath);
    if (await sourceFile.exists()) {
      await sourceFile.copy(internalPath);
    }
    final dbs = List<LocalAudioDbEntry>.of(entries);
    dbs.add(LocalAudioDbEntry(path: internalPath, displayName: displayName));
    await setEntries(dbs);
  }

  Future<void> remove(int index) async {
    final dbs = List<LocalAudioDbEntry>.of(entries);
    if (index < 0 || index >= dbs.length) return;
    final entry = dbs.removeAt(index);
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('${entry.path}$suffix');
      if (await f.exists()) await f.delete();
    }
    await setEntries(dbs);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final dbs = List<LocalAudioDbEntry>.of(entries);
    if (newIndex > oldIndex) newIndex--;
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
