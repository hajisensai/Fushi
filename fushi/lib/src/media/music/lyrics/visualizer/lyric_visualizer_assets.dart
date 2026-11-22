/// 歌词动画样式的用户素材（folia 的群唱头像包 / 表情包、凝彩画布图层、莫奈人像）：用户挑的图片
/// 复制进 app 数据目录 `visualizer_assets/<样式>/<素材包>/`，样式按包列出来用。原文件不长期引用
/// （安卓 file_picker 给的是缓存副本）。素材是设备本地数据，不进备份 / 同步。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart'
    show LyricVisualizerAssetPlacement, lyricVisualizerIsValidPackName;

/// 包目录里存逐张摆放的文件名（不是图片扩展名，[LyricVisualizerAssetStore.list] 不会列出它）。
const String kLyricVisualizerPlacementFile = 'placement.json';

/// 认的图片扩展名（Flutter 能解的）。
const Set<String> kLyricVisualizerAssetExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.gif',
  '.bmp',
};

/// 素材库。[root] 是 `visualizer_assets` 目录；app 里用 [LyricVisualizerAssetStore.open]。
class LyricVisualizerAssetStore {
  LyricVisualizerAssetStore(this.root);

  final Directory root;

  static LyricVisualizerAssetStore? _shared;

  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  /// 任何素材包内容变了（加 / 删图、改摆放、删包）就加一：正在画的样式（凝彩图层）听它重读，
  /// 不用等换包或换歌。
  static ValueListenable<int> get changes => _changes;

  static void _changed() => _changes.value++;

  /// app 数据目录下的共享实例。
  static Future<LyricVisualizerAssetStore> open() async {
    final LyricVisualizerAssetStore? s = _shared;
    if (s != null) return s;
    final Directory support = await getApplicationSupportDirectory();
    return _shared = LyricVisualizerAssetStore(
      Directory(p.join(support.path, 'visualizer_assets')),
    );
  }

  static void _checkName(String name, String what) {
    if (!lyricVisualizerIsValidPackName(name)) {
      throw ArgumentError.value(name, what, 'must match [A-Za-z0-9_-]{1,40}');
    }
  }

  Directory packDir(String style, String pack) {
    _checkName(style, 'style');
    _checkName(pack, 'pack');
    return Directory(p.join(root.path, style, pack));
  }

  /// 某样式下已有的素材包名（按名字排序）。
  Future<List<String>> listPacks(String style) async {
    _checkName(style, 'style');
    final Directory dir = Directory(p.join(root.path, style));
    if (!dir.existsSync()) return const <String>[];
    final List<String> out = <String>[
      await for (final FileSystemEntity e in dir.list())
        if (e is Directory &&
            lyricVisualizerIsValidPackName(p.basename(e.path)))
          p.basename(e.path),
    ]..sort();
    return out;
  }

  /// 包里的图片（按文件名排序；导入时文件名带序号前缀，即导入顺序）。
  Future<List<File>> list(String style, String pack) async {
    final Directory dir = packDir(style, pack);
    if (!dir.existsSync()) return const <File>[];
    final List<File> out =
        <File>[
          await for (final FileSystemEntity e in dir.list())
            if (e is File &&
                kLyricVisualizerAssetExtensions.contains(
                  p.extension(e.path).toLowerCase(),
                ))
              e,
        ]..sort(
          (File a, File b) => p.basename(a.path).compareTo(p.basename(b.path)),
        );
    return out;
  }

  /// 把 [sources] 复制进包（不认识的扩展名跳过；超出 [maxFiles] 的丢掉）。返回新复制的文件。
  Future<List<File>> importFiles(
    String style,
    String pack,
    List<String> sources, {
    int maxFiles = 64,
  }) async {
    final Directory dir = packDir(style, pack);
    await dir.create(recursive: true);
    final List<File> existing = await list(style, pack);
    int next = existing.length;
    int seq = 0;
    for (final File f in existing) {
      final int? n = int.tryParse(p.basename(f.path).split('_').first);
      if (n != null && n >= seq) seq = n + 1;
    }
    final List<File> added = <File>[];
    for (final String src in sources) {
      if (next >= maxFiles) break;
      final String ext = p.extension(src).toLowerCase();
      if (!kLyricVisualizerAssetExtensions.contains(ext)) continue;
      final File source = File(src);
      if (!source.existsSync()) continue;
      final String base = p
          .basenameWithoutExtension(src)
          .replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
      final String name =
          '${seq.toString().padLeft(4, '0')}_${base.isEmpty ? 'image' : base}$ext';
      added.add(await source.copy(p.join(dir.path, name)));
      seq++;
      next++;
    }
    if (added.isNotEmpty) _changed();
    return added;
  }

  /// 删一张图（只认包目录里的文件，防误删别处）；它的摆放记录一起删。
  Future<void> delete(String style, String pack, File file) async {
    final Directory dir = packDir(style, pack);
    if (!p.isWithin(dir.path, file.path)) {
      throw ArgumentError.value(file.path, 'file', 'not inside $pack');
    }
    if (file.existsSync()) await file.delete();
    final Map<String, Object?> raw = await _readPlacements(dir);
    if (raw.remove(p.basename(file.path)) != null) {
      await _writePlacements(dir, raw);
    }
    _changed();
  }

  Future<Map<String, Object?>> _readPlacements(Directory dir) async {
    final File f = File(p.join(dir.path, kLyricVisualizerPlacementFile));
    if (!f.existsSync()) return <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      return decoded is Map
          ? <String, Object?>{
              for (final MapEntry<Object?, Object?> e in decoded.entries)
                if (e.key is String) e.key! as String: e.value,
            }
          : <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    } on FileSystemException {
      return <String, Object?>{};
    }
  }

  Future<void> _writePlacements(Directory dir, Map<String, Object?> raw) async {
    final File f = File(p.join(dir.path, kLyricVisualizerPlacementFile));
    if (raw.isEmpty) {
      if (f.existsSync()) await f.delete();
      return;
    }
    await dir.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(raw), flush: true);
    await tmp.rename(f.path);
  }

  /// 包里每张图的摆放（键是文件名）；没设过的图不在表里，用 [fallback]。坏文件当空表。
  Future<Map<String, LyricVisualizerAssetPlacement>> loadPlacements(
    String style,
    String pack, {
    LyricVisualizerAssetPlacement fallback =
        LyricVisualizerAssetPlacement.defaults,
  }) async {
    final Map<String, Object?> raw = await _readPlacements(
      packDir(style, pack),
    );
    return <String, LyricVisualizerAssetPlacement>{
      for (final MapEntry<String, Object?> e in raw.entries)
        e.key: LyricVisualizerAssetPlacement.fromJson(
          e.value,
          fallback: fallback,
        ),
    };
  }

  /// 存一张图的摆放（[file] 必须在包目录里）。
  Future<void> savePlacement(
    String style,
    String pack,
    File file,
    LyricVisualizerAssetPlacement placement,
  ) async {
    final Directory dir = packDir(style, pack);
    if (!p.isWithin(dir.path, file.path)) {
      throw ArgumentError.value(file.path, 'file', 'not inside $pack');
    }
    final Map<String, Object?> raw = await _readPlacements(dir);
    raw[p.basename(file.path)] = placement.toJson();
    await _writePlacements(dir, raw);
    _changed();
  }

  /// 删整个包。
  Future<void> deletePack(String style, String pack) async {
    final Directory dir = packDir(style, pack);
    if (dir.existsSync()) await dir.delete(recursive: true);
    _changed();
  }
}

/// 让用户挑图片（多选）。取消返回空表。
Future<List<String>> pickLyricVisualizerAssetFiles() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    allowMultiple: true,
  );
  if (result == null) return const <String>[];
  return <String>[
    for (final PlatformFile f in result.files)
      if (f.path != null) f.path!,
  ];
}
