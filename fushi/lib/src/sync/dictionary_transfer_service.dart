import 'dart:async';
import 'dart:io';

import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi_core/fushi_core.dart';

/// 词典管理页的单本传输所处的阶段（进度文案据此换）。
enum DictionaryTransferStage {
  /// 传输中（推送 = 打包 + 上传；下载 = 下载包）。
  transferring,

  /// 下载完、正在导入本机（native 导入，停不下来）。
  importing,
}

/// 一次单本传输的进度快照。
class DictionaryTransferProgress {
  const DictionaryTransferProgress({required this.stage, this.fraction});

  final DictionaryTransferStage stage;

  /// 0..1；null = 估不出（进度条不定态）。
  final double? fraction;
}

/// 单本传输失败的原因（UI 按它选文案）。
enum DictionaryTransferFailureKind {
  /// 这台 host 没配对（或配对里拿不出凭据）。
  notPaired,

  /// 这台 host 的地址全连不上（不会改投别的 host）。
  unreachable,

  /// host 拒了配对凭据（401 / 403）。
  unauthorized,

  /// 来源一侧没有这本（下载：host 清单里没有；推送：本机没装）。
  notFound,

  /// 本机磁盘满了。
  outOfDisk,

  /// 另一次词典 / 资产传输正在跑。
  busy,

  /// 其它失败（原因见 [DictionaryTransferFailed.error]）。
  failed,
}

/// 单本传输的结局。
sealed class DictionaryTransferResult {
  const DictionaryTransferResult();
}

/// 传完了：推送 = host 已导入；下载 = 本机已导入（词典与引擎已重载）。
class DictionaryTransferDone extends DictionaryTransferResult {
  const DictionaryTransferDone();
}

/// 目标一侧已有同名词典，什么都没做（下载 = 本机已装；推送 = host 已有）。
class DictionaryTransferAlreadyPresent extends DictionaryTransferResult {
  const DictionaryTransferAlreadyPresent();
}

/// 失败了。
class DictionaryTransferFailed extends DictionaryTransferResult {
  const DictionaryTransferFailed(this.kind, [this.error]);

  final DictionaryTransferFailureKind kind;

  /// 原始异常（[DictionaryTransferFailureKind.failed] 时上屏 / 进日志）。
  final Object? error;
}

/// 按 host 推送 / 下载**一本**词典（词典管理页「推送到 <服务器>」/「下载到本机」）。
///
/// 只是 [runHostDictionaryTransfer] 的薄壳：锁、在飞登记、只连那一台 host 的后端、
/// 包代码、导入后重载与目录对账都在那条路径上（与同步的词典阶段同一份）。这里把
/// 进度换成 UI 用的形状、把异常归类成 [DictionaryTransferFailureKind]。
class DictionaryTransferService {
  DictionaryTransferService({
    required FushiDatabase db,
    required Directory dictionaryResourceRoot,
    required Directory tempDir,
    SyncPostRunCallback? onPostRun,
    ScopedInterconnectBackendFactory? backendFor,
  }) : _db = db,
       _dictionaryResourceRoot = dictionaryResourceRoot,
       _tempDir = tempDir,
       _onPostRun = onPostRun,
       _backendFor = backendFor;

  final FushiDatabase _db;
  final Directory _dictionaryResourceRoot;
  final Directory _tempDir;
  final SyncPostRunCallback? _onPostRun;
  final ScopedInterconnectBackendFactory? _backendFor;

  /// 把本机词典 [dictionaryName] 推到 [hostId] 那台 host。host 已有同名 →
  /// [DictionaryTransferAlreadyPresent]。
  Future<DictionaryTransferResult> pushToHost(
    String hostId,
    String dictionaryName, {
    void Function(DictionaryTransferProgress progress)? onProgress,
  }) => _run(hostId, dictionaryName, SyncAssetDirection.upload, onProgress);

  /// 把 [hostId] 上的词典 [dictionaryName] 下载并导入本机。本机已有同名词典 =
  /// 已装，不覆盖、不联网（[DictionaryTransferAlreadyPresent]）。
  Future<DictionaryTransferResult> downloadFromHost(
    String hostId,
    String dictionaryName, {
    void Function(DictionaryTransferProgress progress)? onProgress,
  }) async {
    final bool installed = (await _db.getAllDictionaryMetadata()).any(
      (DictionaryMetaRow d) => d.name == dictionaryName,
    );
    if (installed) return const DictionaryTransferAlreadyPresent();
    return _run(
      hostId,
      dictionaryName,
      SyncAssetDirection.download,
      onProgress,
    );
  }

  Future<DictionaryTransferResult> _run(
    String hostId,
    String dictionaryName,
    SyncAssetDirection direction,
    void Function(DictionaryTransferProgress progress)? onProgress,
  ) async {
    final HostDictionaryTransferResult? result;
    try {
      result = await runHostDictionaryTransfer(
        db: _db,
        hostId: hostId,
        dictionaryName: dictionaryName,
        direction: direction,
        dictionaryResourceRoot: _dictionaryResourceRoot,
        tempDir: _tempDir,
        onPostRun: _onPostRun,
        backendFor: _backendFor,
        onProgress: onProgress == null
            ? null
            : (SyncProgress p) => onProgress(
                DictionaryTransferProgress(
                  stage: DictionaryTransferStage.transferring,
                  fraction: p.fileFraction,
                ),
              ),
        onImporting: onProgress == null
            ? null
            : () => onProgress(
                const DictionaryTransferProgress(
                  stage: DictionaryTransferStage.importing,
                ),
              ),
      );
    } catch (e) {
      return DictionaryTransferFailed(classifyDictionaryTransferError(e), e);
    }
    if (result == null) {
      return const DictionaryTransferFailed(DictionaryTransferFailureKind.busy);
    }
    return switch (result.outcome) {
      SingleDictionaryTransferOutcome.transferred =>
        const DictionaryTransferDone(),
      SingleDictionaryTransferOutcome.alreadyPresent =>
        const DictionaryTransferAlreadyPresent(),
      SingleDictionaryTransferOutcome.notFound =>
        const DictionaryTransferFailed(DictionaryTransferFailureKind.notFound),
    };
  }
}

/// 把单本传输抛出的异常归成 UI 能说清的几类。
DictionaryTransferFailureKind classifyDictionaryTransferError(Object error) {
  if (error is HostDictionaryTransferNotPaired) {
    return DictionaryTransferFailureKind.notPaired;
  }
  if (error is SyncAuthError) {
    return error.kind == SyncAuthFailureKind.pairingNotConfigured
        ? DictionaryTransferFailureKind.notPaired
        : DictionaryTransferFailureKind.unauthorized;
  }
  if (error is SyncNotFoundError) {
    return DictionaryTransferFailureKind.notFound;
  }
  if (error is SyncPeerUnreachableError ||
      error is SocketException ||
      error is TimeoutException ||
      error is HttpException) {
    return DictionaryTransferFailureKind.unreachable;
  }
  if (error is FileSystemException && isDiskFullError(error)) {
    return DictionaryTransferFailureKind.outOfDisk;
  }
  return DictionaryTransferFailureKind.failed;
}

/// 磁盘满：POSIX `ENOSPC`（28）、Windows `ERROR_DISK_FULL`（112）/
/// `ERROR_HANDLE_DISK_FULL`（39），或系统消息里写明没空间。
bool isDiskFullError(FileSystemException error) {
  final int? code = error.osError?.errorCode;
  if (code != null) {
    if (Platform.isWindows ? (code == 112 || code == 39) : code == 28) {
      return true;
    }
  }
  final String message = '${error.message} ${error.osError?.message ?? ''}'
      .toLowerCase();
  return message.contains('no space') || message.contains('disk full');
}
