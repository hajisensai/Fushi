import 'dart:io';

import 'package:path/path.dart' as p;

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
  const RemoteBookInfo({
    required this.title,
    required this.hasContent,
    this.bookKey,
    this.hasCover = false,
    this.coverUrl,
    this.coverPath,
    this.hasAudiobook = false,
  });

  final String title;
  final bool hasContent;
  final String? bookKey;
  final bool hasCover;
  final String? coverUrl;
  final String? coverPath;

  /// 该书在 host 端是否已配有有声书（bookKey 出现在 Audiobooks 表）。远端书卡据此
  /// 渲染类型徽章（耳机 / 书本），与本地书卡 `_getAudiobookInfo` 同源（TODO-655a）。
  final bool hasAudiobook;

  String get downloadId => _isNonEmpty(bookKey) ? bookKey! : title;

  bool get hasDisplayCover =>
      hasCover || _isNonEmpty(coverUrl) || _isNonEmpty(coverPath);

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        if (_isNonEmpty(bookKey)) 'bookKey': bookKey,
        'hasContent': hasContent,
        if (hasDisplayCover) 'hasCover': true,
        if (_isNonEmpty(coverUrl)) 'coverUrl': coverUrl,
        if (hasAudiobook) 'hasAudiobook': true,
      };

  RemoteBookInfo copyWith({
    String? bookKey,
    bool? hasCover,
    String? coverUrl,
    String? coverPath,
    bool? hasAudiobook,
  }) =>
      RemoteBookInfo(
        title: title,
        hasContent: hasContent,
        bookKey: bookKey ?? this.bookKey,
        hasCover: hasCover ?? this.hasCover,
        coverUrl: coverUrl ?? this.coverUrl,
        coverPath: coverPath ?? this.coverPath,
        hasAudiobook: hasAudiobook ?? this.hasAudiobook,
      );

  static RemoteBookInfo fromJson(Map<String, Object?> json) {
    final String? coverUrl = _jsonString(json['coverUrl']);
    final String? coverPath = _jsonString(json['coverPath']);
    return RemoteBookInfo(
      title: json['title']?.toString() ?? '',
      hasContent: json['hasContent'] == true,
      bookKey: _jsonString(json['bookKey']),
      hasCover: json['hasCover'] == true ||
          _isNonEmpty(coverUrl) ||
          _isNonEmpty(coverPath),
      coverUrl: coverUrl,
      coverPath: coverPath,
      hasAudiobook: json['hasAudiobook'] == true,
    );
  }
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

/// 把 EPUB 行里持久化的封面 [coverPath]（通常是 **EPUB 内部相对 href**，如
/// `OEBPS/images/cover.jpg`）解析成磁盘上**存在的绝对文件路径**；没有可用封面
/// 时返回 null。
///
/// 纯函数（除文件存在性探测外无副作用）。host 的 `listBooks` 用它把相对 href 拼到
/// [extractDir] 再判存在——否则相对 href 被当绝对路径 `File(href).existsSync()` 恒
/// false，远端书卡永远只有占位图（TODO-033 #4：远端书籍没封面的根因，
/// TODO-007 只修对了绝对路径的视频侧）。
///
/// 探测顺序与 reader_hibiki_source 的封面解析一致：先 [extractDir] + 声明的相对
/// href（去掉前导 `/`），再回退到约定名 `cover.jpg/jpeg/png`，取首个存在者。
/// [coverPath] 本身已是存在的绝对路径时（视频侧 / 旧数据）原样返回。
String? resolveEpubCoverFilePath({
  required String extractDir,
  required String? coverPath,
}) {
  bool exists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  // 已是存在的绝对路径（视频封面就是绝对路径，故视频侧本就正常）：直接用。
  if (coverPath != null && coverPath.isNotEmpty && exists(coverPath)) {
    return coverPath;
  }
  if (extractDir.isEmpty) return null;

  final List<String> candidates = <String>[];
  if (coverPath != null && coverPath.isNotEmpty) {
    String rel = coverPath;
    if (rel.startsWith('/')) rel = rel.substring(1);
    candidates.add(p.join(extractDir, rel));
  }
  for (final String name in const <String>[
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
  ]) {
    candidates.add(p.join(extractDir, name));
  }
  for (final String candidate in candidates) {
    if (exists(candidate)) return candidate;
  }
  return null;
}

/// 从远端书清单 [remote] 里剔除本端已存在的书（按 [localBookKeys] 去重）。
///
/// 纯函数。远端书的去重键 = `sanitizeTtuFilename(title)`（与 `EpubBooks.bookKey`
/// 派生一致，由调用方算好后传入 [keyOf]）。本端已有同 key 的书就不再在「配对设备」
/// 区重复展示（TODO-033 #6：远端与本地重复同一本书）。
List<RemoteBookInfo> dedupeRemoteBooks({
  required List<RemoteBookInfo> remote,
  required Set<String> localBookKeys,
  required String Function(String title) keyOf,
}) {
  return <RemoteBookInfo>[
    for (final RemoteBookInfo book in remote)
      if (!localBookKeys.contains(keyOf(book.title))) book,
  ];
}

// ── 视频 ──────────────────────────────────────────────────────────────────────

/// 视频远端断点位置 prefs key（TODO-559/653）——单一真相源，host service 与
/// video_hibiki_page `_remotePositionPrefKey` 共用同一公式。
///
/// 在线远端视频在 client/host 本地都按稳定 bookUid（= `RemoteVideoInfo.id`）落
/// Drift `preferences` 表。host 自己播放该视频时也用同一 key，故 host 上的这条 prefs
/// 即跨设备进度的真相源。
String videoRemotePositionPrefKey(String bookUid) =>
    'video_remote_position_$bookUid';

/// [videoRemotePositionPrefKey] 对应的「最后更新时间」prefs key（epoch 毫秒）。
/// 冲突解决「取较新时间戳」需要它（见 [resolveVideoPositionSync]）。
String videoRemotePositionAtPrefKey(String bookUid) =>
    'video_remote_position_at_$bookUid';

/// 视频播放进度跨设备冲突解决（TODO-653）——「取较新时间戳」last-write-wins。
///
/// 纯函数，与有声书进度的 `SyncManager._determineSyncDirection` 同范式（取较新者；
/// 时间戳相等时取较大位置，"读得更远者胜"）。host 收到 client 上报时用它决定是否覆盖
/// 已存进度，client 恢复时用它在 host 真相与本地 prefs 之间选较新者。
///
/// [localPositionMs]/[localUpdatedAtMs] 一侧；[remotePositionMs]/[remoteUpdatedAtMs]
/// 另一侧。返回胜出的 (位置, 更新时间)。两侧时间戳均为 0（都无记录）时返回较大位置。
({int positionMs, int updatedAtMs}) resolveVideoPositionSync({
  required int localPositionMs,
  required int localUpdatedAtMs,
  required int remotePositionMs,
  required int remoteUpdatedAtMs,
}) {
  if (remoteUpdatedAtMs > localUpdatedAtMs) {
    return (positionMs: remotePositionMs, updatedAtMs: remoteUpdatedAtMs);
  }
  if (localUpdatedAtMs > remoteUpdatedAtMs) {
    return (positionMs: localPositionMs, updatedAtMs: localUpdatedAtMs);
  }
  // 时间戳相等（含都为 0）：取较大位置（看得更远者胜），保留该时间戳。
  final int winnerPos =
      localPositionMs >= remotePositionMs ? localPositionMs : remotePositionMs;
  return (positionMs: winnerPos, updatedAtMs: localUpdatedAtMs);
}

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
/// [hasSubtitle] host 能找到可下载/可查词的文本字幕时为 true；
///               包括当前集 sidecar 或容器内封文本轨，不包括 PGS/DVD 等图形轨。
/// [subtitleFileName] host 找到的 sidecar 字幕文件名（含真实扩展名），供 client
///                    下载到本地临时文件时保留 `.ass/.ssa/.vtt/.srt` 解析语义。
///                    内封字幕的临时下载名在 [RemoteVideoEmbeddedSubtitleTrack.fileName]。
class RemoteVideoEmbeddedSubtitleTrack {
  const RemoteVideoEmbeddedSubtitleTrack({
    required this.streamIndex,
    required this.codec,
    this.language,
    this.title,
    this.isText = true,
    this.url,
    this.fileName,
  });

  final int streamIndex;
  final String codec;
  final String? language;
  final String? title;
  final bool isText;
  final String? url;
  final String? fileName;

  Map<String, Object?> toJson() => <String, Object?>{
        'streamIndex': streamIndex,
        'codec': codec,
        if (_isNonEmpty(language)) 'language': language,
        if (_isNonEmpty(title)) 'title': title,
        'isText': isText,
        if (_isNonEmpty(url)) 'url': url,
        if (_isNonEmpty(fileName)) 'fileName': fileName,
      };

  RemoteVideoEmbeddedSubtitleTrack copyWith({
    String? url,
    String? fileName,
  }) =>
      RemoteVideoEmbeddedSubtitleTrack(
        streamIndex: streamIndex,
        codec: codec,
        language: language,
        title: title,
        isText: isText,
        url: url ?? this.url,
        fileName: fileName ?? this.fileName,
      );

  static RemoteVideoEmbeddedSubtitleTrack fromJson(
    Map<String, Object?> json,
  ) =>
      RemoteVideoEmbeddedSubtitleTrack(
        streamIndex: _jsonInt(json['streamIndex']) ?? -1,
        codec: json['codec']?.toString() ?? '',
        language: _jsonString(json['language']),
        title: _jsonString(json['title']),
        isText: json['isText'] != false,
        url: _jsonString(json['url']),
        fileName: _jsonString(json['fileName']),
      );
}

class RemoteVideoInfo {
  const RemoteVideoInfo({
    required this.id,
    required this.title,
    this.sizeBytes,
    this.hasSubtitle = false,
    this.subtitleFileName,
    this.embeddedSubtitleTracks = const <RemoteVideoEmbeddedSubtitleTrack>[],
    this.durationMs,
    this.hasCover = false,
    this.coverUrl,
    this.coverPath,
    this.positionMs = 0,
    this.positionUpdatedAtMs = 0,
  });

  final String id;
  final String title;
  final int? sizeBytes;
  final bool hasSubtitle;
  final String? subtitleFileName;
  final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks;
  final int? durationMs;
  final bool hasCover;
  final String? coverUrl;
  final String? coverPath;

  /// host 端记录的该视频上次播放断点（毫秒，TODO-653 跨设备视频进度同步）。
  ///
  /// 视频远端是 host/client 模型——client 不存视频、只从 host 流式播放——故进度的
  /// 唯一真相源是 host，落 host 自己的 `video_remote_position_<bookUid>` prefs（与
  /// host 本地播放该视频时同一键空间，见 video_hibiki_page `_remotePositionPrefKey`）。
  /// 0 表示无记录（从头）。
  final int positionMs;

  /// [positionMs] 的最后更新时间（epoch 毫秒）。跨设备冲突解决用「取较新时间戳」
  /// （last-write-wins by timestamp），与有声书进度的 `_determineSyncDirection`
  /// 同范式。0 表示无记录。
  final int positionUpdatedAtMs;

  bool get hasDisplayCover =>
      hasCover || _isNonEmpty(coverUrl) || _isNonEmpty(coverPath);

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        'hasSubtitle': hasSubtitle,
        if (_isNonEmpty(subtitleFileName)) 'subtitleFileName': subtitleFileName,
        if (embeddedSubtitleTracks.isNotEmpty)
          'embeddedSubtitleTracks': <Map<String, Object?>>[
            for (final RemoteVideoEmbeddedSubtitleTrack track
                in embeddedSubtitleTracks)
              track.toJson(),
          ],
        if (durationMs != null) 'durationMs': durationMs,
        if (hasDisplayCover) 'hasCover': true,
        if (_isNonEmpty(coverUrl)) 'coverUrl': coverUrl,
        if (positionMs > 0) 'positionMs': positionMs,
        if (positionUpdatedAtMs > 0) 'positionUpdatedAtMs': positionUpdatedAtMs,
      };

  RemoteVideoInfo copyWith({
    bool? hasCover,
    String? coverUrl,
    String? coverPath,
    String? subtitleFileName,
    List<RemoteVideoEmbeddedSubtitleTrack>? embeddedSubtitleTracks,
    int? positionMs,
    int? positionUpdatedAtMs,
  }) =>
      RemoteVideoInfo(
        id: id,
        title: title,
        sizeBytes: sizeBytes,
        hasSubtitle: hasSubtitle,
        subtitleFileName: subtitleFileName ?? this.subtitleFileName,
        embeddedSubtitleTracks:
            embeddedSubtitleTracks ?? this.embeddedSubtitleTracks,
        durationMs: durationMs,
        hasCover: hasCover ?? this.hasCover,
        coverUrl: coverUrl ?? this.coverUrl,
        coverPath: coverPath ?? this.coverPath,
        positionMs: positionMs ?? this.positionMs,
        positionUpdatedAtMs: positionUpdatedAtMs ?? this.positionUpdatedAtMs,
      );

  static RemoteVideoInfo fromJson(Map<String, Object?> json) {
    final String? coverUrl = _jsonString(json['coverUrl']);
    final String? coverPath = _jsonString(json['coverPath']);
    final String? subtitleFileName = _jsonString(json['subtitleFileName']);
    final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks =
        _jsonEmbeddedSubtitleTracks(json['embeddedSubtitleTracks']);
    return RemoteVideoInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      hasSubtitle: json['hasSubtitle'] == true,
      subtitleFileName: subtitleFileName,
      embeddedSubtitleTracks: embeddedSubtitleTracks,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      hasCover: json['hasCover'] == true ||
          _isNonEmpty(coverUrl) ||
          _isNonEmpty(coverPath),
      coverUrl: coverUrl,
      coverPath: coverPath,
      positionMs: _jsonInt(json['positionMs']) ?? 0,
      positionUpdatedAtMs: _jsonInt(json['positionUpdatedAtMs']) ?? 0,
    );
  }
}

String? _jsonString(Object? value) {
  if (value == null) return null;
  final String text = value.toString();
  return text.isEmpty ? null : text;
}

int? _jsonInt(Object? value) {
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

List<RemoteVideoEmbeddedSubtitleTrack> _jsonEmbeddedSubtitleTracks(
  Object? value,
) {
  if (value is! List) return const <RemoteVideoEmbeddedSubtitleTrack>[];
  return <RemoteVideoEmbeddedSubtitleTrack>[
    for (final Object? item in value)
      if (item is Map)
        RemoteVideoEmbeddedSubtitleTrack.fromJson(
          item.cast<String, Object?>(),
        ),
  ];
}

bool _isNonEmpty(String? value) => value != null && value.isNotEmpty;

/// client 向 host 申请到的视频播放 URL。
///
/// [streamUrl] 是可直接交给播放器的短时 token URL；[subtitleUrl] 仅表示 host 有
/// 可下载外挂字幕，实际播放器应先通过 client 下载到本地再复用现有字幕路径。
/// [subtitleFileName] 与 [subtitleUrl] 配套，保留 host sidecar 的真实文件名/扩展名。
class RemoteVideoStreamUrls {
  const RemoteVideoStreamUrls({
    required this.streamUrl,
    this.subtitleUrl,
    this.subtitleFileName,
    this.embeddedSubtitleTracks = const <RemoteVideoEmbeddedSubtitleTrack>[],
  });

  final String streamUrl;
  final String? subtitleUrl;
  final String? subtitleFileName;
  final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks;

  static RemoteVideoStreamUrls fromJson(Map<String, Object?> json) {
    final String streamUrl = json['url']?.toString() ?? '';
    final String? subtitleUrl = json['subtitleUrl']?.toString();
    final String? subtitleFileName = _jsonString(json['subtitleFileName']);
    final List<RemoteVideoEmbeddedSubtitleTrack> embeddedSubtitleTracks =
        _jsonEmbeddedSubtitleTracks(json['embeddedSubtitleTracks']);
    return RemoteVideoStreamUrls(
      streamUrl: streamUrl,
      subtitleUrl: subtitleUrl,
      subtitleFileName: subtitleFileName,
      embeddedSubtitleTracks: embeddedSubtitleTracks,
    );
  }
}

/// 从远端视频清单 [remote] 里剔除本端已存在的视频（按 [localBookUids] 去重）。
///
/// 纯函数。视频的跨设备身份就是 [RemoteVideoInfo.id]（= `VideoBooks.bookUid`，
/// 从文件名经 [sanitizeTtuFilename] 派生，host 与本端同源），故直接按 id 精确去重，
/// 不必再走标题再派生（标题可能两端不同，bookUid 才是规范同步键）。本端已有同 id 的
/// 视频就不在「配对设备」区重复展示（TODO-033 #6：远端与本地重复同一视频）。
List<RemoteVideoInfo> dedupeRemoteVideos({
  required List<RemoteVideoInfo> remote,
  required Set<String> localBookUids,
}) {
  return <RemoteVideoInfo>[
    for (final RemoteVideoInfo video in remote)
      if (!localBookUids.contains(video.id)) video,
  ];
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
  Future<File?> resolveVideoSubtitle(String id, {String langCode = ''});

  /// 读 host 端记录的视频 [id] 播放断点（TODO-653）。返回 (位置毫秒, 更新时间毫秒)；
  /// 无记录时返回 (0, 0)。
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(String id);

  /// 把 client 上报的视频 [id] 播放断点写入 host（TODO-653）。
  ///
  /// 冲突解决「取较新时间戳」（见 [resolveVideoPositionSync]）：仅当 [updatedAtMs]
  /// 严格新于 host 已存时间戳才覆盖，避免旧设备的滞后上报回退新进度。
  Future<void> putVideoPosition(String id, int positionMs, int updatedAtMs);
}
