/// 来源目录 sidecar 的边界校验、所有权保护和原子写入。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// MoviePilot 式单资产写入策略。
enum SidecarWritePolicy { skip, missingOnly, overwrite }

/// Fushi 生成物的持久化所有权记录。
class SidecarArtifactRecord {
  const SidecarArtifactRecord({
    required this.path,
    required this.sha256,
    required this.generatorVersion,
    required this.writtenAt,
  });

  final String path;
  final String sha256;
  final String generatorVersion;
  final DateTime writtenAt;
}

/// artifact 持久化边界。数据库层实现该接口；纯 writer 不依赖 Drift。
abstract interface class SidecarArtifactHashStore {
  Future<SidecarArtifactRecord?> findByPath(String absolutePath);

  Future<void> upsert(SidecarArtifactRecord record);
}

/// 一次待写入的 NFO 或图片字节。
class SidecarWriteRequest {
  SidecarWriteRequest({
    required this.targetPath,
    required Uint8List bytes,
    this.policy = SidecarWritePolicy.missingOnly,
    this.allowProtectedOverwrite = false,
  }) : bytes = Uint8List.fromList(bytes);

  final String targetPath;
  final Uint8List bytes;
  final SidecarWritePolicy policy;

  /// 危险确认后才可为 true：允许覆盖第三方文件或已被用户修改的 Fushi 生成物。
  final bool allowProtectedOverwrite;
}

/// 单个目标的最终结果。
enum SidecarWriteStatus {
  written,
  unchanged,
  skippedByPolicy,
  skippedExisting,
  protectedExisting,
  protectedModified,
  rejectedOutsideRoot,
  rejectedSymbolicLink,
  rejectedInvalidTarget,
  failed,
}

/// 单个目标的写入结果。
class SidecarWriteResult {
  const SidecarWriteResult({
    required this.targetPath,
    required this.status,
    this.sha256,
    this.message,
    this.error,
    this.artifactStoreError,
  });

  final String targetPath;
  final SidecarWriteStatus status;
  final String? sha256;
  final String? message;
  final Object? error;

  /// 文件已成功写入、但 artifact 记录失败时单独报告；不把已写入伪装成失败。
  final Object? artifactStoreError;

  bool get didWrite => status == SidecarWriteStatus.written;
  bool get isFailure => switch (status) {
        SidecarWriteStatus.rejectedOutsideRoot ||
        SidecarWriteStatus.rejectedSymbolicLink ||
        SidecarWriteStatus.rejectedInvalidTarget ||
        SidecarWriteStatus.failed =>
          true,
        _ => false,
      };
}

/// 一个批次的逐项可诊断摘要。
class SidecarWriteSummary {
  SidecarWriteSummary(List<SidecarWriteResult> results)
      : results = List<SidecarWriteResult>.unmodifiable(results);

  final List<SidecarWriteResult> results;

  int get writtenCount =>
      results.where((SidecarWriteResult value) => value.didWrite).length;
  int get unchangedCount => results
      .where((SidecarWriteResult value) =>
          value.status == SidecarWriteStatus.unchanged)
      .length;
  int get protectedCount => results
      .where((SidecarWriteResult value) =>
          value.status == SidecarWriteStatus.protectedExisting ||
          value.status == SidecarWriteStatus.protectedModified)
      .length;
  int get skippedCount => results
      .where((SidecarWriteResult value) =>
          value.status == SidecarWriteStatus.skippedByPolicy ||
          value.status == SidecarWriteStatus.skippedExisting)
      .length;
  int get failureCount =>
      results.where((SidecarWriteResult value) => value.isFailure).length;
  int get artifactStoreFailureCount => results
      .where((SidecarWriteResult value) => value.artifactStoreError != null)
      .length;
}

/// 只允许向一个已登记本地来源根目录写入的 sidecar writer。
class VideoSidecarWriter {
  VideoSidecarWriter({
    required String sourceRoot,
    required this.artifactStore,
    this.generatorVersion = 'fushi-nfo-v1',
  }) : sourceRoot = p.normalize(p.absolute(sourceRoot));

  final String sourceRoot;
  final SidecarArtifactHashStore artifactStore;
  final String generatorVersion;

  /// 逐项隔离失败；一个图片/NFO 失败不会阻断同批其它资产。
  Future<SidecarWriteSummary> writeAll(
    Iterable<SidecarWriteRequest> requests,
  ) async {
    final List<SidecarWriteResult> results = <SidecarWriteResult>[];
    for (final SidecarWriteRequest request in requests) {
      results.add(await write(request));
    }
    return SidecarWriteSummary(results);
  }

  /// 写一个资产，并严格执行策略、所有权与真实路径边界。
  Future<SidecarWriteResult> write(SidecarWriteRequest request) async {
    final String target = p.normalize(p.absolute(request.targetPath));
    if (request.policy == SidecarWritePolicy.skip) {
      return SidecarWriteResult(
        targetPath: target,
        status: SidecarWriteStatus.skippedByPolicy,
      );
    }
    final _ValidatedTarget validation;
    try {
      validation = await _validateTarget(target);
    } on _SidecarValidationException catch (error) {
      return SidecarWriteResult(
        targetPath: target,
        status: error.status,
        message: error.message,
        error: error,
      );
    } on Object catch (error) {
      return SidecarWriteResult(
        targetPath: target,
        status: SidecarWriteStatus.failed,
        message: '校验 sidecar 目标失败',
        error: error,
      );
    }

    final File targetFile = File(validation.path);
    final bool exists = validation.exists;
    final String desiredHash = sha256.convert(request.bytes).toString();
    if (exists) {
      if (request.policy == SidecarWritePolicy.missingOnly) {
        return SidecarWriteResult(
          targetPath: target,
          status: SidecarWriteStatus.skippedExisting,
        );
      }
      final String currentHash;
      try {
        currentHash = await _sha256File(targetFile);
      } on Object catch (error) {
        return SidecarWriteResult(
          targetPath: target,
          status: SidecarWriteStatus.failed,
          message: '读取现有 sidecar 失败',
          error: error,
        );
      }
      if (currentHash == desiredHash) {
        return SidecarWriteResult(
          targetPath: target,
          status: SidecarWriteStatus.unchanged,
          sha256: desiredHash,
        );
      }
      if (!request.allowProtectedOverwrite) {
        final SidecarArtifactRecord? artifact;
        try {
          artifact = await artifactStore.findByPath(target);
        } on Object catch (error) {
          return SidecarWriteResult(
            targetPath: target,
            status: SidecarWriteStatus.protectedExisting,
            sha256: currentHash,
            message: '无法验证现有文件归属，已保守保护',
            error: error,
          );
        }
        if (artifact == null) {
          return SidecarWriteResult(
            targetPath: target,
            status: SidecarWriteStatus.protectedExisting,
            sha256: currentHash,
            message: '现有文件不是 Fushi 生成物',
          );
        }
        if (artifact.sha256.toLowerCase() != currentHash) {
          return SidecarWriteResult(
            targetPath: target,
            status: SidecarWriteStatus.protectedModified,
            sha256: currentHash,
            message: 'Fushi 生成物已被用户修改',
          );
        }
      }
    }

    try {
      await _atomicWrite(targetFile, request.bytes);
    } on Object catch (error) {
      return SidecarWriteResult(
        targetPath: target,
        status: SidecarWriteStatus.failed,
        message: '原子写入 sidecar 失败',
        error: error,
      );
    }

    Object? artifactStoreError;
    try {
      await artifactStore.upsert(SidecarArtifactRecord(
        path: target,
        sha256: desiredHash,
        generatorVersion: generatorVersion,
        writtenAt: DateTime.now().toUtc(),
      ));
    } on Object catch (error) {
      artifactStoreError = error;
    }
    return SidecarWriteResult(
      targetPath: target,
      status: SidecarWriteStatus.written,
      sha256: desiredHash,
      message: artifactStoreError == null ? null : '文件已写入，但所有权记录失败',
      artifactStoreError: artifactStoreError,
    );
  }

  Future<_ValidatedTarget> _validateTarget(String target) async {
    if (!_isWithinOrEqual(sourceRoot, target)) {
      throw const _SidecarValidationException(
        SidecarWriteStatus.rejectedOutsideRoot,
        '目标路径越过来源根目录',
      );
    }
    final Directory rootDirectory = Directory(sourceRoot);
    if (!await rootDirectory.exists()) {
      throw const _SidecarValidationException(
        SidecarWriteStatus.rejectedInvalidTarget,
        '来源根目录不存在',
      );
    }
    final String realRoot =
        p.normalize(await rootDirectory.resolveSymbolicLinks());
    final Directory parent = Directory(p.dirname(target));
    if (!await parent.exists()) {
      throw const _SidecarValidationException(
        SidecarWriteStatus.rejectedInvalidTarget,
        'sidecar 父目录不存在',
      );
    }
    final String realParent = p.normalize(await parent.resolveSymbolicLinks());
    if (!_isWithinOrEqual(realRoot, realParent)) {
      throw const _SidecarValidationException(
        SidecarWriteStatus.rejectedSymbolicLink,
        'sidecar 父目录经符号链接后越过来源根目录',
      );
    }

    final FileSystemEntityType type =
        await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const _SidecarValidationException(
        SidecarWriteStatus.rejectedSymbolicLink,
        '拒绝覆盖符号链接 sidecar',
      );
    }
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const _SidecarValidationException(
        SidecarWriteStatus.rejectedInvalidTarget,
        'sidecar 目标不是普通文件',
      );
    }
    return _ValidatedTarget(
      path: target,
      exists: type == FileSystemEntityType.file,
    );
  }

  static Future<String> _sha256File(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static Future<void> _atomicWrite(File target, Uint8List bytes) async {
    final Directory parent = target.parent;
    final String basename = p.basename(target.path);
    final Random random = Random.secure();
    File? temporary;
    for (int attempt = 0; attempt < 20; attempt += 1) {
      final String nonce = random.nextInt(0x7fffffff).toRadixString(16);
      final File candidate = File(
        p.join(parent.path, '.$basename.fushi-$nonce.tmp'),
      );
      try {
        await candidate.create(exclusive: true);
        temporary = candidate;
        break;
      } on FileSystemException {
        // 极低概率撞名，换 nonce 重试；20 次后给出明确失败。
      }
    }
    if (temporary == null) {
      throw FileSystemException('无法创建同目录临时文件', target.path);
    }

    try {
      final RandomAccessFile handle =
          await temporary.open(mode: FileMode.write);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      // 同目录 rename 不跨文件系统；Dart VM 在支持的平台使用 replace 语义。
      await temporary.rename(target.path);
      temporary = null;
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  static bool _isWithinOrEqual(String parent, String child) {
    final String parentKey = _pathKey(parent);
    final String childKey = _pathKey(child);
    final String prefix = parentKey.endsWith(p.separator)
        ? parentKey
        : '$parentKey${p.separator}';
    return childKey == parentKey || childKey.startsWith(prefix);
  }

  static String _pathKey(String value) {
    final String normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

class _ValidatedTarget {
  const _ValidatedTarget({required this.path, required this.exists});

  final String path;
  final bool exists;
}

class _SidecarValidationException implements Exception {
  const _SidecarValidationException(this.status, this.message);

  final SidecarWriteStatus status;
  final String message;

  @override
  String toString() => message;
}
