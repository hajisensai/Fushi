library;

import 'package:drift/drift.dart' show Value;
import 'package:hibiki/src/media/source_library/source_library_row.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_database_store.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_nfo_reader.dart';
import 'package:hibiki/src/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:hibiki/src/media/video/metadata/video_source_work_planner.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

class VideoLocalExtraMatch {
  const VideoLocalExtraMatch(this.kind);

  final VideoMetadataExtraKind kind;
}

/// Kodi 风格本地附件识别。仅分类，不决定作品归属。
VideoLocalExtraMatch? classifyLocalVideoExtra(String path) {
  final List<String> segments = p
      .split(p.normalize(path))
      .map((String value) =>
          value.toLowerCase().replaceAll(RegExp(r'[_-]+'), ' '))
      .toList(growable: false);
  final String stem = p.basenameWithoutExtension(path).toLowerCase();
  VideoMetadataExtraKind? kind;
  for (final String segment in segments.reversed) {
    kind = switch (segment.trim()) {
      'trailers' || 'trailer' => VideoMetadataExtraKind.trailer,
      'featurettes' || 'featurette' => VideoMetadataExtraKind.featurette,
      'behind the scenes' => VideoMetadataExtraKind.behindTheScenes,
      'deleted scenes' ||
      'deleted scene' =>
        VideoMetadataExtraKind.deletedScene,
      'interviews' || 'interview' => VideoMetadataExtraKind.interview,
      'shorts' || 'short' => VideoMetadataExtraKind.short,
      'scenes' || 'scene' => VideoMetadataExtraKind.scene,
      'samples' || 'sample' => VideoMetadataExtraKind.sample,
      'extras' || 'extra' => VideoMetadataExtraKind.extra,
      _ => kind,
    };
    if (kind != null) break;
  }
  if (kind == null && RegExp(r'(^|[ ._\-])trailer([ ._\-]|$)').hasMatch(stem)) {
    kind = VideoMetadataExtraKind.trailer;
  }
  return kind == null ? null : VideoLocalExtraMatch(kind);
}

/// 扫描完成后的本地作品索引：即使尚未联网刮削，也建立可展示的规范作品；同时绑定
/// 唯一可判定归属的本地预告/花絮。
class VideoSourceMetadataIndexer {
  const VideoSourceMetadataIndexer(this.database);

  final HibikiDatabase database;

  Future<void> index(SourceLibraryRow source) async {
    if (source.mediaKind != 'video' || source.transport != 'local') return;
    final List<VideoSourceScrapeWork> allWorks =
        await VideoSourceWorkPlanner(database).plan(source);
    final List<VideoSourceScrapeWork> works = <VideoSourceScrapeWork>[
      for (final VideoSourceScrapeWork work in allWorks)
        if (work.members.any((VideoBookRow member) =>
            classifyLocalVideoExtra(member.videoPath) == null))
          work,
    ];
    final VideoMetadataDatabaseStore store =
        VideoMetadataDatabaseStore(database);
    final VideoNfoReader nfoReader = VideoNfoReader(
      generatedArtifactChecker:
          DatabaseSidecarGeneratedArtifactChecker(database),
    );
    final Map<int, _IndexedWorkRoot> indexed = <int, _IndexedWorkRoot>{};
    for (final VideoSourceScrapeWork work in works) {
      final VideoMetadataWorkRow? existing = work.collection == null
          ? await database
              .getVideoMetadataWorkByBook(work.members.single.bookUid)
          : await database
              .getVideoMetadataWorkByCollection(work.collection!.id);
      final VideoMetadataWork? nfoMetadata = await nfoReader.readForPaths(
        sourceRoot: source.rootPath,
        fallbackTitle: work.title,
        videoPaths: <String>[
          for (final VideoBookRow member in work.members) member.videoPath,
        ],
      );
      int workId;
      if (existing != null && nfoMetadata == null) {
        workId = existing.id;
      } else {
        final VideoMetadataWork metadata = nfoMetadata ?? _provisional(work);
        workId = (await store.apply(
          work,
          metadata,
          seasonEpisodesAuthoritative: metadata.seasons.isNotEmpty,
        ))
            .workId;
      }
      indexed[workId] = _IndexedWorkRoot(
        workId: workId,
        root: _workRoot(work.members, source.rootPath),
      );
    }

    final List<VideoBookRow> books = (await database.allVideoBooks())
        .where((VideoBookRow row) => row.sourceId == source.id)
        .toList(growable: false);
    for (final VideoBookRow book in books) {
      final VideoLocalExtraMatch? match =
          classifyLocalVideoExtra(book.videoPath);
      if (match == null) continue;
      final String directory =
          p.dirname(p.normalize(p.absolute(book.videoPath)));
      final List<_IndexedWorkRoot> candidates = indexed.values
          .where((_IndexedWorkRoot value) =>
              p.equals(value.root, directory) ||
              p.isWithin(value.root, directory))
          .toList()
        ..sort((_IndexedWorkRoot a, _IndexedWorkRoot b) =>
            b.root.length.compareTo(a.root.length));
      if (candidates.isEmpty ||
          (candidates.length > 1 &&
              candidates[0].root.length == candidates[1].root.length)) {
        continue;
      }
      final int now = DateTime.now().millisecondsSinceEpoch;
      await database.upsertVideoMetadataExtra(
        VideoMetadataExtrasCompanion.insert(
          extraKey: 'local:${book.bookUid}',
          workId: candidates.first.workId,
          bookUid: Value<String?>(book.bookUid),
          kind: _kindName(match.kind),
          sourceKind: 'local',
          title: book.title,
          thumbnailPath: Value<String?>(book.coverPath),
          sortOrder: const Value<int>(0),
          updatedAt: now,
        ),
      );
    }
  }

  static VideoMetadataWork _provisional(VideoSourceScrapeWork work) {
    final Map<int, List<VideoMetadataEpisode>> episodes =
        <int, List<VideoMetadataEpisode>>{};
    for (final VideoBookRow member in work.members) {
      final VideoNameInfo parsed =
          parseVideoFilename(p.basename(member.videoPath));
      if (parsed.episode == null) continue;
      final int season = parsed.season ?? 1;
      episodes.putIfAbsent(season, () => <VideoMetadataEpisode>[]).add(
            VideoMetadataEpisode(
              seasonNumber: season,
              episodeNumber: parsed.episode!,
              title: member.title,
            ),
          );
    }
    final bool episodic = work.isEpisodic || episodes.isNotEmpty;
    return VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: episodic ? VideoMetadataMediaKind.tv : VideoMetadataMediaKind.movie,
      title: work.title,
      seasons: <VideoMetadataSeason>[
        for (final MapEntry<int, List<VideoMetadataEpisode>> entry
            in episodes.entries)
          VideoMetadataSeason(
            seasonNumber: entry.key,
            title: 'Season ${entry.key}',
            episodeCount: entry.value.length,
            episodes: entry.value
              ..sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
                  a.episodeNumber.compareTo(b.episodeNumber)),
          ),
      ],
    );
  }

  static String _workRoot(List<VideoBookRow> members, String sourceRoot) {
    List<String> parts =
        p.split(p.dirname(p.normalize(p.absolute(members.first.videoPath))));
    for (final VideoBookRow member in members.skip(1)) {
      final List<String> other =
          p.split(p.dirname(p.normalize(p.absolute(member.videoPath))));
      int length = 0;
      while (length < parts.length &&
          length < other.length &&
          parts[length].toLowerCase() == other[length].toLowerCase()) {
        length++;
      }
      parts = parts.take(length).toList(growable: false);
    }
    String root = p.joinAll(parts);
    if (RegExp(r'^(season|s)\s*\d+|specials$', caseSensitive: false)
        .hasMatch(p.basename(root))) {
      root = p.dirname(root);
    }
    final String source = p.normalize(p.absolute(sourceRoot));
    return p.isWithin(source, root) ? root : source;
  }

  static String _kindName(VideoMetadataExtraKind kind) => switch (kind) {
        VideoMetadataExtraKind.behindTheScenes => 'behind_the_scenes',
        VideoMetadataExtraKind.deletedScene => 'deleted_scene',
        _ => kind.name,
      };
}

class _IndexedWorkRoot {
  const _IndexedWorkRoot({required this.workId, required this.root});
  final int workId;
  final String root;
}
