/// 媒体服务器（Jellyfin / Subsonic）曲目与封面在落库快照里的**只认身份的占位**，以及
/// 带凭据地址的识别与清洗（BUG-5290）。
///
/// 服务器客户端给的播放流 / 封面地址带账号凭据：Jellyfin `api_key=<access token>`，
/// Subsonic `u` + `t`（md5(密码 + 盐)）+ `s`（可重放）或 OpenSubsonic `apiKey`。这些地址只能
/// 活在内存里；落库（最近播放快照 `music_play_events.path / cover_path / source_cover`、
/// 备份、合并）一律换成这里的占位，重播 / 显示时再由当前配置的服务器客户端现算。
///
/// 占位形态（host 固定，id 放路径段：URI host 会被规范成小写，而服务器侧 id 区分大小写）：
/// - 曲目：`fushi-music-server://track/<曲目 id>?server=<服务器配置身份>&album=<专辑 id>`
/// - 封面：`fushi-music-server://cover/<封面引用>?server=<服务器配置身份>`
///
/// `server` / `album` 可缺：v172 迁移清洗存量行时只能从地址里认出曲目 / 封面 id，认不出
/// 是哪台服务器——重播时按 `musicServerTrackUid(serverId, 曲目 id) == trackUid` 在当前配置
/// 的服务器里找回（uid 是哈希，配错服务器对不上，不会张冠李戴）。
///
/// 纯 Dart（fushi_core 不依赖引擎）：迁移、写入守门、备份合并共用这一份判据。
library;

/// 占位 scheme。
const String kMusicServerRefScheme = 'fushi-music-server';

const String _trackHost = 'track';
const String _coverHost = 'cover';

/// 占位指向的是曲目还是封面。
enum MusicServerRefKind { track, cover }

/// 解析出的占位。
typedef MusicServerRef = ({
  MusicServerRefKind kind,
  String id,
  String? serverId,
  String? albumId,
});

String _refUri(String host, String id, {String? serverId, String? albumId}) =>
    Uri(
      scheme: kMusicServerRefScheme,
      host: host,
      pathSegments: <String>[id],
      queryParameters: <String, String>{
        if (serverId != null && serverId.isNotEmpty) 'server': serverId,
        if (albumId != null && albumId.isNotEmpty) 'album': albumId,
      }.nullIfEmpty,
    ).toString();

extension on Map<String, String> {
  Map<String, String>? get nullIfEmpty => isEmpty ? null : this;
}

/// 服务器曲目 → 落库用的占位路径（不含任何凭据）。
String musicServerTrackRefPath(
  String trackId, {
  String? serverId,
  String? albumId,
}) => _refUri(_trackHost, trackId, serverId: serverId, albumId: albumId);

/// 服务器封面引用 → 落库用的占位（不含任何凭据）。
String musicServerCoverRefPath(String coverRef, {String? serverId}) =>
    _refUri(_coverHost, coverRef, serverId: serverId);

/// 占位 → 身份；不是占位（本地路径 / 插件占位 / http 地址 …）回 null。
MusicServerRef? parseMusicServerRef(String? value) {
  if (value == null || !value.startsWith('$kMusicServerRefScheme://')) {
    return null;
  }
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || uri.pathSegments.length != 1) return null;
  final String id = uri.pathSegments.single;
  if (id.isEmpty) return null;
  final MusicServerRefKind kind;
  switch (uri.host) {
    case _trackHost:
      kind = MusicServerRefKind.track;
    case _coverHost:
      kind = MusicServerRefKind.cover;
    default:
      return null;
  }
  String? q(String key) {
    final String? v = uri.queryParameters[key];
    return v == null || v.isEmpty ? null : v;
  }

  return (kind: kind, id: id, serverId: q('server'), albumId: q('album'));
}

/// 认作凭据的 query 键（小写比较）：Jellyfin / Emby 的 token 与 OpenSubsonic 的 apiKey。
const Set<String> _secretQueryKeys = <String>{
  'api_key',
  'apikey',
  'x-emby-token',
  'x-mediabrowser-token',
  'accesstoken',
  'access_token',
};

/// 这个地址是否带账号凭据：URI userinfo、token / apiKey 类 query，或 Subsonic 的
/// `t` + `s`（md5 口令 + 盐，可重放）/ 明文 `p`（与 `u` 同在）。非 http(s) 一律 false。
bool musicUrlCarriesCredentials(String? value) {
  final Uri? uri = _httpUri(value);
  if (uri == null) return false;
  if (uri.userInfo.isNotEmpty) return true;
  final Set<String> keys = <String>{
    for (final String k in uri.queryParametersAll.keys) k.toLowerCase(),
  };
  if (keys.any(_secretQueryKeys.contains)) return true;
  if (keys.contains('t') && keys.contains('s')) return true;
  if (keys.contains('u') && keys.contains('p')) return true;
  return false;
}

Uri? _httpUri(String? value) {
  if (value == null) return null;
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    return null;
  }
  return Uri.tryParse(value);
}

/// 从带凭据的服务器地址里认出曲目 / 封面身份（Jellyfin `/Audio/<id>/…`、
/// `/Items/<id>/Images/…`；Subsonic `/rest/stream[.view]?id=`、
/// `/rest/getCoverArt[.view]?id=`）；认不出回 null。
({MusicServerRefKind kind, String id})? _serverIdentityOfUrl(Uri uri) {
  final List<String> seg = <String>[
    for (final String s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  for (int i = 0; i + 1 < seg.length; i++) {
    final String s = seg[i].toLowerCase();
    if (s == 'audio' && i + 2 < seg.length) {
      return (kind: MusicServerRefKind.track, id: seg[i + 1]);
    }
    if (s == 'items' &&
        i + 2 < seg.length &&
        seg[i + 2].toLowerCase() == 'images') {
      return (kind: MusicServerRefKind.cover, id: seg[i + 1]);
    }
  }
  if (seg.length >= 2 && seg[seg.length - 2].toLowerCase() == 'rest') {
    final String method = seg.last.toLowerCase().replaceFirst(
      RegExp(r'\.view$'),
      '',
    );
    final String? id = uri.queryParameters['id'];
    if (id != null && id.isNotEmpty) {
      if (method == 'stream' || method == 'download') {
        return (kind: MusicServerRefKind.track, id: id);
      }
      if (method == 'getcoverart') {
        return (kind: MusicServerRefKind.cover, id: id);
      }
    }
  }
  return null;
}

/// 落库前的清洗：不带凭据的值原样返回；带凭据的服务器地址换成占位（认得出曲目 /
/// 封面 id 时；[serverId] 已知就一并写进去），认不出就丢掉（回 null）——宁可少一张封面 /
/// 一条可重播的记录，也不把凭据写进库。幂等（占位本身不带凭据）。
String? scrubMusicPersistedUrl(String? value, {String? serverId}) {
  if (!musicUrlCarriesCredentials(value)) return value;
  final ({MusicServerRefKind kind, String id})? ident = _serverIdentityOfUrl(
    _httpUri(value)!,
  );
  if (ident == null) return null;
  return switch (ident.kind) {
    MusicServerRefKind.track => musicServerTrackRefPath(
      ident.id,
      serverId: serverId,
    ),
    MusicServerRefKind.cover => musicServerCoverRefPath(
      ident.id,
      serverId: serverId,
    ),
  };
}

/// 播放来源 id（`server_album` / `server_playlist` 的 `<服务器身份>/<条目 id>`）里的服务器
/// 身份；别的种类回 null。与 app 侧 `MusicPlaySource.serverAlbum / serverPlaylist` 的编码一致。
String? musicServerIdOfPlaySource(String? kind, String? id) {
  if (kind != 'server_album' && kind != 'server_playlist') return null;
  if (id == null) return null;
  // 服务器身份本身可能含 `/`（Jellyfin = `jellyfin:<服务器地址>|<userId>`），条目 id 不含：
  // 按最后一个 `/` 切。
  final int slash = id.lastIndexOf('/');
  if (slash <= 0) return null;
  return id.substring(0, slash);
}
