/// 来源目录内的 NFO/图片安全目标解析。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';

/// sidecar 所描述的媒体层级。
enum VideoSidecarTargetKind { movie, tvShow, season, episode }

/// 一个已确定目录和命名策略的 sidecar 目标。
class VideoSidecarTarget {
  const VideoSidecarTarget._({
    required this.kind,
    required this.nfoPath,
    required this.directoryPath,
    this.mediaStem,
    this.tvRootPath,
    this.seasonNumber,
    this.episodeNumber,
    this.sharedMovieDirectory = false,
  });

  final VideoSidecarTargetKind kind;
  final String nfoPath;
  final String directoryPath;
  final String? mediaStem;
  final String? tvRootPath;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool sharedMovieDirectory;

  /// 返回该层级一张图片应写入的全部兼容路径。
  ///
  /// backdrop 同时生成 fanart 别名；季图片同时生成剧集根目录的
  /// `seasonXX-*` 与季目录通用名。调用方应把同一下载字节提交给返回的每个路径。
  List<String> imagePaths(
    VideoMetadataImageKind imageKind, {
    String extension = '.jpg',
  }) {
    final String ext = _safeExtension(extension);
    final List<String> stems = _imageStems(imageKind);
    switch (kind) {
      case VideoSidecarTargetKind.movie:
        final String prefix = sharedMovieDirectory ? '$mediaStem-' : '';
        return <String>[
          for (final String stem in stems)
            p.join(directoryPath, '$prefix$stem$ext'),
        ];
      case VideoSidecarTargetKind.tvShow:
        return <String>[
          for (final String stem in stems) p.join(directoryPath, '$stem$ext'),
        ];
      case VideoSidecarTargetKind.season:
        final String rootPrefix = seasonNumber == 0
            ? 'season-specials'
            : 'season${seasonNumber!.toString().padLeft(2, '0')}';
        final List<String> paths = <String>[
          for (final String stem in stems) p.join(directoryPath, '$stem$ext'),
        ];
        if (tvRootPath != null) {
          // MoviePilot 对 seasonXX 文件不扩展 backdrop/fanart 别名。
          paths.insert(
            0,
            p.join(tvRootPath!, '$rootPrefix-${stems.first}$ext'),
          );
        }
        return paths;
      case VideoSidecarTargetKind.episode:
        if (imageKind != VideoMetadataImageKind.thumb &&
            imageKind != VideoMetadataImageKind.landscape) {
          return const <String>[];
        }
        return <String>[p.join(directoryPath, '$mediaStem$ext')];
    }
  }

  static List<String> _imageStems(VideoMetadataImageKind kind) =>
      switch (kind) {
        VideoMetadataImageKind.cover => const <String>['poster'],
        VideoMetadataImageKind.backdrop => const <String>['backdrop', 'fanart'],
        VideoMetadataImageKind.logo => const <String>['logo'],
        VideoMetadataImageKind.disc => const <String>['disc'],
        VideoMetadataImageKind.banner => const <String>['banner'],
        VideoMetadataImageKind.thumb => const <String>['thumb'],
        VideoMetadataImageKind.clearart => const <String>['clearart'],
        VideoMetadataImageKind.landscape => const <String>['landscape'],
      };

  static String _safeExtension(String raw) {
    final String normalized = raw.trim().toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(normalized)) {
      return normalized;
    }
    throw ArgumentError.value(raw, 'extension', '必须是安全的文件扩展名');
  }
}

/// 一个电视剧成员及其已解析季集号。
class VideoEpisodePath {
  const VideoEpisodePath({
    required this.path,
    required this.seasonNumber,
    required this.episodeNumber,
  });

  final String path;
  final int seasonNumber;
  final int episodeNumber;
}

/// 作品的所有可安全写入目标。
class VideoSidecarLayout {
  VideoSidecarLayout({
    this.work,
    List<VideoSidecarTarget> seasons = const <VideoSidecarTarget>[],
    List<VideoSidecarTarget> episodes = const <VideoSidecarTarget>[],
    List<String> warnings = const <String>[],
  })  : seasons = List<VideoSidecarTarget>.unmodifiable(seasons),
        episodes = List<VideoSidecarTarget>.unmodifiable(episodes),
        warnings = List<String>.unmodifiable(warnings);

  final VideoSidecarTarget? work;
  final List<VideoSidecarTarget> seasons;
  final List<VideoSidecarTarget> episodes;
  final List<String> warnings;
}

/// 根据一次完整来源扫描的路径集合解析 sidecar 布局。
class VideoSidecarTargetResolver {
  const VideoSidecarTargetResolver._();

  /// 解析独立电影。已知目录内还有其它视频时采用 `<视频名>-poster` 等防碰撞图名。
  static VideoSidecarLayout resolveMovie({
    required String sourceRoot,
    required String videoPath,
    required Iterable<String> knownSourceVideoPaths,
  }) {
    final String root = _absolute(sourceRoot);
    final String video = _absolute(videoPath);
    if (!_isWithinOrEqual(root, video)) {
      return VideoSidecarLayout(
        warnings: <String>['电影路径不在来源根目录内，未生成 sidecar 目标：$videoPath'],
      );
    }
    final String directory = p.dirname(video);
    final bool shared = _samePath(directory, root) ||
        knownSourceVideoPaths.any((String candidate) {
          final String normalized = _absolute(candidate);
          return !_samePath(normalized, video) &&
              _samePath(p.dirname(normalized), directory);
        });
    final String stem = p.basenameWithoutExtension(video);
    return VideoSidecarLayout(
      work: VideoSidecarTarget._(
        kind: VideoSidecarTargetKind.movie,
        nfoPath: p.join(directory, '$stem.nfo'),
        directoryPath: directory,
        mediaStem: stem,
        sharedMovieDirectory: shared,
      ),
    );
  }

  /// 解析电视剧。
  ///
  /// [knownSourceVideoPaths] 必须是本轮来源扫描发现的完整视频集合；它用于验证推导出的
  /// 作品根目录没有混入其它作品。无法证明专属根目录时仍返回安全的逐集目标，但不返回
  /// tvshow/season 目标，避免在平铺目录里互相覆盖。
  static VideoSidecarLayout resolveTv({
    required String sourceRoot,
    required Iterable<VideoEpisodePath> members,
    required Iterable<String> knownSourceVideoPaths,
  }) {
    final String root = _absolute(sourceRoot);
    final List<String> warnings = <String>[];
    final List<VideoEpisodePath> safeMembers = <VideoEpisodePath>[];
    for (final VideoEpisodePath member in members) {
      final String absolute = _absolute(member.path);
      if (!_isWithinOrEqual(root, absolute)) {
        warnings.add('分集路径越过来源根目录，仅跳过该分集 sidecar：${member.path}');
        continue;
      }
      safeMembers.add(VideoEpisodePath(
        path: absolute,
        seasonNumber: member.seasonNumber,
        episodeNumber: member.episodeNumber,
      ));
    }
    safeMembers.sort((VideoEpisodePath a, VideoEpisodePath b) {
      int result = a.seasonNumber.compareTo(b.seasonNumber);
      if (result != 0) {
        return result;
      }
      result = a.episodeNumber.compareTo(b.episodeNumber);
      if (result != 0) {
        return result;
      }
      return _pathKey(a.path).compareTo(_pathKey(b.path));
    });

    final List<VideoSidecarTarget> episodeTargets = <VideoSidecarTarget>[
      for (final VideoEpisodePath member in safeMembers)
        VideoSidecarTarget._(
          kind: VideoSidecarTargetKind.episode,
          nfoPath: p.join(
            p.dirname(member.path),
            '${p.basenameWithoutExtension(member.path)}.nfo',
          ),
          directoryPath: p.dirname(member.path),
          mediaStem: p.basenameWithoutExtension(member.path),
          seasonNumber: member.seasonNumber,
          episodeNumber: member.episodeNumber,
        ),
    ];
    if (safeMembers.isEmpty) {
      return VideoSidecarLayout(episodes: episodeTargets, warnings: warnings);
    }

    String candidateRoot = _commonDirectory(
      safeMembers.map((VideoEpisodePath member) => p.dirname(member.path)),
    );
    if (_looksLikeSeasonDirectory(p.basename(candidateRoot))) {
      candidateRoot = p.dirname(candidateRoot);
    }

    final Set<String> memberPaths = safeMembers
        .map((VideoEpisodePath member) => _pathKey(member.path))
        .toSet();
    final List<String> knownPaths =
        knownSourceVideoPaths.map(_absolute).toList(growable: false);
    final Set<String> knownPathKeys = knownPaths.map(_pathKey).toSet();
    final List<String> knownInCandidate = knownPaths
        .where((String path) => _isWithinOrEqual(candidateRoot, path))
        .toList();
    final Set<String> immediateBranches = <String>{
      for (final VideoEpisodePath member in safeMembers)
        if (!_samePath(p.dirname(member.path), candidateRoot))
          p
              .split(p.relative(
                p.dirname(member.path),
                from: candidateRoot,
              ))
              .first,
    };
    final bool branchesDescribeSeasons = immediateBranches.length <= 1 ||
        immediateBranches.every(_looksLikeSeasonDirectory);
    final bool hasDedicatedRoot = !_samePath(candidateRoot, root) &&
        _isWithinOrEqual(root, candidateRoot) &&
        memberPaths.every(knownPathKeys.contains) &&
        knownInCandidate.every(
          (String path) => memberPaths.contains(_pathKey(path)),
        ) &&
        branchesDescribeSeasons;

    if (!hasDedicatedRoot) {
      warnings.add(
        branchesDescribeSeasons
            ? '无法证明电视剧具有来源根目录下的专属作品目录；仅生成逐集 sidecar。'
            : '成员跨越多个非季度目录，无法确定唯一作品根；仅生成逐集 sidecar。',
      );
      return VideoSidecarLayout(
        episodes: episodeTargets,
        warnings: warnings,
      );
    }

    final VideoSidecarTarget workTarget = VideoSidecarTarget._(
      kind: VideoSidecarTargetKind.tvShow,
      nfoPath: p.join(candidateRoot, 'tvshow.nfo'),
      directoryPath: candidateRoot,
    );
    final List<VideoSidecarTarget> seasonTargets = <VideoSidecarTarget>[];
    final Map<int, List<VideoEpisodePath>> bySeason =
        <int, List<VideoEpisodePath>>{};
    for (final VideoEpisodePath member in safeMembers) {
      bySeason
          .putIfAbsent(member.seasonNumber, () => <VideoEpisodePath>[])
          .add(member);
    }
    final List<int> seasonNumbers = bySeason.keys.toList()..sort();
    for (final int seasonNumber in seasonNumbers) {
      final List<VideoEpisodePath> seasonMembers = bySeason[seasonNumber]!;
      final String seasonDirectory = _commonDirectory(
        seasonMembers.map((VideoEpisodePath member) => p.dirname(member.path)),
      );
      if (_samePath(seasonDirectory, candidateRoot) ||
          !_isWithinOrEqual(candidateRoot, seasonDirectory)) {
        warnings.add('第 $seasonNumber 季没有独立季目录，跳过 season.nfo。');
        continue;
      }
      final bool directoryContainsOtherSeason = safeMembers.any(
        (VideoEpisodePath member) =>
            member.seasonNumber != seasonNumber &&
            _isWithinOrEqual(seasonDirectory, member.path),
      );
      if (directoryContainsOtherSeason) {
        warnings.add('第 $seasonNumber 季目录混有其它季度，跳过 season.nfo。');
        continue;
      }
      seasonTargets.add(VideoSidecarTarget._(
        kind: VideoSidecarTargetKind.season,
        nfoPath: p.join(seasonDirectory, 'season.nfo'),
        directoryPath: seasonDirectory,
        tvRootPath: candidateRoot,
        seasonNumber: seasonNumber,
      ));
    }

    return VideoSidecarLayout(
      work: workTarget,
      seasons: seasonTargets,
      episodes: episodeTargets,
      warnings: warnings,
    );
  }

  static String _commonDirectory(Iterable<String> directories) {
    final List<List<String>> parts = directories
        .map((String path) => p.split(_absolute(path)))
        .toList(growable: false);
    if (parts.isEmpty) {
      throw ArgumentError.value(directories, 'directories', '不能为空');
    }
    int length = parts.first.length;
    for (final List<String> candidate in parts.skip(1)) {
      length = length < candidate.length ? length : candidate.length;
      int index = 0;
      while (index < length &&
          _componentEquals(parts.first[index], candidate[index])) {
        index += 1;
      }
      length = index;
    }
    return p.normalize(p.joinAll(parts.first.take(length).toList()));
  }

  static bool _looksLikeSeasonDirectory(String name) {
    final String normalized = name.trim().toLowerCase();
    return RegExp(r'^(?:season[ ._-]*\d+|s\d{1,3}|specials?|第\s*\d+\s*季)$')
        .hasMatch(normalized);
  }

  static String _absolute(String value) => p.normalize(p.absolute(value));

  static bool _isWithinOrEqual(String parent, String child) {
    final String parentKey = _pathKey(parent);
    final String childKey = _pathKey(child);
    final String prefix = parentKey.endsWith(p.separator)
        ? parentKey
        : '$parentKey${p.separator}';
    return childKey == parentKey || childKey.startsWith(prefix);
  }

  static bool _samePath(String a, String b) => _pathKey(a) == _pathKey(b);

  static String _pathKey(String value) {
    final String normalized = _absolute(value);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static bool _componentEquals(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
}
