/// 音乐插件的清单与能力返回值（契约见 docs/specs/2026-10-28-music-plugins.md §2 / §4）。
///
/// 插件返回的是不可信数据：解析一律宽容——类型不对的字段当缺失，缺 `id` / 标题的实体整条丢弃，
/// 不因一条坏数据让整页失败；但能力返回值整体形状不对（比如 search 没有 items）按插件错误处理。
library;

/// 插件调用失败（插件抛错、返回值形状不对、运行时被终止）。[message] 可以直接给用户看。
final class MusicPluginException implements Exception {
  const MusicPluginException(this.message, {this.pluginId});

  final String message;
  final String? pluginId;

  @override
  String toString() => 'MusicPluginException(${pluginId ?? '?'}): $message';
}

/// 插件此刻不可用的原因（[MusicPluginUnavailableException]）。
enum MusicPluginUnavailableReason {
  /// 没装（或已卸载 / 正在卸载）。
  notInstalled,

  /// 用户在设置里停用了。
  disabled,
}

/// 调用了没装 / 已停用的插件：管理器拒绝开实例，不碰插件代码（队列里留着的旧插件曲目、
/// 设置页停用后仍在显示的页面都会走到这里）。
final class MusicPluginUnavailableException extends MusicPluginException {
  const MusicPluginUnavailableException(
    super.message, {
    required String super.pluginId,
    required this.reason,
  });

  final MusicPluginUnavailableReason reason;

  @override
  String toString() =>
      'MusicPluginUnavailableException($pluginId, ${reason.name}): $message';
}

/// 插件能力调用超过墙钟时限（插件自己一直不 resolve / 卡在宿主调用上）：该次调用作废，
/// 晚到的结果丢弃；实例本身不判死（CPU 超预算才判死，那由运行时负责）。
final class MusicPluginTimeoutException extends MusicPluginException {
  const MusicPluginTimeoutException(
    super.message, {
    required String super.pluginId,
    required this.method,
    required this.timeout,
  });

  final String method;
  final Duration timeout;

  @override
  String toString() =>
      'MusicPluginTimeoutException($pluginId, $method, ${timeout.inSeconds}s)';
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _int(Object? v) => v is num && v.isFinite ? v.toInt() : null;
bool? _bool(Object? v) => v is bool ? v : null;
List<Object?> _list(Object? v) => v is List<Object?> ? v : const <Object?>[];
Map<String, Object?> _map(Object? v) => v is Map<Object?, Object?>
    ? v.cast<String, Object?>()
    : const <String, Object?>{};
List<String> _strings(Object? v) => <String>[
  for (final Object? x in _list(v))
    if (x is String) x,
];

/// 不可信展示文本：去首尾空白，空串当缺失，超过 [max] 个字符（按码点）截断。
String? _text(Object? v, int max) {
  if (v is! String) return null;
  final String s = v.trim();
  if (s.isEmpty) return null;
  final List<int> runes = s.runes.take(max + 1).toList();
  return runes.length > max ? String.fromCharCodes(runes.take(max)) : s;
}

/// 计数：非负整数，否则当缺失。
int? _count(Object? v) {
  final int? n = _int(v);
  return n != null && n >= 0 ? n : null;
}

/// 文本列表：逐项按 [_text] 清洗、去重、最多 [maxItems] 项。
List<String> _textList(Object? v, int maxItems, int maxLength) {
  final List<String> out = <String>[];
  for (final Object? x in _list(v)) {
    if (out.length >= maxItems) break;
    final String? s = _text(x, maxLength);
    if (s != null && !out.contains(s)) out.add(s);
  }
  return out;
}

final RegExp _datePattern = RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?$');

/// 发行日期：`YYYY` / `YYYY-MM` / `YYYY-MM-DD`，其它形状当缺失。
String? _date(Object? v) =>
    v is String && _datePattern.hasMatch(v.trim()) ? v.trim() : null;

/// 插件给的展示文本上限（docs/specs/2026-10-28-music-plugins.md §4）。
abstract final class MusicPluginTextLimits {
  /// 简介 / 介绍段落正文。
  static const int description = 20000;

  /// 介绍段落标题、公司名、歌单创建者等短文本。
  static const int short = 200;

  /// 别名 / 标签：条数与每条长度。
  static const int maxAliases = 10;
  static const int alias = 100;
  static const int maxTags = 10;
  static const int tag = 32;

  /// 艺人「其它介绍」段落数。
  static const int maxIntroSections = 20;
}

/// 插件清单（Rust 侧已校验过，这里只取用）。
class MusicPluginManifest {
  const MusicPluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.api,
    required this.capabilities,
    required this.searchTypes,
    required this.permissions,
    required this.networkDomains,
    this.author,
    this.description,
    this.homepage,
  });

  factory MusicPluginManifest.fromJson(Map<String, Object?> j) {
    final Map<String, Object?> net = _map(j['network']);
    return MusicPluginManifest(
      id: j['id']! as String,
      name: j['name']! as String,
      version: j['version']! as String,
      api: _int(j['api']) ?? 1,
      capabilities: _strings(j['capabilities']),
      searchTypes: _strings(j['searchTypes']),
      permissions: _strings(j['permissions']),
      networkDomains: _strings(net['domains']),
      author: _str(j['author']),
      description: _str(j['description']),
      homepage: _str(j['homepage']),
    );
  }

  final String id;
  final String name;
  final String version;
  final int api;
  final List<String> capabilities;
  final List<String> searchTypes;
  final List<String> permissions;
  final List<String> networkDomains;
  final String? author;
  final String? description;
  final String? homepage;

  bool can(MusicPluginCapability c) => capabilities.contains(c.wire);
}

/// 能力名（wire 值与清单 / 入口导出名一致）。
enum MusicPluginCapability {
  search('search'),
  album('album'),
  playlist('playlist'),
  artist('artist'),
  stream('stream'),
  lyrics('lyrics'),
  login('login'),
  account('account'),
  home('home'),
  library('library'),
  artistAlbums('artistAlbums'),
  artistMvs('artistMvs'),
  mvStream('mvStream'),
  searchBest('searchBest'),

  /// 平台账号的「喜欢」：读喜欢集合与喜欢 / 取消喜欢。
  /// 需同时声明 `login` / `account`。
  like('like');

  const MusicPluginCapability(this.wire);

  final String wire;
}

/// 搜索类型。
enum MusicPluginSearchType {
  song('song'),
  album('album'),
  artist('artist'),
  playlist('playlist');

  const MusicPluginSearchType(this.wire);

  final String wire;
}

/// 取流音质档。
enum MusicPluginQuality {
  standard('standard'),
  high('high'),
  lossless('lossless'),
  hires('hires');

  const MusicPluginQuality(this.wire);

  final String wire;

  static MusicPluginQuality fromWire(String? raw) => values.firstWhere(
    (MusicPluginQuality q) => q.wire == raw,
    orElse: () => high,
  );
}

/// 一个插件包（待安装或已安装）的校验摘要。
class MusicPluginPackageInfo {
  const MusicPluginPackageInfo({
    required this.manifest,
    required this.digest,
    required this.signer,
    required this.files,
  });

  factory MusicPluginPackageInfo.fromJson(Map<String, Object?> j) =>
      MusicPluginPackageInfo(
        manifest: MusicPluginManifest.fromJson(_map(j['manifest'])),
        digest: j['digest']! as String,
        signer: _str(j['signer']),
        files: _strings(j['files']),
      );

  final MusicPluginManifest manifest;

  /// `files.json` 的 sha256：用户确认安装的就是这一份。
  final String digest;

  /// 签名公钥（base64）；null = 未签名。
  final String? signer;
  final List<String> files;
}

class MusicPluginArtistRef {
  const MusicPluginArtistRef({required this.name, this.id});

  final String? id;
  final String name;

  static List<MusicPluginArtistRef> listFrom(Object? v) =>
      <MusicPluginArtistRef>[
        for (final Object? a in _list(v))
          if (_str(_map(a)['name']) case final String name)
            MusicPluginArtistRef(id: _str(_map(a)['id']), name: name),
      ];
}

String joinArtistNames(List<MusicPluginArtistRef> artists) =>
    artists.map((MusicPluginArtistRef a) => a.name).join(' / ');

class MusicPluginTrack {
  const MusicPluginTrack({
    required this.id,
    required this.title,
    this.artists = const <MusicPluginArtistRef>[],
    this.albumId,
    this.albumTitle,
    this.durationMs,
    this.coverUrl,
    this.trackNo,
    this.discNo,
    this.isrc,
    this.playable = true,
    this.note,
    this.mvId,
  });

  static MusicPluginTrack? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? id = _str(j['id']);
    final String? title = _str(j['title']);
    if (id == null || title == null) return null;
    final Map<String, Object?> album = _map(j['album']);
    return MusicPluginTrack(
      id: id,
      title: title,
      artists: MusicPluginArtistRef.listFrom(j['artists']),
      albumId: _str(album['id']),
      albumTitle: _str(album['title']),
      durationMs: _int(j['durationMs']),
      coverUrl: _str(j['coverUrl']),
      trackNo: _int(j['trackNo']),
      discNo: _int(j['discNo']),
      isrc: _str(j['isrc']),
      playable: _bool(j['playable']) ?? true,
      note: _str(j['note']),
      mvId: _str(j['mvId']),
    );
  }

  static List<MusicPluginTrack> listFrom(Object? v) => <MusicPluginTrack>[
    for (final Object? t in _list(v))
      if (fromJson(t) case final MusicPluginTrack track) track,
  ];

  final String id;
  final String title;
  final List<MusicPluginArtistRef> artists;
  final String? albumId;
  final String? albumTitle;
  final int? durationMs;
  final String? coverUrl;
  final int? trackNo;
  final int? discNo;
  final String? isrc;
  final bool playable;
  final String? note;

  /// 这首歌对应的 MV（插件声明了 `mvStream` 才有意义）；没有为 null。
  final String? mvId;

  String get artistText => joinArtistNames(artists);
}

class MusicPluginAlbum {
  const MusicPluginAlbum({
    required this.id,
    required this.title,
    this.artists = const <MusicPluginArtistRef>[],
    this.coverUrl,
    this.year,
    this.trackCount,
    this.releaseDate,
    this.company,
    this.description,
  });

  static MusicPluginAlbum? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? id = _str(j['id']);
    final String? title = _str(j['title']);
    if (id == null || title == null) return null;
    return MusicPluginAlbum(
      id: id,
      title: title,
      artists: MusicPluginArtistRef.listFrom(j['artists']),
      coverUrl: _str(j['coverUrl']),
      year: _int(j['year']),
      trackCount: _count(j['trackCount']),
      releaseDate: _date(j['releaseDate']),
      company: _text(j['company'], MusicPluginTextLimits.short),
      description: _text(j['description'], MusicPluginTextLimits.description),
    );
  }

  static List<MusicPluginAlbum> listFrom(Object? v) => <MusicPluginAlbum>[
    for (final Object? a in _list(v))
      if (fromJson(a) case final MusicPluginAlbum album) album,
  ];

  final String id;
  final String title;
  final List<MusicPluginArtistRef> artists;
  final String? coverUrl;
  final int? year;
  final int? trackCount;

  /// `YYYY` / `YYYY-MM` / `YYYY-MM-DD`。
  final String? releaseDate;

  /// 发行公司 / 厂牌。
  final String? company;

  /// 专辑简介（全文，已截断到 [MusicPluginTextLimits.description]）。
  final String? description;

  String get artistText => joinArtistNames(artists);

  /// 换封面（其余字段原样）：宿主按网络授权清洗封面用。
  MusicPluginAlbum withCover(String? cover) => MusicPluginAlbum(
    id: id,
    title: title,
    artists: artists,
    coverUrl: cover,
    year: year,
    trackCount: trackCount,
    releaseDate: releaseDate,
    company: company,
    description: description,
  );
}

/// 艺人统计（插件给什么显示什么）。
class MusicPluginArtistStats {
  const MusicPluginArtistStats({
    this.trackCount,
    this.albumCount,
    this.mvCount,
    this.fanCount,
  });

  static MusicPluginArtistStats fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    return MusicPluginArtistStats(
      trackCount: _count(j['trackCount']),
      albumCount: _count(j['albumCount']),
      mvCount: _count(j['mvCount']),
      fanCount: _count(j['fanCount']),
    );
  }

  final int? trackCount;
  final int? albumCount;
  final int? mvCount;
  final int? fanCount;

  bool get isEmpty =>
      trackCount == null &&
      albumCount == null &&
      mvCount == null &&
      fanCount == null;
}

/// 艺人「其它介绍」的一段（生平、经历……）。
class MusicPluginIntroSection {
  const MusicPluginIntroSection({required this.text, this.title});

  static List<MusicPluginIntroSection> listFrom(Object? v) =>
      <MusicPluginIntroSection>[
        for (final Object? x in _list(v))
          if (_text(_map(x)['text'], MusicPluginTextLimits.description)
              case final String text)
            MusicPluginIntroSection(
              text: text,
              title: _text(_map(x)['title'], MusicPluginTextLimits.short),
            ),
      ].take(MusicPluginTextLimits.maxIntroSections).toList();

  final String? title;
  final String text;
}

class MusicPluginArtist {
  const MusicPluginArtist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.aliases = const <String>[],
    this.description,
    this.intro = const <MusicPluginIntroSection>[],
    this.stats = const MusicPluginArtistStats(),
  });

  static MusicPluginArtist? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? id = _str(j['id']);
    final String? name = _str(j['name']);
    if (id == null || name == null) return null;
    return MusicPluginArtist(
      id: id,
      name: name,
      coverUrl: _str(j['coverUrl']),
      aliases: _textList(
        j['aliases'],
        MusicPluginTextLimits.maxAliases,
        MusicPluginTextLimits.alias,
      ).where((String a) => a != name).toList(),
      description: _text(j['description'], MusicPluginTextLimits.description),
      intro: MusicPluginIntroSection.listFrom(j['intro']),
      stats: MusicPluginArtistStats.fromJson(j['stats']),
    );
  }

  static List<MusicPluginArtist> listFrom(Object? v) => <MusicPluginArtist>[
    for (final Object? a in _list(v))
      if (fromJson(a) case final MusicPluginArtist artist) artist,
  ];

  final String id;
  final String name;
  final String? coverUrl;

  /// 别名 / 译名（不含 [name] 本身），最多 [MusicPluginTextLimits.maxAliases] 条。
  final List<String> aliases;

  /// 简介全文。
  final String? description;

  /// 其它介绍段落。
  final List<MusicPluginIntroSection> intro;
  final MusicPluginArtistStats stats;

  bool get hasDetails => description != null || intro.isNotEmpty;

  MusicPluginArtist withCover(String? cover) => MusicPluginArtist(
    id: id,
    name: name,
    coverUrl: cover,
    aliases: aliases,
    description: description,
    intro: intro,
    stats: stats,
  );
}

class MusicPluginPlaylist {
  const MusicPluginPlaylist({
    required this.id,
    required this.title,
    this.coverUrl,
    this.trackCount,
    this.owner,
    this.description,
    this.previewTracks = const <MusicPluginTrack>[],
    this.playCount,
    this.tags = const <String>[],
  });

  /// 歌单卡上直接展示的预览曲目上限（docs/specs/2026-10-28-music-plugins.md §4）。
  static const int maxPreviewTracks = 3;

  static MusicPluginPlaylist? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? id = _str(j['id']);
    final String? title = _str(j['title']);
    if (id == null || title == null) return null;
    return MusicPluginPlaylist(
      id: id,
      title: title,
      coverUrl: _str(j['coverUrl']),
      trackCount: _int(j['trackCount']),
      owner: _text(j['owner'], MusicPluginTextLimits.short),
      description: _text(j['description'], MusicPluginTextLimits.description),
      previewTracks: _previewTracksFrom(j['previewTracks']),
      playCount: _count(j['playCount']),
      tags: _textList(
        j['tags'],
        MusicPluginTextLimits.maxTags,
        MusicPluginTextLimits.tag,
      ),
    );
  }

  /// 预览曲目只显示文字：坏条目丢弃、截断到 [maxPreviewTracks]，封面一律丢掉
  /// （不必再过插件网络授权核对）。
  static List<MusicPluginTrack> _previewTracksFrom(Object? v) =>
      <MusicPluginTrack>[
        for (final MusicPluginTrack t in MusicPluginTrack.listFrom(
          v,
        ).take(maxPreviewTracks))
          MusicPluginTrack(
            id: t.id,
            title: t.title,
            artists: t.artists,
            albumId: t.albumId,
            albumTitle: t.albumTitle,
            durationMs: t.durationMs,
            trackNo: t.trackNo,
            discNo: t.discNo,
            isrc: t.isrc,
            playable: t.playable,
            note: t.note,
            mvId: t.mvId,
          ),
      ];

  static List<MusicPluginPlaylist> listFrom(Object? v) => <MusicPluginPlaylist>[
    for (final Object? p in _list(v))
      if (fromJson(p) case final MusicPluginPlaylist playlist) playlist,
  ];

  final String id;
  final String title;
  final String? coverUrl;
  final int? trackCount;
  final String? owner;
  final String? description;

  /// 插件附带的前几首曲目（榜单卡用），最多 [maxPreviewTracks] 条，不含封面；
  /// 插件没给时为空。
  final List<MusicPluginTrack> previewTracks;

  /// 播放次数。
  final int? playCount;

  /// 标签，最多 [MusicPluginTextLimits.maxTags] 条。
  final List<String> tags;

  MusicPluginPlaylist withCover(String? cover) => MusicPluginPlaylist(
    id: id,
    title: title,
    coverUrl: cover,
    trackCount: trackCount,
    owner: owner,
    description: description,
    previewTracks: previewTracks,
    playCount: playCount,
    tags: tags,
  );
}

/// 一支 MV（`artistMvs` 列表项）。
class MusicPluginMv {
  const MusicPluginMv({
    required this.id,
    required this.title,
    this.artists = const <MusicPluginArtistRef>[],
    this.coverUrl,
    this.durationMs,
    this.playCount,
    this.publishDate,
  });

  static MusicPluginMv? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? id = _str(j['id']);
    final String? title = _str(j['title']);
    if (id == null || title == null) return null;
    return MusicPluginMv(
      id: id,
      title: title,
      artists: MusicPluginArtistRef.listFrom(j['artists']),
      coverUrl: _str(j['coverUrl']),
      durationMs: _count(j['durationMs']),
      playCount: _count(j['playCount']),
      publishDate: _date(j['publishDate']),
    );
  }

  static List<MusicPluginMv> listFrom(Object? v) => <MusicPluginMv>[
    for (final Object? m in _list(v))
      if (fromJson(m) case final MusicPluginMv mv) mv,
  ];

  final String id;
  final String title;
  final List<MusicPluginArtistRef> artists;

  /// 横版封面（16:9）。
  final String? coverUrl;
  final int? durationMs;
  final int? playCount;
  final String? publishDate;

  String get artistText => joinArtistNames(artists);

  MusicPluginMv withCover(String? cover) => MusicPluginMv(
    id: id,
    title: title,
    artists: artists,
    coverUrl: cover,
    durationMs: durationMs,
    playCount: playCount,
    publishDate: publishDate,
  );
}

/// MV 播放地址（`mvStream`）。
class MusicPluginMvStream {
  const MusicPluginMvStream({
    required this.url,
    this.headers = const <String, String>{},
    this.expiresAt,
    this.width,
    this.height,
  });

  static MusicPluginMvStream? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? url = _str(j['url']);
    if (url == null) return null;
    return MusicPluginMvStream(
      url: url,
      headers: <String, String>{
        for (final MapEntry<String, Object?> e in _map(j['headers']).entries)
          if (e.value is String) e.key: e.value! as String,
      },
      expiresAt: _int(j['expiresAt']),
      width: _count(j['width']),
      height: _count(j['height']),
    );
  }

  final String url;
  final Map<String, String> headers;
  final int? expiresAt;
  final int? width;
  final int? height;
}

/// 搜索最佳匹配（`searchBest`）：插件按平台自己的综合排序给出，宿主不再按名字猜。
class MusicPluginSearchBest {
  const MusicPluginSearchBest({this.artist, this.playlist, this.album});

  static const MusicPluginSearchBest none = MusicPluginSearchBest();

  final MusicPluginArtist? artist;
  final MusicPluginPlaylist? playlist;
  final MusicPluginAlbum? album;

  bool get isEmpty => artist == null && playlist == null && album == null;
}

/// 已登录账号在平台上「喜欢」的曲目（`like` 的 `op: 'list'`）。
class MusicPluginLikes {
  const MusicPluginLikes({required this.trackIds, this.playlist});

  /// 喜欢的曲目 id（插件曲目 id，不透明）。
  final Set<String> trackIds;

  /// 平台上承载这些曲目的「喜欢」歌单，能用 `playlist` 能力打开；
  /// 平台没有对应歌单时为 null。
  final MusicPluginPlaylist? playlist;

  /// `{ ids: [string], playlist?: Playlist }` → 喜欢集合；形状不对返回 null。
  static MusicPluginLikes? fromJson(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? ids = raw['ids'];
    if (ids is! List<Object?>) return null;
    return MusicPluginLikes(
      trackIds: <String>{
        for (final Object? id in ids)
          if (id is String && id.isNotEmpty)
            id
          else if (id is num && id == id.truncate())
            '${id.truncate()}',
      },
      playlist: MusicPluginPlaylist.fromJson(raw['playlist']),
    );
  }
}

class MusicPluginPage<T> {
  const MusicPluginPage({
    required this.items,
    required this.hasMore,
    this.total,
  });

  final List<T> items;
  final bool hasMore;
  final int? total;
}

/// 推荐页一段的内容种类。
enum MusicPluginHomeKind {
  tracks('tracks'),
  playlists('playlists'),
  albums('albums');

  const MusicPluginHomeKind(this.wire);

  final String wire;

  static MusicPluginHomeKind? parse(Object? v) {
    for (final MusicPluginHomeKind k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

/// 推荐页的一段（每日推荐、推荐歌单、榜单……）。[items] 按 [kind] 是
/// [MusicPluginTrack] / [MusicPluginPlaylist] / [MusicPluginAlbum]。
class MusicPluginHomeSection {
  const MusicPluginHomeSection({
    required this.id,
    required this.title,
    required this.kind,
    required this.items,
    this.subtitle,
  });

  /// 宿主最多取的段数与每段条数（docs/specs/2026-10-28-music-plugins.md §4）。
  static const int maxSections = 12;
  static const int maxItems = 50;

  final String id;
  final String title;
  final String? subtitle;
  final MusicPluginHomeKind kind;
  final List<Object> items;
}

class MusicPluginStream {
  const MusicPluginStream({
    required this.url,
    this.headers = const <String, String>{},
    this.expiresAt,
    this.codec,
    this.bitrateKbps,
    this.sampleRate,
    this.bitDepth,
    this.sizeBytes,
    this.trialStartMs,
    this.trialEndMs,
  });

  static MusicPluginStream? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? url = _str(j['url']);
    if (url == null) return null;
    final Map<String, Object?> trial = _map(j['trial']);
    return MusicPluginStream(
      url: url,
      headers: <String, String>{
        for (final MapEntry<String, Object?> e in _map(j['headers']).entries)
          if (e.value is String) e.key: e.value! as String,
      },
      expiresAt: _int(j['expiresAt']),
      codec: _str(j['codec']),
      bitrateKbps: _int(j['bitrateKbps']),
      sampleRate: _int(j['sampleRate']),
      bitDepth: _int(j['bitDepth']),
      sizeBytes: _int(j['sizeBytes']),
      trialStartMs: _int(trial['startMs']),
      trialEndMs: _int(trial['endMs']),
    );
  }

  final String url;
  final Map<String, String> headers;
  final int? expiresAt;
  final String? codec;
  final int? bitrateKbps;
  final int? sampleRate;
  final int? bitDepth;
  final int? sizeBytes;
  final int? trialStartMs;
  final int? trialEndMs;

  bool get isTrial => trialEndMs != null;
}

class MusicPluginLyricText {
  const MusicPluginLyricText({
    required this.format,
    required this.text,
    this.language,
  });

  static const Set<String> formats = <String>{
    'yrc',
    'lrc',
    'ttml',
    'qrc',
    'krc',
    'txt',
  };

  static MusicPluginLyricText? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final String? format = _str(j['format']);
    final String? text = _str(j['text']);
    if (format == null || text == null || !formats.contains(format))
      return null;
    if (text.trim().isEmpty) return null;
    return MusicPluginLyricText(
      format: format,
      text: text,
      language: _str(j['language']),
    );
  }

  final String format;
  final String text;

  /// BCP 47 语言标签（如译文的 `zh-Hans`）；插件不给为 null。
  final String? language;
}

class MusicPluginLyrics {
  const MusicPluginLyrics({this.original, this.translation, this.romanization});

  static MusicPluginLyrics? fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final MusicPluginLyrics l = MusicPluginLyrics(
      original: MusicPluginLyricText.fromJson(j['original']),
      translation: MusicPluginLyricText.fromJson(j['translation']),
      romanization: MusicPluginLyricText.fromJson(j['romanization']),
    );
    return l.original == null ? null : l;
  }

  final MusicPluginLyricText? original;
  final MusicPluginLyricText? translation;
  final MusicPluginLyricText? romanization;
}

/// 插件账号状态（`account()`）。
class MusicPluginAccount {
  const MusicPluginAccount({
    required this.loggedIn,
    this.name,
    this.avatarUrl,
    this.badge,
  });

  static const MusicPluginAccount anonymous = MusicPluginAccount(
    loggedIn: false,
  );

  static MusicPluginAccount fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    return MusicPluginAccount(
      loggedIn: j['loggedIn'] == true,
      name: _str(j['name']),
      avatarUrl: _str(j['avatarUrl']),
      badge: _str(j['badge']),
    );
  }

  final bool loggedIn;
  final String? name;
  final String? avatarUrl;
  final String? badge;
}

/// 登录方式的界面类型（契约 §4.1）。
enum MusicPluginLoginType {
  qr('qr'),
  form('form'),
  web('web');

  const MusicPluginLoginType(this.wire);

  final String wire;

  static MusicPluginLoginType? fromWire(Object? raw) {
    for (final MusicPluginLoginType t in values) {
      if (t.wire == raw) return t;
    }
    return null;
  }
}

class MusicPluginLoginMethod {
  const MusicPluginLoginMethod({
    required this.id,
    required this.type,
    required this.label,
    this.description,
  });

  static List<MusicPluginLoginMethod> listFrom(Object? raw) =>
      <MusicPluginLoginMethod>[
        for (final Object? m in _list(_map(raw)['methods']))
          if ((
                _str(_map(m)['id']),
                MusicPluginLoginType.fromWire(_map(m)['type']),
                _str(_map(m)['label']),
              )
              case (
                final String id,
                final MusicPluginLoginType type,
                final String label,
              ))
            MusicPluginLoginMethod(
              id: id,
              type: type,
              label: label,
              description: _str(_map(m)['description']),
            ),
      ];

  final String id;
  final MusicPluginLoginType type;
  final String label;
  final String? description;
}

class MusicPluginLoginField {
  const MusicPluginLoginField({
    required this.id,
    required this.label,
    this.secret = false,
    this.multiline = false,
    this.placeholder,
    this.value,
  });

  final String id;
  final String label;
  final bool secret;
  final bool multiline;
  final String? placeholder;
  final String? value;
}

class MusicPluginLoginAction {
  const MusicPluginLoginAction({
    required this.id,
    required this.label,
    this.primary = false,
  });

  final String id;
  final String label;
  final bool primary;
}

enum MusicPluginLoginState { pending, done, failed }

/// 登录过程中的一步（`begin` / `poll` / `submit` 的返回）。
class MusicPluginLoginChallenge {
  const MusicPluginLoginChallenge({
    required this.state,
    this.session,
    this.message,
    this.qrContent,
    this.qrImageBase64,
    this.qrScanned = false,
    this.pollMs,
    this.appUrl,
    this.fields = const <MusicPluginLoginField>[],
    this.actions = const <MusicPluginLoginAction>[],
    this.webUrl,
    this.webCookieUrl,
    this.webDoneCookie,
    this.account,
  });

  static MusicPluginLoginChallenge fromJson(Object? raw) {
    final Map<String, Object?> j = _map(raw);
    final Map<String, Object?> qr = _map(j['qr']);
    final Map<String, Object?> form = _map(j['form']);
    final Map<String, Object?> web = _map(j['web']);
    final MusicPluginLoginState state = switch (j['state']) {
      'done' => MusicPluginLoginState.done,
      'failed' => MusicPluginLoginState.failed,
      _ => MusicPluginLoginState.pending,
    };
    final int? poll = _int(j['pollMs']);
    // 二维码图片设上限，免得插件塞几十 MB 进界面。
    final String? image = _str(qr['imageBase64']);
    return MusicPluginLoginChallenge(
      state: state,
      session: _str(j['session']),
      message: _str(j['message']),
      qrContent: _str(qr['content']),
      qrImageBase64: image != null && image.length <= 300000 ? image : null,
      qrScanned: qr['scanned'] == true,
      pollMs: poll?.clamp(500, 10000),
      appUrl: _str(j['appUrl']),
      fields: <MusicPluginLoginField>[
        for (final Object? f in _list(form['fields']))
          if ((_str(_map(f)['id']), _str(_map(f)['label'])) case (
            final String id,
            final String label,
          ))
            MusicPluginLoginField(
              id: id,
              label: label,
              secret: _map(f)['secret'] == true,
              multiline: _map(f)['multiline'] == true,
              placeholder: _str(_map(f)['placeholder']),
              value: _str(_map(f)['value']),
            ),
      ],
      actions: <MusicPluginLoginAction>[
        for (final Object? a in _list(form['actions']))
          if ((_str(_map(a)['id']), _str(_map(a)['label'])) case (
            final String id,
            final String label,
          ))
            MusicPluginLoginAction(
              id: id,
              label: label,
              primary: _map(a)['primary'] == true,
            ),
      ],
      webUrl: _str(web['url']),
      webCookieUrl: _str(web['cookieUrl']),
      webDoneCookie: _str(web['doneCookie']),
      account: j['account'] == null
          ? null
          : MusicPluginAccount.fromJson(j['account']),
    );
  }

  final MusicPluginLoginState state;
  final String? session;
  final String? message;
  final String? qrContent;
  final String? qrImageBase64;
  final bool qrScanned;
  final int? pollMs;
  final String? appUrl;
  final List<MusicPluginLoginField> fields;
  final List<MusicPluginLoginAction> actions;
  final String? webUrl;
  final String? webCookieUrl;
  final String? webDoneCookie;
  final MusicPluginAccount? account;

  bool get hasQr => qrContent != null || qrImageBase64 != null;
  bool get hasWeb =>
      webUrl != null && webCookieUrl != null && webDoneCookie != null;
}
