/// 歌词动画样式的用户素材（folia 的群唱头像包 / 表情包、凝彩画布图层、莫奈人像）：用户挑的图片
/// 复制进 app 数据目录 `visualizer_assets/<样式>/<素材包>/`，样式按包列出来用。原文件不长期引用
/// （安卓 file_picker 给的是缓存副本）。素材是设备本地数据，不进备份 / 同步。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart'
    show lyricVisualizerIsValidPackName;

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
    return added;
  }

  /// 删一张图（只认包目录里的文件，防误删别处）。
  Future<void> delete(String style, String pack, File file) async {
    final Directory dir = packDir(style, pack);
    if (!p.isWithin(dir.path, file.path)) {
      throw ArgumentError.value(file.path, 'file', 'not inside $pack');
    }
    if (file.existsSync()) await file.delete();
  }

  /// 删整个包。
  Future<void> deletePack(String style, String pack) async {
    final Directory dir = packDir(style, pack);
    if (dir.existsSync()) await dir.delete(recursive: true);
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
