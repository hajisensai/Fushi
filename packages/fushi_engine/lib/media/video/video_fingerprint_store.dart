import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:meta/meta.dart';

/// 一条落盘的视频指纹：算的那一刻的文件状态 + 全文件 SHA-256。
final class _StoredFingerprint {
  const _StoredFingerprint({
    required this.size,
    required this.modifiedUs,
    required this.changedUs,
    required this.digest,
  });

  final int size;
  final int modifiedUs;
  final int changedUs;
  final String digest;

  bool matches(FileStat stat) =>
      stat.type == FileSystemEntityType.file &&
      stat.size == size &&
      stat.modified.microsecondsSinceEpoch == modifiedUs &&
      stat.changed.microsecondsSinceEpoch == changedUs;

  /// 日志里的一行：`{"p": 路径, "s", "m", "c", "h"}`。
  String toLine(String path) => jsonEncode(<String, Object>{
    'p': path,
    's': size,
    'm': modifiedUs,
    'c': changedUs,
    'h': digest,
  });

  static _StoredFingerprint? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? s = raw['s'];
    final Object? m = raw['m'];
    final Object? c = raw['c'];
    final Object? h = raw['h'];
    if (s is! int || m is! int || c is! int || h is! String) return null;
    if (!_digestPattern.hasMatch(h)) return null;
    return _StoredFingerprint(size: s, modifiedUs: m, changedUs: c, digest: h);
  }
}

final RegExp _digestPattern = RegExp(r'^[a-f0-9]{64}$');

/// 视频全文件指纹的落盘缓存（拍板台 left3657）：按绝对路径记「算的那一刻的文件状态
/// （大小 / 修改时间 / 状态变更时间）+ SHA-256」，状态完全一致才命中，文件一动就当
/// 没算过。互联 host 后台预热算过的指纹进程重启后还在，不必每次开机把整个视频库
/// 重读一遍；回跳时 host 能立刻答出指纹。
///
/// 存成文件而不进数据库：它只是可随时丢弃重算的缓存（坏了 / 删了只会让下次重算），
/// 不该进 schema 迁移链。
///
/// 落盘格式是**按键追加的日志**（JSON Lines，一行一条 `{"p": 路径, ...}`，后写的同键
/// 行覆盖先写的）：每次 [put] 只追加新条目那一行，同一时刻攒下的多条并成一次追加
/// （一次 flush）。HBK-AUDIT-009：此前每个 put 都把整张表重新编码、写临时文件、
/// flush、rename，首次预热 N 个文件累计要序列化 N(N+1)/2 条、写 N 次整表。日志里
/// 失效的旧行超过在用条目数（加 [_compactSlack]）时整份压实一次（临时文件 + rename），
/// 摊下来每条 put 写盘 O(1) 条记录。读时逐行回放，坏行（写到一半掉电的尾行）只丢
/// 那一行。旧版整表一个 JSON 对象的文件照样读得进来，下次写入时压实成新格式。
class VideoFingerprintStore {
  VideoFingerprintStore(this.file, {this.maxEntries = 50000})
    : assert(maxEntries > 0);

  final File file;

  /// 条目上限：超出时按写入先后淘汰最旧的（真实视频库远小于此）。
  final int maxEntries;

  /// 日志里的失效行比在用条目多出这么多以上才压实，免得小缓存频繁整份重写。
  static const int _compactSlack = 256;

  LinkedHashMap<String, _StoredFingerprint>? _entries;
  Future<LinkedHashMap<String, _StoredFingerprint>>? _loading;
  Future<void>? _saving;

  /// 还没落盘的条目行（按 put 先后）。
  final List<String> _pendingLines = <String>[];

  /// 磁盘上的日志现有多少行（含被后写行覆盖 / 已淘汰的失效行）。
  int _diskLines = 0;

  /// 下次写入要整份压实：磁盘内容不是本格式、坏了、或不以换行结尾，不能直接追加。
  bool _needsCompact = false;

  int _flushCount = 0;
  int _bytesWritten = 0;

  /// 落盘写入次数（每次追加或压实算一次，含 flush）。供测试量写放大。
  @visibleForTesting
  int get debugFlushCount => _flushCount;

  /// 累计写盘字节数（UTF-8）。供测试量写放大。
  @visibleForTesting
  int get debugBytesWritten => _bytesWritten;

  Future<LinkedHashMap<String, _StoredFingerprint>> _load() {
    final LinkedHashMap<String, _StoredFingerprint>? loaded = _entries;
    if (loaded != null) return Future.value(loaded);
    return _loading ??= () async {
      final LinkedHashMap<String, _StoredFingerprint> map =
          LinkedHashMap<String, _StoredFingerprint>();
      try {
        if (await file.exists()) {
          final String text = await file.readAsString();
          final List<String> lines = const LineSplitter().convert(text);
          _diskLines = lines.length;
          // 不以换行结尾（旧版整表格式 / 写到一半的尾行）时不能直接接着追加。
          if (text.isNotEmpty && !text.endsWith('\n')) _needsCompact = true;
          for (final String line in lines) {
            if (!_replayLine(map, line)) _needsCompact = true;
          }
        }
      } on Object catch (error, stack) {
        // 读不了：当空缓存，下次写入整份覆盖。
        engineLog.log('video.fingerprintStore.load', error, stack);
        map.clear();
        _needsCompact = true;
      }
      _entries = map;
      return map;
    }();
  }

  /// 回放日志里的一行；返回这一行是不是本格式的合法条目行。
  bool _replayLine(Map<String, _StoredFingerprint> map, String line) {
    if (line.trim().isEmpty) return true;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return false;
    }
    if (decoded is! Map) return false;
    final Object? path = decoded['p'];
    if (path is String) {
      final _StoredFingerprint? value = _StoredFingerprint.tryParse(decoded);
      if (value == null) return false;
      _insert(map, path, value);
      return true;
    }
    // 旧版格式：整张表是一个 `{路径: {s, m, c, h}}` 对象。
    for (final MapEntry<Object?, Object?> e in decoded.entries) {
      final Object? key = e.key;
      final _StoredFingerprint? value = _StoredFingerprint.tryParse(e.value);
      if (key is String && value != null) _insert(map, key, value);
    }
    return false;
  }

  void _insert(
    Map<String, _StoredFingerprint> map,
    String path,
    _StoredFingerprint value,
  ) {
    map.remove(path);
    map[path] = value;
    while (map.length > maxEntries) {
      map.remove(map.keys.first);
    }
  }

  /// [absolutePath] 当前状态为 [stat] 时记过的指纹；没记过或文件状态变了返回 null。
  Future<String?> lookup(String absolutePath, FileStat stat) async {
    final _StoredFingerprint? hit = (await _load())[absolutePath];
    return hit != null && hit.matches(stat) ? hit.digest : null;
  }

  /// 记下 [absolutePath] 在状态 [stat] 下的指纹 [digest]，并等它落盘。
  Future<void> put(String absolutePath, FileStat stat, String digest) async {
    if (!_digestPattern.hasMatch(digest)) return;
    final LinkedHashMap<String, _StoredFingerprint> map = await _load();
    final _StoredFingerprint value = _StoredFingerprint(
      size: stat.size,
      modifiedUs: stat.modified.microsecondsSinceEpoch,
      changedUs: stat.changed.microsecondsSinceEpoch,
      digest: digest,
    );
    _insert(map, absolutePath, value);
    _pendingLines.add(value.toLine(absolutePath));
    // 正在写的那一轮写完会接着把本条一起写掉（同一时刻只有一个写者）。
    await (_saving ??= _flush());
  }

  /// 把攒下的条目行写盘；写的期间又有新条目时接着再写一轮，同一时刻只有一个写者。
  Future<void> _flush() async {
    try {
      while (_pendingLines.isNotEmpty) {
        final LinkedHashMap<String, _StoredFingerprint> map = await _load();
        final List<String> batch = List<String>.of(_pendingLines);
        _pendingLines.clear();
        try {
          await file.parent.create(recursive: true);
          if (_needsCompact ||
              _diskLines + batch.length > 2 * map.length + _compactSlack) {
            await _compact(map);
          } else {
            final List<int> chunk = utf8.encode('${batch.join('\n')}\n');
            await file.writeAsBytes(chunk, mode: FileMode.append, flush: true);
            _bytesWritten += chunk.length;
            _flushCount++;
            _diskLines += batch.length;
          }
        } on Object catch (error, stack) {
          // 写不了只是少了落盘缓存（下次开机重算），不影响本次指纹结果。磁盘上的
          // 日志状态不明（可能追加了一半），下次整份压实。
          _needsCompact = true;
          engineLog.log('video.fingerprintStore.save', error, stack);
        }
      }
    } finally {
      _saving = null;
    }
  }

  /// 把在用条目整份写成新日志（临时文件 + rename），丢掉失效行。
  ///
  /// 快照在第一个 await 之前同步取好：写盘期间进来的 put 只改内存表、行进
  /// [_pendingLines]，由 [_flush] 下一轮追加，所以 [_diskLines] 只记快照里的行数。
  Future<void> _compact(Map<String, _StoredFingerprint> map) async {
    final StringBuffer out = StringBuffer();
    for (final MapEntry<String, _StoredFingerprint> e in map.entries) {
      out
        ..write(e.value.toLine(e.key))
        ..write('\n');
    }
    final int lines = map.length;
    final List<int> bytes = utf8.encode(out.toString());
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    _bytesWritten += bytes.length;
    _flushCount++;
    _diskLines = lines;
    _needsCompact = false;
  }
}
