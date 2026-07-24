/// 用户纠错记忆缓存（刮削流水线的「别名缓存」）。
///
/// 用户手动纠正过一次匹配后，把「目录名/标题 key → (来源, 条目 id)」
/// 记住，下次重刮同一目录直接命中，不再走匹配打分。
///
/// 存储：注入目录下的 `scraper_alias_cache.json`；原子写
/// （先写 `.tmp` 再 rename）；文件缺失/损坏时当空缓存重建。
library;

import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/title_normalizer.dart';

/// 缓存文件名（固定，落在注入的存储目录下）。
const String _kCacheFileName = 'scraper_alias_cache.json';

/// 缓存文件格式版本。
const int _kCacheFormatVersion = 1;

/// 用户纠错别名缓存。
class AliasCache {
  /// [directory]：缓存文件所在目录（调用方保证可写；不存在会自动创建）。
  AliasCache(Directory directory)
      : _file = File('${directory.path}${Platform.pathSeparator}'
            '$_kCacheFileName');

  final File _file;

  /// 内存态：归一化 key → (来源, 条目 id)。null 表示尚未从盘加载。
  Map<String, (ScrapeSource, String)>? _entries;

  /// 记住一条纠错：key 先经 [TitleNormalizer.normalize] 归一化。
  Future<void> put(
    String dirOrTitleKey,
    ScrapeSource source,
    String entryId,
  ) async {
    final Map<String, (ScrapeSource, String)> entries = await _load();
    entries[TitleNormalizer.normalize(dirOrTitleKey)] = (source, entryId);
    await _persist(entries);
  }

  /// 查询纠错记录；无记录返回 null。
  Future<(ScrapeSource, String)?> get(String dirOrTitleKey) async {
    final Map<String, (ScrapeSource, String)> entries = await _load();
    return entries[TitleNormalizer.normalize(dirOrTitleKey)];
  }

  /// 懒加载：文件缺失/损坏一律当空缓存（下次 put 时重建）。
  Future<Map<String, (ScrapeSource, String)>> _load() async {
    final Map<String, (ScrapeSource, String)>? cached = _entries;
    if (cached != null) {
      return cached;
    }
    final Map<String, (ScrapeSource, String)> entries =
        <String, (ScrapeSource, String)>{};
    try {
      if (await _file.exists()) {
        final Object? decoded = json.decode(await _file.readAsString());
        if (decoded is Map<String, Object?> &&
            decoded['v'] == _kCacheFormatVersion &&
            decoded['entries'] is Map<String, Object?>) {
          final Map<String, Object?> rawEntries =
              decoded['entries']! as Map<String, Object?>;
          for (final MapEntry<String, Object?> e in rawEntries.entries) {
            final Object? value = e.value;
            if (value is! Map<String, Object?>) {
              continue;
            }
            final Object? sourceName = value['source'];
            final Object? entryId = value['entryId'];
            final ScrapeSource? source = sourceName is String
                ? ScrapeSource.values.asNameMap()[sourceName]
                : null;
            if (source != null && entryId is String && entryId.isNotEmpty) {
              entries[e.key] = (source, entryId);
            }
          }
        }
      }
    } on FormatException {
      // 损坏 JSON：当空重建。
    } on IOException {
      // 读失败：当空重建。
    }
    _entries = entries;
    return entries;
  }

  /// 原子落盘：先写同目录 `.tmp` 再 rename 覆盖，避免写一半留下坏文件。
  Future<void> _persist(
    Map<String, (ScrapeSource, String)> entries,
  ) async {
    final Map<String, Object?> payload = <String, Object?>{
      'v': _kCacheFormatVersion,
      'entries': <String, Object?>{
        for (final MapEntry<String, (ScrapeSource, String)> e
            in entries.entries)
          e.key: <String, String>{
            'source': e.value.$1.name,
            'entryId': e.value.$2,
          },
      },
    };
    final File tmp = File('${_file.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(json.encode(payload), flush: true);
    // Dart 的 rename 在各平台均覆盖已存在目标（Windows 走 ReplaceFile 语义）。
    await tmp.rename(_file.path);
  }
}
