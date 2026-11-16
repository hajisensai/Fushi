import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/download_keep_alive_hub.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 一次词典下载/更新任务当前所处的阶段。
///
/// BUG-1499：取消在两个阶段的语义**完全不同**，所以它必须是一个显式的状态而不是
/// 一个 bool——
/// - [downloading]：纯网络传输，`dio` 的 [CancelToken] 一置位就断流，temp 目录由调
///   用方 finally 清掉，词典库一个字节都没动 → **可以取消**。
/// - [importing]：native 导入是一次不可分割的 FFI 调用（`fushidicts_import` 内部
///   起原生线程后 `join(INFINITE)`，C++ 侧零回调、零 abort flag，Dart 侧还是
///   `Isolate.run` 拿不到句柄），**中途取消在任何层面都不可达**；而且导入内部是
///   「导新到 temp → 删旧 → publish」，硬中断恰好能落在「删旧之后」把用户已有词典
///   毁掉。所以这一阶段取消按钮必须**禁用**，如实告诉用户这一步停不下来，而不是给
///   一个按了没反应的按钮。
enum DictionaryDownloadPhase {
  /// 无任务在跑。
  idle,

  /// 正在下载（可取消）。
  downloading,

  /// 正在导入（不可取消）。
  importing,

  /// 正在把存量词典升级到新磁盘格式（不可取消：原生升级是一次不可分割的 FFI 调用，
  /// 且中途停下也没有意义——每本都是「写新文件再改名提交」，词典始终可用）。只由
  /// [DictionaryDownloadController.runWhenIdle] 的任务体在确有词典要升级时切进来。
  upgrading,
}

/// 一次任务结束后要展示给用户的结果。
///
/// 由 [DictionaryDownloadController] 在任务收尾时统一展示，**不由发起任务的页面
/// 展示**：任务可以被收进后台，用户随后可能已经离开词典页（State 被 dispose），
/// 结果仍必须送达。
@immutable
class DictionaryDownloadOutcome {
  const DictionaryDownloadOutcome({
    required this.message,
    this.severity = ToastSeverity.info,
    this.toastLength = Toast.LENGTH_SHORT,
    this.details,
  });

  final String message;
  final ToastSeverity severity;
  final Toast toastLength;

  /// 可复制的全文诊断（BUG-2188）。非 null 时 [message] 只是标题，真正的原因由
  /// 「错误详情」框全文展示——移动端原生 toast 会把长文案截成两行且不可复制，
  /// 诊断信息恰好全在被截掉的那一半。
  final String? details;
}

/// 交给任务体（`body`）用的句柄：写进度、读取消、切阶段。
///
/// 任务体拿到的是这个句柄而不是 controller 本身——它只能推进自己的进度和阶段，
/// 不能重入 [DictionaryDownloadController.run]。
class DictionaryDownloadJob {
  DictionaryDownloadJob._(this._controller);

  final DictionaryDownloadController _controller;

  /// 进度文案（对话框标题 / 页面状态行都读它）。**必须短**——它渲染在单行标题里。
  ValueNotifier<String> get message => _controller.message;

  /// 附加说明（BUG-2188）：失败原因这类**必须完整读到**的文案走这里，渲染在进度框
  /// 正文里、可多行。以前它和阶段文案挤在同一个 [message] 上，于是被
  /// `FushiModalSheetFrame` 的 `maxLines: 1 + ellipsis` 截成
  /// `DioError [connection ...`。
  ValueNotifier<String> get detail => _controller.detail;

  /// 0..1 的下载比例；0 表示「无法估算」（进度条退化为不定态）。
  ValueNotifier<double> get progress => _controller.progress;

  /// 下载阶段用的取消令牌，整个 job 共用一个：一旦置位，后续本次任务里所有
  /// `dio.download` 都立即失败，批量下载因此**整批**停下而不是只停当前这本。
  CancelToken get cancelToken => _controller.cancelToken;

  /// 用户是否已请求取消。批量循环必须在**每本之间**读它并 `return`——那是除下载
  /// 传输之外唯一安全的中断时点（上一本已完整发布、下一本尚未开始）。
  bool get isCancelled => _controller.cancelRequested;

  /// 切到下载阶段（取消按钮可用）。**只管阶段**，进度文案由调用点自己写进
  /// [message]——各调用点的文案差异（下载 / 检查更新 / 更新中）是它们自己的事。
  void markDownloadPhase() =>
      _controller._setPhase(DictionaryDownloadPhase.downloading);

  /// 切到导入阶段（取消按钮禁用）。
  void markImportPhase() =>
      _controller._setPhase(DictionaryDownloadPhase.importing);

  /// 切到「升级词典格式」阶段（取消按钮禁用）。[DictionaryDownloadController.runWhenIdle]
  /// 的任务体在此之前 phase 保持 idle、状态行不出现；调用这里才亮出来。
  void markUpgradePhase() =>
      _controller._setPhase(DictionaryDownloadPhase.upgrading);
}

/// 接手上一进程的下载后「下完怎么导入」（见
/// [DictionaryDownloadController.resumeAdoptedDownloads]）。
@immutable
class ResumableDictionaryImport {
  const ResumableDictionaryImport({
    required this.name,
    required this.importFile,
  });

  /// 进度 / 结果文案里的词典名。
  final String name;

  /// 导入下好的 [File]，返回结果提示。失败原样抛出。
  final Future<DictionaryDownloadOutcome?> Function(
    DictionaryDownloadJob job,
    File file,
  )
  importFile;
}

/// 词典下载/更新任务的**所有权持有者**。
///
/// BUG-1499 根因：任务原本活在 `_runWithDownloadProgressDialog` 的 `await body(...)`
/// 里——发起、进度、收尾全绑在那个对话框的一次调用上，于是
/// - 收起对话框 = 没有任何合法途径（`barrierDismissible: false`，且 finally 里
///   无条件 `Navigator.pop(context)`：真让用户 pop 掉，收尾时那一 pop 会把词典页
///   本身弹掉）；
/// - 取消 = `DictionaryDownloader.download` 的 `cancelToken` 形参三个调用点全不传，
///   压根没有取消入口。
///
/// 修法是把任务所有权从对话框上移到本 controller（挂在 `AppModel` 上，生命周期
/// 与 app 一致），对话框退化成它的一个**视图**：收起只是不看，任务照跑；结果由
/// controller 自己 toast 出去，与哪个页面还活着无关。
///
/// BUG-1500：本 controller 同时是词典写侧的**唯一互斥点**。手动下载（页面级
/// `_isDownloading`）与启动时静默自动更新（`AppModel._autoUpdateInProgress`）原本
/// 是两个互不相干的 bool，谁也挡不住谁；而两条流程的导入都用**同一个**
/// `<资源目录>/import_temp` 暂存目录，并且都会「删旧目录 + 删 meta 再 publish」。
/// 并发跑同一本词典时后者的 `deleteSync(recursive: true)` 会把前者正在写的暂存整个
/// 删掉，轻则导入失败重则旧词典已删、新词典没落地。改成两条流程共用 [run] 一把锁。
///
/// 后台保活：任务在跑（下载 + 导入两段）期间持有 [downloadKeepAliveHub] 的
/// `dictionary` 租约。此前词典链路是唯一没领租约的下载来源，Android 上用户一切走
/// 就没有前台服务托底，几 GB 的推荐词典 / 启动自动更新随进程被冻结或杀掉而中断。
/// 三条流程（推荐词典、手动更新、启动自动更新）都经 [run]，在这里挂一次全覆盖。
class DictionaryDownloadController {
  DictionaryDownloadController({
    void Function(DictionaryDownloadOutcome outcome)? showOutcome,
    DownloadKeepAlive? keepAlive,
  }) : _showOutcome = showOutcome ?? _defaultShowOutcome,
       _keepAlive = keepAlive ?? downloadKeepAliveHub.lease('dictionary') {
    phase.addListener(_reportKeepAlive);
    message.addListener(_reportKeepAlive);
    progress.addListener(_reportKeepAlive);
  }

  static void _defaultShowOutcome(DictionaryDownloadOutcome outcome) {
    FushiToast.show(
      msg: outcome.message,
      severity: outcome.severity,
      toastLength: outcome.toastLength,
    );
  }

  final void Function(DictionaryDownloadOutcome outcome) _showOutcome;

  /// 任务期间的下载保活租约（Android 前台服务，其余平台 no-op）。
  final DownloadKeepAlive _keepAlive;

  /// 当前阶段。对话框订阅它自动关闭（回到 [DictionaryDownloadPhase.idle] 时），
  /// 词典页订阅它决定是否显示「正在下载…（查看进度）」状态行。
  final ValueNotifier<DictionaryDownloadPhase> phase =
      ValueNotifier<DictionaryDownloadPhase>(DictionaryDownloadPhase.idle);

  /// 当前进度文案（单行标题，必须短）。
  final ValueNotifier<String> message = ValueNotifier<String>('');

  /// 当前附加说明（多行正文，可为空）。见 [DictionaryDownloadJob.detail]。
  final ValueNotifier<String> detail = ValueNotifier<String>('');

  /// 当前下载比例（0..1）；0 = 不定态。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  CancelToken _cancelToken = CancelToken();
  bool _cancelRequested = false;

  /// 写锁是否被占着。与 [phase] 分开：[runWhenIdle] 的任务可以占着锁但 phase 仍是
  /// idle（静默阶段，状态行不出现）。
  bool _locked = false;

  /// 本次任务是否已经亮过非 idle 阶段（亮过才在收尾时撤保活租约）。
  bool _shownThisJob = false;

  /// 等锁释放的 [runWhenIdle] 调用。
  final List<Completer<void>> _unlockWaiters = <Completer<void>>[];

  /// 是否有任务在跑（含静默自动更新、词典格式升级）。
  bool get isBusy => _locked;

  /// 本次任务是否已被请求取消。
  bool get cancelRequested => _cancelRequested;

  /// 当前任务的下载取消令牌。
  CancelToken get cancelToken => _cancelToken;

  /// 取消按钮是否可用：**只在下载阶段**，且尚未取消过。
  ///
  /// 导入阶段恒 false —— 见 [DictionaryDownloadPhase.importing] 的说明：那一步在
  /// 任何层面都停不下来，给可点的按钮就是骗人，硬中断则会毁掉用户已有词典。
  ///
  /// 单独一个 notifier 而不是从 [phase] 派生：取消请求本身**不改变阶段**（下载还在
  /// 断流的路上），若靠重播 phase 来通知订阅者，会让监听 idle 自动关闭的对话框看到
  /// 一次假的 idle 而误关。
  final ValueNotifier<bool> cancellable = ValueNotifier<bool>(false);

  /// 便捷读法，与 [cancellable] 同值。
  bool get canCancel => cancellable.value;

  /// 请求取消。只在 [canCancel] 为真时生效（导入阶段调用是无操作）。
  ///
  /// 置位 [cancelToken] 让**当前**这次 `dio.download` 立刻断流，同时置
  /// [cancelRequested] 让批量循环在下一本开始前停下。
  void requestCancel() {
    if (!canCancel) return;
    _cancelRequested = true;
    cancellable.value = false;
    _cancelToken.cancel('dictionary download cancelled by user');
  }

  /// 跑一个下载/更新任务，**互斥**：已有任务在跑时直接返回 false，不排队、不并发。
  ///
  /// [body] 返回本次任务的结果提示（null = 不提示）。它在 controller 的作用域里
  /// 跑完，与发起它的页面是否还活着无关。
  Future<bool> run({
    required String initialMessage,
    required Future<DictionaryDownloadOutcome?> Function(
      DictionaryDownloadJob job,
    )
    body,
  }) async {
    if (isBusy) return false;

    _acquire();
    message.value = initialMessage;
    _setPhase(DictionaryDownloadPhase.downloading);

    DictionaryDownloadOutcome? outcome;
    try {
      outcome = await body(DictionaryDownloadJob._(this));
    } finally {
      // 导入也要保活到底：native 导入跑在本进程里，被杀会停在「删旧之后」。
      await _release();
    }
    if (outcome != null) _showOutcome(outcome);
    return true;
  }

  /// 等写锁空闲后占锁跑 [body]。phase 由 [body] 自己切：它调
  /// [DictionaryDownloadJob.markUpgradePhase]（或别的 mark*）状态行才出现。占着锁就会
  /// 让 [run] 的调用方（用户点的下载、启动自动更新）被拒，所以 [body] 应当一进来就
  /// 切阶段，让用户看得到是什么占着；确认「有没有事要做」的那部分放在占锁之前。
  ///
  /// 与 [run] 的区别：[run] 忙时直接返回 false（用户发起的下载要立刻告诉用户「已有
  /// 下载在跑」；自动更新是 check-due，跳过一轮零损失）；这里忙时**排队等**它结束，
  /// 给「必须做、但不急」的后台维护任务用（启动期的词典格式升级）——不能因为撞上
  /// 一次下载就永久跳过，也不能和写词典的任务并发。
  ///
  /// 没有结果提示（维护任务不打扰用户）。[body] 抛出原样传给调用方。
  Future<T> runWhenIdle<T>(
    Future<T> Function(DictionaryDownloadJob job) body,
  ) async {
    while (_locked) {
      final Completer<void> waiter = Completer<void>();
      _unlockWaiters.add(waiter);
      await waiter.future;
    }
    _acquire();
    try {
      return await body(DictionaryDownloadJob._(this));
    } finally {
      await _release();
    }
  }

  void _acquire() {
    _locked = true;
    _shownThisJob = false;
    _cancelRequested = false;
    _cancelToken = CancelToken();
    progress.value = 0;
    message.value = '';
    detail.value = '';
  }

  Future<void> _release() async {
    _setPhase(DictionaryDownloadPhase.idle);
    progress.value = 0;
    message.value = '';
    detail.value = '';
    final bool shown = _shownThisJob;
    _shownThisJob = false;
    try {
      if (shown) await _keepAlive.stop();
    } finally {
      _locked = false;
      // 唤醒全部等待者：它们各自在循环里重查 [_locked]，先醒的占锁，其余接着等。
      final List<Completer<void>> waiters = List<Completer<void>>.of(
        _unlockWaiters,
      );
      _unlockWaiters.clear();
      for (final Completer<void> w in waiters) {
        w.complete();
      }
    }
  }

  /// 接手上一个进程留下的在途词典下载（BUG-3887 续，iOS 系统后台会话）。
  ///
  /// iOS 进程被系统回收后，后台会话的传输照常在守护进程里跑，下完的文件也照样落盘；
  /// 等它的那个 [run] 却已经跟着进程没了。这里在新进程里把它们接回来：[resolve]
  /// 按持久化的导入配方给出「下完怎么导入」，null = 真没人要了（配方坏了 / 要替换
  /// 的词典已被删掉）→ 取消任务、删已交付文件。其余的在 [run] 的互斥里逐本
  /// 「接上下载（在途的接进度，已交付的直接拿文件，失败的按候选回退续下一个镜像）→
  /// 走原导入流程」，取消 / 失败归因 / 镜像回退与 [run] 下的新下载同一套语义。
  ///
  /// 已有任务在跑（[run] 返回 false）时什么都不放弃：原生记录原样留着，下次启动再接。
  Future<void> resumeAdoptedDownloads({
    required List<AdoptedDictionaryDownload> adopted,
    required ResumableDictionaryImport? Function(
      DictionaryDownloadHandoff handoff,
    )
    resolve,
  }) async {
    final List<(AdoptedDictionaryDownload, ResumableDictionaryImport)> wanted =
        <(AdoptedDictionaryDownload, ResumableDictionaryImport)>[];
    for (final AdoptedDictionaryDownload download in adopted) {
      final ResumableDictionaryImport? importer = resolve(download.handoff);
      if (importer == null) {
        await download.discard();
      } else {
        wanted.add((download, importer));
      }
    }
    if (wanted.isEmpty) return;

    await run(
      initialMessage: t.dict_download_resuming(name: wanted.first.$2.name),
      body: (DictionaryDownloadJob job) async {
        DictionaryDownloadOutcome? outcome;
        for (final (
              AdoptedDictionaryDownload download,
              ResumableDictionaryImport importer,
            )
            in wanted) {
          // 用户已取消：剩下的同样没人要了。
          if (job.isCancelled) {
            await download.discard();
            continue;
          }
          job.markDownloadPhase();
          job.progress.value = 0;
          job.message.value = t.dict_download_resuming(name: importer.name);
          final File partial = File(download.handoff.destPath);
          try {
            final File file = await DictionaryDownloader.resume(
              adopted: download,
              progressNotifier: job.progress,
              cancelToken: job.cancelToken,
            );
            job.markImportPhase();
            job.progress.value = 0;
            outcome = await importer.importFile(job, file);
          } catch (e, stack) {
            if (isCancellation(e)) {
              outcome = DictionaryDownloadOutcome(
                message: t.dict_download_cancelled,
              );
              continue;
            }
            debugPrint(
              '[DictionaryDownload] resume ${importer.name} failed: $e',
            );
            debugPrintStack(stackTrace: stack);
            outcome = DictionaryDownloadOutcome(
              message: t.dict_download_failed(error: importer.name),
              severity: ToastSeverity.error,
              toastLength: Toast.LENGTH_LONG,
              details: '$e',
            );
          } finally {
            // 与原流程「finally 删暂存」对齐；只删这一个文件，不按持久化路径删目录。
            try {
              if (partial.existsSync()) partial.deleteSync();
            } on FileSystemException catch (e) {
              debugPrint('[DictionaryDownload] cleanup ${partial.path}: $e');
            }
          }
        }
        return outcome;
      },
    );
  }

  /// [CancelToken] 取消导致的失败**不是错误**，调用方据此把它与真失败分开计数、
  /// 分开提示。（dio 5.1 的类型名还是 `DioError`；仓库其余下载路径同样用它。）
  static bool isCancellation(Object error) =>
      error is DioError && error.type == DioErrorType.cancel;

  /// 把当前进度同步到保活通知。只在任务进行中上报（收尾时的复位不算）；
  /// 节流 / 去重在 [DownloadKeepAlive] 实现里做。导入阶段没有可信进度
  /// （[progress] 停在下载结束时的值），一律报不确定。
  void _reportKeepAlive() {
    // 按 phase 判而不是 [isBusy]：静默占锁（[runWhenIdle] 尚未亮状态行）时不上报，
    // 否则 Android 上一次「什么都不用做」的启动维护也会拉起前台服务通知。
    if (phase.value == DictionaryDownloadPhase.idle) return;
    final double ratio = progress.value;
    final int? percent =
        phase.value == DictionaryDownloadPhase.downloading && ratio > 0
        ? (ratio.clamp(0.0, 1.0) * 100).floor()
        : null;
    unawaited(
      _keepAlive.update(
        title: t.dict_keep_alive_title,
        text: message.value,
        percent: percent,
      ),
    );
  }

  void _setPhase(DictionaryDownloadPhase next) {
    if (next != DictionaryDownloadPhase.idle) _shownThisJob = true;
    cancellable.value =
        next == DictionaryDownloadPhase.downloading && !_cancelRequested;
    if (phase.value == next) return;
    phase.value = next;
  }

  void dispose() {
    phase.removeListener(_reportKeepAlive);
    message.removeListener(_reportKeepAlive);
    progress.removeListener(_reportKeepAlive);
    phase.dispose();
    message.dispose();
    detail.dispose();
    progress.dispose();
    cancellable.dispose();
  }
}
