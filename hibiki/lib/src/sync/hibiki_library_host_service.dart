import 'dart:io';

/// host 实时词典的清单条目（不含 contentHash：Phase 1 按名 union，与现有暂存
/// 路径同语义，避免引入跨设备哈希一致性的新风险；overwrite-by-hash 列为 follow-up）。
class RemoteDictionaryInfo {
  const RemoteDictionaryInfo({required this.name, required this.type});
  final String name;
  final String type;

  Map<String, Object?> toJson() =>
      <String, Object?>{'name': name, 'type': type};

  static RemoteDictionaryInfo fromJson(Map<String, Object?> json) =>
      RemoteDictionaryInfo(
        name: json['name']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
      );
}

/// 按名 union 的 diff 结果。删除不在此处推断（交给 BUG-086 A 的删除传播）。
class DictionarySyncDiff {
  const DictionarySyncDiff({required this.toPull, required this.toPush});

  /// 对端有 ∧ 本端无 → 需要从对端拉取。
  final Set<String> toPull;

  /// 本端有 ∧ 对端无 → 需要推送到对端。
  final Set<String> toPush;
}

/// 按名 union 计算词典同步 diff。
///
/// [localNames]  本端已安装的词典名集合。
/// [remoteNames] 对端已安装的词典名集合。
DictionarySyncDiff computeDictionarySyncDiff({
  required Set<String> localNames,
  required Set<String> remoteNames,
}) {
  return DictionarySyncDiff(
    toPull: remoteNames.difference(localNames),
    toPush: localNames.difference(remoteNames),
  );
}

// ── Books ──────────────────────────────────────────────────────────────────

/// host 实时书籍的清单条目。
///
/// [title]      书名（与 DB `epub_books.title` 列一致）。
/// [hasContent] extractDir 非空且目录存在时为 true——表示该书可被导出。
///              无内容的书（extractDir 丢失或空）不应被 pull（与 orchestrator
///              `importRemoteBooks` 的跳过语义一致）。
class RemoteBookInfo {
  const RemoteBookInfo({required this.title, required this.hasContent});

  final String title;
  final bool hasContent;

  Map<String, Object?> toJson() =>
      <String, Object?>{'title': title, 'hasContent': hasContent};

  static RemoteBookInfo fromJson(Map<String, Object?> json) => RemoteBookInfo(
        title: json['title']?.toString() ?? '',
        hasContent: json['hasContent'] == true,
      );
}

/// 按 `sanitizeTtuFilename(title)` union 的书籍同步 diff 结果。
///
/// 删除由删除传播处理，不在此推断。
class BookSyncDiff {
  const BookSyncDiff({required this.toPull, required this.toPush});

  /// 远端有内容（hasContent==true）∧ 本端无 → 需从远端 pull。
  final Set<String> toPull;

  /// 本端有 ∧ 远端无 → 需推送到远端。
  final Set<String> toPush;
}

/// 按 `sanitizeTtuFilename(title)` union 计算书籍同步 diff。
///
/// [localKeys]          本端书籍的 sanitizeTtuFilename(title) 集合。
/// [remoteKeyHasContent] 远端书籍的 key → hasContent 映射；
///                       只有 hasContent==true 的远端书才进入 [BookSyncDiff.toPull]
///                       （无内容的书跳过，与 orchestrator importRemoteBooks 语义一致）。
BookSyncDiff computeBookSyncDiff({
  required Set<String> localKeys,
  required Map<String, bool> remoteKeyHasContent,
}) {
  final Set<String> toPull = <String>{};
  final Set<String> toPush = <String>{};

  for (final MapEntry<String, bool> entry in remoteKeyHasContent.entries) {
    if (entry.value && !localKeys.contains(entry.key)) {
      toPull.add(entry.key);
    }
  }
  for (final String key in localKeys) {
    if (!remoteKeyHasContent.containsKey(key)) {
      toPush.add(key);
    }
  }

  return BookSyncDiff(toPull: toPull, toPush: toPush);
}

// ── Abstract service ───────────────────────────────────────────────────────

/// host 侧「库感知」服务：把 host 的实时库即时 export/import/delete/list。
/// 抽象不依赖 AppModel，便于测试用 fake 注入。所有实现里的库变动必须串行
/// （经 runExclusiveWithSync）——见 AppModelLibraryHostService（后续任务实现）。
abstract class HibikiLibraryHostService {
  /// host 当前实时词典清单（从 DictionaryMeta 表读，不是从任何暂存目录）。
  Future<List<RemoteDictionaryInfo>> listDictionaries();

  /// 即时把名为 [name] 的实时词典打包成 .hibikidict 临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。词典不存在抛 [StateError]。
  Future<File> exportDictionary(String name);

  /// 把 [packageFile]（.hibikidict）导入 host 实时库（幂等：同名覆盖资源 + upsert 元数据）。
  Future<void> importDictionary(File packageFile);

  /// 从 host 实时库删除名为 [name] 的词典（DB 元数据 + 资源目录）。
  Future<void> deleteDictionary(String name);

  // ── 书籍 ─────────────────────────────────────────────────────────────────

  /// host 当前书库清单（从 EpubBooks 表读）。
  Future<List<RemoteBookInfo>> listBooks();

  /// 即时把书名为 [title] 的书 extractDir 重打包成 .epub 临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [title] 含路径穿越字符时抛 [ArgumentError]；
  /// 书不存在或 extractDir 为空/不存在时抛 [StateError]。
  Future<File> exportBook(String title);

  /// 把 [epubFile] 导入 host 书库（复用 EpubImporter）。
  Future<void> importBook(File epubFile);

  /// 从 host 书库删除书名为 [title] 的书（DB 行 + 磁盘目录）。
  /// [title] 含路径穿越字符时抛 [ArgumentError]。
  Future<void> deleteBook(String title);
}
