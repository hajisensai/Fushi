/// 有声书素材库的 IO 层：把用户指定的目录扫成 [AudiobookMaterialIndex]。
///
/// 纯分类/配对规则住在 `audiobook_material_library.dart`（无 IO、全可单测），
/// 本层只负责「读偏好 → 递归列目录 → 建索引 → 缓存」。
///
/// 扫描结果**缓存在内存**：一次下载完成要查一次索引，重扫上千个文件不划算。
/// 目录内容变了由用户主动 [refresh]（设置页改目录时自动 refresh）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';

import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';
import 'package:fushi/src/media/audiobook/text_to_epub.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_plan.dart';

/// 正文素材扩展名：EPUB + 所有可转文本格式（引用既有真相源，不自造副本）。
Set<String> audiobookMaterialContentExtensions() => <String>{
  '.epub',
  for (final String ext in TextToEpub.supportedExtensions) '.$ext',
};

/// 单次扫描的产物与统计（统计供设置页显示「认得 N 部作品」）。
class AudiobookMaterialScan {
  const AudiobookMaterialScan({
    required this.index,
    required this.scannedFileCount,
    required this.missingDirs,
  });

  const AudiobookMaterialScan.empty()
    : index = const AudiobookMaterialIndex.empty(),
      scannedFileCount = 0,
      missingDirs = const <String>[];

  final AudiobookMaterialIndex index;
  final int scannedFileCount;

  /// 配置了但当前不存在的目录（U 盘拔了/路径改名），供设置页如实提示。
  final List<String> missingDirs;
}

/// 素材库读端口。偏好读写由调用方注入，避免本层依赖 AppModel。
typedef AudiobookMaterialDirsReader = List<String> Function();

class AudiobookMaterialService {
  AudiobookMaterialService({required AudiobookMaterialDirsReader readDirs})
    : _readDirs = readDirs;

  final AudiobookMaterialDirsReader _readDirs;
  AudiobookMaterialScan? _cached;

  /// 当前索引；首次调用或 [refresh] 后重扫，其余走缓存。
  Future<AudiobookMaterialScan> scan() async =>
      _cached ??= await _rescan(_readDirs());

  /// 丢弃缓存并立即重扫。
  Future<AudiobookMaterialScan> refresh() async {
    _cached = null;
    return scan();
  }

  /// 仅丢缓存（下次用时才扫）。
  void invalidate() => _cached = null;

  Future<AudiobookMaterialScan> _rescan(List<String> dirs) async {
    if (dirs.isEmpty) return const AudiobookMaterialScan.empty();
    final List<String> files = <String>[];
    final List<String> missing = <String>[];
    for (final String dir in dirs) {
      final Directory handle = Directory(dir);
      if (!handle.existsSync()) {
        missing.add(dir);
        continue;
      }
      // 素材库可能上千个文件；只收文件名，不读内容。
      await for (final FileSystemEntity entity in handle.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) files.add(entity.path);
      }
    }
    return AudiobookMaterialScan(
      index: indexAudiobookMaterials(
        files,
        subtitleExtensions: kDiscoverySubtitleExtensions,
        contentExtensions: audiobookMaterialContentExtensions(),
      ),
      scannedFileCount: files.length,
      missingDirs: missing,
    );
  }
}

/// 偏好值（JSON 数组字符串）↔ 目录列表。坏值一律当空库，不让一条脏偏好把
/// 整个功能变成启动崩溃。
List<String> decodeAudiobookMaterialDirs(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return <String>[
      for (final Object? item in decoded)
        if (item is String && item.trim().isNotEmpty) item,
    ];
  } on FormatException {
    return const <String>[];
  }
}

String encodeAudiobookMaterialDirs(List<String> dirs) => jsonEncode(dirs);

/// 给一部作品配素材，并按「音频 + 已配到的素材」产出可执行的导入计划。
///
/// 返回 null 表示配不齐——**正文缺失时不返回计划**：本仓能用字幕合成正文
/// （`CuesToEpub`），但那样得到的"正文"混着版权页与解说、没有排版和振假名，
/// 不能在用户不知情的情况下当原书入库。缺正文时交由 UI 让用户确认。
AlignAudiobookPlan? planAudiobookFromMaterials({
  required List<String> audioPaths,
  required AudiobookMaterialMatch match,
}) {
  if (audioPaths.isEmpty) return null;
  final String? subtitle = match.subtitlePath;
  final String? content = match.contentPath;
  if (subtitle == null || content == null) return null;
  final List<String> sorted = List<String>.of(audioPaths)..sort();
  return AlignAudiobookPlan(
    contentPath: content,
    subtitlePath: subtitle,
    audioPaths: sorted,
  );
}

/// 音频文件名里的作品身份键（下载任务没记 externalId 时的兜底）。
///
/// CoreAudio 目录 4223 条的 `my_filename` / `original_filename` **全部**含自身
/// 主键，所以对任何来路的已有音频都管用，不限于本 app 下载的。
String? audiobookKeyFromAudioPath(String path) => audiobookMaterialKeyOf(path);

/// 音频扩展名判据（复用有声书存储的单一真相）。
bool isAudiobookMaterialAudio(String path) =>
    AudiobookStorage.isAudioFile(path);
