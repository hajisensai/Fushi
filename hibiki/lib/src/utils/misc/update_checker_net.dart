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

/// **根因修复（TODO-384 第二轮）**：让更新检查/下载用的 [HttpClient] 走用户机器上
/// 正在运行的系统/环境代理。
///
/// 背景：BUG-292 已查明纯 GFW（直连 `api.github.com` 被切、公共 gh 代理又不代理 API）
/// 环境下检查注定失败，唯一出路是「经用户自己的代理出口直连 API」。但**裸 `HttpClient()`
/// 默认不设 `findProxy`，连环境变量代理都不读**，所以即便用户开着 clash/v2ray，更新请求
/// 仍走直连被切——这是真正可修的结构性缺口。
///
/// Dart 的 `HttpClient.findProxyFromEnvironment` **只读环境变量**（`HTTPS_PROXY` /
/// `HTTP_PROXY` / `NO_PROXY`，大小写均认），**不读 Windows 注册表 / macOS / Linux GUI 系统
/// 代理设置**（已实测 + 官方文档确认）。因此：
///   * 所有平台：合并 `Platform.environment`，覆盖「代理 app 导出了 env 变量」「用户手动
///     `set HTTPS_PROXY` 后启动」等场景。
///   * Windows：clash/v2ray 的「系统代理」模式只写注册表
///     `HKCU\...\Internet Settings\ProxyServer`，env 变量为空 → 额外读注册表并把它注入
///     environment map（见 [resolveWindowsSystemProxyEnvironment]）。
///   * macOS：GUI「网络偏好设置 → 代理」写在系统配置（`scutil --proxy` 可读），env 为空 →
///     读 scutil 注入（见 [resolveMacSystemProxyEnvironment]）。
///   * Linux：GNOME「网络 → 网络代理」写在 GSettings（`gsettings get org.gnome.system.proxy`
///     可读），env 为空 → 读 gsettings 注入（见 [resolveLinuxSystemProxyEnvironment]）。
///
/// **统一优先级（TODO-704 硬规则）**：`env > GUI 系统代理 > DIRECT`。三平台共用同一个
/// `hasEnvProxy` 闸门——用户显式 set 的 env 代理不该被任何 GUI 系统代理覆盖；仅当 env 未给
/// 代理时才按平台读 GUI 系统代理。GUI 也无 / 命中 PAC / 读取异常 → environment 不含代理键，
/// `findProxyFromEnvironment` 自然返回 `DIRECT`，等价原「裸 HttpClient 直连」——**不破坏现有
/// 逐镜像回退**。
///
/// **PAC 降级**：mac/Linux GUI 配成 PAC（自动代理）时，本实现**不解析/执行 PAC 脚本**，明确
/// 降级直连（DIRECT）并打 debug 日志（见 [resolveMacSystemProxyEnvironment] /
/// [resolveLinuxSystemProxyEnvironment]）。
Future<void> applyUpdateProxy(HttpClient client) async {
  final Map<String, String> environment = <String, String>{
    ...Platform.environment,
  };
  // env 变量优先：用户显式 set 的不该被 GUI 系统代理覆盖。仅当 env 没给代理时才按平台补 GUI
  // 系统代理。三平台共用同一闸门，杜绝优先级不一致（TODO-704）。
  final bool hasEnvProxy = environment.keys.any((String k) {
    final String lower = k.toLowerCase();
    return lower == 'https_proxy' || lower == 'http_proxy';
  });
  if (!hasEnvProxy) {
    final Map<String, String> systemProxy;
    if (Platform.isWindows) {
      systemProxy = await resolveWindowsSystemProxyEnvironment();
    } else if (Platform.isMacOS) {
      systemProxy = await resolveMacSystemProxyEnvironment();
    } else if (Platform.isLinux) {
      systemProxy = await resolveLinuxSystemProxyEnvironment();
    } else {
      systemProxy = const <String, String>{};
    }
    environment.addAll(systemProxy);
  }
  client.findProxy = (Uri uri) =>
      HttpClient.findProxyFromEnvironment(uri, environment: environment);
}

/// 读取 Windows「系统代理」设置（clash/v2ray 系统代理模式写在这里），返回可喂给
/// [HttpClient.findProxyFromEnvironment] 的 environment 片段（`{'https_proxy': ...,
/// 'http_proxy': ...}`）；未启用 / 读取失败 / 非 Windows 返回空 map（= 不补代理）。
///
/// 走 `reg query`（异步、无需 FFI、无新依赖），在构建 client 前一次性解析；解析逻辑下沉到
/// 纯函数 [parseWindowsRegistryProxy] 以便单测。
Future<Map<String, String>> resolveWindowsSystemProxyEnvironment() async {
  if (!Platform.isWindows) return const <String, String>{};
  try {
    const String key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    final ProcessResult enableResult = await Process.run(
      'reg',
      <String>['query', key, '/v', 'ProxyEnable'],
    );
    final ProcessResult serverResult = await Process.run(
      'reg',
      <String>['query', key, '/v', 'ProxyServer'],
    );
    return parseWindowsRegistryProxy(
      proxyEnableOutput:
          enableResult.stdout is String ? enableResult.stdout as String : '',
      proxyServerOutput:
          serverResult.stdout is String ? serverResult.stdout as String : '',
    );
  } catch (e) {
    // 读不到注册表（权限/环境异常）就当没有系统代理，回退直连——best-effort。
    debugPrint('[UpdateChecker] read windows system proxy failed: $e');
    return const <String, String>{};
  }
}

/// **纯函数**：解析 `reg query ... /v ProxyEnable|ProxyServer` 的原始输出，生成
/// `findProxyFromEnvironment` 用的 environment 片段。
///
/// - `ProxyEnable` 必须为 `0x1`（启用）才返回代理；`0x0`/缺失 → 空 map（系统代理关着）。
/// - `ProxyServer` 形如 `127.0.0.1:7890`（全局）或
///   `http=127.0.0.1:7890;https=127.0.0.1:7890;...`（分协议）。两种都解析：分协议时取
///   `https=`（优先）/`http=` 段；全局时直接用整串。
/// - 输出畸形 / 无 ProxyServer → 空 map。
///
/// `reg query` 单行格式：`    ProxyServer    REG_SZ    127.0.0.1:7890`（前导空白 + 三段，
/// 以连续空白分隔；值本身可能含 `=`/`;`/`:` 但不含空白，故按「类型标记 REG_* 之后」取值）。
@visibleForTesting
Map<String, String> parseWindowsRegistryProxy({
  required String proxyEnableOutput,
  required String proxyServerOutput,
}) {
  final String? enableValue =
      _registryValueAfterType(proxyEnableOutput, 'ProxyEnable');
  // ProxyEnable 是 REG_DWORD，值形如 `0x1`/`0x0`。非 0x1 视为未启用。
  if (enableValue == null || enableValue.toLowerCase() != '0x1') {
    return const <String, String>{};
  }
  final String? serverValue =
      _registryValueAfterType(proxyServerOutput, 'ProxyServer');
  if (serverValue == null || serverValue.isEmpty) {
    return const <String, String>{};
  }

  final String? https = _proxyForScheme(serverValue, 'https');
  final String? http =
      _proxyForScheme(serverValue, 'http') ?? _globalProxy(serverValue);
  return _buildProxyEnv(https: https, http: http);
}

/// 从单条 `reg query` 输出里取出指定值名后、`REG_<TYPE>` 标记之后的那段值。
/// 匹配行必须含 `valueName`，再按空白切出最后一段作为值。无匹配返回 null。
String? _registryValueAfterType(String output, String valueName) {
  for (final String rawLine in const LineSplitter().convert(output)) {
    final String line = rawLine.trim();
    if (!line.startsWith(valueName)) continue;
    final RegExpMatch? m =
        RegExp(r'^' + valueName + r'\s+REG_\w+\s+(.+)$').firstMatch(line);
    if (m != null) return m.group(1)!.trim();
  }
  return null;
}

/// 从分协议代理串（`http=h:p;https=h:p`）里取指定 scheme 的 `host:port`；全局串
/// （不含 `=`）返回 null。
String? _proxyForScheme(String proxyServer, String scheme) {
  if (!proxyServer.contains('=')) return null;
  for (final String part in proxyServer.split(';')) {
    final int eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.substring(0, eq).trim().toLowerCase() == scheme) {
      return part.substring(eq + 1).trim();
    }
  }
  return null;
}

/// 全局代理串（不含 `=`，形如 `127.0.0.1:7890`）原样返回；分协议串返回 null。
String? _globalProxy(String proxyServer) =>
    proxyServer.contains('=') ? null : proxyServer.trim();

/// 读取 macOS GUI 系统代理（「系统设置 → 网络 → 代理」写在系统配置里，clash/v2ray 等的
/// 「系统代理」模式也落这里），返回可喂给 [HttpClient.findProxyFromEnvironment] 的
/// environment 片段；未启用 / 命中 PAC / 读取失败 / 非 macOS 返回空 map（= 不补代理，回退
/// env / DIRECT）。
///
/// 走 `scutil --proxy`（系统自带、无需 FFI、无新依赖），在构建 client 前一次性解析；解析逻辑
/// 下沉到纯函数 [parseScutilProxy] 以便单测。命中 PAC 时该纯函数返回 `pacDowngraded=true`，
/// 这里打明确降级日志（TODO-704：PAC 不解析，明确降级直连）。
Future<Map<String, String>> resolveMacSystemProxyEnvironment() async {
  if (!Platform.isMacOS) return const <String, String>{};
  try {
    final ProcessResult result =
        await Process.run('scutil', <String>['--proxy']);
    final String stdout =
        result.stdout is String ? result.stdout as String : '';
    final (Map<String, String> proxy, bool pacDowngraded) =
        parseScutilProxy(stdout);
    if (pacDowngraded) {
      debugPrint(
        '[UpdateChecker] 检测到 macOS PAC 自动代理，更新检查降级直连（不解析 PAC）',
      );
    }
    return proxy;
  } catch (e) {
    // 读不到系统代理（权限/环境异常）就当没有，回退 env / 直连——best-effort。
    debugPrint('[UpdateChecker] read macOS system proxy failed: $e');
    return const <String, String>{};
  }
}

/// **纯函数**：解析 `scutil --proxy` 的原始输出，生成 `findProxyFromEnvironment` 用的
/// environment 片段 + 「是否命中 PAC 降级」标志。
///
/// `scutil --proxy` 典型输出（每行 `  Key : Value`，分隔符是 ` : `）：
/// ```
/// <dictionary> {
///   HTTPEnable : 1
///   HTTPProxy : 127.0.0.1
///   HTTPPort : 7890
///   HTTPSEnable : 1
///   HTTPSProxy : 127.0.0.1
///   HTTPSPort : 7890
///   ProxyAutoConfigEnable : 1
/// }
/// ```
///
/// 规则（**⚠️ scutil 的 Enable 值是 `1` 不是 Windows 的 `0x1`，别照搬**）：
/// - `ProxyAutoConfigEnable : 1`（PAC）→ 返回空 map + `pacDowngraded=true`（明确降级直连，
///   **不再回退 env**——调用方据此打降级日志）。
/// - 否则优先 HTTPS（更新走 https）：`HTTPSEnable : 1` 且有 `HTTPSProxy` + `HTTPSPort` →
///   `host:port`；无则回退 HTTP（`HTTPEnable : 1` + `HTTPProxy` + `HTTPPort`）。
/// - 全 0 / 缺字段 / 畸形输出 → 空 map + `pacDowngraded=false`（none，回退 env / 直连）。
///
/// **字段格式（Enable 值 `1`、分隔符 ` : `、键名 HTTPSEnable 等）属外部命令契约，需 macOS
/// 真机 dump 一次 `scutil --proxy` 输出核对。**
@visibleForTesting
(Map<String, String>, bool) parseScutilProxy(String stdout) {
  final Map<String, String> fields = <String, String>{};
  for (final String rawLine in const LineSplitter().convert(stdout)) {
    final String line = rawLine.trim();
    final int sep = line.indexOf(' : ');
    if (sep < 0) continue;
    final String key = line.substring(0, sep).trim();
    final String value = line.substring(sep + 3).trim();
    if (key.isEmpty) continue;
    fields[key] = value;
  }

  // PAC（自动代理）命中 → 明确降级直连，不解析脚本。
  if (fields['ProxyAutoConfigEnable'] == '1') {
    return (const <String, String>{}, true);
  }

  final String? https = _scutilSchemeProxy(fields, 'HTTPS');
  final String? http = _scutilSchemeProxy(fields, 'HTTP');
  return (_buildProxyEnv(https: https, http: http), false);
}

/// 从 scutil 字段表里取某个 scheme（`HTTPS` / `HTTP`）的 `host:port`：`<scheme>Enable` 为
/// `1` 且 `<scheme>Proxy` 非空、`<scheme>Port` 非空才返回，否则 null。
String? _scutilSchemeProxy(Map<String, String> fields, String scheme) {
  if (fields['${scheme}Enable'] != '1') return null;
  final String? host = fields['${scheme}Proxy'];
  final String? port = fields['${scheme}Port'];
  if (host == null || host.isEmpty) return null;
  if (port == null || port.isEmpty) return null;
  return '$host:$port';
}

/// 读取 Linux GNOME GUI 系统代理（「设置 → 网络 → 网络代理」写在 GSettings
/// `org.gnome.system.proxy`），返回可喂给 [HttpClient.findProxyFromEnvironment] 的
/// environment 片段；mode=none / 命中 PAC（mode=auto）/ gsettings 不存在（非 GNOME 桌面）/
/// 读取失败 / 非 Linux 返回空 map（= 不补代理，回退 env / DIRECT）。
///
/// 走 `gsettings`（GNOME 自带、无需 FFI、无新依赖）：先取 `mode`，仅 `manual` 时再取
/// `org.gnome.system.proxy.https` 的 `host` + `port`（无 https 配置回退 `.http`）；解析逻辑
/// 下沉到纯函数 [parseGsettingsProxy] 以便单测。`auto`（PAC）→ 明确降级直连并打日志。
Future<Map<String, String>> resolveLinuxSystemProxyEnvironment() async {
  if (!Platform.isLinux) return const <String, String>{};
  try {
    final ProcessResult modeResult = await Process.run(
      'gsettings',
      <String>['get', 'org.gnome.system.proxy', 'mode'],
    );
    final String mode =
        modeResult.stdout is String ? modeResult.stdout as String : '';

    // 只有 manual 才需要再查具体 host/port，省两次 Process.run。
    String httpsHost = '';
    String httpsPort = '';
    String httpHost = '';
    String httpPort = '';
    if (parseGsettingsMode(mode) == _GsettingsProxyMode.manual) {
      httpsHost = await _gsettingsGet('org.gnome.system.proxy.https', 'host');
      httpsPort = await _gsettingsGet('org.gnome.system.proxy.https', 'port');
      httpHost = await _gsettingsGet('org.gnome.system.proxy.http', 'host');
      httpPort = await _gsettingsGet('org.gnome.system.proxy.http', 'port');
    }

    final (Map<String, String> proxy, bool pacDowngraded) = parseGsettingsProxy(
      mode: mode,
      httpsHost: httpsHost,
      httpsPort: httpsPort,
      httpHost: httpHost,
      httpPort: httpPort,
    );
    if (pacDowngraded) {
      debugPrint(
        '[UpdateChecker] 检测到 Linux PAC 自动代理，更新检查降级直连（不解析 PAC）',
      );
    }
    return proxy;
  } catch (e) {
    // gsettings 不存在（非 GNOME / 无 glib）或读取异常 → 当没有系统代理，回退 env / 直连。
    debugPrint('[UpdateChecker] read Linux system proxy failed: $e');
    return const <String, String>{};
  }
}

/// 跑一条 `gsettings get <schema> <key>` 取裸值（已剥单引号），异常/非 String 返回空串。
Future<String> _gsettingsGet(String schema, String key) async {
  final ProcessResult result =
      await Process.run('gsettings', <String>['get', schema, key]);
  final String raw = result.stdout is String ? result.stdout as String : '';
  return _stripGsettingsQuotes(raw);
}

/// GSettings 代理 mode 三态。`auto` 即 PAC（自动代理）。
enum _GsettingsProxyMode { none, manual, auto }

/// **纯函数**：解析 `gsettings get org.gnome.system.proxy mode` 的原始输出。gsettings 字符串
/// 值带单引号（形如 `'manual'`）+ 可能有换行，剥引号 / 空白后归一到三态；未知值当 none。
@visibleForTesting
_GsettingsProxyMode parseGsettingsMode(String modeOutput) {
  final String mode = _stripGsettingsQuotes(modeOutput);
  switch (mode) {
    case 'manual':
      return _GsettingsProxyMode.manual;
    case 'auto':
      return _GsettingsProxyMode.auto;
    default:
      return _GsettingsProxyMode.none;
  }
}

/// **纯函数**：综合 gsettings 的 `mode` + https/http 的 host+port，生成
/// `findProxyFromEnvironment` 用的 environment 片段 + 「是否命中 PAC 降级」标志。
///
/// 规则：
/// - `mode=auto`（PAC）→ 空 map + `pacDowngraded=true`（明确降级直连，不解析 PAC）。
/// - `mode=manual` + 有 https host+port → `host:port`（优先 https，更新走 https）；无 https
///   配置回退 http host+port；都无 → 空 map。
/// - `mode=none` / 未知 / 空 host → 空 map + `pacDowngraded=false`（回退 env / 直连）。
///
/// host/port 入参须为**已剥单引号**的裸值（由 [_gsettingsGet] / 测试保证）。port 为 gsettings
/// 整数值（形如 `7890`），空串 / `0` 视为未配置。
///
/// **字段格式（mode 带单引号、host 带单引号、port 整数、schema 名）属外部命令契约，需 Linux
/// 真机 dump `gsettings get org.gnome.system.proxy ...` 输出核对。**
@visibleForTesting
(Map<String, String>, bool) parseGsettingsProxy({
  required String mode,
  required String httpsHost,
  required String httpsPort,
  required String httpHost,
  required String httpPort,
}) {
  switch (parseGsettingsMode(mode)) {
    case _GsettingsProxyMode.auto:
      return (const <String, String>{}, true);
    case _GsettingsProxyMode.none:
      return (const <String, String>{}, false);
    case _GsettingsProxyMode.manual:
      final String? https = _gsettingsSchemeProxy(httpsHost, httpsPort);
      final String? http = _gsettingsSchemeProxy(httpHost, httpPort);
      return (_buildProxyEnv(https: https, http: http), false);
  }
}

/// 从 gsettings 的 host+port 拼 `host:port`：host 非空且 port 非空且非 `0` 才返回，否则 null。
String? _gsettingsSchemeProxy(String host, String port) {
  final String h = host.trim();
  final String p = port.trim();
  if (h.isEmpty) return null;
  if (p.isEmpty || p == '0') return null;
  return '$h:$p';
}

/// 剥掉 gsettings 字符串值外层的单引号 + 首尾空白（`'manual'\n` → `manual`）。无引号原样
/// trim。
String _stripGsettingsQuotes(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

/// 把已解析的 https/http `host:port` 拼成 `findProxyFromEnvironment` 用的 environment 片段。
/// 与 [parseWindowsRegistryProxy] 同范式：`findProxyFromEnvironment` 对 https URL 读
/// `https_proxy`、回退 `http_proxy`，两者都填最稳；任一缺失互相回退。都无 → 空 map。
Map<String, String> _buildProxyEnv({
  required String? https,
  required String? http,
}) {
  final Map<String, String> result = <String, String>{};
  final String? effectiveHttps = https ?? http;
  if (effectiveHttps != null && effectiveHttps.isNotEmpty) {
    result['https_proxy'] = effectiveHttps;
  }
  final String? effectiveHttp = http ?? https;
  if (effectiveHttp != null && effectiveHttp.isNotEmpty) {
    result['http_proxy'] = effectiveHttp;
  }
  return result;
}

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
