import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 历史下载根的保留上限（超出丢最旧的）。历史根只用于「列表别把旧任务漏掉」，
/// 无限增长没有收益，只会让每次过滤多做无谓比较。
const int kMaxSaveRootHistory = 8;

/// 内置 libtorrent 引擎的下载根集合。
///
/// TODO-1961：下载根从硬编码 `<documents>/anime_downloads/content` 变成用户可配置
/// 之后，「当前根」和「历史根」必须活在**同一个**数据结构里。以前只有一个
/// `baseSavePath` 字段，`listTorrents` 拿 `<base>/<category>` 做全等过滤——用户一改
/// 目录，仍在跑的旧任务 savePath 还指着旧根，整批从下载页消失（服务还会按
/// `torrentMissingTimeout` 把它们判失败）。把「写入用哪个根」和「认哪些根」拆成两个
/// 概念，特殊情况就没有了。
///
/// 不变量：
/// - [active] 是**新任务**的落点：只有它参与 add / mkdir；
/// - [legacy] 是历史根（改目录前用过的、以及默认根）：**只**参与列表过滤，永不写入；
/// - [all] = active 在前的去重列表；一切路径比较走 `package:path`
///   （Windows 的大小写不敏感与 `/` `\` 混用由它负责，别自己写 `startsWith`）。
class TorrentSaveRoots {
  /// 规范化构造：normalize 全部路径，丢空串，legacy 去重且剔除与 [active] 相同的项。
  factory TorrentSaveRoots({
    required String active,
    Iterable<String> legacy = const <String>[],
  }) {
    final String normalizedActive = p.normalize(active.trim());
    final List<String> uniqueLegacy = <String>[];
    for (final String raw in legacy) {
      if (raw.trim().isEmpty) continue;
      final String normalized = p.normalize(raw.trim());
      if (p.equals(normalized, normalizedActive)) continue;
      if (uniqueLegacy.any((String kept) => p.equals(kept, normalized))) {
        continue;
      }
      uniqueLegacy.add(normalized);
      if (uniqueLegacy.length >= kMaxSaveRootHistory) break;
    }
    return TorrentSaveRoots._(
        normalizedActive, List<String>.unmodifiable(uniqueLegacy));
  }

  const TorrentSaveRoots._(this.active, this.legacy);

  /// 新任务落点（唯一的写入根）。
  final String active;

  /// 历史根（只读、只用于过滤）。
  final List<String> legacy;

  /// active 在前的全部根。
  List<String> get all => <String>[active, ...legacy];

  /// 新任务的分类目录（add / mkdir 用这个，永远基于 [active]）。
  String categoryPathFor(String category) => p.join(active, category);

  /// 某个种子的 `savePath` 是否属于本 app 的 [category] 目录 —— **任意**根下都算。
  ///
  /// 除了 `<root>/<category>` 全等，还接受它的子目录：用户把下好的内容整理进分类
  /// 目录下的子文件夹（TODO-1961 ②，配合引擎侧 move_storage 才不掐做种）之后，
  /// savePath 仍落在分类目录内，任务不该从下载页蒸发。
  bool ownsCategoryPath(String savePath, String category) {
    final String normalized = p.normalize(savePath);
    for (final String root in all) {
      final String categoryPath = p.normalize(p.join(root, category));
      if (p.equals(normalized, categoryPath)) return true;
      if (p.isWithin(categoryPath, normalized)) return true;
    }
    return false;
  }

  /// 换活动根：旧的活动根自动降级成历史根（永不丢），新根等于旧根时是空操作。
  TorrentSaveRoots withActive(String newActive) => TorrentSaveRoots(
        active: newActive,
        legacy: <String>[active, ...legacy],
      );

  @override
  bool operator ==(Object other) {
    if (other is! TorrentSaveRoots) return false;
    if (other.active != active || other.legacy.length != legacy.length) {
      return false;
    }
    for (int i = 0; i < legacy.length; i++) {
      if (other.legacy[i] != legacy[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(active, Object.hashAll(legacy));

  @override
  String toString() =>
      'TorrentSaveRoots(active: $active, legacy: ${legacy.join(', ')})';
}

/// 从「默认根 + 用户配置根 + 历史根」解析出本次会话该用的根集合。
///
/// [configuredRoot] 空串 = 用户没设过 → 活动根就是 [defaultRoot]，行为与 TODO-1961
/// 之前逐字节一致。[defaultRoot] **总是**进历史根：默认根下的旧任务在任何配置下
/// 都必须仍然可见。
TorrentSaveRoots resolveTorrentSaveRoots({
  required String defaultRoot,
  required String configuredRoot,
  Iterable<String> history = const <String>[],
}) {
  final String configured = configuredRoot.trim();
  return TorrentSaveRoots(
    active: configured.isEmpty ? defaultRoot : configured,
    legacy: <String>[defaultRoot, ...history],
  );
}

/// 目录不可用的原因（UI 据此选文案；null = 可用）。
enum DownloadSaveRootIssue {
  /// 空串或相对路径 —— 下载根必须是绝对路径。
  notAbsolute,

  /// 目录不存在且创建失败（盘符不存在 / 权限不足 / 只读介质）。
  createFailed,

  /// 目录存在但写不进去。
  notWritable,
}

/// 真实探测一个候选下载根是否可用：不存在就建，建好再写一个探针文件确认真能写。
/// 返回 null 表示可用。**不静默**——调用方必须把非 null 结果反馈给用户。
Future<DownloadSaveRootIssue?> checkDownloadSaveRoot(String path) async {
  final String trimmed = path.trim();
  if (trimmed.isEmpty || !p.isAbsolute(trimmed)) {
    return DownloadSaveRootIssue.notAbsolute;
  }
  final Directory dir = Directory(trimmed);
  try {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  } on FileSystemException {
    return DownloadSaveRootIssue.createFailed;
  }
  final File probe = File(p.join(trimmed, '.hibiki_write_probe'));
  try {
    await probe.writeAsString('hibiki', flush: true);
  } on FileSystemException {
    return DownloadSaveRootIssue.notWritable;
  } finally {
    try {
      if (probe.existsSync()) probe.deleteSync();
    } on FileSystemException {
      // 探针删不掉不影响判定（下次覆写即可）。
    }
  }
  return null;
}

/// 历史根 JSON 解码（畸形/非法一律当空，绝不抛）。
List<String> decodeSaveRootHistory(String raw) {
  if (raw.trim().isEmpty) return const <String>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return <String>[
      for (final Object? entry in decoded)
        if (entry is String && entry.trim().isNotEmpty) entry.trim(),
    ];
  } on FormatException {
    return const <String>[];
  }
}

/// 历史根 JSON 编码：normalize + 去重 + 截到 [kMaxSaveRootHistory]（保序，新的在前）。
String encodeSaveRootHistory(Iterable<String> roots) {
  final List<String> kept = <String>[];
  for (final String raw in roots) {
    if (raw.trim().isEmpty) continue;
    final String normalized = p.normalize(raw.trim());
    if (kept.any((String existing) => p.equals(existing, normalized))) continue;
    kept.add(normalized);
    if (kept.length >= kMaxSaveRootHistory) break;
  }
  return jsonEncode(kept);
}
