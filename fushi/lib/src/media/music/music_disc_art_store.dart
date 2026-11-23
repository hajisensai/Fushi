/// 盘面图识别的落盘缓存（BUG-5311：曲库唱片每次冷启动都要等一会才出来）。
///
/// [MusicDiscArtIndex] 按内容判扫图、[MusicDiscFaceGeometryCache] 量盘面几何都要
/// 引擎解码图片，是曲库首屏出唱片前最慢的两步；结果原先只在进程里，每次启动重来。
/// 这里把两类结果按**图片文件**（路径 + 大小 + 修改时间）记进 app 缓存目录下的一份
/// JSON：文件没变就直接用，变了（替换 / 重压）才重新解码。
///
/// 只存从本地文件推导出、随时可重算的结果：放 app 缓存目录（存储页清缓存可删，
/// 不进备份 / 同步，不升数据库 schema）。列目录不缓存——它便宜，且是「哪张是盘面图」
/// 的真相（文件增删立即生效）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 一个图片文件的身份：大小 + 修改时间（毫秒）。两者都没变视作同一份内容。
typedef MusicDiscArtFileStamp = ({int size, int modifiedMs});

/// 缓存文件格式版本：判据 / 几何算法改了就加一，旧缓存整份作废。
const int kMusicDiscArtStoreVersion = 1;

/// 盘面图识别结果的落盘缓存（进程内单例；读写都在第一次用时懒加载）。
class MusicDiscArtStore {
  MusicDiscArtStore._();

  static final MusicDiscArtStore instance = MusicDiscArtStore._();

  /// 缓存文件位置；解析不了（单测没有 path_provider）为 null，只在内存里缓存。
  @visibleForTesting
  Future<File?> Function() fileResolver = _defaultFile;

  static Future<File?> _defaultFile() async {
    try {
      final Directory root = await AppPaths.appCacheRootDirectory();
      return File(p.join(root.path, 'music', 'disc_art_cache.json'));
    } on Object {
      return null;
    }
  }

  /// 按内容判盘面的结论：图片路径 → (文件身份, 是不是盘面)。
  final Map<String, ({MusicDiscArtFileStamp stamp, bool isFace})> _faces =
      <String, ({MusicDiscArtFileStamp stamp, bool isFace})>{};

  /// 盘面几何：图片路径 → (文件身份, [cx, cy, rx, ry, hub])。
  final Map<String, ({MusicDiscArtFileStamp stamp, List<double> geometry})>
  _geometry =
      <String, ({MusicDiscArtFileStamp stamp, List<double> geometry})>{};

  Future<void>? _loading;
  File? _file;
  bool _dirty = false;
  Future<void>? _saving;

  /// 读入缓存文件（只读一次；读不了 / 格式不对当空缓存）。
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final File? file = await fileResolver();
    _file = file;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final Object? json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?>) return;
      if (json['v'] != kMusicDiscArtStoreVersion) return;
      final Object? faces = json['faces'];
      if (faces is Map<String, Object?>) {
        for (final MapEntry<String, Object?> e in faces.entries) {
          final Object? v = e.value;
          if (v is! List || v.length != 3) continue;
          final Object? size = v[0];
          final Object? modified = v[1];
          final Object? isFace = v[2];
          if (size is! int || modified is! int || isFace is! int) continue;
          _faces.putIfAbsent(
            e.key,
            () => (
              stamp: (size: size, modifiedMs: modified),
              isFace: isFace == 1,
            ),
          );
        }
      }
      final Object? geometry = json['geometry'];
      if (geometry is Map<String, Object?>) {
        for (final MapEntry<String, Object?> e in geometry.entries) {
          final Object? v = e.value;
          if (v is! List || v.length != 7) continue;
          final Object? size = v[0];
          final Object? modified = v[1];
          if (size is! int || modified is! int) continue;
          final List<double> g = <double>[
            for (final Object? x in v.skip(2))
              if (x is num) x.toDouble(),
          ];
          if (g.length != 5) continue;
          _geometry.putIfAbsent(
            e.key,
            () => (
              stamp: (size: size, modifiedMs: modified),
              geometry: List<double>.unmodifiable(g),
            ),
          );
        }
      }
    } on Object {
      // 损坏的缓存文件：当空缓存，下次保存时整份覆盖。
    }
  }

  /// [path] 按内容判过的结论；文件身份对不上（或没判过）为 null。需先 [ensureLoaded]。
  bool? faceVerdict(String path, MusicDiscArtFileStamp stamp) {
    final ({MusicDiscArtFileStamp stamp, bool isFace})? hit = _faces[path];
    return hit != null && hit.stamp == stamp ? hit.isFace : null;
  }

  /// 记下 [path] 按内容判的结论。
  void putFaceVerdict(String path, MusicDiscArtFileStamp stamp, bool isFace) {
    final ({MusicDiscArtFileStamp stamp, bool isFace})? old = _faces[path];
    if (old != null && old.stamp == stamp && old.isFace == isFace) return;
    _faces[path] = (stamp: stamp, isFace: isFace);
    _markDirty();
  }

  /// [path] 量过的几何 `[cx, cy, rx, ry, hub]`；文件身份对不上（或没量过）为 null。
  /// 需先 [ensureLoaded]。
  List<double>? geometry(String path, MusicDiscArtFileStamp stamp) {
    final ({MusicDiscArtFileStamp stamp, List<double> geometry})? hit =
        _geometry[path];
    return hit != null && hit.stamp == stamp ? hit.geometry : null;
  }

  /// 记下 [path] 量出的几何。
  void putGeometry(
    String path,
    MusicDiscArtFileStamp stamp,
    List<double> geometry,
  ) {
    final ({MusicDiscArtFileStamp stamp, List<double> geometry})? old =
        _geometry[path];
    if (old != null &&
        old.stamp == stamp &&
        listEquals(old.geometry, geometry)) {
      return;
    }
    _geometry[path] = (
      stamp: stamp,
      geometry: List<double>.unmodifiable(geometry),
    );
    _markDirty();
  }

  /// 去掉按内容判的结论里 [stale] 为真的条目（重新列过目录、已不再是候选的图）。
  void removeFaceVerdictsWhere(bool Function(String path) stale) {
    final int before = _faces.length;
    _faces.removeWhere((String path, _) => stale(path));
    if (_faces.length != before) _markDirty();
  }

  void _markDirty() {
    _dirty = true;
    _saving ??= _drain();
  }

  /// 有改动就写；写的过程中又有改动，写完接着再写一次（合并成串行的几次整份写）。
  Future<void> _drain() async {
    try {
      await ensureLoaded();
      while (_dirty) {
        _dirty = false;
        await _write();
      }
    } finally {
      _saving = null;
    }
  }

  /// 等进行中的保存写完（测试与退出前用）。
  Future<void> flush() async {
    while (_saving != null) {
      await _saving;
    }
  }

  Future<void> _write() async {
    final File? file = _file;
    if (file == null) return;
    final String text = jsonEncode(<String, Object?>{
      'v': kMusicDiscArtStoreVersion,
      'faces': <String, Object?>{
        for (final MapEntry<
              String,
              ({MusicDiscArtFileStamp stamp, bool isFace})
            >
            e
            in _faces.entries)
          e.key: <int>[
            e.value.stamp.size,
            e.value.stamp.modifiedMs,
            if (e.value.isFace) 1 else 0,
          ],
      },
      'geometry': <String, Object?>{
        for (final MapEntry<
              String,
              ({MusicDiscArtFileStamp stamp, List<double> geometry})
            >
            e
            in _geometry.entries)
          e.key: <num>[
            e.value.stamp.size,
            e.value.stamp.modifiedMs,
            ...e.value.geometry,
          ],
      },
    });
    try {
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
    } on FileSystemException {
      // 缓存目录写不了（只读盘 / 被清理中）：只丢掉落盘，内存里的结果照用。
    }
  }

  /// 清空内存并按 [fileResolver] 重新读（测试用：模拟冷启动）。
  @visibleForTesting
  Future<void> debugReset() async {
    await flush();
    _faces.clear();
    _geometry.clear();
    _loading = null;
    _file = null;
    _dirty = false;
  }
}

/// 读 [path] 的文件身份；不存在 / 读不了为 null。同步版，在后台 isolate 里用。
MusicDiscArtFileStamp? musicDiscArtFileStampSync(String path) {
  try {
    final FileStat st = File(path).statSync();
    if (st.type != FileSystemEntityType.file) return null;
    return (size: st.size, modifiedMs: st.modified.millisecondsSinceEpoch);
  } on Object {
    return null;
  }
}

/// 读 [path] 的文件身份；不存在 / 读不了为 null。
Future<MusicDiscArtFileStamp?> musicDiscArtFileStamp(String path) async {
  try {
    final FileStat st = await File(path).stat();
    if (st.type != FileSystemEntityType.file) return null;
    return (size: st.size, modifiedMs: st.modified.millisecondsSinceEpoch);
  } on Object {
    return null;
  }
}
