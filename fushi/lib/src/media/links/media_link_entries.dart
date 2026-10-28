import 'package:fushi/src/mining/galgame_repository.dart'
    show galgameEntryFromRow;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_cover.dart'
    show
        collectionOwnCoverCandidates,
        firstExistingCoverPath,
        loadCollectionOwnCoverCandidates;
import 'package:material_ui/material_ui.dart';

/// 作品图谱一个端点在本机的展示信息（[resolveMediaLinkEntry] 产出）。
@immutable
class MediaLinkEntry {
  const MediaLinkEntry({
    required this.endpoint,
    required this.title,
    required this.inLibrary,
    this.coverPath,
  });

  final MediaLinkEndpoint endpoint;

  /// 显示标题；本机没有该条目时是由键推出的最佳猜测（书 bookKey 由标题派生）。
  final String title;

  /// 本机库里是否存在该条目。false = 「未入库」灰卡。
  final bool inLibrary;

  /// 本地封面绝对路径（可空）。
  final String? coverPath;
}

/// 某个详情页视角下的一条连接：[other] 是另一端，[otherIsFrom] 表示另一端是不是
/// 连接的 `from`（adaptation 的原作、theme_song 的音乐那一端）。
@immutable
class MediaLinkView {
  const MediaLinkView({
    required this.row,
    required this.other,
    required this.otherIsFrom,
  });

  final MediaLinkRow row;
  final MediaLinkEntry other;
  final bool otherIsFrom;

  MediaLinkId get id => mediaLinkIdOf(row);
  MediaLinkRelation? get relation => MediaLinkRelation.tryParse(row.relation);
  MediaLinkState get state => mediaLinkStateOf(row);
}

/// 端点种类 ↔ 合集 / 库页的 [MediaKind]（只用于封面解析与图标；作品图谱自己的
/// 值域与 [MediaKind] 不同，跨域换算只在这里写一次）。
MediaKind? mediaKindOfLinkKind(MediaLinkKind kind) => switch (kind) {
  MediaLinkKind.book || MediaLinkKind.audiobook => MediaKind.epub,
  MediaLinkKind.videoCollection ||
  MediaLinkKind.videoEpisode => MediaKind.video,
  MediaLinkKind.game => MediaKind.game,
  MediaLinkKind.musicAlbum || MediaLinkKind.musicTrack => null,
};

/// 端点种类的显示名。
String mediaLinkKindLabel(MediaLinkKind kind) => switch (kind) {
  MediaLinkKind.videoCollection => t.media_link_kind_video_collection,
  MediaLinkKind.videoEpisode => t.media_link_kind_video_episode,
  MediaLinkKind.book => t.media_link_kind_book,
  MediaLinkKind.game => t.media_link_kind_game,
  MediaLinkKind.musicAlbum => t.media_link_kind_music_album,
  MediaLinkKind.musicTrack => t.media_link_kind_music_track,
  MediaLinkKind.audiobook => t.media_link_kind_audiobook,
};

/// 端点种类的图标（占位封面与选择器行首用）。
IconData mediaLinkKindIcon(MediaLinkKind kind) => switch (kind) {
  MediaLinkKind.videoCollection => FushiIcons.video,
  MediaLinkKind.videoEpisode => FushiIcons.video,
  MediaLinkKind.book => FushiIcons.books,
  MediaLinkKind.game => FushiIcons.game,
  MediaLinkKind.musicAlbum => FushiIcons.music,
  MediaLinkKind.musicTrack => FushiIcons.music,
  MediaLinkKind.audiobook => FushiIcons.audiobook,
};

/// 关系的显示名。
String mediaLinkRelationLabel(MediaLinkRelation relation) => switch (relation) {
  MediaLinkRelation.adaptation => t.media_link_relation_adaptation,
  MediaLinkRelation.themeSong => t.media_link_relation_theme_song,
  MediaLinkRelation.soundtrack => t.media_link_relation_soundtrack,
  MediaLinkRelation.sameWork => t.media_link_relation_same_work,
  MediaLinkRelation.cast => t.media_link_relation_cast,
};

/// 卡片角标：站在本页条目的视角描述另一端是什么（「原作」「改编作」「主题曲」…）。
String mediaLinkBadgeLabel(MediaLinkView view) {
  final MediaLinkRelation? relation = view.relation;
  if (relation == null) return view.row.relation;
  if (relation == MediaLinkRelation.adaptation) {
    return view.otherIsFrom
        ? t.media_link_role_original
        : t.media_link_role_adapted;
  }
  return mediaLinkRelationLabel(relation);
}

/// 把一个端点解析成本机展示信息。本机不存在时 [MediaLinkEntry.inLibrary] 为
/// false，标题由键推出（不抛）。
Future<MediaLinkEntry> resolveMediaLinkEntry(
  FushiDatabase db,
  MediaLinkEndpoint endpoint,
) async {
  MediaLinkEntry missing(String title) =>
      MediaLinkEntry(endpoint: endpoint, title: title, inLibrary: false);
  switch (endpoint.kind) {
    case MediaLinkKind.book:
    case MediaLinkKind.audiobook:
      final EpubBookRow? book = await db.getEpubBook(endpoint.key);
      if (book == null) return missing(endpoint.key);
      return MediaLinkEntry(
        endpoint: endpoint,
        title: book.title,
        inLibrary: true,
        coverPath: book.coverPath,
      );
    case MediaLinkKind.videoEpisode:
      final VideoBookRow? video = await db.getVideoBookByBookUid(endpoint.key);
      if (video == null) return missing(endpoint.key);
      return MediaLinkEntry(
        endpoint: endpoint,
        title: video.title,
        inLibrary: true,
        coverPath: video.coverPath,
      );
    case MediaLinkKind.videoCollection:
      final int? id = collectionIdOfTagEntryKey(endpoint.key);
      final MediaCollectionRow? collection = id == null
          ? null
          : await db.getMediaCollectionById(id);
      if (collection == null) return missing(endpoint.key);
      return MediaLinkEntry(
        endpoint: endpoint,
        title: collection.name,
        inLibrary: true,
        coverPath: await firstExistingCoverPath(
          await loadCollectionOwnCoverCandidates(db, collection),
        ),
      );
    case MediaLinkKind.game:
      final GalgameRow? game = await db.getGalgame(endpoint.key);
      if (game == null) return missing(endpoint.key);
      final List<GalgameSourceRow> sources = await db.getGalgameSources(
        endpoint.key,
      );
      return MediaLinkEntry(
        endpoint: endpoint,
        title: galgameEntryFromRow(game, sources: sources).displayName,
        inLibrary: true,
        coverPath: game.coverPath,
      );
    case MediaLinkKind.musicAlbum:
      final MusicAlbumRow? album = await db.getMusicAlbum(endpoint.key);
      if (album == null) return missing(endpoint.key);
      return MediaLinkEntry(
        endpoint: endpoint,
        title: album.title,
        inLibrary: true,
        coverPath: album.coverPath,
      );
    case MediaLinkKind.musicTrack:
      final MusicTrackRow? track = await db.getMusicTrack(endpoint.key);
      if (track == null || track.deletedAt != null) {
        return missing(endpoint.key);
      }
      final String? albumUid = track.albumUid;
      final MusicAlbumRow? album = albumUid == null
          ? null
          : await db.getMusicAlbum(albumUid);
      return MediaLinkEntry(
        endpoint: endpoint,
        title: track.title,
        inLibrary: true,
        coverPath: album?.coverPath,
      );
  }
}

/// 某个本机条目的全部连接（不含墓碑），已解析好另一端。未知种类 / 关系的行
/// （对端未来版本写的）跳过。已确认在前、建议在后，各自按创建时间。
Future<List<MediaLinkView>> loadMediaLinkViews(
  FushiDatabase db,
  MediaLinkEndpoint self,
) async {
  final List<MediaLinkView> views = <MediaLinkView>[];
  for (final MediaLinkRow row in await db.mediaLinksForEndpoint(
    self.kind,
    self.key,
  )) {
    final bool selfIsFrom =
        row.fromKind == self.kind.dbValue && row.fromKey == self.key;
    final MediaLinkKind? otherKind = MediaLinkKind.tryParse(
      selfIsFrom ? row.toKind : row.fromKind,
    );
    if (otherKind == null || MediaLinkRelation.tryParse(row.relation) == null) {
      continue;
    }
    final MediaLinkEntry other = await resolveMediaLinkEntry(db, (
      kind: otherKind,
      key: selfIsFrom ? row.toKey : row.fromKey,
    ));
    views.add(MediaLinkView(row: row, other: other, otherIsFrom: !selfIsFrom));
  }
  return views;
}

/// 手动连接对话框里可选的目标种类（有声书与其 EPUB 共用 bookKey，连书即可）。
const List<MediaLinkKind> kMediaLinkPickableKinds = <MediaLinkKind>[
  MediaLinkKind.videoCollection,
  MediaLinkKind.videoEpisode,
  MediaLinkKind.book,
  MediaLinkKind.game,
  // 主题曲连接（作品图谱 L2）的音乐端。专辑端点只由同步 / 推断带来：OP / ED 是单曲，
  // 手动连接选曲目即可，分段按钮也放不下第六段。
  MediaLinkKind.musicTrack,
];

/// 主题曲连接要求一端是音乐、一端是视频（合集或单个视频）。
bool mediaLinkThemeSongCompatible(MediaLinkKind a, MediaLinkKind b) {
  bool isMusic(MediaLinkKind k) =>
      k == MediaLinkKind.musicTrack || k == MediaLinkKind.musicAlbum;
  bool isVideo(MediaLinkKind k) =>
      k == MediaLinkKind.videoCollection || k == MediaLinkKind.videoEpisode;
  return (isMusic(a) && isVideo(b)) || (isVideo(a) && isMusic(b));
}

/// 主题曲连接的方向固定为「音乐 → 视频」（`MediaLinkRelation.themeSong` 的约定）。
bool mediaLinkIsMusicKind(MediaLinkKind k) =>
    k == MediaLinkKind.musicTrack || k == MediaLinkKind.musicAlbum;

/// 某种类的全部本机条目（手动连接的候选），按标题排序。
Future<List<MediaLinkEntry>> loadMediaLinkCandidates(
  FushiDatabase db,
  MediaLinkKind kind,
) async {
  final List<MediaLinkEntry> out = <MediaLinkEntry>[];
  switch (kind) {
    case MediaLinkKind.book:
    case MediaLinkKind.audiobook:
      for (final EpubBookRow b in await db.getAllEpubBooks()) {
        out.add(
          MediaLinkEntry(
            endpoint: (kind: kind, key: b.bookKey),
            title: b.title,
            inLibrary: true,
            coverPath: b.coverPath,
          ),
        );
      }
    case MediaLinkKind.videoEpisode:
      for (final VideoBookRow v in await db.allVideoBooks()) {
        out.add(
          MediaLinkEntry(
            endpoint: (kind: kind, key: v.bookUid),
            title: v.title,
            inLibrary: true,
            coverPath: v.coverPath,
          ),
        );
      }
    case MediaLinkKind.videoCollection:
      // 合集表不带种类列：按成员推导出的视频库域取（与「加入合集」同一判据）。
      final Map<int, List<MediaImageRow>> discCovers =
          <int, List<MediaImageRow>>{};
      for (final MediaImageRow row in await db.getMediaImagesOfKind(
        MediaImageKind.discCover,
      )) {
        if (row.collectionId case final int id) {
          (discCovers[id] ??= <MediaImageRow>[]).add(row);
        }
      }
      for (final MediaCollectionRow c
          in await db.getMediaCollectionsForEntryDomain(MediaKind.video, '')) {
        out.add(
          MediaLinkEntry(
            endpoint: (kind: kind, key: collectionTagEntryKey(c.id)),
            title: c.name,
            inLibrary: true,
            coverPath: await firstExistingCoverPath(
              collectionOwnCoverCandidates(c, discCovers[c.id]),
            ),
          ),
        );
      }
    case MediaLinkKind.game:
      final Map<String, List<GalgameSourceRow>> sources = await db
          .getAllGalgameSources();
      for (final GalgameRow g in await db.getAllGalgames()) {
        out.add(
          MediaLinkEntry(
            endpoint: (kind: kind, key: g.id),
            title: galgameEntryFromRow(
              g,
              sources: sources[g.id] ?? const <GalgameSourceRow>[],
            ).displayName,
            inLibrary: true,
            coverPath: g.coverPath,
          ),
        );
      }
    case MediaLinkKind.musicAlbum:
      for (final MusicAlbumRow a in await db.listMusicAlbums()) {
        out.add(
          MediaLinkEntry(
            endpoint: (kind: kind, key: a.albumUid),
            title: a.title,
            inLibrary: true,
            coverPath: a.coverPath,
          ),
        );
      }
    case MediaLinkKind.musicTrack:
      final Map<String, MusicAlbumRow> albums = <String, MusicAlbumRow>{
        for (final MusicAlbumRow a in await db.listMusicAlbums()) a.albumUid: a,
      };
      for (final MusicTrackRow tr in await db.listMusicTracks()) {
        if (tr.deletedAt != null) continue;
        final MusicAlbumRow? album = tr.albumUid == null
            ? null
            : albums[tr.albumUid];
        out.add(
          MediaLinkEntry(
            endpoint: (kind: kind, key: tr.trackUid),
            // 同名曲目（TV size / 完整版 / 伴奏）靠专辑名区分。
            title: album == null ? tr.title : '${tr.title} · ${album.title}',
            inLibrary: true,
            coverPath: album?.coverPath,
          ),
        );
      }
  }
  out.sort((MediaLinkEntry a, MediaLinkEntry b) => a.title.compareTo(b.title));
  return out;
}
