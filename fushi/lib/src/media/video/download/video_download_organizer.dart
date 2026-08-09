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
    final Set<String> targetKeys = <String>{};
    final List<VideoOrganizationFilePlan> planned =
        <VideoOrganizationFilePlan>[];
    for (final TorrentFileEntry file in videoFiles) {
      final String extension = p.extension(file.name).toLowerCase();
      late final String relative;
      int? seasonNumber;
      int? episodeNumber;
      if (request.kind == VideoOrganizationKind.movie) {
        if (identical(file, mainMovie)) {
          relative = _portableJoin(<String>[
            displayRoot,
            '$displayRoot$extension',
          ]);
        } else {
          final String extraName = _safeSegment(
            p.basenameWithoutExtension(file.name),
          );
          relative = _portableJoin(<String>[
            displayRoot,
            'Extras',
            '$extraName$extension',
          ]);
        }
      } else {
        final VideoNameInfo parsed = parseVideoFilename(p.basename(file.name));
        episodeNumber = parsed.episode;
        if (episodeNumber == null) {
          throw FormatException(
            'unable to determine episode number: ${file.name}',
          );
        }
        seasonNumber = parsed.season ?? request.defaultSeasonNumber;
        final String season = seasonNumber.toString().padLeft(2, '0');
        final String episode = episodeNumber.toString().padLeft(2, '0');
        relative = _portableJoin(<String>[
          displayRoot,
          'Season $season',
          '$displayRoot - S${season}E$episode$extension',
        ]);
      }
      final String targetKey =
          Platform.isWindows ? relative.toLowerCase() : relative;
      if (!targetKeys.add(targetKey)) {
        throw FormatException('organization target collision: $relative');
      }
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
}
