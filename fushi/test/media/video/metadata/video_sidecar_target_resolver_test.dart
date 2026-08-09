import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_sidecar_target_resolver.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fushi_targets_');
  });

  tearDown(() async {
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  test('独立电影使用 MoviePilot 根图名，共享目录使用视频名前缀', () {
    final String movie = p.join(temporary.path, 'Movies', 'Film.mkv');
    final VideoSidecarLayout dedicated =
        VideoSidecarTargetResolver.resolveMovie(
      sourceRoot: temporary.path,
      videoPath: movie,
      knownSourceVideoPaths: <String>[movie],
    );
    expect(
        dedicated.work?.nfoPath, p.join(temporary.path, 'Movies', 'Film.nfo'));
    expect(
      dedicated.work?.imagePaths(VideoMetadataImageKind.cover),
      <String>[p.join(temporary.path, 'Movies', 'poster.jpg')],
    );
    expect(
      dedicated.work?.imagePaths(VideoMetadataImageKind.backdrop),
      <String>[
        p.join(temporary.path, 'Movies', 'backdrop.jpg'),
        p.join(temporary.path, 'Movies', 'fanart.jpg'),
      ],
    );

    final VideoSidecarLayout shared = VideoSidecarTargetResolver.resolveMovie(
      sourceRoot: temporary.path,
      videoPath: movie,
      knownSourceVideoPaths: <String>[
        movie,
        p.join(temporary.path, 'Movies', 'Other.mp4'),
      ],
    );
    expect(
      shared.work?.imagePaths(VideoMetadataImageKind.cover),
      <String>[p.join(temporary.path, 'Movies', 'Film-poster.jpg')],
    );
    expect(
      shared.work?.imagePaths(VideoMetadataImageKind.backdrop),
      <String>[
        p.join(temporary.path, 'Movies', 'Film-backdrop.jpg'),
        p.join(temporary.path, 'Movies', 'Film-fanart.jpg'),
      ],
    );
  });

  test('电影直接位于来源根时始终使用视频名前缀', () {
    final String movie = p.join(temporary.path, 'Film.mkv');
    final VideoSidecarTarget target = VideoSidecarTargetResolver.resolveMovie(
      sourceRoot: temporary.path,
      videoPath: movie,
      knownSourceVideoPaths: <String>[movie],
    ).work!;

    expect(
      target.imagePaths(VideoMetadataImageKind.cover),
      <String>[p.join(temporary.path, 'Film-poster.jpg')],
    );
  });

  test('嵌套电视剧推导唯一作品根、季目录与稳定逐集目标', () {
    final String root = p.join(temporary.path, 'source');
    final String s1e1 = p.join(root, 'My Show', 'Season 01', 'S01E01.mkv');
    final String s1e2 = p.join(root, 'My Show', 'Season 01', 'S01E02.mkv');
    final String s2e1 = p.join(root, 'My Show', 'Season 02', 'S02E01.mkv');
    final VideoSidecarLayout layout = VideoSidecarTargetResolver.resolveTv(
      sourceRoot: root,
      members: <VideoEpisodePath>[
        VideoEpisodePath(path: s2e1, seasonNumber: 2, episodeNumber: 1),
        VideoEpisodePath(path: s1e2, seasonNumber: 1, episodeNumber: 2),
        VideoEpisodePath(path: s1e1, seasonNumber: 1, episodeNumber: 1),
      ],
      knownSourceVideoPaths: <String>[s1e1, s1e2, s2e1],
    );

    expect(layout.work?.nfoPath, p.join(root, 'My Show', 'tvshow.nfo'));
    expect(
      layout.seasons.map((VideoSidecarTarget target) => target.nfoPath),
      <String>[
        p.join(root, 'My Show', 'Season 01', 'season.nfo'),
        p.join(root, 'My Show', 'Season 02', 'season.nfo'),
      ],
    );
    expect(
      layout.episodes.map((VideoSidecarTarget target) => target.nfoPath),
      <String>[
        p.join(root, 'My Show', 'Season 01', 'S01E01.nfo'),
        p.join(root, 'My Show', 'Season 01', 'S01E02.nfo'),
        p.join(root, 'My Show', 'Season 02', 'S02E01.nfo'),
      ],
      reason: '目标必须按季、集、路径稳定排序',
    );

    final VideoSidecarTarget firstSeason = layout.seasons.first;
    expect(
      firstSeason.imagePaths(VideoMetadataImageKind.cover, extension: '.png'),
      <String>[
        p.join(root, 'My Show', 'season01-poster.png'),
        p.join(root, 'My Show', 'Season 01', 'poster.png'),
      ],
    );
    expect(
      firstSeason.imagePaths(VideoMetadataImageKind.backdrop),
      <String>[
        p.join(root, 'My Show', 'season01-backdrop.jpg'),
        p.join(root, 'My Show', 'Season 01', 'backdrop.jpg'),
        p.join(root, 'My Show', 'Season 01', 'fanart.jpg'),
      ],
    );
    expect(
      layout.episodes.first.imagePaths(VideoMetadataImageKind.thumb),
      <String>[p.join(root, 'My Show', 'Season 01', 'S01E01.jpg')],
    );
  });

  test('单季也从 Season 目录上提到作品根，特别篇图使用 specials 名', () {
    final String root = p.join(temporary.path, 'source');
    final String special = p.join(root, 'My Show', 'Specials', 'S00E01.mkv');
    final VideoSidecarLayout layout = VideoSidecarTargetResolver.resolveTv(
      sourceRoot: root,
      members: <VideoEpisodePath>[
        VideoEpisodePath(path: special, seasonNumber: 0, episodeNumber: 1),
      ],
      knownSourceVideoPaths: <String>[special],
    );

    expect(layout.work?.nfoPath, p.join(root, 'My Show', 'tvshow.nfo'));
    expect(layout.seasons, hasLength(1));
    expect(
      layout.seasons.single.imagePaths(VideoMetadataImageKind.cover).first,
      p.join(root, 'My Show', 'season-specials-poster.jpg'),
    );
  });

  test('平铺来源无法证明专属作品目录时只生成逐集 sidecar', () {
    final String first = p.join(temporary.path, 'Show S01E01.mkv');
    final String second = p.join(temporary.path, 'Show S01E02.mkv');
    final VideoSidecarLayout layout = VideoSidecarTargetResolver.resolveTv(
      sourceRoot: temporary.path,
      members: <VideoEpisodePath>[
        VideoEpisodePath(path: first, seasonNumber: 1, episodeNumber: 1),
        VideoEpisodePath(path: second, seasonNumber: 1, episodeNumber: 2),
      ],
      knownSourceVideoPaths: <String>[first, second],
    );

    expect(layout.work, isNull);
    expect(layout.seasons, isEmpty);
    expect(layout.episodes, hasLength(2));
    expect(layout.warnings.single, contains('仅生成逐集'));
  });

  test('作品目录混有其它视频时降级，不写 tvshow.nfo', () {
    final String root = p.join(temporary.path, 'source');
    final String episode = p.join(root, 'My Show', 'S01E01.mkv');
    final String unrelated = p.join(root, 'My Show', 'Other Movie.mkv');
    final VideoSidecarLayout layout = VideoSidecarTargetResolver.resolveTv(
      sourceRoot: root,
      members: <VideoEpisodePath>[
        VideoEpisodePath(path: episode, seasonNumber: 1, episodeNumber: 1),
      ],
      knownSourceVideoPaths: <String>[episode, unrelated],
    );

    expect(layout.work, isNull);
    expect(
        layout.episodes.single.nfoPath, p.join(root, 'My Show', 'S01E01.nfo'));
  });

  test('跨多个非季度目录不把分类祖先误判为作品根', () {
    final String root = p.join(temporary.path, 'source');
    final String first = p.join(root, 'Anime', 'Disk1', 'Show.S01E01.mkv');
    final String second = p.join(root, 'Anime', 'Disk2', 'Show.S01E02.mkv');
    final VideoSidecarLayout layout = VideoSidecarTargetResolver.resolveTv(
      sourceRoot: root,
      members: <VideoEpisodePath>[
        VideoEpisodePath(path: first, seasonNumber: 1, episodeNumber: 1),
        VideoEpisodePath(path: second, seasonNumber: 1, episodeNumber: 2),
      ],
      knownSourceVideoPaths: <String>[first, second],
    );

    expect(layout.work, isNull);
    expect(layout.seasons, isEmpty);
    expect(layout.episodes, hasLength(2));
    expect(layout.warnings.single, contains('非季度目录'));
  });

  test('来源扫描清单不完整时保守降级，不凭部分集合创建 tvshow.nfo', () {
    final String root = p.join(temporary.path, 'source');
    final String first = p.join(root, 'My Show', 'S01E01.mkv');
    final String second = p.join(root, 'My Show', 'S01E02.mkv');
    final VideoSidecarLayout layout = VideoSidecarTargetResolver.resolveTv(
      sourceRoot: root,
      members: <VideoEpisodePath>[
        VideoEpisodePath(path: first, seasonNumber: 1, episodeNumber: 1),
        VideoEpisodePath(path: second, seasonNumber: 1, episodeNumber: 2),
      ],
      knownSourceVideoPaths: <String>[first],
    );

    expect(layout.work, isNull);
    expect(layout.episodes, hasLength(2));
  });

  test('越界分集不产生任何写入目标，合法成员仍保留逐集目标', () {
    final String root = p.join(temporary.path, 'source');
    final String valid = p.join(root, 'My Show', 'S01E01.mkv');
    final String outside = p.join(temporary.path, 'outside', 'S01E02.mkv');
    final VideoSidecarLayout layout = VideoSidecarTargetResolver.resolveTv(
      sourceRoot: root,
      members: <VideoEpisodePath>[
        VideoEpisodePath(path: valid, seasonNumber: 1, episodeNumber: 1),
        VideoEpisodePath(path: outside, seasonNumber: 1, episodeNumber: 2),
      ],
      knownSourceVideoPaths: <String>[valid],
    );

    expect(layout.episodes, hasLength(1));
    expect(layout.episodes.single.episodeNumber, 1);
    expect(layout.warnings, isNotEmpty);
  });

  test('拒绝把任意字符串当作图片扩展名', () {
    final String movie = p.join(temporary.path, 'Film.mkv');
    final VideoSidecarTarget target = VideoSidecarTargetResolver.resolveMovie(
      sourceRoot: temporary.path,
      videoPath: movie,
      knownSourceVideoPaths: <String>[movie],
    ).work!;

    expect(
      () => target.imagePaths(
        VideoMetadataImageKind.cover,
        extension: '../evil',
      ),
      throwsArgumentError,
    );
  });
}
