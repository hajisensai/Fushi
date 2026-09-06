import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart';
import 'package:fushi/src/utils/misc/segmented_downloader.dart';
import 'package:fushi/utils.dart';

/// 推荐包（9.5 GB 的词典 + 发音库整包）下载任务所处的阶段。
///
/// 「下完」与「已导入」是两件事：导入要用户在确认框里选覆盖/合并、并且**重启
/// 进程**，controller 不能替用户做这一步 —— 所以下完之后停在
/// [downloaded] 等一个显式的导入动作，而不是直接回 [idle]。
enum RecommendedPackDownloadStage {
  /// 无任务在跑，磁盘上也没有任何可续的半截、也没有下好待导入的整包。
  idle,

  /// 正在下载（可取消；取消保留半截文件，下次续传）。
  downloading,

  /// 磁盘上躺着一截下到一半的包，但**没有任务在跑**：用户取消了、下载失败了，
  /// 或者上一个进程在下载途中被关掉。
  ///
  /// 这个阶段是 BUG-2165 的核心：在它存在之前，以上三种情况一律落回 [idle]，
  /// 而 [idle] 的语义是「什么都没有」——于是 3 GB 半截在 UI 层**完全无法表达**，
  /// 判据是 [isActive] 的可见入口全部不渲染，用户既看不到已下了多少，也没有任何
  /// 地方能把它续上（唯一入口是重开新手引导，而那条按钮还写着「下载 9.5 GB」、
  /// 点下去进度从 0 起跳）。
  paused,

  /// 整包已下完躺在磁盘上，等用户确认导入。
  downloaded,
}

/// 真正干活的下载体。默认实现是 [RecommendedPackDownloadController] 自己的
/// 清单解析 + 分片并发下载；测试注入替身，不碰真网络。
typedef RecommendedPackDownloadRunner = Future<File> Function({
  required Directory packDir,
  required ValueNotifier<double> progress,
  required ValueNotifier<int> receivedBytes,
  required CancelToken cancelToken,
});

/// 推荐包下载任务的**所有权持有者**（挂在 `AppModel` 上，生命周期与 app 一致）。
///
/// BUG-2097 根因：任务原本活在新手引导页的 State 里 —— 下载器、进度 notifier、
/// `CancelToken` 全是 `_OnboardingWizardPageState` 的字段，而它的 `dispose()` 里
/// 有一句 `_packCancelToken?.cancel()`。于是「点了下载 → 走下一步 → 走完向导」
/// 这条最普通的路径上，向导一 pop，9.5 GB 的下载就被静默取消：没有提示、没有
/// 通知、也没有任何地方还能看到它。文案（`onboarding_pack_action_download_desc`）
/// 承诺的「后台下载」在页面被销毁时并不成立。
///
/// 修法与词典下载（[DictionaryDownloadController]，BUG-1499）同一条纪律：任务
/// 所有权上移到本 controller，页面退化成它的一个**视图** —— 关掉向导只是不看，
/// 下载照跑；进度另有常驻入口（设置 → 系统 → 推荐包那一行）可看、可取消、
/// 可导入。
///
/// 本 controller **不自己发起导入**：导入走
/// `runBackupImportFlowForFile`（要用户确认覆盖/合并，随后重启进程），由发起
/// 下载的向导（若还活着）或设置里那一行显式触发。
class RecommendedPackDownloadController {
  RecommendedPackDownloadController({
    required Directory Function() packDirectory,
    RecommendedPackDownloadRunner? runner,
    void Function(String message, ToastSeverity severity)? showOutcome,
  })  : _packDirectory = packDirectory,
        _runner = runner,
        _showOutcome = showOutcome ?? _defaultShowOutcome;

  static void _defaultShowOutcome(String message, ToastSeverity severity) {
    FushiToast.show(
      msg: message,
      severity: severity,
      toastLength: Toast.LENGTH_LONG,
    );
  }

  /// 包目录解析器（`<appDirectory>/recommended_pack`）。**惰性**：controller 在
  /// `AppModel` 字段初始化时就构造，那时 `appDirectory` 还没定。
  final Directory Function() _packDirectory;

  RecommendedPackDownloadRunner? _runner;

  /// 下载体替身注入点。整包 9.5 GB：集成测试要在**真 app**里验「离开向导下载还在
  /// 不在」，就不能真去下——但那条路径上的一切（真向导、真按钮、真 controller、
  /// 真 dispose）都必须是真的，所以替身只换最外面这一层。
  @visibleForTesting
  set runner(RecommendedPackDownloadRunner? value) => _runner = value;
  final void Function(String message, ToastSeverity severity) _showOutcome;

  /// 当前阶段。向导步骤与设置那一行都订阅它决定显示什么。
  final ValueNotifier<RecommendedPackDownloadStage> stage =
      ValueNotifier<RecommendedPackDownloadStage>(
    RecommendedPackDownloadStage.idle,
  );

  /// 0..1 的下载比例；0 = 总大小未知（进度条退化为不定态）。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  /// 已收字节（含续传前已在磁盘上的半截）。
  final ValueNotifier<int> receivedBytes = ValueNotifier<int>(0);

  /// 最近一次失败原因；null = 无错。用户取消**不是**失败，不写这里。
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  /// 用户已把首页迷你条**收起**（本次会话内）。
  ///
  /// 只影响那条常驻迷你条，不影响设置里那一行——「看得到」和「一直杵在眼前」是
  /// 两件事：主动点了取消、或者点了迷你条上的 ×，就是用户已经对这件事做过决定，
  /// 再把「已暂停 · 3.2 GB」永久钉在每个页面底部就成了骚扰。[start] 会重新放开。
  final ValueNotifier<bool> miniBarDismissed = ValueNotifier<bool>(false);

  /// 已 dispose。notifier 写入前的门：下载体是 in-flight 的，`AppModel.dispose`
  /// 之后它的进度回调仍可能打回来（写已 dispose 的 [ValueNotifier] 会抛
  /// "used after being disposed"）。
  bool _disposed = false;

  /// 清单解析出的下载器，整个会话只解析一次 —— 同一会话内 URL 抖动会打断续传。
  RecommendedPackDownloader? _manifestDownloader;

  CancelToken? _cancelToken;

  Directory get packDir => _packDirectory();

  File get packFile => RecommendedPackDownloader.packFileIn(packDir);

  bool get isDownloading =>
      stage.value == RecommendedPackDownloadStage.downloading;

  /// 整包已下完、等一个导入动作。
  bool get hasPendingImport =>
      stage.value == RecommendedPackDownloadStage.downloaded;

  /// 盘上有半截、但没有任务在跑：可续传。
  bool get isPaused => stage.value == RecommendedPackDownloadStage.paused;

  /// 有任何值得给用户看的状态（下载中 / 已暂停有半截 / 下完待导入）。设置里那一行
  /// 与首页迷你条据此显隐。
  bool get isActive => stage.value != RecommendedPackDownloadStage.idle;

  /// 按磁盘现状对齐阶段（下载中时不动）。向导/设置进场时调，让「上次下完但没
  /// 导入」「上次导入完已删包」这两种历史状态都能被如实显示。
  void syncStageWithDisk() {
    if (isDownloading) return;
    _settleStageFromDisk();
  }

  /// 无条件按磁盘定阶段。任务收尾（取消/失败）时用它——那时 [stage] 还停在
  /// [RecommendedPackDownloadStage.downloading]，[syncStageWithDisk] 的
  /// 「下载中不动」守卫会把这次收尾整个跳过，任务就永远卡在下载中。
  void _settleStageFromDisk() {
    if (_disposed) return;
    if (RecommendedPackDownloader.hasCompletedFileIn(packDir)) {
      stage.value = RecommendedPackDownloadStage.downloaded;
      return;
    }
    // 磁盘有四种状态，状态机就得有四个阶段（BUG-2165）。半截也是**进度**：把它
    // 读进 [receivedBytes]，暂停态的可见入口才报得出「已下 3.2 GB」而不是空白。
    final int partial = RecommendedPackDownloader.partialBytesIn(packDir);
    if (partial > 0) {
      receivedBytes.value = partial;
      stage.value = RecommendedPackDownloadStage.paused;
      return;
    }
    receivedBytes.value = 0;
    progress.value = 0;
    stage.value = RecommendedPackDownloadStage.idle;
  }

  /// 包目录的进场收尾：删掉「已导入」的残包、把改名前的旧半截文件搬到新名字，
  /// 再对齐阶段。下载中时整体跳过 —— 这些都是在动同一批文件。
  Future<void> prepareDiskState() async {
    if (isDownloading) return;
    final Directory dir = packDir;
    await RecommendedPackDownloader.cleanupIfImported(dir);
    RecommendedPackDownloader.migrateLegacyArtifacts(dir);
    syncStageWithDisk();
  }

  /// 开始（或续传）下载。返回下好的整包；被取消/失败返回 null。
  ///
  /// **互斥**：已有任务在跑时直接返回 null，不排队、不并发（两份下载写同一个
  /// 半截文件会互相踩）。任务在本 controller 的作用域里跑完，与发起它的页面是否
  /// 还活着无关。
  Future<File?> start() async {
    if (isDownloading || _disposed) return null;
    error.value = null;
    miniBarDismissed.value = false;
    progress.value = 0;
    // 续传要从**盘上已有的半截**起跳，不是从 0：归零会让刚点「继续下载」的用户
    // 看着 3.2 GB 变成 0 B，以为前面白下了（BUG-2165）。下载器随后报的
    // [receivedBytes] 本来就含半截，这里只是补上「点下去到第一个 tick」之间那段
    // 空窗。
    receivedBytes.value = RecommendedPackDownloader.partialBytesIn(packDir);
    final CancelToken cancelToken = CancelToken();
    _cancelToken = cancelToken;
    stage.value = RecommendedPackDownloadStage.downloading;
    try {
      final File file = await (_runner ?? _runRealDownload)(
        packDir: packDir,
        progress: progress,
        receivedBytes: receivedBytes,
        cancelToken: cancelToken,
      );
      if (_disposed) return file;
      stage.value = RecommendedPackDownloadStage.downloaded;
      // 后台下完必须有声响：用户可能早就离开向导了，不然 9.5 GB 下完之后
      // 屏幕上不会有任何变化。下完的整包**不**受 [miniBarDismissed] 压制——
      // 那次收起针对的是当时那个状态，「可以导入了」是新消息。
      miniBarDismissed.value = false;
      _showOutcome(t.onboarding_pack_download_finished, ToastSeverity.success);
      return file;
    } catch (e) {
      // 用户取消：半截文件保留，下次续传；非取消才示错。
      //
      // 取消的形态有**两种**，因为下载有两条路：清单能解出分片计划就走
      // `_downloadSegmented`（这是默认路径），解不出才退单流。分片路取消抛的是
      // [SegmentedDownloadCancelledException]（一个普通 Exception），单流路才抛
      // `DioError(type: cancel)`。只认后者的话，用户在真实路径上点「取消」会被
      // 判成失败——而本条 bug 恰恰把失败原因做成了常驻可见，于是设置行与迷你条
      // 上会赫然写着「推荐包下载失败：SegmentedDownloadCancelledException」。
      if (!_isCancellation(e, cancelToken)) {
        _failWith(e is DioError ? (e.message ?? e.toString()) : e.toString());
      }
      _settleStageFromDisk();
      return null;
    } finally {
      _cancelToken = null;
    }
  }

  /// 这个异常是不是「用户取消」。
  ///
  /// 三条判据缺一不可：分片路的专用异常、单流路的 `DioError(type: cancel)`、
  /// 以及 token 自己的状态（下载体在两条路之外的地方响应取消时，抛出来的可能是
  /// 别的形态，但 `cancelToken.isCancelled` 一定为真）。
  static bool _isCancellation(Object error, CancelToken token) {
    if (error is SegmentedDownloadCancelledException) return true;
    if (error is DioError && error.type == DioErrorType.cancel) return true;
    return token.isCancelled;
  }

  void _failWith(String message) {
    if (_disposed) return;
    error.value = message;
    _showOutcome(
      t.onboarding_pack_download_failed(message: message),
      ToastSeverity.error,
    );
  }

  /// 请求取消当前下载。半截文件保留供下次续传（阶段随后落到
  /// [RecommendedPackDownloadStage.paused]，设置里那一行仍能把它续上）。
  void requestCancel() {
    // 主动点取消 = 用户已经对这件事做过决定，首页迷你条随即收起；进度并没有丢，
    // 设置 → 系统那一行照旧显示「已暂停 · 3.2 GB · 继续下载」。
    miniBarDismissed.value = true;
    _cancelToken?.cancel('recommended pack cancelled');
  }

  /// 收起首页那条迷你条（本次会话内）。
  void dismissMiniBar() => miniBarDismissed.value = true;

  /// 导入即将真正开始时给包目录落「已导入」flag：导入会重启进程，重启回来由
  /// [prepareDiskState] 删掉这 9.5 GB。
  Future<void> markImportStarted() =>
      RecommendedPackDownloader.markImportStarted(packDir);

  /// 真实下载：先拉稳定清单拿分片表与来源表（换包零发版），拉不到就退到内置的
  /// 整包直链单流下载。
  Future<File> _runRealDownload({
    required Directory packDir,
    required ValueNotifier<double> progress,
    required ValueNotifier<int> receivedBytes,
    required CancelToken cancelToken,
  }) async {
    if (_manifestDownloader == null) {
      final RecommendedPackManifest? manifest =
          await fetchRecommendedPackManifest();
      if (manifest != null) {
        _manifestDownloader = RecommendedPackDownloader.fromManifest(
          packDir: packDir,
          manifest: manifest,
        );
      }
    }
    final RecommendedPackDownloader downloader = _manifestDownloader ??
        RecommendedPackDownloader(
          packDir: packDir,
          url: kRecommendedPackGoogleDriveDirectUrl,
        );
    return downloader.download(
      progress: progress,
      receivedBytes: receivedBytes,
      cancelToken: cancelToken,
    );
  }

  void dispose() {
    // 先立门再 dispose：in-flight 的下载体还会回调进度，写已 dispose 的 notifier
    // 会抛。取消是尽力而为——半截文件保留，下个进程由 [prepareDiskState] 认出来
    // 并落到 [RecommendedPackDownloadStage.paused]。
    _disposed = true;
    _cancelToken?.cancel('recommended pack controller disposed');
    _cancelToken = null;
    stage.dispose();
    progress.dispose();
    receivedBytes.dispose();
    error.dispose();
    miniBarDismissed.dispose();
  }
}

/// 已下量文案：`3.2 GB (34%)`；总大小未知（服务器不报 length）时只报字节数。
/// 向导步骤与设置那一行共用，两处不再各写一份 GB 除法。
String recommendedPackProgressLabel({
  required double progress,
  required int receivedBytes,
}) {
  final String received = FushiByteFormat.bytes(receivedBytes);
  if (progress <= 0) return received;
  final String percent = (progress * 100).clamp(0, 100).toStringAsFixed(0);
  return '$received ($percent%)';
}
