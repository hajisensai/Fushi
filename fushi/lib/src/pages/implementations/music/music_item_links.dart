/// 从一个播放项跳到它的歌手 / 专辑详情（歌词页、播放条等「正在播放」处用）。
///
/// 本地曲目：专辑按 `albumUid` 查曲库，歌手按名字匹配曲库歌手表；插件曲目：用
/// 播放项带的插件歌手 id / 专辑 id（[MusicPlayItem.artistRefs] /
/// [MusicPlayItem.sourceAlbumId]），从最近播放重建的老播放项没有 id 时按名字在
/// 插件里搜歌手。服务器曲目暂不支持（返回 false，调用方不显示可点样式）。
library;

import 'dart:async';

import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, MusicAlbumRow, MusicArtistRow, MusicTrackRow;
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 歌手字符串里常见的分隔（「A / B」「A、B」「A feat. B」「A & B」）。
final RegExp _artistSplit = RegExp(
  r'\s*(?:/|、|,|，|;|；|&|＆| feat\.? | ft\.? | x | × )\s*',
  caseSensitive: false,
);

List<String> _artistNames(MusicPlayItem item) => <String>[
  for (final MusicPlayArtistRef a in item.artistRefs) a.name,
  if (item.artistRefs.isEmpty)
    ...?item.artist
        ?.split(_artistSplit)
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty),
];

/// 这个播放项能不能点进歌手页（有歌手名，且不是服务器曲目）。
bool musicItemHasArtistLink(MusicPlayItem item) =>
    _artistNames(item).isNotEmpty && !_isRemoteStream(item);

/// 这个播放项能不能点进专辑页。
bool musicItemHasAlbumLink(MusicPlayItem item) {
  if (parseMusicPluginTrackPath(item.path) != null) {
    return item.sourceAlbumId != null;
  }
  return item.albumUid != null && !_isRemoteStream(item);
}

bool _isRemoteStream(MusicPlayItem item) =>
    item.path.startsWith('http://') || item.path.startsWith('https://');

Future<MusicPluginManifest?> _manifestOf(AppModel app, String pluginId) async {
  for (final InstalledMusicPlugin p in await app.musicPluginManager.list()) {
    if (p.id == pluginId && p.usable) return p.info!.manifest;
  }
  return null;
}

Future<void> _push(BuildContext context, Widget page) => Navigator.of(
  context,
).push<void>(adaptivePageRoute<void>(context: context, builder: (_) => page));

/// 多个歌手时先让用户挑一个；一个就直接返回。
Future<int?> _pickArtist(BuildContext context, List<String> names) async {
  if (names.length == 1) return 0;
  return showFushiChoiceDialog<int>(
    context: context,
    title: t.music_section_artists,
    icon: FushiIcons.person,
    options: <FushiChoiceOption<int>>[
      for (int i = 0; i < names.length; i++)
        FushiChoiceOption<int>(value: i, label: names[i]),
    ],
  );
}

/// 打开 [item] 的歌手页。
Future<void> openMusicArtistOf(
  BuildContext context,
  AppModel app,
  MusicPlayItem item,
) async {
  final List<String> names = _artistNames(item);
  if (names.isEmpty) return;
  final int? pick = await _pickArtist(context, names);
  if (pick == null || !context.mounted) return;
  final String name = names[pick];
  final ({String pluginId, String trackId})? plugin = parseMusicPluginTrackPath(
    item.path,
  );
  if (plugin != null) {
    final MusicPluginManifest? m = await _manifestOf(app, plugin.pluginId);
    if (m == null || !context.mounted) {
      FushiToast.show(msg: t.music_link_unavailable);
      return;
    }
    String? id = pick < item.artistRefs.length
        ? item.artistRefs[pick].id
        : null;
    if (id == null) {
      // 老播放项（最近播放重建）没带歌手 id：按名字在插件里搜，取同名的第一个。
      try {
        final MusicPluginPage<MusicPluginArtist> r = await app
            .musicPluginManager
            .source(m.id)
            .searchArtists(name, pageSize: 10);
        id = r.items
            .where(
              (MusicPluginArtist a) =>
                  a.name.toLowerCase() == name.toLowerCase(),
            )
            .firstOrNull
            ?.id;
      } on Object {
        id = null;
      }
    }
    if (!context.mounted) return;
    if (id == null) {
      FushiToast.show(msg: t.music_link_unavailable);
      return;
    }
    await _push(
      context,
      MusicPluginArtistPage(
        manifest: m,
        artist: MusicPluginArtist(id: id, name: name),
      ),
    );
    return;
  }
  // 本地：按名字（不分大小写）匹配曲库歌手表。
  final FushiDatabase db = app.database;
  final MusicArtistRow? artist = (await db.listMusicArtists())
      .where((MusicArtistRow a) => a.name.toLowerCase() == name.toLowerCase())
      .firstOrNull;
  if (!context.mounted) return;
  if (artist == null) {
    FushiToast.show(msg: t.music_link_unavailable);
    return;
  }
  final List<MusicTrackRow> tracks = await db.listMusicTracksByArtist(
    artist.artistUid,
  );
  final Map<String, MusicAlbumRow> albums = <String, MusicAlbumRow>{};
  for (final String uid in <String>{
    for (final MusicTrackRow t in tracks)
      if (t.albumUid != null) t.albumUid!,
  }) {
    final MusicAlbumRow? a = await db.getMusicAlbum(uid);
    if (a != null) albums[uid] = a;
  }
  if (!context.mounted) return;
  await _push(
    context,
    MusicTrackListPage(title: artist.name, tracks: tracks, albums: albums),
  );
}

/// 打开 [item] 的专辑页。
Future<void> openMusicAlbumOf(
  BuildContext context,
  AppModel app,
  MusicPlayItem item,
) async {
  final ({String pluginId, String trackId})? plugin = parseMusicPluginTrackPath(
    item.path,
  );
  if (plugin != null) {
    final String? albumId = item.sourceAlbumId;
    final MusicPluginManifest? m = await _manifestOf(app, plugin.pluginId);
    if (albumId == null || m == null || !context.mounted) {
      if (context.mounted) FushiToast.show(msg: t.music_link_unavailable);
      return;
    }
    await _push(
      context,
      MusicPluginCollectionPage.album(
        manifest: m,
        album: MusicPluginAlbum(
          id: albumId,
          title: item.album ?? '',
          coverUrl: item.coverPath,
        ),
      ),
    );
    return;
  }
  final String? uid = item.albumUid;
  if (uid == null) return;
  final FushiDatabase db = app.database;
  final MusicAlbumRow? album = await db.getMusicAlbum(uid);
  if (album == null || !context.mounted) {
    if (context.mounted) FushiToast.show(msg: t.music_link_unavailable);
    return;
  }
  final List<MusicTrackRow> tracks = await db.listMusicTracks(albumUid: uid);
  if (!context.mounted) return;
  await _push(context, MusicAlbumPage(album: album, tracks: tracks));
}
