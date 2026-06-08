import 'dart:io';

// ── 本地音频 ──────────────────────────────────────────────────────────────────

/// host 实时本地音频来源的清单条目（键 = displayName）。
///
/// [displayName] 是用户设置的显示名，用作跨设备 union-key（与 orchestrator
/// `kSyncLocalAudioNamespace` 的资产名语义一致）。
class RemoteLocalAudioInfo {
  const RemoteLocalAudioInfo({required this.displayName});

  final String displayName;

  Map<String, Object?> toJson() =>
      <String, Object?>{'displayName': displayName};

  static RemoteLocalAudioInfo fromJson(Map<String, Object?> json) =>
      RemoteLocalAudioInfo(
        displayName: json['displayName']?.toString() ?? '',
      );
}

/// 按 displayName union 的本地音频同步 diff 结果。
class LocalAudioSyncDiff {
  const LocalAudioSyncDiff({required this.toPull, required this.toPush});

  /// 对端有 ∧ 本端无 → 需从对端拉取。
  final Set<String> toPull;

  /// 本端有 ∧ 对端无 → 需推送到对端。
  final Set<String> toPush;
}

/// 按 displayName union 计算本地音频同步 diff。
///
/// [localNames]  本端已注册的本地音频 displayName 集合。
/// [remoteNames] 对端已注册的本地音频 displayName 集合。
LocalAudioSyncDiff computeLocalAudioSyncDiff({
  required Set<String> localNames,
  required Set<String> remoteNames,
}) {
  return LocalAudioSyncDiff(
    toPull: remoteNames.difference(localNames),
    toPush: localNames.difference(remoteNames),
  );
}

// ── 有声书包 ──────────────────────────────────────────────────────────────────

/// host 实时有声书的清单条目（键 = bookKey）。
///
/// [bookKey] 即 `sanitizeTtuFilename(title)`，在 Audiobooks/SrtBooks/AudioCues 表
/// 中均以此为外键，跨设备稳定一致。[title] 可选，供显示用（允许 null）。
class RemoteAudiobookInfo {
  const RemoteAudiobookInfo({required this.bookKey, this.title});

  final String bookKey;
  final String? title;

  Map<String, Object?> toJson() =>
      <String, Object?>{'bookKey': bookKey, 'title': title};

  static RemoteAudiobookInfo fromJson(Map<String, Object?> json) =>
      RemoteAudiobookInfo(
        bookKey: json['bookKey']?.toString() ?? '',
        title: json['title']?.toString(),
      );
}

/// 按 bookKey union 的有声书同步 diff 结果。
class AudiobookSyncDiff {
  const AudiobookSyncDiff({required this.toPull, required this.toPush});

  /// 对端有 ∧ 本端无 → 需从对端拉取。
  final Set<String> toPull;

  /// 本端有 ∧ 对端无 → 需推送到对端。
  final Set<String> toPush;
}

/// 按 bookKey union 计算有声书同步 diff。
///
/// [localKeys]  本端已有有声书的 bookKey 集合。
/// [remoteKeys] 对端已有有声书的 bookKey 集合。
AudiobookSyncDiff computeAudiobookSyncDiff({
  required Set<String> localKeys,
  required Set<String> remoteKeys,
}) {
  return AudiobookSyncDiff(
    toPull: remoteKeys.difference(localKeys),
    toPush: localKeys.difference(remoteKeys),
  );
}

// ── 词典 ──────────────────────────────────────────────────────────────────────

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
/// [hasContent] 存在可导出的 EPUB 根目录时为 true——表示该书可被导出。
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

// ── 视频 ──────────────────────────────────────────────────────────────────────

/// host 实时视频的清单条目（只读，不同步——视频文件通常过大，不走同步管道）。
///
/// [id] 即 `VideoBooks.bookUid`，从文件名派生的稳定字符串（如 `video/my_film`
/// 或 `video/playlist/series`）。host 服务用 id 反查 DB 行拿真实路径，客户端
/// 持 id 请求流式传输时 **server 只做 DB 查询，绝不接受外部传入的文件路径**。
///
/// [sizeBytes] 对单视频是当前集文件大小（字节）；播放列表取第一集大小；
///             文件不存在或无法 stat 时为 null。
/// [durationMs] DB 无 duration 列，此字段留给后续任务由 ffprobe/libmpv 填充；
///              目前恒为 null（占位）。
/// [hasSubtitle] host 能找到外挂字幕（当前集 sidecar）时为 true；
///               内封字幕不算，外挂字幕缺失或文件路径未知时为 false。
class RemoteVideoInfo {
  const RemoteVideoInfo({
    required this.id,
    required this.title,
    this.sizeBytes,
    this.hasSubtitle = false,
    this.durationMs,
  });

  final String id;
  final String title;
  final int? sizeBytes;
  final bool hasSubtitle;
  final int? durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        'hasSubtitle': hasSubtitle,
        if (durationMs != null) 'durationMs': durationMs,
      };

  static RemoteVideoInfo fromJson(Map<String, Object?> json) => RemoteVideoInfo(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
        hasSubtitle: json['hasSubtitle'] == true,
        durationMs: (json['durationMs'] as num?)?.toInt(),
      );
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

  // ── 本地音频 ───────────────────────────────────────────────────────────────

  /// host 当前本地音频来源清单（从已注入的 localAudioEntries 取 displayName）。
  Future<List<RemoteLocalAudioInfo>> listLocalAudio();

  /// 即时把 displayName 为 [displayName] 的本地音频库打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到该来源或其 DB 文件不存在时抛 [StateError]。
  Future<File> exportLocalAudio(String displayName);

  /// 把本地音频包文件导入 host（解包 + 注册回调）。
  /// 实现应调用 [onLocalAudioImported] 回调完成 native 注册；
  /// 回调为 null 时抛 [UnsupportedError]。
  Future<void> importLocalAudio(File packageFile);

  /// 从 host 删除 displayName 为 [displayName] 的本地音频来源。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]。
  Future<void> deleteLocalAudio(String displayName);

  // ── 有声书包 ──────────────────────────────────────────────────────────────

  /// host 当前可导出的有声书清单。
  Future<List<RemoteAudiobookInfo>> listAudiobooks();

  /// 即时把 bookKey 为 [bookKey] 的有声书打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [bookKey] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到该有声书时抛 [StateError]。
  Future<File> exportAudiobook(String bookKey);

  /// 把有声书包文件导入 host（解包写 DB + 音频文件）。
  /// 实现需要 [audioDatabaseRoot] 来确定音频文件落盘目录。
  Future<void> importAudiobook(File packageFile, {String? bookKeyOverride});

  /// 从 host 删除 bookKey 为 [bookKey] 的有声书（Audiobooks/SrtBooks/AudioCues 行
  /// + 磁盘音频目录）。[bookKey] 含路径穿越字符时抛 [ArgumentError]。
  Future<void> deleteAudiobook(String bookKey);

  // ── 视频（只读，不同步）────────────────────────────────────────────────────────

  /// host 当前视频清单（从 VideoBooks 表读，按 importedAt DESC 排序）。
  ///
  /// 只读接口：视频文件通常数 GB，不走同步管道；这里仅供客户端请求流式传输用。
  Future<List<RemoteVideoInfo>> listVideos();

  /// 按 [id]（即 `VideoBooks.bookUid`）反查真实视频文件。
  ///
  /// 实现**只查 DB** 得到 videoPath，然后验证文件存在后返回；文件不存在或 id 未知
  /// 时返回 null。绝不接受外部任意路径——[id] 只能来自 [listVideos] 返回的条目，
  /// 防止路径穿越。
  Future<File?> resolveVideoFile(String id);

  /// 按 [id] 查找对应视频的外挂字幕文件（sidecar）。
  ///
  /// 用 [langCode] 优先匹配带语言标记的字幕（如 `.ja.srt`）；内封字幕不在此列。
  /// 找不到外挂字幕或视频未知时返回 null。
  Future<File?> resolveVideoSubtitle(String id, {String langCode = 'ja'});
}
