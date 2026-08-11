import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

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
  });

  final String message;
  final ToastSeverity severity;
  final Toast toastLength;
}

/// 交给任务体（`body`）用的句柄：写进度、读取消、切阶段。
///
/// 任务体拿到的是这个句柄而不是 controller 本身——它只能推进自己的进度和阶段，
/// 不能重入 [DictionaryDownloadController.run]。
class DictionaryDownloadJob {
  DictionaryDownloadJob._(this._controller);

  final DictionaryDownloadController _controller;

  /// 进度文案（对话框标题 / 页面状态行都读它）。
  ValueNotifier<String> get message => _controller.message;

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
class DictionaryDownloadController {
  DictionaryDownloadController({
    void Function(DictionaryDownloadOutcome outcome)? showOutcome,
  }) : _showOutcome = showOutcome ?? _defaultShowOutcome;

  static void _defaultShowOutcome(DictionaryDownloadOutcome outcome) {
    FushiToast.show(
      msg: outcome.message,
      severity: outcome.severity,
      toastLength: outcome.toastLength,
    );
  }

  final void Function(DictionaryDownloadOutcome outcome) _showOutcome;

  /// 当前阶段。对话框订阅它自动关闭（回到 [DictionaryDownloadPhase.idle] 时），
  /// 词典页订阅它决定是否显示「正在下载…（查看进度）」状态行。
  final ValueNotifier<DictionaryDownloadPhase> phase =
      ValueNotifier<DictionaryDownloadPhase>(DictionaryDownloadPhase.idle);

  /// 当前进度文案。
  final ValueNotifier<String> message = ValueNotifier<String>('');

  /// 当前下载比例（0..1）；0 = 不定态。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  CancelToken _cancelToken = CancelToken();
  bool _cancelRequested = false;

  /// 是否有任务在跑（含静默自动更新）。
  bool get isBusy => phase.value != DictionaryDownloadPhase.idle;

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
    ) body,
  }) async {
    if (isBusy) return false;

    _cancelRequested = false;
    _cancelToken = CancelToken();
    progress.value = 0;
    message.value = initialMessage;
    _setPhase(DictionaryDownloadPhase.downloading);

    DictionaryDownloadOutcome? outcome;
    try {
      outcome = await body(DictionaryDownloadJob._(this));
    } finally {
      _setPhase(DictionaryDownloadPhase.idle);
      progress.value = 0;
      message.value = '';
    }
    if (outcome != null) _showOutcome(outcome);
    return true;
  }

  /// [CancelToken] 取消导致的失败**不是错误**，调用方据此把它与真失败分开计数、
  /// 分开提示。（dio 5.1 的类型名还是 `DioError`；仓库其余下载路径同样用它。）
  static bool isCancellation(Object error) =>
      error is DioError && error.type == DioErrorType.cancel;

  void _setPhase(DictionaryDownloadPhase next) {
    cancellable.value =
        next == DictionaryDownloadPhase.downloading && !_cancelRequested;
    if (phase.value == next) return;
    phase.value = next;
  }

  void dispose() {
    phase.dispose();
    message.dispose();
    progress.dispose();
    cancellable.dispose();
  }
}
