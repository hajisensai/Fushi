import 'dart:io';

import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/video/download/video_download_path_mapping.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;

enum VideoOrganizationKind { movie, episodic }

class VideoOrganizationRequest {
  VideoOrganizationRequest({
    required this.torrentId,
    required this.title,
    required this.kind,
    required this.sourceRoot,
    required this.pathMapping,
    this.year,
    this.defaultSeasonNumber = 1,
  });

  final String torrentId;
  final String title;
  final int? year;
  final VideoOrganizationKind kind;
  final int defaultSeasonNumber;
  final String sourceRoot;
  final VideoDownloadPathMapping pathMapping;
}

class VideoOrganizationFilePlan {
  const VideoOrganizationFilePlan({
    required this.backendFileIndex,
    required this.originalRelativePath,
    required this.targetRelativePath,
    required this.finalLocalPath,
    this.seasonNumber,
    this.episodeNumber,
  });

  final int backendFileIndex;
  final String originalRelativePath;
  final String targetRelativePath;
  final String finalLocalPath;
  final int? seasonNumber;
  final int? episodeNumber;
}

class VideoOrganizationPlan {
  VideoOrganizationPlan({
    required this.remoteSourceRoot,
    required List<VideoOrganizationFilePlan> files,
  }) : files = List<VideoOrganizationFilePlan>.unmodifiable(files);

  final String remoteSourceRoot;
  final List<VideoOrganizationFilePlan> files;
}

class VideoOrganizationResult {
  VideoOrganizationResult({
    required this.ok,
    required List<VideoOrganizationFilePlan> files,
    this.error,
  }) : files = List<VideoOrganizationFilePlan>.unmodifiable(files);

  final bool ok;
  final List<VideoOrganizationFilePlan> files;
  final String? error;
}

typedef VideoOrganizationFileCommitted = Future<void> Function(
  VideoOrganizationFilePlan file,
);

/// 只通过 torrent backend 改名和移动的受管来源整理器。
class VideoDownloadOrganizer {
  const VideoDownloadOrganizer();

  VideoOrganizationPlan plan(
    VideoOrganizationRequest request,
    List<TorrentFileEntry> files,
  ) {
    if (files.isEmpty) {
      throw const FormatException('torrent has no files');
    }
    final String title = _safeSegment(request.title);
    final String displayRoot =
        request.year == null ? title : '$title (${request.year})';
    final String? remoteRoot =
        request.pathMapping.localToRemote(request.sourceRoot);
    if (remoteRoot == null) {
      throw const FormatException(
        'managed source is outside the backend path mapping',
      );
    }

    final List<TorrentFileEntry> videoFiles = files
        .where((TorrentFileEntry file) => _isVideo(file.name))
        .toList(growable: false);
    if (videoFiles.isEmpty) {
      throw const FormatException('torrent has no supported video files');
    }
    final TorrentFileEntry? mainMovie =
        request.kind == VideoOrganizationKind.movie
            ? (videoFiles.toList()
                  ..sort((TorrentFileEntry a, TorrentFileEntry b) =>
                      b.size.compareTo(a.size)))
                .first
            : null;
    final String? sharedRoot = _sharedRootSegment(videoFiles);
    final Map<String, String> claimedTargets = <String, String>{};
    final List<VideoOrganizationFilePlan> planned =
        <VideoOrganizationFilePlan>[];
    var recognizedEpisodes = 0;
    for (final TorrentFileEntry file in videoFiles) {
      final String extension = p.extension(file.name).toLowerCase();
      late final String relative;
      int? seasonNumber;
      int? episodeNumber;
      // 剧集与电影共用同一条 Extras 规则：认得出集号的进 Season 目录，其余
      // 一律镜像进 Extras（预告/特典/菜单等，BUG-1785），下游 `kind: 'extra'`
      // 已是既有概念。电影额外把最大文件抬成正片。
      //
      // 集号只对**正片**有意义（BUG-1865）：发布组把特典收进 `EXTRA/` `SPs/`
      // `Previews/` 时，那些文件名同样以 `- 05` / `[SP05]` 结尾，硬解析会让
      // 「Making Video Collection - 05」和真正的第 5 集抢同一个目标名。所以
      // 先按目录判正片/特典、再解析集号；顺序反过来就只能靠撞号事后发现，
      // 而**没撞上的那些会被静默改名成正片**——后者才是更贵的一半。
      if (request.kind == VideoOrganizationKind.episodic &&
          !_isInExtraDirectory(file.name, sharedRoot: sharedRoot)) {
        final VideoNameInfo parsed =
            parseVideoFilename(_segments(file.name).last);
        episodeNumber = parsed.episode;
        if (episodeNumber != null) {
          seasonNumber = parsed.season ?? request.defaultSeasonNumber;
        }
      }
      if (episodeNumber != null) {
        recognizedEpisodes += 1;
        final String season = seasonNumber.toString().padLeft(2, '0');
        final String episode = episodeNumber.toString().padLeft(2, '0');
        relative = _portableJoin(<String>[
          displayRoot,
          'Season $season',
          '$displayRoot - S${season}E$episode$extension',
        ]);
      } else if (identical(file, mainMovie)) {
        relative = _portableJoin(<String>[
          displayRoot,
          '$displayRoot$extension',
        ]);
      } else {
        relative = _portableJoin(<String>[
          displayRoot,
          'Extras',
          ..._extraSegments(file.name, sharedRoot: sharedRoot),
        ]);
      }
      final String targetKey =
          Platform.isWindows ? relative.toLowerCase() : relative;
      // 冲突消息必须点名**两个**源文件：只报目标名的话，用户看到
      // 「S03E05 撞了」根本不知道是哪两个文件在抢，也就无从判断该删哪个。
      final String? claimedBy = claimedTargets[targetKey];
      if (claimedBy != null) {
        throw FormatException(
          'organization target collision: $relative '
          '(claimed by "$claimedBy", also matched by "${file.name}")',
        );
      }
      claimedTargets[targetKey] = file.name;
      final String finalPath = p.normalize(p.joinAll(<String>[
        request.sourceRoot,
        ...relative.split('/'),
      ]));
      planned.add(VideoOrganizationFilePlan(
        backendFileIndex: file.index,
        originalRelativePath: file.name,
        targetRelativePath: relative,
        finalLocalPath: finalPath,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      ));
    }
    // 一集都认不出说明种子与「剧集」判定不符（比如误标 kind），全 Extras 的
    // 静默入库只会把问题藏起来，仍然显式失败。报的样本取**正片候选**里的第一个
    // ——报特典目录里的文件只会把人往「特典没识别」的错方向带。
    if (request.kind == VideoOrganizationKind.episodic &&
        recognizedEpisodes == 0) {
      final TorrentFileEntry sample = videoFiles.firstWhere(
        (TorrentFileEntry file) =>
            !_isInExtraDirectory(file.name, sharedRoot: sharedRoot),
        orElse: () => videoFiles.first,
      );
      throw FormatException(
        'unable to determine episode number: ${sample.name}',
      );
    }
    return VideoOrganizationPlan(remoteSourceRoot: remoteRoot, files: planned);
  }

  Future<VideoOrganizationResult> organize({
    required TorrentBackend backend,
    required VideoOrganizationRequest request,
    VideoOrganizationFileCommitted? onFileCommitted,
  }) async {
    final List<TorrentFileEntry> backendFiles =
        await backend.listFiles(request.torrentId);
    final VideoOrganizationPlan planned;
    try {
      planned = plan(request, backendFiles);
    } on FormatException catch (error) {
      return VideoOrganizationResult(
        ok: false,
        files: const <VideoOrganizationFilePlan>[],
        error: error.message.toString(),
      );
    }
    for (final VideoOrganizationFilePlan file in planned.files) {
      if (await File(file.finalLocalPath).exists()) {
        return VideoOrganizationResult(
          ok: false,
          files: planned.files,
          error: 'organization target already exists: ${file.finalLocalPath}',
        );
      }
    }
    final List<VideoOrganizationFilePlan> committed =
        <VideoOrganizationFilePlan>[];
    for (final VideoOrganizationFilePlan file in planned.files) {
      if (_normalizeRelative(file.originalRelativePath) !=
          _normalizeRelative(file.targetRelativePath)) {
        final TorrentStorageResult renamed = await backend.renameFile(
          request.torrentId,
          file.backendFileIndex,
          file.targetRelativePath,
        );
        if (!renamed.ok) {
          return VideoOrganizationResult(
            ok: false,
            files: committed,
            error: renamed.error ?? 'backend file rename failed',
          );
        }
      }
      committed.add(file);
      await onFileCommitted?.call(file);
    }
    final TorrentStorageResult moved = await backend.moveStorage(
      request.torrentId,
      planned.remoteSourceRoot,
    );
    if (!moved.ok) {
      return VideoOrganizationResult(
        ok: false,
        files: committed,
        error: moved.error ?? 'backend storage move failed',
      );
    }
    return VideoOrganizationResult(ok: true, files: planned.files);
  }

  static bool _isVideo(String value) => const <String>{
        '.3gp',
        '.avi',
        '.flv',
        '.m2ts',
        '.m4v',
        '.mkv',
        '.mov',
        '.mp4',
        '.mpeg',
        '.mpg',
        '.ts',
        '.webm',
        '.wmv',
      }.contains(p.extension(value).toLowerCase());

  static String _safeSegment(String value) {
    final String safe =
        safeWindowsFileName(value).replaceAll(RegExp(r'[. ]+$'), '').trim();
    if (safe.isEmpty) throw const FormatException('empty media title');
    return safe;
  }

  static String _portableJoin(List<String> segments) => segments.join('/');

  static String _normalizeRelative(String value) =>
      value.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');

  /// 种子内相对路径切段（`/` 与 `\` 都认：qBittorrent 返回 `/`，内置引擎在
  /// Windows 上返回 `\`）。
  static List<String> _segments(String name) => name
      .split(RegExp(r'[\\/]+'))
      .where((String s) => s.trim().isNotEmpty)
      .toList(growable: false);

  /// 单根种子的发布目录名（所有视频文件共享的第一段）；平铺种子返回 null。
  /// Extras 镜像时剥掉它，免得多出一层 `[Group] Title [1080p]` 噪音目录。
  static String? _sharedRootSegment(List<TorrentFileEntry> files) {
    String? root;
    for (final TorrentFileEntry file in files) {
      final List<String> segments = _segments(file.name);
      if (segments.length < 2) return null;
      if (root == null) {
        root = segments.first;
      } else if (segments.first != root) {
        return null;
      }
    }
    return root;
  }

  /// 发布组显式划为「非正片」的目录名（归一化后比较，见 [_normalizedSegment]）。
  ///
  /// 只用来判**目录段**，绝不拿去扫文件名：正片文件名天然带 `S3` `BD Rip`
  /// `FLACx3` 这类词，同一张表扫文件名迟早误伤真番剧标题（`Extra Olympia
  /// Kyklos`、`Special A`）。目录是发布组自己划的边界，语义确定得多；表里没有
  /// 的目录名只会退回旧口径（按集号判），不会把正片错判成特典。
  static const Set<String> _extraDirectoryNames = <String>{
    'bdscan',
    'bdscans',
    'bonus',
    'cd',
    'cds',
    'cm',
    'extra',
    'extras',
    'interview',
    'interviews',
    'making',
    'menu',
    'menus',
    'misc',
    'nc',
    'nced',
    'ncop',
    'other',
    'others',
    'preview',
    'previews',
    'pv',
    'scan',
    'scans',
    'sp',
    'special',
    'specials',
    'sps',
    'trailer',
    'trailers',
    'webpreview',
    'webpreviews',
  };

  /// 该文件是否躺在发布组标记的特典目录里（共享根与文件名段都不参与判定）。
  static bool _isInExtraDirectory(String name, {String? sharedRoot}) {
    final List<String> segments = _segments(name);
    final List<String> inner = sharedRoot != null && segments.length > 1
        ? segments.sublist(1)
        : segments;
    for (final String segment in inner.take(inner.length - 1)) {
      if (_extraDirectoryNames.contains(_normalizedSegment(segment))) {
        return true;
      }
    }
    return false;
  }

  /// 目录名归一化：转小写并去掉所有非字母数字，`SPs` → `sps`、`[SP]` → `sp`、
  /// `Web Previews` → `webpreviews`、`BD Scans` → `bdscans`。
  static String _normalizedSegment(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Extras 目标段：镜像种子内目录结构（剥共享根），路径天然唯一，不同子目录
  /// 里的同名特典不会互相顶掉。每段过 [_safeSegment]，末段扩展名统一小写。
  static List<String> _extraSegments(String name, {String? sharedRoot}) {
    final List<String> segments = _segments(name);
    final List<String> inner = sharedRoot != null && segments.length > 1
        ? segments.sublist(1)
        : segments;
    final String extension = p.extension(inner.last).toLowerCase();
    final String stem = _safeSegment(p.basenameWithoutExtension(inner.last));
    return <String>[
      ...inner.sublist(0, inner.length - 1).map(_safeSegment),
      '$stem$extension',
    ];
  }
}
