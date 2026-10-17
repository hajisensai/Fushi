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
      authorName: _nonEmpty(metadata['authorName']),
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
List<AudiobookshelfItem> parseAudiobookshelfSearch(Map<String, Object?> json) {
  final Object? books = json['book'];
  if (books is! List) return const <AudiobookshelfItem>[];
  return <AudiobookshelfItem>[
    for (final Object? match in books)
      if (match is Map<String, Object?>)
        if (AudiobookshelfItem.parse(match['libraryItem'])
            case final AudiobookshelfItem item)
          item,
  ];
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
