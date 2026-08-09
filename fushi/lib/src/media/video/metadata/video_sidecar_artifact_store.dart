/// [VideoSidecarWriter] 与 v77 `video_sidecar_artifacts` 的适配层。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/video/metadata/video_sidecar_writer.dart';
import 'package:fushi/src/media/video/scraper/sidecar_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 用 v77 artifact 路径和 SHA-256 区分 Fushi 生成图片与用户 sidecar。
///
/// 这是旧 [CoverScraperService] 的可选桥接：没有 artifact、文件已被改动，或读取
/// / 查询失败时都返回 false，确保第三方文件和用户修改继续受到保护。
class DatabaseSidecarGeneratedArtifactChecker
    implements SidecarGeneratedArtifactChecker {
  const DatabaseSidecarGeneratedArtifactChecker(this.database);

  final FushiDatabase database;

  @override
  Future<bool> isUnmodifiedGeneratedArtifact(String absolutePath) async {
    final String path = p.normalize(p.absolute(absolutePath));
    try {
      final VideoSidecarArtifactRow? artifact =
          await database.getVideoSidecarArtifactByPath(path);
      if (artifact == null) {
        return false;
      }
      final File file = File(path);
      if (!await file.exists()) {
        return false;
      }
      final String currentHash =
          (await sha256.bind(file.openRead()).first).toString();
      return artifact.sha256.toLowerCase() == currentHash.toLowerCase();
    } on Object {
      return false;
    }
  }
}

class VideoSidecarArtifactContext {
  const VideoSidecarArtifactContext({
    required this.artifactKind,
    required this.writePolicy,
    this.workId,
    this.seasonId,
    this.episodeId,
    this.fileSize,
    this.remoteUrl,
  });

  final String artifactKind;
  final String writePolicy;
  final int? workId;
  final int? seasonId;
  final int? episodeId;
  final int? fileSize;
  final String? remoteUrl;
}

class DatabaseSidecarArtifactStore implements SidecarArtifactHashStore {
  DatabaseSidecarArtifactStore({
    required this.database,
    required this.sourceId,
    required this.runId,
  });

  final FushiDatabase database;
  final int sourceId;
  final int runId;
  final Map<String, VideoSidecarArtifactContext> _contexts =
      <String, VideoSidecarArtifactContext>{};

  void register(String path, VideoSidecarArtifactContext context) {
    _contexts[_key(path)] = context;
  }

  VideoSidecarArtifactContext? contextFor(String path) => _contexts[_key(path)];

  @override
  Future<SidecarArtifactRecord?> findByPath(String absolutePath) async {
    final VideoSidecarArtifactRow? row =
        await database.getVideoSidecarArtifactByPath(_normalized(absolutePath));
    if (row == null || row.sourceId != sourceId) return null;
    return SidecarArtifactRecord(
      path: row.path,
      sha256: row.sha256,
      generatorVersion: row.generatorVersion,
      writtenAt:
          DateTime.fromMillisecondsSinceEpoch(row.updatedAt, isUtc: true),
    );
  }

  @override
  Future<void> upsert(SidecarArtifactRecord record) async {
    final String path = _normalized(record.path);
    final VideoSidecarArtifactContext? context = _contexts[_key(path)];
    if (context == null) {
      throw StateError('sidecar artifact context was not registered: $path');
    }
    final VideoSidecarArtifactRow? existing =
        await database.getVideoSidecarArtifactByPath(path);
    final int updatedAt = record.writtenAt.millisecondsSinceEpoch;
    await database.upsertVideoSidecarArtifact(
      VideoSidecarArtifactsCompanion.insert(
        id: existing == null
            ? const Value<int>.absent()
            : Value<int>(existing.id),
        sourceId: Value<int?>(sourceId),
        runId: Value<int?>(runId),
        workId: Value<int?>(context.workId),
        seasonId: Value<int?>(context.seasonId),
        episodeId: Value<int?>(context.episodeId),
        artifactKind: context.artifactKind,
        path: path,
        sha256: record.sha256,
        fileSize: Value<int?>(context.fileSize),
        generatorVersion: record.generatorVersion,
        writePolicy: context.writePolicy,
        createdAt: existing?.createdAt ?? updatedAt,
        updatedAt: updatedAt,
      ),
    );
  }

  static String _normalized(String value) => p.normalize(p.absolute(value));

  static String _key(String value) {
    final String normalized = _normalized(value);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
