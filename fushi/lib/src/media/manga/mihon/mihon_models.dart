import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 一个扩展 APK 承载的媒体种类。
///
/// Mihon（漫画）与 Aniyomi（视频）扩展共用 APK 打包、仓库索引格式、宿主运行时与
/// 安装/信任/偏好基础设施，只在 manifest feature（`tachiyomi.extension` /
/// `tachiyomi.animeextension`）与源接口（`Source` / `AnimeSource`）上分岔。
/// 持久化值 [dbValue] 落 `manga_extension_stores` / `manga_extensions` /
/// `manga_online_sources` 三表的 `media_kind` 列（v107），表名冻结不追改。
enum MihonMediaKind {
  manga('manga'),
  anime('anime');

  const MihonMediaKind(this.dbValue);

  final String dbValue;

  static MihonMediaKind fromDbValue(String? value) => switch (value) {
    'anime' => MihonMediaKind.anime,
    _ => MihonMediaKind.manga,
  };

  /// 桌面 sidecar `/inspect` 与 Android `inspectExtension` 回传的 `kind`。
  static MihonMediaKind fromInspectionJson(Object? value) =>
      fromDbValue(value?.toString());

  /// 本生态可安装的 extensions-lib 版本标签（`MihonExtensionInspection.libVersion`）。
  ///
  /// 漫画：Mihon 1.4 / 1.6。视频：Aniyomi **14 / 15 / 16**——桌面 sidecar 与 Android
  /// 宿主编入的 `animesource` ABI（`third_party/m_extension_server/overlay`）是 lib 14
  /// 与 lib 16 的并集：老构造 `Video(url, quality, videoUrl, …)` + `getVideoList(episode)`
  /// 与新 data class `Video(videoUrl, videoTitle, resolution, …)` + Hoster API +
  /// `SEpisode.fillermark` / `SAnime.fetch_type` 同时存在。yuzono / Anikku 仓库里
  /// versionName 仍写 14 的 APK，dex 实际编译目标已是 lib 16 面（实测 KickAssAnime
  /// 在纯 lib 14 宿主上 `NoSuchMethodError: Video.getVideoTitle()`、AniDB 写
  /// `fillermark`），所以版本标签本身从不决定能不能播；只有 14..16 之外的世代才拒。
  List<String> get supportedLibVersions => switch (this) {
    MihonMediaKind.manga => const <String>['1.4', '1.6'],
    MihonMediaKind.anime => const <String>['14', '15', '16'],
  };
}

@immutable
class MihonCapabilities {
  const MihonCapabilities({
    required this.bridgeVersion,
    required this.sourceFactory,
    required this.preferenceCallbacks,
    required this.imageProxy,
    required this.sourceUrls,
  });

  factory MihonCapabilities.fromJson(Map<String, Object?> json) =>
      MihonCapabilities(
        bridgeVersion:
            (json['fushiMihonBridge'] ?? json['mangatanMihonBridge'] ?? 0)
                as int,
        sourceFactory: json['sourceFactory'] == true,
        preferenceCallbacks: json['preferenceCallbacks'] == true,
        imageProxy: json['imageProxy'] == true,
        sourceUrls: json['sourceUrls'] == true,
      );

  final int bridgeVersion;
  final bool sourceFactory;
  final bool preferenceCallbacks;
  final bool imageProxy;
  final bool sourceUrls;

  bool get isUsable =>
      bridgeVersion >= 1 &&
      sourceFactory &&
      preferenceCallbacks &&
      imageProxy &&
      sourceUrls;
}

@immutable
class MihonExtensionInspection {
  const MihonExtensionInspection({
    required this.packageName,
    required this.name,
    required this.apkVersionCode,
    required this.versionName,
    required this.libVersion,
    required this.signerSha256,
    required this.sourceClasses,
    this.kind = MihonMediaKind.manga,
  });

  factory MihonExtensionInspection.fromJson(Map<String, Object?> json) =>
      MihonExtensionInspection(
        packageName: json['packageName']! as String,
        name: json['name']! as String,
        apkVersionCode: (json['versionCode']! as num).toInt(),
        versionName: json['versionName']! as String,
        libVersion: json['libVersion']! as String,
        signerSha256: json['signerSha256']! as String,
        sourceClasses:
            (json['sourceClasses'] as List<Object?>? ?? const <Object?>[])
                .cast<String>(),
        // 旧宿主（没有 kind 字段）只认漫画扩展，缺省即漫画。
        kind: MihonMediaKind.fromInspectionJson(json['kind']),
      );

  final String packageName;
  final String name;

  /// APK manifest 的 `android:versionCode`。名字只标**出处**（来自 APK），不标尺度。
  ///
  /// 与仓库索引的 [MihonAvailableExtension.extensionVersionCode] **是同一个量**，
  /// 可直接比较。BUG-1996 一度写成「两侧不同尺度、索引是裸的 69、APK 是 104069」，
  /// 那是错的：keiyoushi 两侧都由 gradle 的同一个 `androidVersionCodeProvider`
  /// 产出（`ExtensionPlugin.kt` 同时喂给 APK output 与索引元数据），实测
  /// `repo/index.pb` 的 field 5 与 APK 的 `android:versionCode` 逐字相同：
  /// SamuraiScan 两侧都是 104069、Manga Mura 两侧都是 104005。
  ///
  /// DB 里 `manga_extensions.versionCode` 存的也是它（列名冻结），所以身份门、
  /// 降级门 `DOWNGRADE_REJECTED`、「有更新」角标三处两侧同量、自洽。
  final int apkVersionCode;
  final String versionName;
  final String libVersion;
  final String signerSha256;
  final List<String> sourceClasses;

  /// 由 APK manifest 的源类元数据判定（`tachiyomi.extension.class` /
  /// `tachiyomi.animeextension.class`），不看包名。
  final MihonMediaKind kind;
}

@immutable
class MihonExtensionRef {
  const MihonExtensionRef({required this.packageName, required this.apkPath});

  final String packageName;
  final String apkPath;
}

@immutable
class MihonSource {
  const MihonSource({
    required this.extensionPackage,
    required this.id,
    required this.name,
    required this.language,
    required this.baseUrl,
  });

  factory MihonSource.fromJson(
    String extensionPackage,
    Map<String, Object?> json,
  ) => MihonSource(
    extensionPackage: extensionPackage,
    id: json['id'].toString(),
    name: json['name']?.toString() ?? '',
    language: (json['lang'] ?? json['language'])?.toString() ?? '',
    baseUrl: (json['baseUrl'] ?? json['homeUrl'])?.toString() ?? '',
  );

  final String extensionPackage;
  final String id;
  final String name;
  final String language;
  final String baseUrl;
}

/// 源浏览网格里的一张卡：漫画作品与视频作品在网格上长得一样（封面 + 标题，
/// 以源内 `url` 为身份），浏览页按它渲染、按具体类型分派详情页。
abstract interface class MihonCatalogueEntry {
  String get url;
  String get title;
  String? get coverUrl;
}

@immutable
class MihonManga implements MihonCatalogueEntry {
  const MihonManga({
    required this.url,
    required this.title,
    this.coverUrl,
    this.artist,
    this.author,
    this.description,
    this.genre,
    this.status = 0,
    this.initialized = false,
  });

  factory MihonManga.fromJson(Map<String, Object?> json) => MihonManga(
    url: json['url']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    coverUrl: (json['thumbnail_url'] ?? json['coverUrl'])?.toString(),
    artist: json['artist']?.toString(),
    author: json['author']?.toString(),
    description: json['description']?.toString(),
    genre: json['genre']?.toString(),
    status: (json['status'] as num?)?.toInt() ?? 0,
    initialized: json['initialized'] == true,
  );

  @override
  final String url;
  @override
  final String title;
  @override
  final String? coverUrl;
  final String? artist;
  final String? author;
  final String? description;
  final String? genre;
  final int status;
  final bool initialized;

  /// 把一次详情拉取的结果合回本条目。
  ///
  /// Mihon 的详情解析返回的是**增量**：`url` 是条目身份，扩展从不
  /// 回填，上游官方 app 也从不读它。两个后端各自暴露了这个假设：
  /// Android 原生桥直接读 `lateinit url` 而崩（RUNTIME_FAILURE），桌面
  /// sidecar 则把它静默读成空串，导致接下来拉章节用空 url（BUG-1767）。
  ///
  /// 所以身份统一在这里收敛：新值只能覆盖元数据，覆盖不了 `url`。
  MihonManga mergedWithDetails(MihonManga update) => MihonManga(
    url: url,
    title: update.title.isNotEmpty ? update.title : title,
    coverUrl: update.coverUrl ?? coverUrl,
    artist: update.artist ?? artist,
    author: update.author ?? author,
    description: update.description ?? description,
    genre: update.genre ?? genre,
    status: update.status != 0 ? update.status : status,
    initialized: update.initialized || initialized,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'title': title,
    'thumbnail_url': coverUrl,
    'artist': artist,
    'author': author,
    'description': description,
    'genre': genre,
    'status': status,
    'initialized': initialized,
  };
}

@immutable
class MihonMangaPage {
  const MihonMangaPage({required this.items, required this.hasNextPage});

  factory MihonMangaPage.fromJson(Map<String, Object?> json) => MihonMangaPage(
    items: (json['mangas'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(
          (Map<Object?, Object?> value) =>
              MihonManga.fromJson(value.cast<String, Object?>()),
        )
        .toList(growable: false),
    hasNextPage: json['hasNextPage'] == true,
  );

  final List<MihonManga> items;
  final bool hasNextPage;
}

@immutable
class MihonChapter {
  const MihonChapter({
    required this.url,
    required this.name,
    required this.uploadedAt,
    required this.number,
    this.scanlator,
  });

  factory MihonChapter.fromJson(Map<String, Object?> json) => MihonChapter(
    url: json['url']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    uploadedAt: (json['date_upload'] as num?)?.toInt() ?? 0,
    number: (json['chapter_number'] as num?)?.toDouble() ?? 0,
    scanlator: json['scanlator']?.toString(),
  );

  final String url;
  final String name;
  final int uploadedAt;
  final double number;
  final String? scanlator;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'name': name,
    'date_upload': uploadedAt,
    'chapter_number': number,
    'scanlator': scanlator,
  };
}

@immutable
class MihonPage {
  const MihonPage({required this.index, required this.url, this.imageUrl});

  factory MihonPage.fromJson(Map<String, Object?> json) => MihonPage(
    index: (json['index'] as num?)?.toInt() ?? 0,
    url: json['url']?.toString() ?? '',
    imageUrl: json['imageUrl']?.toString(),
  );

  final int index;
  final String url;
  final String? imageUrl;

  String get resolvedUrl => imageUrl?.isNotEmpty == true ? imageUrl! : url;
}

enum MihonFilterKind {
  header,
  separator,
  select,
  text,
  checkBox,
  triState,
  group,
  sort,
  unsupported,
}

@immutable
class MihonFilter {
  const MihonFilter({
    required this.name,
    required this.kind,
    this.state,
    this.values = const <String>[],
    this.children = const <MihonFilter>[],
  });

  final String name;
  final MihonFilterKind kind;
  final Object? state;
  final List<String> values;
  final List<MihonFilter> children;

  Map<String, Object?> toBridgeJson() {
    final Map<Object?, Object?>? sortState = state is Map<Object?, Object?>
        ? state as Map<Object?, Object?>
        : null;
    return <String, Object?>{
      'name': name,
      'type': kind.name,
      if (state is String) 'stateString': state,
      if (state is int) 'stateInt': state,
      if (kind == MihonFilterKind.checkBox)
        'stateList': <Map<String, Object?>>[
          <String, Object?>{'name': name, 'stateBoolean': state == true},
        ],
      if (kind == MihonFilterKind.sort)
        'stateSort': <String, Object?>{
          'index': (sortState?['index'] as num?)?.toInt() ?? 0,
          'ascending': sortState?['ascending'] != false,
        },
      if (children.isNotEmpty)
        'stateList': children
            .map(
              (MihonFilter child) => <String, Object?>{
                'name': child.name,
                'type': child.kind.name,
                if (child.state is bool) 'stateBoolean': child.state,
                if (child.state is int) 'stateInt': child.state,
                if (child.state is String) 'stateString': child.state,
              },
            )
            .toList(growable: false),
    };
  }
}

enum MihonPreferenceKind {
  checkBox,
  switchControl,
  text,
  list,
  multiSelect,
  unsupported,
}

@immutable
class MihonPreference {
  const MihonPreference({
    required this.key,
    required this.kind,
    required this.title,
    required this.value,
    this.summary = '',
    this.entries = const <String>[],
    this.entryValues = const <String>[],
  });

  factory MihonPreference.fromBridgeJson(Map<String, Object?> json) {
    const Map<String, MihonPreferenceKind> kinds =
        <String, MihonPreferenceKind>{
          'checkBoxPreference': MihonPreferenceKind.checkBox,
          'switchPreferenceCompat': MihonPreferenceKind.switchControl,
          'editTextPreference': MihonPreferenceKind.text,
          'listPreference': MihonPreferenceKind.list,
          'multiSelectListPreference': MihonPreferenceKind.multiSelect,
        };
    final String payloadKey = kinds.keys.firstWhere(
      json.containsKey,
      orElse: () => '',
    );
    final Map<String, Object?> props =
        (json[payloadKey] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, Object?>();
    final MihonPreferenceKind decodedKind =
        kinds[payloadKey] ?? MihonPreferenceKind.unsupported;
    final List<String> entries =
        (props['entries'] as List<Object?>? ?? const <Object?>[])
            .map((Object? entry) => entry.toString())
            .toList(growable: false);
    final List<String> entryValues =
        (props['entryValues'] as List<Object?>? ?? const <Object?>[])
            .map((Object? entry) => entry.toString())
            .toList(growable: false);
    final MihonPreferenceKind kind =
        (decodedKind == MihonPreferenceKind.list && entries.isEmpty) ||
            (decodedKind == MihonPreferenceKind.multiSelect &&
                (entries.isEmpty || entryValues.length != entries.length))
        ? MihonPreferenceKind.unsupported
        : decodedKind;
    final Object? value = switch (kind) {
      MihonPreferenceKind.checkBox ||
      MihonPreferenceKind.switchControl => props['value'] ?? false,
      MihonPreferenceKind.text => props['value'] ?? '',
      MihonPreferenceKind.list => props['valueIndex'] ?? 0,
      MihonPreferenceKind.multiSelect =>
        (props['values'] as List<Object?>? ?? const <Object?>[])
            .map((Object? value) => value.toString())
            .toList(growable: false),
      MihonPreferenceKind.unsupported => null,
    };
    return MihonPreference(
      key: json['key']?.toString() ?? '',
      kind: kind,
      title: props['title']?.toString() ?? json['key']?.toString() ?? '',
      summary: props['summary']?.toString() ?? '',
      value: value,
      entries: entries,
      entryValues: entryValues,
    );
  }

  final String key;
  final MihonPreferenceKind kind;
  final String title;
  final String summary;
  final Object? value;
  final List<String> entries;
  final List<String> entryValues;

  String encodeValue() => jsonEncode(value);

  Map<String, Object?> toBridgeJson() {
    final String payloadKey = switch (kind) {
      MihonPreferenceKind.checkBox => 'checkBoxPreference',
      MihonPreferenceKind.switchControl => 'switchPreferenceCompat',
      MihonPreferenceKind.text => 'editTextPreference',
      MihonPreferenceKind.list => 'listPreference',
      MihonPreferenceKind.multiSelect => 'multiSelectListPreference',
      MihonPreferenceKind.unsupported => 'unsupportedPreference',
    };
    return <String, Object?>{
      'key': key,
      payloadKey: <String, Object?>{
        'title': title,
        'summary': summary,
        if (kind == MihonPreferenceKind.checkBox ||
            kind == MihonPreferenceKind.switchControl ||
            kind == MihonPreferenceKind.text)
          'value': value,
        if (kind == MihonPreferenceKind.list) 'valueIndex': value,
        if (kind == MihonPreferenceKind.multiSelect) 'values': value,
        if (entries.isNotEmpty) 'entries': entries,
        if (entryValues.isNotEmpty) 'entryValues': entryValues,
      },
    };
  }
}

class MihonRuntimeException implements Exception {
  const MihonRuntimeException(
    this.code,
    this.message, {
    this.cause,
    this.details,
  });

  final String code;
  final String message;
  final Object? cause;

  /// 原生侧回传的完整堆栈（`PlatformException.details`）。
  ///
  /// 不进 [toString]：它会被直接渲染到页面上，几 KB 堆栈堆到
  /// 屏幕上反而把真正可操作的 [message] 顶掉。堆栈只走诊断对话框
  /// 和日志（见 [diagnostics]）。
  final String? details;

  /// 诊断通道（可复制对话框 / 日志）用的全文。
  String get diagnostics {
    final String? stack = details;
    if (stack == null || stack.isEmpty) return toString();
    return '${toString()}\n\n$stack';
  }

  @override
  String toString() => 'MihonRuntimeException($code): $message';
}

class MihonCloudflareChallengeException extends MihonRuntimeException {
  const MihonCloudflareChallengeException(
    this.url, {
    this.userAgent,
    super.cause,
    super.details,
  }) : super(
         'CLOUDFLARE_CHALLENGE_REQUIRED',
         'Source requires browser verification',
       );

  final Uri url;
  final String? userAgent;
}

/// Aniyomi 扩展的作品条目（sidecar `JAnime` / Android `SAnime` 桥接形状）。
///
/// 与 [MihonManga] 逐字段同构（上游两套模型本就是复制的），但刻意不共用一个类：
/// 视频侧的调用面（剧集/取流）不该拿到一个叫「manga」的类型，两边各自演进也不
/// 会互相牵连。
@immutable
class MihonAnime implements MihonCatalogueEntry {
  const MihonAnime({
    required this.url,
    required this.title,
    this.coverUrl,
    this.artist,
    this.author,
    this.description,
    this.genre,
    this.status = 0,
    this.initialized = false,
  });

  factory MihonAnime.fromJson(Map<String, Object?> json) => MihonAnime(
    url: json['url']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    coverUrl: (json['thumbnail_url'] ?? json['coverUrl'])?.toString(),
    artist: json['artist']?.toString(),
    author: json['author']?.toString(),
    description: json['description']?.toString(),
    genre: json['genre']?.toString(),
    status: (json['status'] as num?)?.toInt() ?? 0,
    initialized: json['initialized'] == true,
  );

  @override
  final String url;
  @override
  final String title;
  @override
  final String? coverUrl;
  final String? artist;
  final String? author;
  final String? description;
  final String? genre;
  final int status;
  final bool initialized;

  /// 同 [MihonManga.mergedWithDetails]：详情是增量，身份 `url` 只来自入参。
  MihonAnime mergedWithDetails(MihonAnime update) => MihonAnime(
    url: url,
    title: update.title.isNotEmpty ? update.title : title,
    coverUrl: update.coverUrl ?? coverUrl,
    artist: update.artist ?? artist,
    author: update.author ?? author,
    description: update.description ?? description,
    genre: update.genre ?? genre,
    status: update.status != 0 ? update.status : status,
    initialized: update.initialized || initialized,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'title': title,
    'thumbnail_url': coverUrl,
    'artist': artist,
    'author': author,
    'description': description,
    'genre': genre,
    'status': status,
    'initialized': initialized,
  };
}

@immutable
class MihonAnimePage {
  const MihonAnimePage({required this.items, required this.hasNextPage});

  factory MihonAnimePage.fromJson(Map<String, Object?> json) => MihonAnimePage(
    items: (json['animes'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(
          (Map<Object?, Object?> value) =>
              MihonAnime.fromJson(value.cast<String, Object?>()),
        )
        .toList(growable: false),
    hasNextPage: json['hasNextPage'] == true,
  );

  final List<MihonAnime> items;
  final bool hasNextPage;
}

/// 一集（sidecar `JEpisode` / Android `SEpisode`）。`url` 是源内稳定身份。
@immutable
class MihonEpisode {
  const MihonEpisode({
    required this.url,
    required this.name,
    required this.uploadedAt,
    required this.number,
    this.scanlator,
  });

  factory MihonEpisode.fromJson(Map<String, Object?> json) => MihonEpisode(
    url: json['url']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    uploadedAt: (json['date_upload'] as num?)?.toInt() ?? 0,
    number: (json['episode_number'] as num?)?.toDouble() ?? 0,
    scanlator: json['scanlator']?.toString(),
  );

  final String url;
  final String name;
  final int uploadedAt;
  final double number;
  final String? scanlator;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'name': name,
    'date_upload': uploadedAt,
    'episode_number': number,
    'scanlator': scanlator,
  };
}

/// 一条外挂字幕/音轨（Aniyomi `Track`）。
@immutable
class MihonVideoTrack {
  const MihonVideoTrack({required this.url, required this.lang});

  factory MihonVideoTrack.fromJson(Map<String, Object?> json) =>
      MihonVideoTrack(
        url: json['url']?.toString() ?? '',
        lang: json['lang']?.toString() ?? '',
      );

  final String url;

  /// 扩展给的语言**标签**（如 `日本語` / `English`），不是 BCP-47 码。
  final String lang;
}

/// 一集的一个可播候选（Aniyomi lib 14 `Video`，经 sidecar/Android 投影后的五字段）。
///
/// 一集通常回多条：不同画质、不同 hoster。播放器要的是 [resolvedUrl] + [headers]
/// （站点防盗链几乎都靠 Referer/User-Agent）；[quality] 只是给用户挑的标签。
@immutable
class MihonVideo {
  const MihonVideo({
    required this.url,
    required this.quality,
    this.videoUrl,
    this.resolution,
    this.bitrate,
    this.preferred = false,
    this.headers = const <String, String>{},
    this.subtitleTracks = const <MihonVideoTrack>[],
    this.audioTracks = const <MihonVideoTrack>[],
    this.mpvArgs = const <MapEntry<String, String>>[],
  });

  /// 宿主投影（sidecar `DalvikHandler.Video.toBridgeMap` / Android
  /// `MihonModelBridge.Video.toBridgeMap`）：lib 14 的 `url` / `quality` /
  /// `videoUrl` 与 lib 16 的 `videoTitle` / `resolution` / `bitrate` / `preferred`
  /// 并存；`quality` 缺省时取 `videoTitle`，反之亦然。
  factory MihonVideo.fromJson(Map<String, Object?> json) {
    final String quality = json['quality']?.toString() ?? '';
    final String videoTitle = json['videoTitle']?.toString() ?? '';
    final String? videoUrl = json['videoUrl']?.toString();
    return MihonVideo(
      url: json['url']?.toString() ?? '',
      quality: quality.isNotEmpty ? quality : videoTitle,
      videoUrl: videoUrl == null || videoUrl.isEmpty || videoUrl == 'null'
          ? null
          : videoUrl,
      resolution: (json['resolution'] as num?)?.toInt(),
      bitrate: (json['bitrate'] as num?)?.toInt(),
      preferred: json['preferred'] == true,
      headers: (json['headers'] as Map<Object?, Object?>? ?? const {}).map(
        (Object? key, Object? value) =>
            MapEntry<String, String>(key.toString(), value?.toString() ?? ''),
      ),
      subtitleTracks: _tracks(json['subtitleTracks']),
      audioTracks: _tracks(json['audioTracks']),
      mpvArgs: _mpvArgs(json['mpvArgs']),
    );
  }

  static List<MapEntry<String, String>> _mpvArgs(Object? value) =>
      (value as List<Object?>? ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> item) => MapEntry<String, String>(
              item['key']?.toString() ?? '',
              item['value']?.toString() ?? '',
            ),
          )
          .where((MapEntry<String, String> entry) => entry.key.isNotEmpty)
          .toList(growable: false);

  static List<MihonVideoTrack> _tracks(Object? value) =>
      (value as List<Object?>? ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> item) =>
                MihonVideoTrack.fromJson(item.cast<String, Object?>()),
          )
          .where((MihonVideoTrack track) => track.url.isNotEmpty)
          .toList(growable: false);

  /// lib 14 的页面 / embed 地址；宿主已做过 `getVideoUrl` 解析，这里只作展示与回退。
  final String url;

  /// 显示名（lib 14 `quality` / lib 16 `videoTitle`）。
  final String quality;

  /// 可播地址。宿主（`AnimeVideoLoader`）已把 `resolveVideo` / `getVideoUrl` 跑完，
  /// 解析不出的候选不会过桥，所以到这里恒非空；null 只剩测试 fake 会造出来。
  final String? videoUrl;

  /// lib 16 扩展自报的行数（`resolution`）；lib 14 只能从 [quality] 文本猜。
  final int? resolution;
  final int? bitrate;

  /// lib 16：扩展按用户偏好标出的首选候选（可多条为 true），选流时优先于行数。
  final bool preferred;
  final Map<String, String> headers;
  final List<MihonVideoTrack> subtitleTracks;
  final List<MihonVideoTrack> audioTracks;

  /// lib 16：扩展要求附加给 mpv 的选项（`http-header-fields` 之类），本期只透传记录。
  final List<MapEntry<String, String>> mpvArgs;

  /// 直接交给播放器的地址。
  String get resolvedUrl {
    final String? direct = videoUrl;
    return direct != null && direct.isNotEmpty && direct != 'null'
        ? direct
        : url;
  }

  /// 行数：lib 16 自报的 [resolution] 优先，否则从画质标签解（`1080p` → 1080；
  /// `Auto` / hoster 名 → null），供选流排序。
  int? get resolutionHint {
    final int? declared = resolution;
    if (declared != null && declared > 0) return declared;
    final RegExpMatch? match = RegExp(r'(\d{3,4})\s*[pP]').firstMatch(quality);
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}
