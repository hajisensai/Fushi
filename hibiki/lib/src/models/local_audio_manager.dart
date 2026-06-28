import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';

class LocalAudioDbEntry {
  const LocalAudioDbEntry({
    required this.path,
    required this.displayName,
    this.enabled = false,
    this.sources = const <LocalAudioSourcePref>[],
  });

  factory LocalAudioDbEntry.fromJson(Map<String, dynamic> json) =>
      LocalAudioDbEntry(
        path: json['path'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        sources: (json['sources'] as List<dynamic>?)
                ?.map((dynamic e) =>
                    LocalAudioSourcePref.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <LocalAudioSourcePref>[],
      );

  final String path;
  final String displayName;
  final bool enabled;

  /// 库内子来源偏好（优先级序，首=最高）。空=未配置 → 查询退回 DB 自然序、全启用。
  final List<LocalAudioSourcePref> sources;

  LocalAudioDbEntry copyWith({
    String? displayName,
    bool? enabled,
    List<LocalAudioSourcePref>? sources,
  }) =>
      LocalAudioDbEntry(
        path: path,
        displayName: displayName ?? this.displayName,
        enabled: enabled ?? this.enabled,
        sources: sources ?? this.sources,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'displayName': displayName,
        'enabled': enabled,
        if (sources.isNotEmpty)
          'sources':
              sources.map((LocalAudioSourcePref s) => s.toJson()).toList(),
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

  /// 上一次分配的内部副本时间戳。仅用毫秒时间戳做文件名时，连续两次导入若落在
  /// 同一毫秒（在快机器/CI 上很常见）会撞出相同 internalPath → 后一个覆盖前一个，
  /// 两条配置塌成同一 path、身份丢失。这里保证严格单调递增，**毫秒相同也强制 +1**，
  /// 让每次导入的内部文件名唯一（仍是单段数字，匹配 [pruneOrphans] 的命名正则）。
  static int _lastImportStamp = 0;

  /// 把一个库 entry 转成喂 native 的配置：sourceOrder 只含**启用**的子来源，
  /// 按存储顺序（=优先级）。空 sources → 空 order → native 退回全启用自然序。
  static LocalAudioDbConfig _configFor(LocalAudioDbEntry e) =>
      LocalAudioDbConfig(
        path: e.path,
        sourceOrder: e.sources
            .where((LocalAudioSourcePref s) => s.enabled)
            .map((LocalAudioSourcePref s) => s.name)
            .toList(),
      );

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
    await TtsChannel.instance
        .setLocalAudioDbs(dbs.where((e) => e.enabled).map(_configFor).toList());
  }

  /// 只改某个库的子来源偏好（优先级序 + 逐源启用），立即持久化并重推 native。
  Future<void> setSourcesFor(
      String path, List<LocalAudioSourcePref> prefs) async {
    final List<LocalAudioDbEntry> dbs = List<LocalAudioDbEntry>.of(entries);
    final int i = dbs.indexWhere((LocalAudioDbEntry e) => e.path == path);
    if (i < 0) return;
    dbs[i] = dbs[i].copyWith(sources: prefs);
    await setEntries(dbs); // setEntries 内已重推 native
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
    int stamp = DateTime.now().millisecondsSinceEpoch;
    if (stamp <= _lastImportStamp) stamp = _lastImportStamp + 1;
    _lastImportStamp = stamp;
    final String internalName = 'local_audio_$stamp.db';
    final String internalPath =
        path.join(_databaseDirectory.path, internalName);
    final File sourceFile = File(sourcePath);
    // 源文件不存在不再静默跳过 copy（BUG-446「假成功」根因：旧实现会返回一个指向
    // 空 internalPath 的 entry，导入「成功」却拷不出任何文件）。显式失败抛错，让上层
    // catch 记录真因（路径/选择问题）并把可见反馈带给用户。
    if (!await sourceFile.exists()) {
      throw FileSystemException(
          'local audio db source file not found', sourcePath);
    }
    try {
      await sourceFile.copy(internalPath);
    } on FileSystemException catch (e) {
      // copy 失败（磁盘满 / 无写权限 / 目录不存在 / 源被占用）：带上真 errno
      // （FileSystemException.osError）重抛，让上层日志能定位具体系统级原因。
      throw FileSystemException(
        'failed to copy local audio db into store: ${e.message}'
        '${e.osError != null ? ' (${e.osError})' : ''}',
        sourcePath,
        e.osError,
      );
    }
    return LocalAudioDbEntry(
      path: internalPath,
      displayName: displayName,
      enabled: true,
    );
  }

  /// 删除库目录里所有不被 [keepPaths] 引用的本地音频副本文件
  /// （只动 `local_audio_*.db` 及其 -wal/-shm 旁文件，绝不碰其它文件，如主库 hibiki.db）。
  /// 用于回收"拷贝了但从未持久化"的孤儿文件。
  Future<void> pruneOrphans(Iterable<String> keepPaths) async {
    // 规范化引用路径，避免 Windows 反斜杠 / 正斜杠 + 大小写差异导致误删被引用文件。
    final Set<String> keep =
        keepPaths.map((String p) => path.canonicalize(p)).toSet();
    if (!await _databaseDirectory.exists()) return;
    final RegExp namePattern = RegExp(r'^local_audio_\d+\.db$');
    await for (final FileSystemEntity entity in _databaseDirectory.list()) {
      if (entity is! File) continue;
      final String name = path.basename(entity.path);
      if (!namePattern.hasMatch(name)) continue; // 只清本地音频副本，跳过 -wal/-shm 和其它文件
      if (keep.contains(path.canonicalize(entity.path))) continue;
      await deleteFiles(entity.path); // 连带删除该副本的 -wal / -shm
    }
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

  Future<void> bindForNativeHandler({bool clearMissingPath = false}) async {
    final dbs = entries;
    if (dbs.isEmpty) return;

    final validConfigs = <LocalAudioDbConfig>[];
    for (final entry in dbs) {
      if (!entry.enabled) continue;
      if (await File(entry.path).exists()) {
        validConfigs.add(_configFor(entry));
      } else {
        debugPrint('[hibiki-audio] DB missing, skipping: ${entry.path}');
      }
    }
    if (validConfigs.isNotEmpty) {
      await TtsChannel.instance.setLocalAudioDbs(validConfigs);
    }
  }
}
