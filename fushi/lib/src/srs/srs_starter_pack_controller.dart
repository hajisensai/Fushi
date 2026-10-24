/// 复习（SRS）入门预置卡组的「下载 → 导入」控制器（app 级常驻，不绑页面生命周期）。
///
/// 清单、下载与校验在引擎 `srs/starter/srs_starter_packs.dart`；这里只管：
/// - **判重**：同一个包正在下载 / 导入时再点直接返回 [SrsStarterInstallResult.busy]，不起第二份
///   下载；当前 profile 已有同名顶层牌组（[SrsStarterPack.deckName]）时返回
///   [SrsStarterInstallResult.alreadyInstalled]，不下载。
/// - **进度 / 取消**：下载进度按包记在 [stateOf]，[cancel] 断流（`.part` 保留，下次续传）。
/// - **导入**：下完交给与「导入 .apkg」同一条后台导入队列（`srs_import_task.dart`），导入成功
///   后删掉下载的包；导入失败保留包，重试不必重下 100 MB。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/starter/srs_starter_packs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/srs/srs_import_task.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/utils.dart';

/// 一个预置包当前所处的阶段。
enum SrsStarterPackPhase { idle, downloading, importing, failed }

/// 一次「添加」请求的结果。
enum SrsStarterInstallResult {
  /// 已经下完并排进导入队列。
  started,

  /// 当前 profile 已有这个牌组，没有下载。
  alreadyInstalled,

  /// 这个包正在下载 / 导入，本次点击被忽略。
  busy,

  /// 用户取消了下载。
  cancelled,

  /// 下载 / 校验 / 入队失败（原因见 [SrsStarterPackState.error]）。
  failed,
}

/// 一个预置包的状态快照。
class SrsStarterPackState {
  const SrsStarterPackState({
    this.phase = SrsStarterPackPhase.idle,
    this.received = 0,
    this.total = 0,
    this.error,
  });

  final SrsStarterPackPhase phase;
  final int received;
  final int total;
  final Object? error;

  bool get busy =>
      phase == SrsStarterPackPhase.downloading ||
      phase == SrsStarterPackPhase.importing;

  /// 0..1；总量未知时 null。
  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
}

/// 下载一个包（测试注入假实现；缺省 [downloadSrsStarterPack]）。
typedef SrsStarterPackDownload =
    Future<File> Function({
      required SrsStarterPack pack,
      required Directory dir,
      required void Function(int received, int total) onProgress,
      required SrsStarterDownloadCancelToken cancel,
    });

Future<File> _defaultDownload({
  required SrsStarterPack pack,
  required Directory dir,
  required void Function(int received, int total) onProgress,
  required SrsStarterDownloadCancelToken cancel,
}) => downloadSrsStarterPack(
  pack: pack,
  dir: dir,
  onProgress: onProgress,
  cancel: cancel,
);

/// 当前 profile 里有没有 [pack] 导入出的顶层牌组（未删除的同名顶层牌组）。
Future<bool> srsStarterPackInstalled(
  SrsDbStore store,
  SrsStarterPack pack,
) async {
  final SrsDeckTree tree = await store.deckTree();
  return tree.decks.any(
    (SrsDeckView d) =>
        d.parentId == null && d.deletedAt == null && d.name == pack.deckName,
  );
}

class SrsStarterPackController extends ChangeNotifier {
  SrsStarterPackController({
    required Future<Directory> Function() downloadDir,
    required Future<bool> Function(SrsStarterPack pack) isInstalled,
    required Future<SrsImportTask?> Function(SrsStarterPack pack, File file)
    enqueueImport,
    SrsStarterPackDownload? download,
  }) : _downloadDir = downloadDir,
       _isInstalled = isInstalled,
       _enqueueImport = enqueueImport,
       _download = download ?? _defaultDownload;

  final Future<Directory> Function() _downloadDir;
  final Future<bool> Function(SrsStarterPack pack) _isInstalled;
  final Future<SrsImportTask?> Function(SrsStarterPack pack, File file)
  _enqueueImport;
  final SrsStarterPackDownload _download;

  final Map<String, SrsStarterPackState> _states =
      <String, SrsStarterPackState>{};
  final Map<String, SrsStarterDownloadCancelToken> _tokens =
      <String, SrsStarterDownloadCancelToken>{};

  /// 正在处理的包（从点击起算，含「查是否已安装」这一步，防连点穿透）。
  final Set<String> _inFlight = <String>{};
  bool _disposed = false;

  SrsStarterPackState stateOf(String id) =>
      _states[id] ?? const SrsStarterPackState();

  void _set(String id, SrsStarterPackState state) {
    if (_disposed) return;
    _states[id] = state;
    notifyListeners();
  }

  /// 取消 [id] 的下载（导入阶段走导入任务条自己的取消）。
  void cancel(String id) => _tokens[id]?.cancel();

  /// 下载并导入 [pack]（导入在后台队列里跑，本函数在入队后即返回）。
  Future<SrsStarterInstallResult> install(SrsStarterPack pack) async {
    if (!_inFlight.add(pack.id)) return SrsStarterInstallResult.busy;
    try {
      if (await _isInstalled(pack)) {
        _set(pack.id, const SrsStarterPackState());
        return SrsStarterInstallResult.alreadyInstalled;
      }
      final SrsStarterDownloadCancelToken token =
          SrsStarterDownloadCancelToken();
      _tokens[pack.id] = token;
      _set(
        pack.id,
        SrsStarterPackState(
          phase: SrsStarterPackPhase.downloading,
          total: pack.sizeBytes,
        ),
      );
      final File file;
      try {
        file = await _download(
          pack: pack,
          dir: await _downloadDir(),
          cancel: token,
          onProgress: (int received, int total) => _set(
            pack.id,
            SrsStarterPackState(
              phase: SrsStarterPackPhase.downloading,
              received: received,
              total: total,
            ),
          ),
        );
      } on SrsStarterDownloadCancelled {
        _set(pack.id, const SrsStarterPackState());
        return SrsStarterInstallResult.cancelled;
      } catch (e, stack) {
        ErrorLogService.instance.log('srsStarterPack.download', e, stack);
        _set(
          pack.id,
          SrsStarterPackState(phase: SrsStarterPackPhase.failed, error: e),
        );
        return SrsStarterInstallResult.failed;
      } finally {
        _tokens.remove(pack.id);
      }

      final SrsImportTask? task = await _enqueueImport(pack, file);
      if (task == null) {
        _set(
          pack.id,
          const SrsStarterPackState(
            phase: SrsStarterPackPhase.failed,
            error: 'import unavailable',
          ),
        );
        return SrsStarterInstallResult.failed;
      }
      _set(
        pack.id,
        const SrsStarterPackState(phase: SrsStarterPackPhase.importing),
      );
      // 导入阶段仍算「处理中」（下面 finally 不放行）：任务结束前再点也不重复入队。
      unawaited(_awaitImport(pack, file, task));
      return SrsStarterInstallResult.started;
    } finally {
      if (stateOf(pack.id).phase != SrsStarterPackPhase.importing) {
        _inFlight.remove(pack.id);
      }
    }
  }

  Future<void> _awaitImport(
    SrsStarterPack pack,
    File file,
    SrsImportTask task,
  ) async {
    try {
      await task.result;
      // 导入成功才删包；失败 / 取消保留，重试不必重下。
      try {
        await file.delete();
      } on FileSystemException {
        // 被占用：留在应用数据目录，下次添加时会按哈希直接复用。
      }
      _set(pack.id, const SrsStarterPackState());
    } catch (e) {
      // 失败原因由导入任务条展示；这里只回到可重试状态。
      _set(
        pack.id,
        e is SrsImportCancelledException
            ? const SrsStarterPackState()
            : SrsStarterPackState(phase: SrsStarterPackPhase.failed, error: e),
      );
    } finally {
      _inFlight.remove(pack.id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final SrsStarterDownloadCancelToken token in _tokens.values) {
      token.cancel();
    }
    super.dispose();
  }
}

/// app 级控制器：下载落 `<应用支持目录>/srs_starter_packs/`，导入进当前 profile。
final Provider<SrsStarterPackController> srsStarterPackControllerProvider =
    Provider<SrsStarterPackController>((Ref ref) {
      final SrsStarterPackController c = SrsStarterPackController(
        downloadDir: () async => Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}srs_starter_packs',
        ),
        isInstalled: (SrsStarterPack pack) async {
          final SrsDbStore? store = await ref.read(srsStoreProvider.future);
          return store != null && await srsStarterPackInstalled(store, pack);
        },
        enqueueImport: (SrsStarterPack pack, File file) =>
            startSrsBackgroundImportFromRef(
              ref,
              file: file,
              displayName: pack.name,
            ),
      );
      ref.onDispose(c.dispose);
      return c;
    });
