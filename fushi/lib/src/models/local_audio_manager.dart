import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:fushi/src/models/local_audio_source_pref.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';

/// 选中的文件不是一个可用的本地音频源库（不是 Yomitan「本地音频服务器」SQLite，
/// 或库里没有任何音频）。[LocalAudioManager.importFile] 在把文件收进库前抛出，
/// 让上层给用户一句「这不是有效音频数据库」，而不是把没用的 zip / 备份 zip 当成
/// 音频源静默导入成空音频（BUG-779）。
class InvalidLocalAudioDbException implements Exception {
  const InvalidLocalAudioDbException(this.sourcePath);

  final String sourcePath;

  @override
  String toString() =>
      'InvalidLocalAudioDbException: not a usable local audio database '
      '($sourcePath)';
}

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

  /// 内部副本命名（[importFile] 生成、[pruneOrphans] 回收的形状）：
  /// `local_audio_<毫秒时间戳>.db`。是判定「可跨机按文件名归一」的唯一真值。
  static final RegExp _internalCopyNamePattern =
      RegExp(r'^local_audio_\d+\.db$');

  /// 同时容忍 `/` 与 `\` 的 basename（不依赖运行平台的 [path.basename] 语义，
  /// 兼容跨 OS 备份：Windows 备份在 POSIX 机导入时反斜杠也要被切掉）。
  static String _basenameAnySep(String p) {
    int cut = -1;
    for (int i = p.length - 1; i >= 0; i--) {
      final String c = p[i];
      if (c == '/' || c == '\\') {
        cut = i;
        break;
      }
    }
    return cut < 0 ? p : p.substring(cut + 1);
  }

  /// [dbPath] 的 basename 是否是内部副本命名。跨机导入后目录前缀是**源机**的，
  /// 只有文件名可信，故只按 basename 判断（[resolveInternalPath] 据此归一）。
  static bool isInternalCopyName(String dbPath) =>
      dbPath.isNotEmpty &&
      _internalCopyNamePattern.hasMatch(_basenameAnySep(dbPath));

  /// 把一条存储的 localAudio 库路径归一到本机库目录 [dir]：内部副本按**文件名**
  /// 重挂到 `<dir>/<basename>`（跨机可移植——丢弃源机绝对前缀，只认文件名，修
  /// TODO-1171：换机后源机绝对 path 不存在导致本地发音静默消失）；外部引用
  /// （BUG-483 引用模式，命名不匹配）原样返回（本就无法跨机，保留原值等重指）。
  static String resolveInternalPath(String storedPath, String dir) =>
      isInternalCopyName(storedPath)
          ? path.join(dir, _basenameAnySep(storedPath))
          : storedPath;

  /// 把一个库 entry 转成喂 native 的配置：path 先按 [resolveInternalPath] 归一到
  /// 本机库目录（内部副本认文件名，跨机安全），sourceOrder 只含**启用**的子来源，
  /// 按存储顺序（=优先级）。空 sources → 空 order → native 退回全启用自然序。
  LocalAudioDbConfig _configFor(LocalAudioDbEntry e) => LocalAudioDbConfig(
        path: resolveInternalPath(e.path, _databaseDirectory.path),
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

  /// 路径是否落在库目录 [_databaseDirectory] 内部（=我们自己复制的内部副本）。
  /// 引用模式下 entry.path 指向用户原文件，天然落在库目录之外 → 返回 false，
  /// [pruneOrphans] / [remove] 据此跳过删除，绝不动用户原文件。
  bool _isInternalCopy(String dbPath) {
    if (dbPath.isEmpty) return false;
    final String dir = path.canonicalize(_databaseDirectory.path);
    final String parent = path.canonicalize(path.dirname(dbPath));
    return path.equals(dir, parent);
  }

  /// 把外部 [sourcePath] 拷贝进库目录，返回指向内部副本的 entry（默认启用），
  /// 但不写 prefs、不通知 native。持久化交给 setEntries / setAudioSourceConfigs。
  ///
  /// [reference]=true（BUG-483）：跳过 copy，直接返回指向用户原始 [sourcePath] 的
  /// entry，不在 C 盘 AppData / 手机内部存储留副本。false（默认，向后兼容）：复制进
  /// 库目录返回内部副本 entry。
  ///
  /// 调用方必须确保 [sourcePath] 是**用户原始位置的真实路径**（BUG-1667）：安卓
  /// file_picker 回退路径给的是会被系统清掉的 app cache 临时副本，引用它等于引用一个
  /// 随时消失的文件。判据不是平台而是路径出处，见 `pickRealFilePathDetailed` 的
  /// `PickedFilePath.isRealPath`。
  Future<LocalAudioDbEntry> importFile(
    String sourcePath, {
    required String displayName,
    bool reference = false,
  }) async {
    final File sourceFile = File(sourcePath);
    // 源文件不存在不再静默跳过 copy（BUG-446「假成功」根因：旧实现会返回一个指向
    // 空 internalPath 的 entry，导入「成功」却拷不出任何文件）。显式失败抛错，让上层
    // catch 记录真因（路径/选择问题）并把可见反馈带给用户。两种模式共用此校验。
    if (!await sourceFile.exists()) {
      throw FileSystemException(
          'local audio db source file not found', sourcePath);
    }
    // BUG-779：导入前校验内容，拒绝「没用的 zip / 备份 zip / 空库」。旧实现只查存在性
    // 就复制并报成功，无效性要等查询时才在 LocalAudioDb 的 catch 里被吞成空音频源。
    // 校验源文件（引用模式指向它、复制模式即将复制它），无效即抛，绝不留内部副本孤儿。
    if (!LocalAudioDb.isUsableAudioSource(sourcePath)) {
      throw InvalidLocalAudioDbException(sourcePath);
    }
    if (reference) {
      // 引用模式（BUG-483）：不复制，直接指向用户原路径。清理逻辑按 [_isInternalCopy]
      // 派生「外部引用 = 不删」，原文件天然落在库目录之外故安全。
      return LocalAudioDbEntry(
        path: sourcePath,
        displayName: displayName,
        enabled: true,
      );
    }
    int stamp = DateTime.now().millisecondsSinceEpoch;
    if (stamp <= _lastImportStamp) stamp = _lastImportStamp + 1;
    _lastImportStamp = stamp;
    final String internalName = 'local_audio_$stamp.db';
    final String internalPath =
        path.join(_databaseDirectory.path, internalName);
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
    // 归一后再规范化：跨机导入后 keepPaths 里内部副本仍带**源机**绝对前缀，
    // 若不归一，本机已落地的同名副本会被判为孤儿误删（TODO-1171 数据丢失）。
    final Set<String> keep = keepPaths
        .map((String p) =>
            path.canonicalize(resolveInternalPath(p, _databaseDirectory.path)))
        .toSet();
    if (!await _databaseDirectory.exists()) return;
    final RegExp namePattern = _internalCopyNamePattern;
    // BUG-483：本方法只遍历 [_databaseDirectory] 自身、且只匹配 `local_audio_<ts>.db`
    // 内部副本命名，故引用模式落在库目录之外的用户原文件天然不会进入此循环、不被回收。
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
    // 绑定期的后台建索引（LocalAudioDb.ensureIndexes）可能还握着本库的
    // readWrite 句柄；Windows 上删被打开的文件是 errno 32。先等它结束
    // （没有在途任务时立即返回），删除与索引生命周期同步而非撞运气。
    await LocalAudioDb.waitForPendingIndexing(dbPath);
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
    // BUG-483：只删我们复制进库目录的内部副本；引用模式 entry.path 指向用户原文件
    // （在库目录之外），移除来源条目时绝不删用户原文件。
    if (_isInternalCopy(entry.path)) {
      await deleteFiles(entry.path);
    }
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
      // 存在性判定认归一后的本机路径（内部副本按文件名重挂），而非可能来自别机
      // 的存储 path——否则跨机导入的同名库虽已落地却被判缺失静默跳过（TODO-1171）。
      final String resolved =
          resolveInternalPath(entry.path, _databaseDirectory.path);
      if (await File(resolved).exists()) {
        validConfigs.add(_configFor(entry));
      } else {
        debugPrint('[fushi-audio] DB missing, skipping: $resolved'
            '${resolved == entry.path ? '' : ' (stored: ${entry.path})'}');
      }
    }
    if (validConfigs.isNotEmpty) {
      await TtsChannel.instance.setLocalAudioDbs(validConfigs);
    }
  }
}
