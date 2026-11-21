/// 合集详情里「这一集只能在线播放」的标签（拍板台 646L8W6DK2）。
///
/// 在线视频源（Aniyomi 扩展）入库、还没下载的集，`videoPath` 是 `anime-source://`
/// 标识；下载完的集会被替换成本地文件（见 `anime_source_library.dart`），于是
/// 「是不是只在线」的判据就是 [isAnimeSourceVideoPath]。源名从扩展表
/// （`manga_online_sources`，`media_kind = 'anime'`）按 `(扩展包, 源 id)` 查——
/// 只读数据库，不碰 `AppModel.animeMihonManager`（取它会把本进程判成「在用在线源」，
/// 推迟扩展自动更新）。
library;

import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, MangaOnlineSourceRow, VideoBookRow;
import 'package:fushi_engine/media/video/anime_source_video_path.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart'
    show MihonMediaKind;

/// 只在线播放的成员：bookUid → 源名（扩展已卸载 / 源表里查不到时为 null）。
/// 不在结果里的成员 = 本地文件（或别的流媒体形态），照旧显示规格摘要。
Map<String, String?> animeSourceStreamingNames(
  Iterable<VideoBookRow> members,
  Iterable<MangaOnlineSourceRow> sources,
) {
  final Map<String, String> nameByRef = <String, String>{
    for (final MangaOnlineSourceRow source in sources)
      if (source.name.trim().isNotEmpty)
        '${source.extensionPackage}/${source.sourceId}': source.name.trim(),
  };
  return <String, String?>{
    for (final VideoBookRow member in members)
      if (isAnimeSourceVideoPath(member.videoPath))
        member.bookUid: switch (parseAnimeSourceVideoPath(member.videoPath)) {
          (:final String extensionPackage, :final String sourceId) =>
            nameByRef['$extensionPackage/$sourceId'],
          null => null,
        },
  };
}

/// 读库版 [animeSourceStreamingNames]：成员里没有在线集时不查源表。
Future<Map<String, String?>> loadAnimeSourceStreamingNames(
  FushiDatabase database,
  List<VideoBookRow> members,
) async {
  if (!members.any((VideoBookRow m) => isAnimeSourceVideoPath(m.videoPath))) {
    return const <String, String?>{};
  }
  final List<MangaOnlineSourceRow> sources = await database
      .getMangaOnlineSources(mediaKind: MihonMediaKind.anime.dbValue);
  return animeSourceStreamingNames(members, sources);
}

/// 状态行文字：`Streams · Anikoto`；源名未知时只写 `Streams`。
String animeSourceStreamingLabel(String? sourceName) =>
    sourceName == null || sourceName.isEmpty
    ? t.media_collection_episode_streams
    : t.media_collection_episode_streams_source(source: sourceName);
