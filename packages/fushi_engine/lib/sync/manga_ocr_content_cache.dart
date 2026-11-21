/// 互联 host 代跑漫画 OCR 的**按页图内容**键控的结果缓存。
///
/// 卷目录里的逐页断点缓存（`vol_<slug>/manga_ocr_out/_pages/<引擎签名>/`）按「页名 +
/// 大小 + 修改时间」认页，只能省同一卷、同一卷名的重复识别，页图也必须先传上来。
/// 本缓存按「引擎签名 + 页图 SHA-256」存一页的识别结果（manga.json 的一页，去掉
/// `url`），与卷名、页名、设备无关：对端先报页图哈希，命中的页**不必上传**，换设备、
/// 重导同一卷、改了卷名都能命中。
///
/// 落在任务根目录下的 [kMangaOcrContentCacheDirName]，不在任何卷目录里：取消任务删
/// 页图、TTL 清卷目录都碰不到它（孤儿清扫按名字跳过）。条目按最近使用（文件修改时间，
/// 命中时刷新）淘汰，总数超过 [MangaOcrContentCache.maxEntries] 就删最旧的。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/utils/misc/atomic_text_file.dart'
    show readAtomicallyWrittenTextFile, writeTextFileAtomically;

/// 任务根目录下内容缓存的目录名（以 `_` 开头，与 `vol_` / `job_` 卷目录不重名）。
const String kMangaOcrContentCacheDirName = '_content_cache';

/// 条目格式版本：改了条目结构就加一，旧条目读到当 miss。
const int _kEntryVersion = 1;

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// [value] 是不是 64 位小写十六进制 SHA-256。
bool isMangaOcrContentSha256(String value) => _sha256Hex.hasMatch(value);

/// 一页的缓存结果。
class MangaOcrContentCacheEntry {
  const MangaOcrContentCacheEntry({required this.page, this.ocr});

  /// manga.json 里的一页（`width` / `height` / `blocks`…），不含 `url`。
  final Map<String, Object?> page;

  /// 产出这一页的那份 manga.json 的 `ocr` 元数据（引擎 / 签名 / schema）；产物没带
  /// 时为 null。
  final Map<String, Object?>? ocr;
}

class MangaOcrContentCache {
  MangaOcrContentCache({required this.root, this.maxEntries = 20000});

  /// 缓存根目录（`<任务根>/_content_cache`）。
  final Directory root;

  /// 条目上限（一页约几 KB；两万页约一两百 MB）。
  final int maxEntries;

  /// 签名要能直接当一层目录名（与卷目录下 `_pages/<签名>` 同一套取值）；带路径
  /// 分隔符、`..`、盘符冒号或空的一律不缓存。
  static bool usableSignature(String signature) =>
      signature.isNotEmpty &&
      signature.length <= 200 &&
      signature != '.' &&
      signature != '..' &&
      !signature.contains('/') &&
      !signature.contains('\\') &&
      !signature.contains(':');

  File? _fileFor(String signature, String sha256) {
    if (!usableSignature(signature) || !isMangaOcrContentSha256(sha256)) {
      return null;
    }
    return File(p.join(root.path, signature, '$sha256.json'));
  }

  /// 取 [signature] 下内容哈希为 [sha256] 的页；没有 / 损坏 / 版本不对返回 null。
  /// 命中时把条目的修改时间刷成现在（最近使用）。
  Future<MangaOcrContentCacheEntry?> read(
    String signature,
    String sha256,
  ) async {
    final File? file = _fileFor(signature, sha256);
    if (file == null || !file.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(
        await readAtomicallyWrittenTextFile(file),
      );
      if (decoded is! Map<String, dynamic> ||
          decoded['v'] != _kEntryVersion ||
          decoded['signature'] != signature ||
          decoded['sha256'] != sha256) {
        return null;
      }
      final Object? page = decoded['page'];
      if (page is! Map<String, dynamic> || page['blocks'] is! List) {
        return null;
      }
      final Object? ocr = decoded['ocr'];
      try {
        await file.setLastModified(DateTime.now());
      } on FileSystemException {
        // 刷不了最近使用只影响淘汰顺序。
      }
      return MangaOcrContentCacheEntry(
        page: Map<String, Object?>.of(page)..remove('url'),
        ocr: ocr is Map<String, dynamic> ? Map<String, Object?>.of(ocr) : null,
      );
    } on Object catch (error, stack) {
      // 损坏条目当 miss，这一页照常上传、识别后覆盖写。
      engineLog.log('MangaOcrContentCache.read(${file.path})', error, stack);
      return null;
    }
  }

  /// 记下一页的结果（[page] 里的 `url` 不入缓存）。签名 / 哈希不合规时什么也不做。
  Future<void> write(
    String signature,
    String sha256,
    Map<String, Object?> page, {
    Map<String, Object?>? ocr,
  }) async {
    final File? file = _fileFor(signature, sha256);
    if (file == null) return;
    await file.parent.create(recursive: true);
    await writeTextFileAtomically(
      file,
      jsonEncode(<String, Object?>{
        'v': _kEntryVersion,
        'signature': signature,
        'sha256': sha256,
        'page': Map<String, Object?>.of(page)..remove('url'),
        if (ocr != null) 'ocr': ocr,
      }),
    );
  }

  /// 条目超过 [maxEntries] 时按修改时间删最旧的，删到上限的九成（不在每次写后
  /// 都删一两个）。尽力而为：IO 失败只记日志。
  Future<void> prune() async {
    try {
      if (!root.existsSync()) return;
      final List<(File, DateTime)> entries = <(File, DateTime)>[];
      await for (final FileSystemEntity entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final FileStat stat = await entity.stat();
        entries.add((entity, stat.modified));
      }
      if (entries.length <= maxEntries) return;
      entries.sort(
        ((File, DateTime) a, (File, DateTime) b) => a.$2.compareTo(b.$2),
      );
      final int keep = (maxEntries * 9) ~/ 10;
      for (int i = 0; i < entries.length - keep; i++) {
        try {
          await entries[i].$1.delete();
        } on FileSystemException {
          // 删不掉的下次再删。
        }
      }
    } on Object catch (error, stack) {
      engineLog.log('MangaOcrContentCache.prune(${root.path})', error, stack);
    }
  }
}
