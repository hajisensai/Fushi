part of 'update_checker.dart';

/// **首字节超时（TODO-683）**。[_kPerAttemptTimeout]（15s）管「一段正式下载」的整体
/// 耗时；但下载阶段第一步是对每个候选发探针（`Range: bytes=0-`，只探不真下载），目的
/// 只是「这个源能不能用、拿到总大小」。GFW 下坏候选 TCP 连上后挂起不返首字节，用 15s
/// 整体超时会让每个坏候选都吃满 15s，首字节前进度恒显 0%（TODO-596 回归）。探针只需
/// 一个短得多的「建连到首字节」超时来快判死坏候选——5s 足够区分「能用」与「连上即挂」，
/// 又不会误杀慢但可用的源。**只用于探针**；分段正式下载各段仍用 [_kPerAttemptTimeout]。
const Duration _kFirstByteTimeout = Duration(seconds: 5);

/// 直连与镜像近乎同时返回 206 时的 tie-break 窗口（TODO-683）。最快候选是镜像时，再多
/// 等本窗口看直连是否也到达；到了就优先选直连——与 [updateCheckUrls] / `net.dart` 把直连
/// 恒放首位、视作最权威/最快的哲学一致（直连无镜像中转跳数、不受镜像共享 IP 限流，长下载
/// 更稳）。窗口太大会让明显更慢的直连压住快镜像；500ms 是「同时到」的经验阈值。
const Duration _kDirectTieBreakWindow = Duration(milliseconds: 500);

/// **下载状态翻转控制器（TODO-683 Step1，体感快修）**。下载前期（建连 + 各候选探针）
/// 首字节到达前没有任何 onProgress（进度恒 0%），原先遮罩一进来就显「正在下载更新…」，
/// GFW 下坏候选累积超时期间用户盯着「下载中 0%」一动不动，体感像卡死。改成：
///   * [markConnecting]：进下载前把状态置「正在连接更新源…」（[t.update_connecting]）。
///   * [onFirstByte]：第一个 onProgress（>0）/ onDiagnostics 回调到达时**一次性**翻成
///     「正在下载更新…」（[t.update_downloading]），之后不再改（幂等）。
///
/// 纯逻辑（只写一个注入的 [ValueNotifier<String>]），不碰 UI 结构，便于 widget 测试直接
/// 注入 status notifier 断言「首信号前显 connecting、首信号后显 downloading」。
@visibleForTesting
class UpdateDownloadStatusController {
  UpdateDownloadStatusController(this._status);

  final ValueNotifier<String> _status;
  bool _switchedToDownloading = false;

  /// 进入下载流程前调用：显示「正在连接更新源…」。
  void markConnecting() {
    _status.value = t.update_connecting;
  }

  /// 首个真实下载信号（onProgress>0 / onDiagnostics）到达时调用：一次性翻成
  /// 「正在下载更新…」。重复调用幂等（已翻则不再写，避免无谓 notify）。
  void onFirstByte() {
    if (_switchedToDownloading) return;
    _switchedToDownloading = true;
    _status.value = t.update_downloading;
  }

  @visibleForTesting
  bool get switchedToDownloadingForTest => _switchedToDownloading;
}

/// 一次候选探针的结果（竞速选源用）。[url] = 被探的候选；[total] = 从 Content-Range
/// 解出的资源总大小（null 表示拿不到 → 该候选不算「胜出资格」）；[elapsed] = 从探针
/// 发起到拿到 206 首响应的耗时（tie-break 比较用）；[isDirect] = 该候选是否直连
/// （url == directUrl，tie-break 直连优先用）。
@visibleForTesting
class UpdateProbeOutcome {
  const UpdateProbeOutcome({
    required this.url,
    required this.total,
    required this.elapsed,
    required this.isDirect,
  });

  final String url;
  final int? total;
  final Duration elapsed;
  final bool isDirect;

  /// 「胜出资格」：探针返回 206 且能拿到合法总大小（[total] > 0）。拿不到总大小的
  /// 候选无法用于分片，不参与竞速胜出（仍可作为串行回退候选）。
  bool get isEligible => total != null && total! > 0;
}

/// **纯函数（TODO-683）**：从一批 eligible（206 + 拿到总大小）的探针结果里挑出竞速
/// 胜出的候选 url。调用方只把 eligible 的结果传进来。
///
/// 规则（与边界澄清 + PM tie-break ④ 一致）：
///   1. 取「首字节最快」（[UpdateProbeOutcome.elapsed] 最小）者为基准 winner。
///   2. **tie-break 直连优先**：若存在一个直连候选，且它的首字节时刻在「最快候选首字节
///      + [_kDirectTieBreakWindow]」内（近乎同时到），改选直连（与 net.dart「直连恒
///      首位」哲学一致）。
///   3. 空列表 → null。
@visibleForTesting
String? selectRaceWinnerUrl(List<UpdateProbeOutcome> eligibleOutcomes) {
  if (eligibleOutcomes.isEmpty) return null;

  UpdateProbeOutcome fastest = eligibleOutcomes.first;
  for (final UpdateProbeOutcome o in eligibleOutcomes) {
    if (o.elapsed < fastest.elapsed) fastest = o;
  }
  if (fastest.isDirect) return fastest.url;

  final Duration cutoff = fastest.elapsed + _kDirectTieBreakWindow;
  for (final UpdateProbeOutcome o in eligibleOutcomes) {
    if (o.isDirect && o.elapsed <= cutoff) return o.url;
  }
  return fastest.url;
}

/// **纯函数（TODO-683）**：把竞速胜出的 [winnerUrl] 提到候选列表首位，其余候选保持
/// 原相对顺序跟随其后。这样下载先走胜出源（最快活源），若胜出源中途下载失败，现有
/// 串行 [_downloadUpdateAssetUncoalesced] 循环仍能逐个回退其余候选——竞速只「重排」
/// 不「删减」，保留完整换源能力。[winnerUrl] 不在列表里（理论不该发生）则原样返回。
@visibleForTesting
List<String> reorderCandidatesByRaceWinner(
  List<String> candidateUrls,
  String winnerUrl,
) {
  if (!candidateUrls.contains(winnerUrl)) return candidateUrls;
  return <String>[
    winnerUrl,
    for (final String url in candidateUrls)
      if (url != winnerUrl) url,
  ];
}

/// **竞速接入入口（TODO-683）**：被 [_downloadUpdateAssetUncoalesced] 在候选串行循环前
/// 调用。满足竞速门控（[_shouldRaceCandidates]）→ 并发探针选最快活源、把胜出 url 提首位
/// 返回重排后的候选列表；不满足门控 / 竞速选不出源 → 原样返回 [candidateUrls]（现有串行
/// 循环 + [selectRepresentativeDownloadFailure] 锚定直连完全不变）。把整段接入逻辑下沉到
/// 本 race part，让下载 part 只剩一行调用、不越结构守卫的 1500 行天花板。
Future<List<String>> orderedCandidatesAfterRace({
  required List<String> candidateUrls,
  required UpdateAsset asset,
  required _UpdateDownloadStagingPaths stagingPaths,
  required int connectionCount,
  required int minSegmentBytes,
  required _UpdateDownloadMetadata? metadata,
  required UpdateDownloadOpen openUrl,
}) async {
  if (!await _shouldRaceCandidates(
    candidateUrls: candidateUrls,
    asset: asset,
    stagingPaths: stagingPaths,
    connectionCount: connectionCount,
    minSegmentBytes: minSegmentBytes,
    metadata: metadata,
  )) {
    return candidateUrls;
  }
  final _UpdateDownloadMetadata? raceMetadata =
      await _UpdateDownloadMetadata.read(stagingPaths.metadataFile);
  final List<String>? raced = await raceSelectFastestCandidate(
    candidateUrls: candidateUrls,
    directUrl: asset.url,
    openUrl: openUrl,
    ifRange: raceMetadata?.etag ?? raceMetadata?.lastModified,
  );
  return raced ?? candidateUrls;
}

/// **竞速门控（TODO-683）**：判断是否值得对多候选并发竞速选源。只在「真会走分片
/// 下载」时竞速，避免给单线程/小文件/续传路径平添探针请求（保现有测试零回归）：
///   1. [candidateUrls.length] <= 1 → 不竞速（退化单候选，竞速函数也会自退化，这里早返
///      省一次 metadata 读）。
///   2. [connectionCount] <= 1 → 不竞速（单线程下载不需要竞速选源，串行回退已够）。
///   3. size 已知（asset / 循环外 metadata）且小到切不出多段（小文件）→ 不竞速：与
///      [_downloadCandidate] 的 `sizePermitsSegmentation` 预门控同一判据，小文件不分片
///      也就不该多发探针（直击「2 候选小文件 200 + 断言无 Range」类现有用例）。size
///      未知（纯 GFW 302 无 Content-Length）才让竞速探针去拿总大小并选源。
///   4. 已有可续传的 part 残留（partFile 存在且非空）→ 不竞速：续传应继续当前 staging
///      源/偏移，换源会让 If-Range 失配、退而重下，竞速反而帮倒忙。
Future<bool> _shouldRaceCandidates({
  required List<String> candidateUrls,
  required UpdateAsset asset,
  required _UpdateDownloadStagingPaths stagingPaths,
  required int connectionCount,
  required int minSegmentBytes,
  required _UpdateDownloadMetadata? metadata,
}) async {
  if (candidateUrls.length <= 1) return false;
  if (connectionCount <= 1) return false;
  final int? knownSize = asset.sizeBytes ?? metadata?.sizeBytes;
  if (knownSize != null) {
    final bool permitsSegmentation = planDownloadSegments(
          totalBytes: knownSize,
          connectionCount: connectionCount,
          minSegmentBytes: minSegmentBytes,
        ).length >
        1;
    if (!permitsSegmentation) return false;
  }
  try {
    if (await stagingPaths.partFile.exists() &&
        await stagingPaths.partFile.length() > 0) {
      return false;
    }
  } catch (_) {
    // 读 part 出错按「无可续传残留」处理，不阻断竞速。
  }
  return true;
}

/// **并发探针竞速选源（TODO-683 核心）**。对 [candidateUrls] 里的**所有**候选并发发
/// 探针（`Range: bytes=0-`，只探不真下载）。语义：
///   * 第一个返回 206 且拿到合法总大小的候选触发裁决——若它是直连，立即胜出；若它是
///     镜像，再多等 [_kDirectTieBreakWindow]（或直到某个直连也到）做 tie-break（PM ④）。
///   * 裁决后（`_settled` 置位）所有候选 response 立即 `drain()` 回收（取消语义 R1）。
///   * 拿不到任何 eligible 候选（全部探针失败 / 非 206 / 拿不到总大小）→ 返回 null，由
///     调用方回退现有串行循环（它填 failures、让 [selectRepresentativeDownloadFailure]
///     锚定直连）。
///
/// 返回竞速重排后的候选列表（胜出 url 提首位，其余原序跟随，见
/// [reorderCandidatesByRaceWinner]）；选不出 → null。
///
/// **边界**：[candidateUrls.length] <= 1 → 返回 null（退化为现有单候选行为，不并发；
/// 保「现有 segmented/resume/mirror 单 url + 请求计数」用例零回归）。探针只用
/// [_kFirstByteTimeout]（5s）计时，快判死「连上即挂」的坏候选。
///
/// **取消语义（R1）**：用 `bool settled` 只采首个胜出裁决（单 isolate 顺序执行回调，bool
/// 够用无需锁）；落败 response 的 `drain()` 一律 await 且 try/catch 吞错——坏镜像断流
/// drain 会抛，吞掉以免在 settle 后产生后台 uncaught 异常污染日志/测试 Stream 告警。
/// Dart [HttpClient] 已发请求不能真 abort，落败 socket 靠 drain + idleTimeout 回收。
Future<List<String>?> raceSelectFastestCandidate({
  required List<String> candidateUrls,
  required String directUrl,
  required UpdateDownloadOpen openUrl,
  String? ifRange,
}) async {
  if (candidateUrls.length <= 1) return null;

  final List<UpdateProbeOutcome> eligible = <UpdateProbeOutcome>[];
  var settled = false;
  // 首个 eligible 到达后开一个 tie-break 计时器，到点裁决。直连先到则直接裁决（不等）。
  final Completer<void> decided = Completer<void>();
  Timer? tieBreakTimer;

  void decide() {
    if (decided.isCompleted) return;
    settled = true;
    decided.complete();
  }

  Future<void> drainQuietly(UpdateDownloadResponse response) async {
    try {
      await response.stream.drain<void>();
    } catch (_) {
      // 落败 / 坏镜像断流 drain 抛错属预期：吞掉，避免 settle 后后台 uncaught 异常。
    }
  }

  /// 把一个 eligible 结果纳入竞速并按语义推进裁决：直连 eligible → 立即裁决；首个镜像
  /// eligible → 启动 tie-break 计时器；窗口内直连补到则提前裁决。
  void admit(UpdateProbeOutcome outcome) {
    eligible.add(outcome);
    if (decided.isCompleted) return;
    if (outcome.isDirect) {
      decide();
      return;
    }
    tieBreakTimer ??= Timer(_kDirectTieBreakWindow, decide);
  }

  Future<void> probe(String url) async {
    final Stopwatch watch = Stopwatch()..start();
    final Map<String, String> headers = <String, String>{
      HttpHeaders.rangeHeader: 'bytes=0-',
      if (ifRange != null && ifRange.isNotEmpty)
        HttpHeaders.ifRangeHeader: ifRange,
    };
    final UpdateDownloadResponse response;
    try {
      response =
          await openUrl(Uri.parse(url), headers).timeout(_kFirstByteTimeout);
    } catch (_) {
      // 探针失败（连不上 / 超时 / 非 206 前出错）：不参与胜出，留给串行回退处理。
      return;
    }
    watch.stop();
    // 先按首字节到达时刻 admit（裁决依据 elapsed，不被 drain 拖延），再 drain body。
    // 探针 body 一律 drain：胜出者也 drain（正式下载由现有 _downloadSegmented 重新探+
    // 取），落败者更要 drain（取消语义 R1）；drain await 仅为 Future.wait 收口、回收 socket。
    final int? total = response.statusCode == HttpStatus.partialContent
        ? _contentRangeTotal(response.header(HttpHeaders.contentRangeHeader))
        : null;
    if (total != null && total > 0) {
      admit(UpdateProbeOutcome(
        url: url,
        total: total,
        elapsed: watch.elapsed,
        isDirect: url == directUrl,
      ));
    }
    await drainQuietly(response); // 非 206 / 拿到总大小都要 drain 回收 body。
  }

  final List<Future<void>> probes = <Future<void>>[
    for (final String url in candidateUrls) probe(url),
  ];
  // 两条收口路径：① decided 被裁决（首个 eligible / tie-break）；② 所有探针都跑完
  // （含全部失败 → 永不 decide → 靠 Future.wait 收口，再用空 eligible 返回 null）。
  final Future<void> allProbes = Future.wait(probes);
  await Future.any(<Future<void>>[decided.future, allProbes]);
  // 裁决后不再等剩余探针；但要确保已到达的 eligible 都被纳入比较。已 admit 的进
  // eligible 列表，未到达的探针忽略（晚到也不改判，settled 已置位）。
  settled = true;
  tieBreakTimer?.cancel();
  assert(settled);

  final String? winner = selectRaceWinnerUrl(eligible);
  if (winner == null) return null;
  return reorderCandidatesByRaceWinner(candidateUrls, winner);
}

/// **下载取消令牌（TODO-738 / TODO-808）**。下载遮罩「取消」按钮按下时置位。
///
/// 两层取消语义协作，缺一不可：
///   1. **候选边界检查**（TODO-738）：下载引擎在每个候选尝试边界调 [throwIfCancelled]，
///      已取消则抛 [UpdateDownloadCancelledException] 中断整轮，不再串行回退其余候选。
///   2. **在途 abort**（TODO-808）：仅边界检查不够——Dart [HttpClient] 默认要等当前候选
///      首字节 5s / body 段超时走完才到下一个边界，用户点「取消」后仍卡几秒到十几秒。
///      调用方用 [registerAbort] 登记一个「强断在途连接」回调（实际是
///      `client.close(force: true)`，强制断开该 client 上所有在途 socket），[cancel] 时
///      **主动**调用它，让正在 await 的建连 / 读流立即抛错跳出，取消即时生效。
///
/// abort 回调登记/清理用 [registerAbort] / [clearAbort] 成对管理。整轮下载共用同一个
/// [HttpClient]（见 release part `_downloadAndInstall`），故只需登记一次；回调内的
/// `client.close(force: true)` 与 finally 的 `client.close()` 关两次幂等、不报错。
/// 放在 race part：与竞速探针 drain 的取消语义（R1）同家，且让 download part 不越结构守卫。
@visibleForTesting
class UpdateDownloadCancellation {
  bool _cancelled = false;
  void Function()? _abort;

  /// 是否已请求取消。
  bool get isCancelled => _cancelled;

  /// 登记「强断在途连接」回调（TODO-808）。下载开始前由调用方注入
  /// `() => client.close(force: true)`。若**登记时已取消**，立即触发一次 abort——覆盖
  /// 「用户在 client 建好之前就点了取消」的竞态，避免回调登记后再也不被调用。
  void registerAbort(void Function() abort) {
    _abort = abort;
    if (_cancelled) _fireAbort();
  }

  /// 注销 abort 回调（TODO-808）。下载结束（finally）时清理，避免 cancel() 误关已被
  /// 复用/释放的下一个 client。
  void clearAbort() {
    _abort = null;
  }

  /// 请求取消（幂等）。置位取消标记，并**立即**触发已登记的 abort 回调强断在途连接
  /// （TODO-808），不再等候选边界 / 超时；引擎在下一个边界看到标记后收尾为已取消。
  void cancel() {
    _cancelled = true;
    _fireAbort();
  }

  /// 触发并消费 abort 回调（只触发一次：触发后清空，防强断后 finally 再次 force-close
  /// 已关 client）。回调自身的异常吞掉——强断 best-effort，不该让取消路径再抛。
  void _fireAbort() {
    final void Function()? abort = _abort;
    _abort = null;
    if (abort == null) return;
    try {
      abort();
    } catch (_) {
      // 强断 best-effort：client 已关 / 平台差异导致的异常吞掉，不污染取消路径。
    }
  }

  /// 已取消则抛 [UpdateDownloadCancelledException]，供候选循环在边界处统一检查。
  void throwIfCancelled() {
    if (_cancelled) throw const UpdateDownloadCancelledException();
  }
}

/// 用户主动取消下载时抛出的哨兵异常（TODO-738）。调用方据其类型把 UI 收尾为「已取消」
/// 而非「下载失败」（不弹错误 SnackBar）。
class UpdateDownloadCancelledException implements Exception {
  const UpdateDownloadCancelledException();

  @override
  String toString() => 'UpdateDownloadCancelledException';
}
