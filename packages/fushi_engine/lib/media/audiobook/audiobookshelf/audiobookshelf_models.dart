/// Audiobookshelf（ABS，自托管有声书服务器）协议层的 DTO 与 JSON→DTO 纯函数解析。
///
/// 纯 Dart：app 侧的发现源与将来的无头服务端共用。字段形状按服务端 v2.37.1 源码核实
/// （`LibraryItem.toOldJSONMinified` / `Book.toOldJSONMinified` /
/// `User.toOldJSONForBrowser` / `Auth.getUserLoginResponsePayload`）。
///
/// 解析一律**宽容**：ABS 历代版本字段时有时无（`refreshToken` 2.26 起才有、
/// `numAudioFiles` 只在 book 媒体上有），缺字段降级为 null 而不是抛；只有「连身份都
/// 没有」的条目（无 id）才丢弃。
library;

import 'dart:convert';

/// 访问一台 ABS 服务器所需的令牌组。
///
/// 两种来源：
/// - 账号密码登录（`POST /login` + `x-return-tokens: true`）：[accessToken] 1 小时、
///   [refreshToken] 30 天且**每次刷新都会轮换**，刷新后必须持久化新值；
/// - 用户直接粘贴的 API key（v2.26+ `/api/api-keys` 生成）或旧版 `user.token`：
///   只有 [accessToken]，[refreshToken] 为 null，不能刷新。
class AudiobookshelfTokens {
  const AudiobookshelfTokens({required this.accessToken, this.refreshToken});

  final String accessToken;
  final String? refreshToken;

  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is AudiobookshelfTokens &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken;

  @override
  int get hashCode => Object.hash(accessToken, refreshToken);
}

/// 当前用户（`/api/me`、登录响应的 `user`）里本仓用到的部分。
class AudiobookshelfUser {
  const AudiobookshelfUser({
    required this.id,
    required this.username,
    required this.canDownload,
    this.type,
  });

  final String id;
  final String username;

  /// `root` / `admin` / `user` / `guest`。
  final String? type;

  /// `permissions.download`。服务端 `GET /api/items/:id/download` 以它为唯一判据
  /// （`LibraryItemController.download` → `req.user.canDownload`），没有就 403。
  final bool canDownload;

  static AudiobookshelfUser parse(Map<String, Object?> json) {
    final Object? permissions = json['permissions'];
    return AudiobookshelfUser(
      id: _str(json['id']) ?? '',
      username: _str(json['username']) ?? '',
      type: _str(json['type']),
      canDownload: permissions is Map && permissions['download'] == true,
    );
  }
}

/// 登录 / 刷新的结果：令牌 + 用户 + 服务器自报信息。
class AudiobookshelfSession {
  const AudiobookshelfSession({
    required this.tokens,
    required this.user,
    this.defaultLibraryId,
    this.serverVersion,
  });

  final AudiobookshelfTokens tokens;
  final AudiobookshelfUser user;
  final String? defaultLibraryId;
  final String? serverVersion;

  /// 解析 `POST /login` / `POST /auth/refresh` 的响应体。
  ///
  /// 新版（≥2.26）给 `user.accessToken`（+ 请求了才给的 `user.refreshToken`）；旧版只有
  /// 永不过期的 `user.token`。两者都没有即视为响应畸形（抛 [FormatException]）。
  static AudiobookshelfSession parse(Map<String, Object?> json) {
    final Object? rawUser = json['user'];
    if (rawUser is! Map<String, Object?>) {
      throw const FormatException('ABS login response has no user object');
    }
    final String? accessToken =
        _nonEmpty(rawUser['accessToken']) ?? _nonEmpty(rawUser['token']);
    if (accessToken == null) {
      throw const FormatException('ABS login response carries no token');
    }
    final Object? settings = json['serverSettings'];
    return AudiobookshelfSession(
      tokens: AudiobookshelfTokens(
        accessToken: accessToken,
        refreshToken: _nonEmpty(rawUser['refreshToken']),
      ),
      user: AudiobookshelfUser.parse(rawUser),
      defaultLibraryId: _nonEmpty(json['userDefaultLibraryId']),
      serverVersion: settings is Map<String, Object?>
          ? _str(settings['version'])
          : null,
    );
  }
}

/// ABS 媒体库的媒体类型。只有 [book] 进发现页（podcast v1 不支持）。
enum AudiobookshelfMediaType { book, podcast, unknown }

/// 一个媒体库（`GET /api/libraries` 的一项）。
class AudiobookshelfLibrary {
  const AudiobookshelfLibrary({
    required this.id,
    required this.name,
    required this.mediaType,
  });

  final String id;
  final String name;
  final AudiobookshelfMediaType mediaType;

  bool get isBookLibrary => mediaType == AudiobookshelfMediaType.book;

  static AudiobookshelfLibrary? parse(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final String? id = _nonEmpty(raw['id']);
    if (id == null) return null;
    return AudiobookshelfLibrary(
      id: id,
      name: _str(raw['name']) ?? id,
      mediaType: switch (_str(raw['mediaType'])) {
        'book' => AudiobookshelfMediaType.book,
        'podcast' => AudiobookshelfMediaType.podcast,
        _ => AudiobookshelfMediaType.unknown,
      },
    );
  }

  /// `{libraries: [...]}` → 清单（坏条目逐条丢弃）。
  static List<AudiobookshelfLibrary> parseList(Map<String, Object?> json) {
    final Object? raw = json['libraries'];
    if (raw is! List) return const <AudiobookshelfLibrary>[];
    return <AudiobookshelfLibrary>[
      for (final Object? entry in raw)
        if (parse(entry) case final AudiobookshelfLibrary library) library,
    ];
  }
}

/// 一个库条目（minified 或 expanded 形状都能解析，本仓只用两者的公共字段）。
class AudiobookshelfItem {
  const AudiobookshelfItem({
    required this.id,
    required this.title,
    this.libraryId,
    this.mediaType,
    this.authorName,
    this.narratorName,
    this.seriesName,
    this.publishedYear,
    this.durationSeconds,
    this.sizeBytes,
    this.isFile = false,
    this.relPath,
    this.numAudioFiles,
    this.ebookFormat,
  });

  final String id;
  final String title;
  final String? libraryId;
  final String? mediaType;
  final String? authorName;
  final String? narratorName;
  final String? seriesName;
  final String? publishedYear;
  final double? durationSeconds;
  final int? sizeBytes;

  /// 条目是库根下的**单个文件**（而非目录）：下载端点直接回该文件，不打 zip。
  final bool isFile;

  /// 条目相对库文件夹的路径；单文件条目时就是带扩展名的文件名（下载端点用它当
  /// `Content-Disposition` 文件名）。
  final String? relPath;

  /// 音频文件数。null = 响应里没这个字段（不能当 0）。
  final int? numAudioFiles;

  /// 电子书格式（`epub` / `pdf` …）；没有电子书为 null。
  final String? ebookFormat;

  /// 是否确定**没有**音频（只有电子书 / 补充文件的条目）。字段缺失时不下结论。
  bool get hasNoAudio => numAudioFiles == 0;

  static AudiobookshelfItem? parse(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final String? id = _nonEmpty(raw['id']);
    if (id == null) return null;
    final Object? rawMedia = raw['media'];
    final Map<String, Object?> media = rawMedia is Map<String, Object?>
        ? rawMedia
        : const <String, Object?>{};
    final Object? rawMetadata = media['metadata'];
    final Map<String, Object?> metadata = rawMetadata is Map<String, Object?>
        ? rawMetadata
        : const <String, Object?>{};
    return AudiobookshelfItem(
      id: id,
      title: _nonEmpty(metadata['title']) ?? _nonEmpty(raw['relPath']) ?? id,
      libraryId: _nonEmpty(raw['libraryId']),
      mediaType: _nonEmpty(raw['mediaType']),
      // 播客的创作者在 `author`，书在 `authorName`。
      authorName: _nonEmpty(metadata['authorName']) ?? _nonEmpty(metadata['author']),
      narratorName: _nonEmpty(metadata['narratorName']),
      seriesName: _nonEmpty(metadata['seriesName']),
      publishedYear: _nonEmpty(metadata['publishedYear']),
      durationSeconds: _num(media['duration'])?.toDouble(),
      sizeBytes: _num(raw['size'])?.toInt() ?? _num(media['size'])?.toInt(),
      isFile: raw['isFile'] == true,
      relPath: _nonEmpty(raw['relPath']),
      numAudioFiles: _audioFileCount(media),
      ebookFormat: _ebookFormat(media),
    );
  }

  /// minified 给 `numAudioFiles`；expanded 给 `audioFiles` 数组。
  static int? _audioFileCount(Map<String, Object?> media) {
    final int? count = _num(media['numAudioFiles'])?.toInt();
    if (count != null) return count;
    final Object? files = media['audioFiles'];
    return files is List ? files.length : null;
  }

  /// minified 给 `ebookFormat`；expanded 给 `ebookFile.ebookFormat`。
  static String? _ebookFormat(Map<String, Object?> media) {
    final String? format = _nonEmpty(media['ebookFormat']);
    if (format != null) return format;
    final Object? file = media['ebookFile'];
    return file is Map<String, Object?> ? _nonEmpty(file['ebookFormat']) : null;
  }
}

/// `GET /api/libraries/:id/items` 的一页。
class AudiobookshelfItemPage {
  const AudiobookshelfItemPage({
    required this.items,
    required this.total,
    required this.page,
    required this.limit,
  });

  final List<AudiobookshelfItem> items;

  /// 库内条目总数（服务端计数，含被本仓过滤掉的无音频条目）。
  final int total;

  /// 0 基页码。
  final int page;
  final int limit;

  /// 还有下一页。按服务端总数判，不按本页条数（本页可能被过滤得更短）。
  bool get hasMore => limit > 0 && (page + 1) * limit < total;

  /// `{results, total, limit, page}`；`limit`/`page` 回显的是查询串原值，
  /// 可能是字符串，故宽容解析，缺失时回落到请求值。
  static AudiobookshelfItemPage parse(
    Map<String, Object?> json, {
    required int requestedPage,
    required int requestedLimit,
  }) {
    final Object? raw = json['results'];
    final List<AudiobookshelfItem> items = <AudiobookshelfItem>[
      if (raw is List)
        for (final Object? entry in raw)
          if (AudiobookshelfItem.parse(entry)
              case final AudiobookshelfItem item)
            item,
    ];
    return AudiobookshelfItemPage(
      items: items,
      total: _num(json['total'])?.toInt() ?? items.length,
      page: _num(json['page'])?.toInt() ?? requestedPage,
      limit: _num(json['limit'])?.toInt() ?? requestedLimit,
    );
  }
}

/// `GET /api/libraries/:id/search` → `{book: [{libraryItem}], ...}` 的条目。
///
/// podcast 库返回的是 `{podcast: [{libraryItem}]}`，两种形状都收。
List<AudiobookshelfItem> parseAudiobookshelfSearch(Map<String, Object?> json) {
  return <AudiobookshelfItem>[
    for (final String key in const <String>['book', 'podcast'])
      if (json[key] case final List<Object?> matches)
        for (final Object? match in matches)
          if (match is Map<String, Object?>)
            if (AudiobookshelfItem.parse(match['libraryItem'])
                case final AudiobookshelfItem item)
              item,
  ];
}

/// `GET /status`（免鉴权）：用来在填地址时确认对面真是 ABS，并拿到版本与登录方式。
class AudiobookshelfServerStatus {
  const AudiobookshelfServerStatus({
    required this.serverVersion,
    required this.isInit,
    required this.authMethods,
  });

  final String? serverVersion;
  final bool isInit;

  /// `local` / `openid`。没有 `local` 就不能用账号密码登录，只能贴 API key。
  final List<String> authMethods;

  /// 旧版本不报 `authMethods`：空表按「支持」处理，别把老服务器挡在门外。
  bool get supportsPasswordLogin =>
      authMethods.isEmpty || authMethods.contains('local');

  /// 响应不是 ABS（`app` 不是 audiobookshelf）时返回 null。
  static AudiobookshelfServerStatus? parse(Map<String, Object?> json) {
    if (json['app'] != 'audiobookshelf') return null;
    final Object? methods = json['authMethods'];
    return AudiobookshelfServerStatus(
      serverVersion: _str(json['serverVersion']),
      isInit: json['isInit'] == true,
      authMethods: <String>[
        if (methods is List)
          for (final Object? method in methods)
            if (method is String) method,
      ],
    );
  }
}

/// 一条音轨（多文件有声书里的一个音频文件，或播客单集的唯一音频）。
///
/// [startOffsetMs] 是该轨在整本书时间轴上的起点（服务端给的是累计值）。
class AudiobookshelfTrack {
  const AudiobookshelfTrack({
    required this.index,
    required this.ino,
    required this.durationMs,
    required this.startOffsetMs,
    required this.itemId,
    this.mimeType,
    this.sizeBytes,
    this.filename,
  });

  /// 从 1 开始的序号（服务端的 `index`）；缺失时按出现顺序补。
  final int index;
  final String ino;
  final int durationMs;
  final int startOffsetMs;
  final String itemId;
  final String? mimeType;
  final int? sizeBytes;
  final String? filename;

  /// 文件端点路径（相对服务器根，已含 `/api`）。
  String get contentPath =>
      '/api/items/${Uri.encodeComponent(itemId)}/file/${Uri.encodeComponent(ino)}';

  int get endOffsetMs => startOffsetMs + durationMs;

  /// 解析 `tracks[]`（含 `startOffset`）或 `audioFiles[]`（不含，由调用方累计）。
  static AudiobookshelfTrack? parse(
    Object? raw, {
    required String itemId,
    required int fallbackIndex,
    required int fallbackStartOffsetMs,
  }) {
    if (raw is! Map<String, Object?>) return null;
    final String? ino = _nonEmpty(raw['ino']);
    if (ino == null) return null;
    final Object? rawMetadata = raw['metadata'];
    final Map<String, Object?> metadata = rawMetadata is Map<String, Object?>
        ? rawMetadata
        : const <String, Object?>{};
    final num? startOffset = _num(raw['startOffset']);
    return AudiobookshelfTrack(
      index: _num(raw['index'])?.toInt() ?? fallbackIndex,
      ino: ino,
      itemId: itemId,
      durationMs: ((_num(raw['duration']) ?? 0) * 1000).round(),
      startOffsetMs: startOffset == null
          ? fallbackStartOffsetMs
          : (startOffset * 1000).round(),
      mimeType: _nonEmpty(raw['mimeType']),
      sizeBytes: _num(metadata['size'])?.toInt(),
      filename: _nonEmpty(metadata['filename']),
    );
  }

  /// 解析一组音轨：优先 `tracks`，否则用 `audioFiles` 并自己累计偏移。
  static List<AudiobookshelfTrack> parseList(
    Map<String, Object?> media, {
    required String itemId,
  }) {
    final Object? tracks = media['tracks'];
    final Object? source = tracks is List && tracks.isNotEmpty
        ? tracks
        : media['audioFiles'];
    if (source is! List) return const <AudiobookshelfTrack>[];
    final List<AudiobookshelfTrack> out = <AudiobookshelfTrack>[];
    int offset = 0;
    for (final Object? entry in source) {
      final AudiobookshelfTrack? track = parse(
        entry,
        itemId: itemId,
        fallbackIndex: out.length + 1,
        fallbackStartOffsetMs: offset,
      );
      if (track == null) continue;
      out.add(track);
      offset = track.endOffsetMs;
    }
    return out;
  }
}

/// 条目文件夹里的一个文件（`libraryFiles[]`）。
class AudiobookshelfLibraryFile {
  const AudiobookshelfLibraryFile({
    required this.ino,
    required this.filename,
    this.relPath,
    this.sizeBytes,
    this.fileType,
  });

  final String ino;
  final String filename;
  final String? relPath;
  final int? sizeBytes;
  final String? fileType;

  /// 字幕扩展名。服务端不认 `.srt`（`fileType` 是 `unknown`），只能看扩展名。
  static const Set<String> subtitleExtensions = <String>{
    'srt',
    'vtt',
    'ass',
    'ssa',
    'lrc',
  };

  String get extension {
    final int dot = filename.lastIndexOf('.');
    return dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  }

  bool get isSubtitle => subtitleExtensions.contains(extension);

  static AudiobookshelfLibraryFile? parse(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final String? ino = _nonEmpty(raw['ino']);
    final Object? rawMetadata = raw['metadata'];
    if (ino == null || rawMetadata is! Map<String, Object?>) return null;
    final String? filename = _nonEmpty(rawMetadata['filename']);
    if (filename == null) return null;
    return AudiobookshelfLibraryFile(
      ino: ino,
      filename: filename,
      relPath: _nonEmpty(rawMetadata['relPath']),
      sizeBytes: _num(rawMetadata['size'])?.toInt(),
      fileType: _nonEmpty(raw['fileType']),
    );
  }
}

/// 章节（时间单位秒，沿用服务端）。
class AudiobookshelfChapter {
  const AudiobookshelfChapter({
    required this.startSeconds,
    required this.endSeconds,
    required this.title,
  });

  final double startSeconds;
  final double endSeconds;
  final String title;

  static List<AudiobookshelfChapter> parseList(Object? raw) {
    if (raw is! List) return const <AudiobookshelfChapter>[];
    return <AudiobookshelfChapter>[
      for (final Object? entry in raw)
        if (entry is Map<String, Object?>)
          AudiobookshelfChapter(
            startSeconds: _num(entry['start'])?.toDouble() ?? 0,
            endSeconds: _num(entry['end'])?.toDouble() ?? 0,
            title: _str(entry['title']) ?? '',
          ),
    ];
  }
}

/// 播客单集。音频就是它自己的 `audioFile`，没有累计偏移（恒为单轨）。
class AudiobookshelfEpisode {
  const AudiobookshelfEpisode({
    required this.id,
    required this.itemId,
    required this.title,
    required this.track,
    this.index,
    this.season,
    this.episode,
    this.pubDate,
    this.publishedAtMs,
  });

  final String id;
  final String itemId;
  final String title;
  final int? index;
  final String? season;
  final String? episode;
  final String? pubDate;
  final int? publishedAtMs;

  /// 单集的音频轨（`startOffsetMs` 恒为 0）。
  final AudiobookshelfTrack track;

  static AudiobookshelfEpisode? parse(Object? raw, {required String itemId}) {
    if (raw is! Map<String, Object?>) return null;
    final String? id = _nonEmpty(raw['id']);
    final Object? audioFile = raw['audioFile'];
    if (id == null || audioFile is! Map<String, Object?>) return null;
    final AudiobookshelfTrack? track = AudiobookshelfTrack.parse(
      audioFile,
      itemId: itemId,
      fallbackIndex: 1,
      fallbackStartOffsetMs: 0,
    );
    if (track == null) return null;
    return AudiobookshelfEpisode(
      id: id,
      itemId: itemId,
      title: _nonEmpty(raw['title']) ?? id,
      index: _num(raw['index'])?.toInt(),
      season: _nonEmpty(raw['season']),
      episode: _nonEmpty(raw['episode']),
      pubDate: _nonEmpty(raw['pubDate']),
      publishedAtMs: _num(raw['publishedAt'])?.toInt(),
      // 展开形状的单集可能带 audioTrack.startOffset：单集音轨起点固定为 0。
      track: AudiobookshelfTrack(
        index: 1,
        ino: track.ino,
        itemId: itemId,
        durationMs: track.durationMs,
        startOffsetMs: 0,
        mimeType: track.mimeType,
        sizeBytes: track.sizeBytes,
        filename: track.filename,
      ),
    );
  }
}

/// 某条目 / 单集的收听进度（`/api/me/progress`、`userMediaProgress`）。
class AudiobookshelfMediaProgress {
  const AudiobookshelfMediaProgress({
    required this.currentTimeSeconds,
    required this.durationSeconds,
    required this.isFinished,
    this.progress,
    this.lastUpdateMs,
    this.episodeId,
  });

  final double currentTimeSeconds;
  final double durationSeconds;
  final bool isFinished;
  final double? progress;
  final int? lastUpdateMs;
  final String? episodeId;

  static AudiobookshelfMediaProgress? parse(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    return AudiobookshelfMediaProgress(
      currentTimeSeconds: _num(raw['currentTime'])?.toDouble() ?? 0,
      durationSeconds: _num(raw['duration'])?.toDouble() ?? 0,
      isFinished: raw['isFinished'] == true,
      progress: _num(raw['progress'])?.toDouble(),
      lastUpdateMs: _num(raw['lastUpdate'])?.toInt(),
      episodeId: _nonEmpty(raw['episodeId']),
    );
  }
}

/// 条目详情（`GET /api/items/:id`）：基础字段 + 音轨 / 文件 / 章节 / 单集 / 进度。
class AudiobookshelfItemDetail {
  const AudiobookshelfItemDetail({
    required this.item,
    required this.tracks,
    required this.libraryFiles,
    required this.chapters,
    required this.episodes,
    this.progress,
  });

  final AudiobookshelfItem item;

  /// 书的音轨；播客为空（音频在 [episodes] 里）。
  final List<AudiobookshelfTrack> tracks;
  final List<AudiobookshelfLibraryFile> libraryFiles;
  final List<AudiobookshelfChapter> chapters;
  final List<AudiobookshelfEpisode> episodes;
  final AudiobookshelfMediaProgress? progress;

  bool get isPodcast => item.mediaType == 'podcast';

  /// 服务器上随条目存放的字幕文件。
  List<AudiobookshelfLibraryFile> get subtitleFiles =>
      <AudiobookshelfLibraryFile>[
        for (final AudiobookshelfLibraryFile file in libraryFiles)
          if (file.isSubtitle) file,
      ];

  static AudiobookshelfItemDetail? parse(Object? raw) {
    final AudiobookshelfItem? item = AudiobookshelfItem.parse(raw);
    if (item == null || raw is! Map<String, Object?>) return null;
    final Object? rawMedia = raw['media'];
    final Map<String, Object?> media = rawMedia is Map<String, Object?>
        ? rawMedia
        : const <String, Object?>{};
    final Object? files = raw['libraryFiles'];
    final Object? episodes = media['episodes'];
    return AudiobookshelfItemDetail(
      item: item,
      tracks: AudiobookshelfTrack.parseList(media, itemId: item.id),
      libraryFiles: <AudiobookshelfLibraryFile>[
        if (files is List)
          for (final Object? entry in files)
            if (AudiobookshelfLibraryFile.parse(entry)
                case final AudiobookshelfLibraryFile file)
              file,
      ],
      chapters: AudiobookshelfChapter.parseList(media['chapters']),
      episodes: <AudiobookshelfEpisode>[
        if (episodes is List)
          for (final Object? entry in episodes)
            if (AudiobookshelfEpisode.parse(entry, itemId: item.id)
                case final AudiobookshelfEpisode episode)
              episode,
      ],
      progress: AudiobookshelfMediaProgress.parse(raw['userMediaProgress']),
    );
  }
}

/// `POST /api/items/:id/play` 开出的播放会话。
class AudiobookshelfPlaySession {
  const AudiobookshelfPlaySession({
    required this.id,
    required this.itemId,
    required this.tracks,
    required this.currentTimeSeconds,
    required this.durationSeconds,
    this.episodeId,
  });

  final String id;
  final String itemId;
  final String? episodeId;
  final List<AudiobookshelfTrack> tracks;

  /// 服务端记的续播位置（整本书时间轴上的秒数）。
  final double currentTimeSeconds;
  final double durationSeconds;

  static AudiobookshelfPlaySession? parse(Map<String, Object?> json) {
    final String? id = _nonEmpty(json['id']);
    final String? itemId = _nonEmpty(json['libraryItemId']);
    if (id == null || itemId == null) return null;
    final Object? rawTracks = json['audioTracks'];
    final List<AudiobookshelfTrack> tracks = <AudiobookshelfTrack>[];
    int offset = 0;
    if (rawTracks is List) {
      for (final Object? entry in rawTracks) {
        final AudiobookshelfTrack? track = AudiobookshelfTrack.parse(
          entry,
          itemId: itemId,
          fallbackIndex: tracks.length + 1,
          fallbackStartOffsetMs: offset,
        );
        if (track == null) continue;
        tracks.add(track);
        offset = track.endOffsetMs;
      }
    }
    return AudiobookshelfPlaySession(
      id: id,
      itemId: itemId,
      episodeId: _nonEmpty(json['episodeId']),
      tracks: tracks,
      currentTimeSeconds:
          (_num(json['currentTime']) ?? _num(json['startTime']))?.toDouble() ??
          0,
      durationSeconds: _num(json['duration'])?.toDouble() ?? 0,
    );
  }
}

/// 「继续收听」里的一项：条目 + （播客时）最近收听的那一集。
class AudiobookshelfInProgressEntry {
  const AudiobookshelfInProgressEntry({
    required this.item,
    this.episodeId,
    this.episodeTitle,
  });

  final AudiobookshelfItem item;
  final String? episodeId;
  final String? episodeTitle;

  static List<AudiobookshelfInProgressEntry> parseList(
    Map<String, Object?> json,
  ) {
    final Object? raw = json['libraryItems'];
    if (raw is! List) return const <AudiobookshelfInProgressEntry>[];
    return <AudiobookshelfInProgressEntry>[
      for (final Object? entry in raw)
        if (AudiobookshelfItem.parse(entry) case final AudiobookshelfItem item)
          AudiobookshelfInProgressEntry(
            item: item,
            episodeId: _recentEpisodeField(entry, 'id'),
            episodeTitle: _recentEpisodeField(entry, 'title'),
          ),
    ];
  }

  static String? _recentEpisodeField(Object? entry, String field) {
    if (entry is! Map<String, Object?>) return null;
    final Object? episode = entry['recentEpisode'];
    return episode is Map<String, Object?> ? _nonEmpty(episode[field]) : null;
  }
}

/// 解码 JWT 的 `exp`（秒 → [DateTime]）。API key / 旧版永久 token / 非 JWT
/// 都没有可用的 `exp`，返回 null（调用方当作「不知道何时过期」）。
DateTime? audiobookshelfTokenExpiry(String token) {
  final List<String> parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final Object? payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is! Map<String, Object?>) return null;
    final num? exp = _num(payload['exp']);
    if (exp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (exp * 1000).round(),
      isUtc: true,
    );
  } on FormatException {
    return null;
  }
}

String? _str(Object? value) => value is String ? value : null;

String? _nonEmpty(Object? value) {
  if (value is num) return '$value';
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 数字字段宽容解析：ABS 回显的分页参数是查询串原值（字符串）。
num? _num(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim());
  return null;
}
