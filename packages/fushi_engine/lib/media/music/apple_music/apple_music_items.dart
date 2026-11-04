/// Apple Music API 的条目模型与解析（catalog / 资料库 / 个人推荐共用）：歌单、电台、流派，以及
/// 推荐 / 最近播放 / 最近加入这类「混排」回包里的任意条目（[AppleMusicItem]）。
///
/// 资源类型按 Apple Music API 的 `type` 字段区分：catalog 资源（`albums` / `playlists` /
/// `stations` / `songs`）与资料库资源（`library-albums` / `library-playlists` / `library-songs`）
/// id 空间不同，所以每个条目都带 [AppleMusicItem.library]，界面据此选用 catalog 还是资料库来源打开。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

Map<String, Object?> _attrs(Map<String, Object?> res) {
  final Object? a = res['attributes'];
  return a is Map<String, Object?> ? a : const <String, Object?>{};
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

String? _artwork(Map<String, Object?> attrs) {
  final Object? art = attrs['artwork'];
  return art is Map<String, Object?> ? _str(art['url']) : null;
}

/// 取回包里某个容器的 `data` 数组（不是数组回空）。
List<Object?> appleMusicDataOf(Object? container) {
  if (container is! Map<String, Object?>) return const <Object?>[];
  final Object? d = container['data'];
  return d is List<Object?> ? d : const <Object?>[];
}

/// Apple 的简介是 `{standard, short}`（catalog）或纯字符串（资料库）；可能带少量 HTML 标签。
String? _description(Object? raw) {
  String? s;
  if (raw is Map<String, Object?>) {
    s = _str(raw['standard']) ?? _str(raw['short']);
  } else {
    s = _str(raw);
  }
  if (s == null) return null;
  final String plain = s
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .trim();
  return plain.isEmpty ? null : plain;
}

/// `playlists`（catalog）/ `library-playlists`（资料库）资源 → 歌单。其它类型或缺 id / 名回 null。
/// 资料库歌单的 [MusicServerPlaylist.editable] 取 `canEdit`（自己建的歌单才是 true）。
MusicServerPlaylist? parseAppleMusicPlaylist(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final Object? type = raw['type'];
  if (type != 'playlists' && type != 'library-playlists') return null;
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  if (id == null || name == null) return null;
  return MusicServerPlaylist(
    id: id,
    title: name,
    description: _description(a['description']),
    curator: _str(a['curatorName']),
    trackCount: _int(a['trackCount']),
    coverRef: _artwork(a),
    editable: type == 'library-playlists' && a['canEdit'] == true,
  );
}

/// 一个电台（catalog `stations`）。
class AppleMusicStation {
  const AppleMusicStation({
    required this.id,
    required this.name,
    this.coverRef,
    this.isLive = false,
    this.subtitle,
  });

  final String id;
  final String name;
  final String? coverRef;

  /// 直播电台（Apple Music 1 等）：没有可拖动的时间轴。
  final bool isLive;

  /// 编辑附注 / 节目名（`editorialNotes.short` / `stationProviderName`）。
  final String? subtitle;
}

/// `stations` 资源 → 电台。
AppleMusicStation? parseAppleMusicStation(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'stations') return null;
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  if (id == null || name == null) return null;
  final Object? notes = a['editorialNotes'];
  return AppleMusicStation(
    id: id,
    name: name,
    coverRef: _artwork(a),
    isLive: a['isLive'] == true,
    subtitle: notes is Map<String, Object?>
        ? _str(notes['short']) ?? _str(a['stationProviderName'])
        : _str(a['stationProviderName']),
  );
}

/// 一个流派（catalog `genres`）。
class AppleMusicGenre {
  const AppleMusicGenre({required this.id, required this.name, this.parentId});

  final String id;
  final String name;
  final String? parentId;
}

/// `genres` 资源 → 流派。
AppleMusicGenre? parseAppleMusicGenre(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'genres') return null;
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  if (id == null || name == null) return null;
  return AppleMusicGenre(id: id, name: name, parentId: _str(a['parentId']));
}

/// 混排回包里的一个条目。[library] = 资料库资源（id 在资料库空间，要用资料库来源打开）。
sealed class AppleMusicItem {
  const AppleMusicItem({required this.library});

  final bool library;

  /// 用来去重 / 作 widget key 的身份（类型 + id）。
  String get key;
}

final class AppleMusicAlbumItem extends AppleMusicItem {
  const AppleMusicAlbumItem(this.album, {required super.library});

  final MusicServerAlbum album;

  @override
  String get key => '${library ? 'l' : 'c'}-album-${album.id}';
}

final class AppleMusicPlaylistItem extends AppleMusicItem {
  const AppleMusicPlaylistItem(this.playlist, {required super.library});

  final MusicServerPlaylist playlist;

  @override
  String get key => '${library ? 'l' : 'c'}-playlist-${playlist.id}';
}

final class AppleMusicStationItem extends AppleMusicItem {
  const AppleMusicStationItem(this.station) : super(library: false);

  final AppleMusicStation station;

  @override
  String get key => 'c-station-${station.id}';
}

/// 一首歌（id 一律是 catalog id：资料库歌曲已经按 `playParams.catalogId` 换过）。
final class AppleMusicSongItem extends AppleMusicItem {
  const AppleMusicSongItem(this.track) : super(library: false);

  final MusicServerTrack track;

  @override
  String get key => 'c-song-${track.id}';
}

/// 任意资源 → 条目；认不出的类型（`music-videos`、`apple-curators` …）回 null。
AppleMusicItem? parseAppleMusicItem(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  switch (raw['type']) {
    case 'albums':
      final MusicServerAlbum? a = parseAppleMusicAlbum(raw);
      return a == null ? null : AppleMusicAlbumItem(a, library: false);
    case 'library-albums':
      final MusicServerAlbum? a = parseAppleMusicLibraryAlbum(raw);
      return a == null ? null : AppleMusicAlbumItem(a, library: true);
    case 'playlists':
    case 'library-playlists':
      final MusicServerPlaylist? p = parseAppleMusicPlaylist(raw);
      return p == null
          ? null
          : AppleMusicPlaylistItem(
              p,
              library: raw['type'] == 'library-playlists',
            );
    case 'stations':
      final AppleMusicStation? s = parseAppleMusicStation(raw);
      return s == null ? null : AppleMusicStationItem(s);
    case 'songs':
      final AppleMusicSong? s = parseAppleMusicSong(raw);
      return s == null ? null : AppleMusicSongItem(s.track);
    case 'library-songs':
      final AppleMusicLibrarySong? s = parseAppleMusicLibrarySong(raw);
      return s == null
          ? null
          : AppleMusicSongItem(appleMusicTrackWithId(s.track, s.catalogId));
  }
  return null;
}

/// 一组条目（去重、保持顺序）。
List<AppleMusicItem> parseAppleMusicItems(Iterable<Object?> raw) {
  final Set<String> seen = <String>{};
  final List<AppleMusicItem> out = <AppleMusicItem>[];
  for (final Object? r in raw) {
    final AppleMusicItem? item = parseAppleMusicItem(r);
    if (item != null && seen.add(item.key)) out.add(item);
  }
  return out;
}

/// 推荐页的一行（「为你推荐」的一组：标题 + 条目）。
class AppleMusicShelf {
  const AppleMusicShelf({required this.title, required this.items});

  final String title;
  final List<AppleMusicItem> items;
}

/// `personal-recommendation` 资源 → 一行。没有标题或内容回 null。
AppleMusicShelf? parseAppleMusicRecommendation(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final Map<String, Object?> a = _attrs(raw);
  final Object? title = a['title'];
  final String? text = title is Map<String, Object?>
      ? _str(title['stringForDisplay'])
      : _str(title);
  final Object? rel = raw['relationships'];
  final Object? contents = rel is Map<String, Object?> ? rel['contents'] : null;
  final List<AppleMusicItem> items = parseAppleMusicItems(
    appleMusicDataOf(contents),
  );
  if (text == null || items.isEmpty) return null;
  return AppleMusicShelf(title: text, items: items);
}

/// 一个 storefront 的榜单（同一次 `charts` 请求的三类）。
class AppleMusicCharts {
  const AppleMusicCharts({
    this.songs = const <MusicServerTrack>[],
    this.albums = const <MusicServerAlbum>[],
    this.playlists = const <MusicServerPlaylist>[],
    this.songsTitle,
    this.albumsTitle,
    this.playlistsTitle,
  });

  final List<MusicServerTrack> songs;
  final List<MusicServerAlbum> albums;
  final List<MusicServerPlaylist> playlists;

  /// Apple 给的本地化榜单名（「トップソング」…）；没有为 null，界面用自己的文案。
  final String? songsTitle;
  final String? albumsTitle;
  final String? playlistsTitle;

  bool get isEmpty => songs.isEmpty && albums.isEmpty && playlists.isEmpty;
}

/// 换掉曲目 id（资料库歌曲 → catalog id，好让 catalog 来源能放）。
MusicServerTrack appleMusicTrackWithId(
  MusicServerTrack t,
  String id, {
  String? albumId,
}) => MusicServerTrack(
  id: id,
  title: t.title,
  artist: t.artist,
  album: t.album,
  albumId: albumId ?? t.albumId,
  discNo: t.discNo,
  trackNo: t.trackNo,
  durationMs: t.durationMs,
  container: t.container,
  codec: t.codec,
  bitrateKbps: t.bitrateKbps,
  sampleRate: t.sampleRate,
  bitDepth: t.bitDepth,
  channels: t.channels,
  sizeBytes: t.sizeBytes,
  coverRef: t.coverRef,
);
