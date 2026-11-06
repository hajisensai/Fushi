import 'dart:async';

import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_detector.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi_core/fushi_core.dart';

/// 手动连接里可选的关系（原声需要 OST 专辑端点、声优需要人物端点，那两类本地条目
/// 落地前不提供）。主题曲只在一端音乐、一端视频时可选（[mediaLinkThemeSongCompatible]）。
const List<MediaLinkRelation> kMediaLinkPickableRelations = <MediaLinkRelation>[
  MediaLinkRelation.adaptation,
  MediaLinkRelation.sameWork,
  MediaLinkRelation.themeSong,
];

/// 主题曲连接可选的角色（`media_links.role`）。
const List<ThemeSongRole> kMediaLinkPickableThemeSongRoles = <ThemeSongRole>[
  ThemeSongRole.op,
  ThemeSongRole.ed,
  ThemeSongRole.insert,
];

/// 一次手动连接写入的结果：连接身份 + 写入前这一行的快照（没有 = null，撤销用）。
typedef ManualMediaLinkWrite = ({MediaLinkId id, MediaLinkRow? previous});

/// 详情页「关联作品」对话框与 AI 操作 `links.add` 共用的写入：按关系定方向，写一条
/// 手动连接（[FushiDatabase.upsertManualMediaLink]，恒为已确认）。
///
/// - [MediaLinkRelation.themeSong]：方向固定「音乐 → 视频」，[self] / [target] 谁是音乐
///   都行；写完后台识别这条连接覆盖的各集；两端不是「音乐 + 视频」抛 [ArgumentError]；
/// - [MediaLinkRelation.adaptation]：[selfIsOriginal] = true 时本条是原作（本条 → 目标）；
/// - [MediaLinkRelation.sameWork]：无方向。
Future<ManualMediaLinkWrite> writeManualMediaLink(
  FushiDatabase db, {
  required MediaLinkEndpoint self,
  required MediaLinkEndpoint target,
  required MediaLinkRelation relation,
  bool selfIsOriginal = true,
  ThemeSongRole themeSongRole = ThemeSongRole.op,
  String episodeRange = '',
  int? at,
}) async {
  if (!kMediaLinkPickableRelations.contains(relation)) {
    throw ArgumentError.value(relation.dbValue, 'relation', '不能手动连接');
  }
  final MediaLinkEndpoint from;
  final MediaLinkEndpoint to;
  if (relation == MediaLinkRelation.themeSong) {
    if (!mediaLinkThemeSongCompatible(self.kind, target.kind)) {
      throw ArgumentError('主题曲连接要一端是音乐、一端是视频');
    }
    final bool selfIsMusic = mediaLinkIsMusicKind(self.kind);
    from = selfIsMusic ? self : target;
    to = selfIsMusic ? target : self;
  } else {
    final bool selfIsFrom =
        relation != MediaLinkRelation.adaptation || selfIsOriginal;
    from = selfIsFrom ? self : target;
    to = selfIsFrom ? target : self;
  }
  final MediaLinkRow? previous = await db.mediaLinkById(
    mediaLinkIdFor(relation, from, to),
  );
  final String range = episodeRange.trim();
  final MediaLinkId id = await db.upsertManualMediaLink(
    relation: relation,
    from: from,
    to: to,
    role: relation == MediaLinkRelation.themeSong ? themeSongRole.wire : null,
    // 解析不了的范围按「全部」存（不把一段垃圾文本冻进 wire 值）。
    episodeRange:
        relation == MediaLinkRelation.themeSong &&
            parseEpisodeRange(range) != null
        ? range
        : null,
    at: at,
  );
  if (relation == MediaLinkRelation.themeSong) {
    // 后台识别这条连接覆盖的各集（串行队列、缓存有效的集跳过）。
    unawaited(
      themeSongDetectorFor(db).detect(
        onlyTrackUid: from.kind == MediaLinkKind.musicTrack ? from.key : null,
      ),
    );
  }
  return (id: id, previous: previous);
}
