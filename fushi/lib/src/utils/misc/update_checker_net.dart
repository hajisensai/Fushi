part of 'update_checker.dart';

/// GitHub 直连不通时（GFW 机器，且 app 运行时**不走**本机命令行代理）套在 GitHub
/// 链接前的加速代理前缀。逐个尝试（见 [fetchFirstSuccessfulBody]），任一成功即返回，
/// 全部失败才优雅放弃。这些公共镜像会不定期轮换/下线（`mirror.ghproxy.com`、
/// `ghproxy.homeboyc.cn` 均因 DNS 不再解析下线移除——后者见用户真机日志
/// `Failed host lookup: 'ghproxy.homeboyc.cn' (errno = 7)`，TODO-666），具体哪个通取
/// 决于用户机器与时段，故多备几个（BUG-277：单点不可达不该让整轮检查失败）。
///
/// **结构性根治（TODO-666）**：删一个死域名只是治标——公共 gh 代理本就会轮换下线。
/// 真正会坑用户的是「下载全失败时把碰巧排列表最后的死镜像错误当成整轮失败原因展示」，
/// 那个误导性报错由 [_downloadUpdateAssetUncoalesced] 的失败错误选择逻辑根治：全失败时
/// 优先抛**直连**（首候选）的错误，而不是列表末尾镜像的 host-lookup 失败。
///
/// **重要结构性事实（BUG-292，2026-06-15 实测）**：这些公共 gh 代理**只代理
/// `raw.githubusercontent.com` / release 资源「下载」**，对 `api.github.com` JSON
/// API 一律 HTTP 403（GitHub 对镜像共享出口 IP 的未授权限流，403 头里带
/// `x-ratelimit-remaining: 0`）或直接 TLS 失败。所以更新「**检查**」（命中
/// `api.github.com`，见 [_fetchReleasesForChannel]）经**任何**镜像都不可能成功——
/// 检查阶段唯一能成功的是**直连**（[updateCheckUrls] 把直连放首位正是为此）；镜像
/// 列表只对「**下载**」阶段（[_downloadAndInstall]，命中
/// `github.com/.../releases/download/...`）真正有用，实测 ghfast.top / ghproxy.net
/// 可返回 206 分片。**勿误以为「换/加 API 镜像」能修检查不通**：纯 GFW（直连 API 被
/// 切断）环境下检查注定失败，需用户开代理/VPN 或自建 API 反代。
///
/// 与 `video_shader_downloader.dart` 的 `_kGhProxyPrefixes`（BUG-319/271）同一范式——
/// 那个只下载 raw 资源、不命中 API，故不受本限制影响。
@visibleForTesting
const List<String> updateCheckProxyPrefixes = <String>[
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghproxy.cc/',
  'https://gh.llkk.cc/',
];

/// **纯函数**：为一个 GitHub API / 直链 [url] 生成按优先级排序的候选 URL 列表。
///
/// 顺序：① 直连 [url] 本身（有 VPN / 系统代理时最快、最权威）→ ② 每个
/// [updateCheckProxyPrefixes] 套在直连前（GFW 兜底）。逐个尝试，任一成功即整体成功
/// （见 [fetchFirstSuccessfulBody]）。直连只出现一次、候选无重复。
@visibleForTesting
List<String> updateCheckUrls(String url) {
  return <String>[
    url,
    for (final String prefix in updateCheckProxyPrefixes) '$prefix$url',
  ];
}

/// 直连与镜像在检查阶段近乎同时返回合法响应时的 tie-break 窗口（TODO-821）。最快候选是
/// 镜像时，再多等本窗口看直连是否也成功；成功就优先选直连——与 [updateCheckUrls] 把直连
/// 恒放首位、视作最权威/最可信的哲学一致（检查命中 `api.github.com` 时镜像必 403，唯一
/// 真能成功的就是直连）。与下载阶段 race part 的 `_kDirectTieBreakWindow` 同范式、同值。
const Duration _kCheckDirectTieBreakWindow = Duration(milliseconds: 500);

/// **可注入核心**：对 [urls] **全部候选并发**调用 [fetch]，返回**第一个合法成功**（非
/// null）的响应体；全部失败才返回 null。这是更新检查可达性的真正逻辑（BUG-277 把它从原
/// `_httpGetString` 的真实网络 IO 里抽出来，TODO-821 把串行逐个尝试改成并发竞速选最快活
/// 源——纯 GFW 下 6 个候选里 5 个镜像命中 `api.github.com` 必 403、各吃满超时，串行会叠加
/// 几十秒「正在连接更新源」，并发竞速则只付最快活源那一份耗时）。
///
/// **胜出条件是「合法响应」而非「最先返回」**：镜像对 `api.github.com` 会**快速** 403 →
/// [fetch] 返回 null（视为失败），不会赢过慢但唯一可成功的直连。只有 [fetch] 返回非 null
/// 才算胜出资格。
///
/// **直连优先 tie-break**（与 [updateCheckUrls]「直连恒首位」哲学一致）：首个合法成功是
/// 镜像时，再多等 [_kCheckDirectTieBreakWindow] 看直连（[urls] 首项）是否也成功；窗口内直连
/// 也拿到合法响应则改用直连结果。直连先成功则立即裁决、不等。
///
/// - [fetch] 返回非 null → 该候选合法成功，纳入竞速；按上面 tie-break 裁决胜者。
/// - [fetch] 返回 null 或抛异常 → 视为该候选失败，记 [onFailure]（主机标签 + 错误对象，
///   异常时非 null）；落败/失败候选**不**终止其他候选。异常不冒泡。
/// - 全部候选耗尽仍无合法成功 → 返回 null（由调用方决定如何提示「全失败」）。
@visibleForTesting
Future<String?> fetchFirstSuccessfulBody(
  List<String> urls, {
  required Future<String?> Function(String url) fetch,
  void Function(String host, Object? error)? onFailure,
}) {
  return raceFirstSuccessfulBody(
    urls,
    fetch: fetch,
    onFailure: onFailure,
  );
}

/// 一个并发候选 [fetch] 的结果（检查阶段竞速用）。[url] = 被抓的候选；[body] = 合法成功
/// 响应体（null 表示该候选失败 / 不具胜出资格）；[isDirect] = 该候选是否直连（[url] ==
/// 候选列表首项，tie-break 直连优先用）。
class _UpdateCheckOutcome {
  const _UpdateCheckOutcome({
    required this.url,
    required this.body,
    required this.isDirect,
  });

  final String url;
  final String? body;
  final bool isDirect;
}

/// **并发竞速取首个合法成功响应（TODO-821 核心）**。对 [urls] 里**所有**候选并发调用
/// [fetch]，语义见 [fetchFirstSuccessfulBody]：第一个合法成功（非 null body）触发裁决——
/// 直连立即胜出；镜像则再等 [_kCheckDirectTieBreakWindow] 做直连优先 tie-break。失败候选
/// （null / 抛异常）经 [onFailure] 记录、不参与裁决、不中断其他候选。全失败 → null。
///
/// 与下载阶段 [raceSelectFastestCandidate] 同范式（`Future.any` + `Completer decided` +
/// tie-break 计时器 + 落败者继续耗尽），统一两阶段并发语义、消除两套实现分裂。
///
/// **边界**：[urls] 为空 → null；单候选 → 退化为「跑那一个候选」（无并发开销、无 tie-break
/// 窗口等待，直连/单镜像单请求行为零变化）。
@visibleForTesting
Future<String?> raceFirstSuccessfulBody(
  List<String> urls, {
  required Future<String?> Function(String url) fetch,
  void Function(String host, Object? error)? onFailure,
}) async {
  if (urls.isEmpty) return null;
  final String directUrl = urls.first;

  final List<_UpdateCheckOutcome> succeeded = <_UpdateCheckOutcome>[];
  final Completer<void> decided = Completer<void>();
  Timer? tieBreakTimer;

  void decide() {
    if (decided.isCompleted) return;
    decided.complete();
  }

  // 把一个合法成功结果纳入竞速并推进裁决：直连 → 立即裁决；首个镜像 → 启动 tie-break
  // 计时器；窗口内直连补到则由它自己的 decide() 提前裁决。
  void admit(_UpdateCheckOutcome outcome) {
    succeeded.add(outcome);
    if (decided.isCompleted) return;
    if (outcome.isDirect) {
      decide();
      return;
    }
    tieBreakTimer ??= Timer(_kCheckDirectTieBreakWindow, decide);
  }

  Future<void> attempt(String url) async {
    final bool isDirect = url == directUrl;
    try {
      final String? body = await fetch(url);
      if (body != null) {
        admit(_UpdateCheckOutcome(url: url, body: body, isDirect: isDirect));
        return;
      }
      onFailure?.call(hostLabelForUpdateUrl(url), null);
    } catch (e) {
      onFailure?.call(hostLabelForUpdateUrl(url), e);
    }
  }

  final List<Future<void>> attempts = <Future<void>>[
    for (final String url in urls) attempt(url),
  ];
  // 两条收口路径：① decided 被裁决（首个合法成功 / tie-break 到点）；② 所有候选都跑完
  // （含全部失败 → 永不 decide → 靠 Future.wait 收口，再用空 succeeded 返回 null）。
  final Future<void> allDone = Future.wait(attempts);
  await Future.any(<Future<void>>[decided.future, allDone]);
  tieBreakTimer?.cancel();

  return _selectCheckRaceWinner(succeeded);
}

/// **纯函数（TODO-821）**：从一批合法成功的并发结果里挑胜出 body。规则与下载阶段
/// [selectRaceWinnerUrl] 一致：存在直连成功 → 直连优先（net.dart「直连恒首位」哲学）；
/// 否则取首个到达的成功镜像（[succeeded] 按 admit 顺序，首项即最快返回的成功镜像）。
String? _selectCheckRaceWinner(List<_UpdateCheckOutcome> succeeded) {
  if (succeeded.isEmpty) return null;
  for (final _UpdateCheckOutcome outcome in succeeded) {
    if (outcome.isDirect) return outcome.body;
  }
  return succeeded.first.body;
}

/// **纯函数（TODO-1123 / BUG-539）**：判定一次下载失败是否是「asset 已被 rolling tag
/// 覆盖 / 客户端手里的 manifest 过期」——即服务器对下载 URL 返回 **404 Not Found**。
///
/// 根因：debug 通道走镜像 `latest-debug.json`（[kDebugManifestUrl]）。app 在「检查」阶段
/// 解析出 `asset.url` 后，「真正下载」时不再重取 manifest、直接信任旧 URL。CI 每次 push 都
/// 在 `debug-rolling` 这一个滚动 tag 上 prune 掉非当前 seq 的 asset，用户设备持旧 manifest
/// （旧 seq）去下载时，CI 可能已滚到新 seq 把旧 APK 删了 → 该 URL 404。这是 rolling tag
/// 覆盖式 prune 竞态，不是「网络连不上」，需触发「重取 manifest + 换新 URL 重试」而非当作
/// 普通网络失败静默失败。
///
/// 下载引擎（[ResumableDownloader] / [_runSegmentRequest]）对 4xx/5xx 统一抛
/// `HttpException('download failed (<code>): <url>')`，故此处按消息里的 `(404)` 段识别
/// （不引入新异常类型、不改引擎契约）。非 [HttpException] / 非 404 → false（真网络失败照走
/// 原路径冒泡，绝不误当过期 asset）。
bool isStaleAssetDownloadFailure(Object error) {
  if (error is! HttpException) return false;
  return _kDownload404Pattern.hasMatch(error.message);
}

// 下载引擎对 404 抛 `HttpException('download failed (404): <url>')`；匹配 `(404)` 段。
// HttpStatus.notFound == 404（避免魔法数与协议常量脱节，此处以注释锚定其数值语义）。
final RegExp _kDownload404Pattern = RegExp(r'\(404\)');

/// 更新检查与下载都是 best-effort。网络类失败——连不上、连接超时、TLS 握手
/// 失败、底层 HTTP 协议错误、单候选整体超时（[_kPerAttemptTimeout]）——是预期现象
/// （尤其 GFW 下访问 GitHub / 代理本就不稳），不该当错误带完整堆栈塞进用户可见的
/// 错误日志，否则真正的 bug 信号会被这类噪音淹没。返回 true 表示该异常只需
/// debugPrint / i18n 摘要，无需写完整堆栈到 ErrorLogService。
bool isExpectedUpdateNetworkFailure(Object e) =>
    e is SocketException ||
    e is HandshakeException ||
    e is HttpException ||
    e is TimeoutException;

/// **纯函数**：把一次更新网络失败的异常翻译成「为什么连不上」的可读原因，供用户
/// 错误日志使用（TODO-371）。原来无论真实异常是 DNS 解析失败、连接被拒、还是真超时，
/// 日志都死板地写「网络超时或不可达」，把瞬时失败也误报成超时、且吞掉了 errno 等
/// 关键线索。这里区分常见底层原因并尽量带上 `SocketException.osError`（errno +
/// 系统 message），让用户一眼看出是 DNS 不通、被拒、超时还是证书问题。
///
/// - [error] 为 null（HTTP 状态非 200、无异常的失败回退）→「服务器无有效响应」。
/// - `SocketException`：按 message / osError 细分 DNS 失败 / 连接被拒 / 超时 / 一般
///   连接失败，并附上 `(errno=…: …)`。
/// - `TimeoutException`：单候选整体超时。
/// - `HandshakeException`：TLS/SSL 握手失败。
/// - `HttpException`：底层 HTTP 协议错误。
/// - 其它：回退到该异常的 `toString()`，不再谎称超时。
String describeUpdateNetworkFailureReason(Object? error) {
  if (error == null) {
    return 'no valid response from server';
  }
  if (error is SocketException) {
    final OSError? os = error.osError;
    final String osPart =
        os != null ? ' (errno=${os.errorCode}: ${os.message})' : '';
    final String message = error.message;
    final String lower = message.toLowerCase();
    final String category;
    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname') ||
        lower.contains('name or service not known')) {
      category = 'DNS lookup failed';
    } else if (lower.contains('connection refused')) {
      category = 'connection refused';
    } else if (lower.contains('timed out') || lower.contains('timeout')) {
      category = 'connection timed out';
    } else {
      category = message.isNotEmpty ? message : 'connection failed';
    }
    return '$category$osPart';
  }
  if (error is TimeoutException) {
    return 'connection timed out';
  }
  if (error is HandshakeException) {
    final String message = error.message;
    return message.isNotEmpty
        ? 'TLS handshake failed: $message'
        : 'TLS handshake failed';
  }
  if (error is HttpException) {
    final String message = error.message;
    return message.isNotEmpty
        ? 'HTTP protocol error: $message'
        : 'HTTP protocol error';
  }
  return error.toString();
}

/// 从更新请求 URL 取主机名，作为日志里「连不上哪个源」的可读标签。代理 URL
/// 形如 `https://ghfast.top/https://api.github.com/...`，其 host 是代理本身
/// （ghfast.top），正好对应真正发起连接、真正超时的那一跳。URL 畸形时回退到原串。
String hostLabelForUpdateUrl(String url) {
  try {
    final String host = Uri.parse(url).host;
    return host.isNotEmpty ? host : url;
  } catch (_) {
    return url;
  }
}

/// 一次失败的下载候选记录：哪个 [url]、抛了什么 [error]、堆栈 [stack]。下载阶段
/// （[downloadUpdateAsset]）逐候选尝试，把每个失败的候选收进列表，全失败时交
/// [selectRepresentativeDownloadFailure] 选出要抛给用户的代表性错误。
@visibleForTesting
class UpdateDownloadAttemptFailure {
  const UpdateDownloadAttemptFailure({
    required this.url,
    required this.error,
    required this.stack,
  });

  final String url;
  final Object error;
  final StackTrace stack;
}

/// **纯函数（TODO-666）**：从所有失败的下载候选里挑出最该展示给用户的「整轮失败原因」。
///
/// 下载候选顺序是「直连 [directUrl] → 各 gh 代理前缀套直连」（见 [updateCheckUrls]）。
/// 全失败时**不该**用列表里碰巧排最后的候选错误代表整轮失败——那通常是某个公共 gh 代理
/// （会轮换/下线，DNS 失效时给出 `Failed host lookup` 这种误导性报错，让用户以为是镜像
/// 域名的问题，正是 TODO-666 的 `ghproxy.homeboyc.cn` 现象）。真正有诊断价值的是**直连
/// GitHub** 的失败：直连不通才说明用户需要代理/VPN。
///
/// 选择优先级：
///   1. 候选 url == [directUrl]（直连本身，host 是 github.com）的失败 → 优先返回。
///   2. 否则回退到**首个**失败候选（保持「列表靠前 = 更权威」的直觉，仍不取末尾死镜像）。
///   3. [failures] 为空 → null（调用方用通用「全部源失败」兜底）。
@visibleForTesting
UpdateDownloadAttemptFailure? selectRepresentativeDownloadFailure(
  List<UpdateDownloadAttemptFailure> failures, {
  required String directUrl,
}) {
  if (failures.isEmpty) return null;
  for (final UpdateDownloadAttemptFailure failure in failures) {
    if (failure.url == directUrl) return failure;
  }
  return failures.first;
}

/// 「更新日志」页数据源（TODO-1310，应用内查看历史发布说明）：拉取本仓库全部
/// GitHub releases（含各版本 `tag_name` / `published_at` / Markdown `body` /
/// `prerelease` 标记 / `html_url`），复用与「检查更新」完全相同的私有 HTTP 管线
/// （[UpdateChecker._httpGetStringFromGitHubRepos]）——自动继承多镜像回退、系统/自定义
/// 代理注入（[applyAppProxy]）、每候选整体超时、`kGitHubRepoFallbacks` 旧库回退。
/// `draft` 草稿被过滤（未发布，用户不该看到）。
///
/// ⚠️ `api.github.com/.../releases` 列表 API 经任何公共 gh 代理都会 403（BUG-292），
/// 且无 302 网页等价物，故纯 GFW 无代理环境会拿到空列表；网络/解析异常同样收敛为
/// 空列表（记诊断日志、不抛）。返回空列表对 UI 一律等价于「无数据」，调用方给
/// 「拉取失败/请检查网络或代理」空态并提供「打开发布页」逃生口即可。
Future<List<Map<String, dynamic>>> fetchAllGitHubReleases({
  String customProxy = '',
  int perPage = 30,
}) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    await applyAppProxy(client, userProxy: customProxy);
    final String? body = await UpdateChecker._httpGetStringFromGitHubRepos(
      client,
      (String repo) =>
          'https://api.github.com/repos/$repo/releases?per_page=$perPage',
      headers: const <String, String>{'Accept': 'application/vnd.github+json'},
    );
    if (body == null) return const <Map<String, dynamic>>[];
    return parseGitHubReleasesResponse(body);
  } catch (e, stack) {
    ErrorLogService.instance.log('fetchAllGitHubReleases', e, stack);
    return const <Map<String, dynamic>>[];
  } finally {
    client.close();
  }
}

/// 解析 GitHub `releases` 列表 API 响应体（[fetchAllGitHubReleases] 的纯解析核心，
/// 抽出便于单测）：期望顶层是 release 对象数组，逐元素保留 `Map`、过滤 `draft==true`
/// 的草稿；顶层非数组（如错误对象 `{"message":...}`）返回空列表。**不吞 JSON 语法
/// 错误**——`jsonDecode` 抛出交由调用方的 try 收敛为空列表并记日志。
@visibleForTesting
List<Map<String, dynamic>> parseGitHubReleasesResponse(String body) {
  final dynamic decoded = jsonDecode(body);
  if (decoded is! List) return const <Map<String, dynamic>>[];
  return decoded
      .whereType<Map<String, dynamic>>()
      .where((Map<String, dynamic> release) => release['draft'] != true)
      .toList(growable: false);
}
