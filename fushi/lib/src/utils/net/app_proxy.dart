/// 全应用**出站 HTTP 代理**解析层：把「用户机器上正在跑的代理」翻译成
/// [HttpClient.findProxy]。
///
/// 本层原先住在 `update_checker_net.dart`（更新检查库的 part）里，命名与归属都写死成
/// 「更新专用」。但代理是**进程级网络出口策略**，不是更新检查的私有属性：BUG-1348 里
/// 谷歌云盘登录的 token 交换用裸 `http.Client()` 直连 `oauth2.googleapis.com`，在同一台
/// 开着代理的机器上必然 `errno = 121`（信号灯超时）失败——浏览器那半程走系统代理拿到了
/// 授权码，app 这半程走直连换不到 token。part 文件契约禁止 part 内 import，同步层没法
/// 复用它，于是同一台机器上「更新检查能走代理、云同步不能」。
///
/// 故本层提取为**独立库**：代理**怎么解析**（`env > GUI 系统代理 > DIRECT`、用户手填优先、
/// PAC 降级）全应用只有这一份实现，接代理的调用方一律 import 这里，不再各自重写一遍优先级。
///
/// **覆盖面（BUG-1498 收敛后）**：出站装配不再是「每个调用点各自记得做」的事。
///   * 公网出站一律经 `utils/net/app_http.dart` 的 [createAppHttpClient] /
///     `createAppHttpIoClient` / `createAppDio`（内部调 [applyAppProxySync]）；
///   * 需要异步现场解析的老调用点（云同步 / 更新检查 / 下载发现）继续用 [applyAppProxy]；
///   * 词典链路经 `utils/net/dictionary_dio.dart` 的工厂钩子（BUG-1493）；
///   * **本机 / 局域网 / 自建服务**（AnkiConnect、Yomitan 端口、Mihon sidecar、互联 peer、
///     qBittorrent WebUI、WebDAV/FTP/SFTP、texthooker WS）**故意不经本层**，并且**即便经了
///     也不会被代理**——见 [isDirectProxyTarget]。
///   * 结构上注入不了代理的：`NetworkImage` / `CachedNetworkImageProvider`（Flutter 内部
///     HttpClient）、media_kit/libmpv 拉流、内置 torrent 引擎（BT peer 不是 HTTP，代理只能
///     设在 libtorrent session 上）。
///
/// 守卫 `test/tools/outbound_http_discipline_guard_test.dart` 钉死这条纪律：新增裸
/// `HttpClient()` / `http.Client()` / `IOClient()` / `Dio()` 必须登记在案并写明理由。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 进程级「用户手填代理」读取器——[applyAppProxy] 不显式传 `userProxy` 时的取值来源。
///
/// 代理是全局网络配置，却存在 `PreferencesRepository` 里，而同步层（`GoogleDriveAuth`
/// 等单例）拿不到 `AppModel`。与其给每条网络调用链穿一路 `userProxy` 参数（穿漏一处就
/// 是一个「这条路不走代理」的暗坑，BUG-1348 正是如此），不如让配置本身有一个进程级
/// 真相源：`AppModel.initialise()` 把它接到偏好上，此后任何调用方 `applyAppProxy(client)`
/// 都自动拿到同一个值。
///
/// 默认返回空串 = 未接（测试 / popup 等精简入口），[applyAppProxy] 据此回退
/// `env > GUI 系统代理 > DIRECT`，与接入前逐字等价。
String Function() appUserProxyReader = () => '';

/// **纯函数（TODO-871/862）**：把用户手填的「自定义更新代理」原始串归一成
/// `host:port`，非法返 null（调用方据此 fail-open 落回默认 env>GUI>DIRECT 逻辑，绝不误切）。
///
/// 规则：trim → 剥可选 `http://` / `https://` 前缀 → 校验 `host:port`：
/// * host = IPv4（四段 0-255）或主机名（字母数字 + `.` + `-`，至少一个非空标签）。
/// * port = 纯数字、范围 1-65535。
///
/// **【必改④】IPv6 字面量**（`[::1]:7890`，含方括号 / 多个冒号）本期**不支持**→ 直接返
/// null（fail-open 落回默认）。空串 / 缺端口 / 非数字端口 / `0` / `70000` / 带路径 → null。
///
/// 公开（非 @visibleForTesting）：除测试外，设置页输入框也实时调用它做格式校验
/// （`settings_schema_system.dart`），故是真实生产 API。
String? normalizeUserProxyHostPort(String raw) {
  String value = raw.trim();
  if (value.isEmpty) return null;
  // 剥可选 scheme 前缀（大小写不敏感）。
  for (final String scheme in const <String>['https://', 'http://']) {
    if (value.toLowerCase().startsWith(scheme)) {
      value = value.substring(scheme.length).trim();
      break;
    }
  }
  if (value.isEmpty) return null;
  // 带路径 / query / fragment 一律不接受（host:port 之外的内容）。
  if (value.contains('/') || value.contains('?') || value.contains('#')) {
    return null;
  }
  // IPv6 字面量（方括号或多于一个冒号）本期不支持 → null（【必改④】）。
  if (value.contains('[') || value.contains(']')) return null;
  final int firstColon = value.indexOf(':');
  if (firstColon < 0) return null; // 缺端口。
  if (value.indexOf(':', firstColon + 1) >= 0) return null; // 多冒号（疑似 IPv6）。
  final String host = value.substring(0, firstColon);
  final String portText = value.substring(firstColon + 1);
  if (host.isEmpty || portText.isEmpty) return null;
  if (!_isValidProxyHost(host)) return null;
  final int? port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) return null;
  return '$host:$port';
}

/// 校验 [host] 是否为合法 IPv4 或主机名（normalizeUserProxyHostPort 内部用）。
bool _isValidProxyHost(String host) {
  // IPv4：四段、每段 0-255。
  final RegExpMatch? ipv4 =
      RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(host);
  if (ipv4 != null) {
    for (int i = 1; i <= 4; i++) {
      final int seg = int.parse(ipv4.group(i)!);
      if (seg > 255) return false;
    }
    return true;
  }
  // 主机名：点分标签，每段字母数字或内部连字符，不以 `-` 起止。
  final RegExp label = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$');
  final List<String> parts = host.split('.');
  for (final String part in parts) {
    if (part.isEmpty) return false;
    if (!label.hasMatch(part)) return false;
  }
  return true;
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
///
/// [userProxy] 省略时取进程级真相源 [appUserProxyReader]（见其文档：全局配置不该靠逐条
/// 调用链穿参，穿漏一处就是一条不走代理的暗路）。显式传值仍然优先，故既有调用点行为
/// 逐字不变。
Future<void> applyAppProxy(HttpClient client, {String? userProxy}) async {
  // 【必改③】用户手填代理优先：normalize 非 null → 直接短路，不进 environment 合并、
  // 不参与 env>GUI>DIRECT 排序，消除「手填 vs 系统代理」覆盖顺序不确定（TODO-871/862）。
  // fake-ip/TUN 模式下系统代理写注册表 Dart 读不到，这是唯一可靠出口。normalize 返 null
  // （空/畸形/IPv6）则 fail-open 落回下面默认逻辑——绝不误切。
  final String? normalizedUserProxy =
      normalizeUserProxyHostPort(userProxy ?? appUserProxyReader());
  if (normalizedUserProxy != null) {
    client.findProxy = (Uri uri) =>
        isDirectProxyTarget(uri.host) ? 'DIRECT' : 'PROXY $normalizedUserProxy';
    return;
  }
  final Map<String, String> environment = <String, String>{
    ...Platform.environment,
  };
  // env 变量优先：用户显式 set 的不该被 GUI 系统代理覆盖。仅当 env 没给代理时才按平台补 GUI
  // 系统代理。三平台共用同一闸门，杜绝优先级不一致（TODO-704）。
  if (!_hasEnvProxy(environment)) {
    environment.addAll(await resolveSystemProxyEnvironment());
  }
  client.findProxy = (Uri uri) => _directiveFor(uri, environment);
}

/// env 里有没有给代理（`https_proxy` / `http_proxy`，大小写不敏感）。
bool _hasEnvProxy(Map<String, String> environment) =>
    environment.keys.any((String k) {
      final String lower = k.toLowerCase();
      return lower == 'https_proxy' || lower == 'http_proxy';
    });

/// 统一的「一个 URI 该走什么出口」判定：**先过本机/局域网直连闸门**，再交给
/// `findProxyFromEnvironment`。同步版与异步版共用，两条路不可能给出不同答案。
String _directiveFor(Uri uri, Map<String, String> environment) =>
    isDirectProxyTarget(uri.host)
        ? 'DIRECT'
        : HttpClient.findProxyFromEnvironment(uri, environment: environment);

/// 按平台读 GUI 系统代理（Windows 注册表 / macOS scutil / Linux gsettings）。
/// 其余平台返回空 map。
Future<Map<String, String>> resolveSystemProxyEnvironment() async {
  if (Platform.isWindows) return resolveWindowsSystemProxyEnvironment();
  if (Platform.isMacOS) return resolveMacSystemProxyEnvironment();
  if (Platform.isLinux) return resolveLinuxSystemProxyEnvironment();
  return const <String, String>{};
}

// ---------------------------------------------------------------------------
// 同步装配路径（BUG-1498）
// ---------------------------------------------------------------------------
//
// 为什么必须有一条同步路：全仓 40+ 个出站点的形态都是构造函数初始化列表里的
// `client ?? http.Client()`（刮削 / 弹幕 / 字幕 / 封面 / 发音源……）。初始化列表里
// **不能 await**，而 [applyAppProxy] 是异步的（要跑 `reg query` / `scutil` /
// `gsettings`）。这正是「代理层存在、却有 40 条链路绕过它」的结构性成因——不是谁忘了，
// 是那个形状根本接不上。
//
// 解法是把「异步的那一半」搬到进程启动时做一次：`AppModel.initialise()` 调
// [primeAppProxy] 缓存平台 GUI 系统代理解析结果，此后 [applyAppProxySync] 纯同步装配。
// 系统代理是机器级设置、一次解析足够；用户在设置页改了手填代理不受影响，因为
// `findProxy` 是**请求时**才调的闭包，每次都重读 [appUserProxyReader]。

/// 平台 GUI 系统代理解析结果的进程级缓存。null = 还没 prime 过。
Map<String, String>? _cachedSystemProxyEnv;

/// 预解析并缓存平台 GUI 系统代理，供 [applyAppProxySync] 同步取用。
///
/// 在 `AppModel.initialise()` 里调一次即可；重复调用会按当前系统设置刷新缓存
/// （用户改了系统代理后可以再调一次让它生效）。解析失败按各 `resolve*` 的约定
/// 返回空 map（= 不补代理），绝不抛。
Future<void> primeAppProxy() async {
  _cachedSystemProxyEnv = await resolveSystemProxyEnvironment();
}

/// 重置 GUI 系统代理缓存（测试用；生产上重新 [primeAppProxy] 即可）。
@visibleForTesting
void resetAppProxyCacheForTest() {
  _cachedSystemProxyEnv = null;
}

/// 覆盖 GUI 系统代理缓存（测试用：本机跑不出目标平台的 GUI 代理，只能注入）。
@visibleForTesting
void debugSetCachedSystemProxyEnv(Map<String, String>? env) {
  _cachedSystemProxyEnv = env == null ? null : Map<String, String>.of(env);
}

/// **同步版** [applyAppProxy]：装一个请求时才求值的 `findProxy` 闭包。
///
/// 优先级与异步版逐字一致（本机/局域网直连 > 用户手填 > env > GUI 系统代理 > DIRECT），
/// 唯一差别是 GUI 系统代理那一格取自 [primeAppProxy] 缓存而不是现场 `Process.run`。
/// **没 prime 过时该格为空**，于是退化成 `env > DIRECT`——与本函数存在之前那些裸
/// `HttpClient()` 相比只多不少，绝不会更坏。
void applyAppProxySync(HttpClient client) {
  client.findProxy = resolveAppProxyDirective;
}

/// **纯查表**：一个 URI 该走什么出口。[applyAppProxySync] 装进 `findProxy` 的就是它。
///
/// 公开（非 `@visibleForTesting`）是因为它是这条纪律的可断言表面：守卫与单测要能直接
/// 问「AnkiConnect / 局域网 peer 会不会被代理」，而不是去 mock 一个 HttpClient。
String resolveAppProxyDirective(Uri uri) {
  if (isDirectProxyTarget(uri.host)) return 'DIRECT';
  final String? normalizedUserProxy =
      normalizeUserProxyHostPort(appUserProxyReader());
  if (normalizedUserProxy != null) return 'PROXY $normalizedUserProxy';
  final Map<String, String> environment = <String, String>{
    ...Platform.environment,
  };
  if (!_hasEnvProxy(environment)) {
    environment.addAll(_cachedSystemProxyEnv ?? const <String, String>{});
  }
  return HttpClient.findProxyFromEnvironment(uri, environment: environment);
}

/// **本机 / 局域网直连闸门**：这些目标经 HTTP 代理只会更坏，甚至直接把功能打断。
///
/// 这不是「优化」，是一条硬正确性约束。实测（`HttpClient.findProxyFromEnvironment`，
/// environment 里给了 `http_proxy`）：
/// ```text
/// http://127.0.0.1:8765/      -> PROXY 1.2.3.4:8080
/// http://localhost:8765/      -> PROXY 1.2.3.4:8080
/// http://192.168.1.34:5000/   -> PROXY 1.2.3.4:8080
/// http://hibiki-pc.local:8080 -> PROXY 1.2.3.4:8080
/// ```
/// Dart **不做任何隐式 loopback bypass**（浏览器和 Windows 的 `ProxyOverride`
/// 默认值 `<local>` 都做），`no_proxy` 也只在用户自己设了才有；而 Windows 系统代理是从
/// 注册表 `ProxyServer` 读的，`ProxyOverride` 压根没被读进来。用户手填代理那条分支更极端
/// ——它无条件返回 `PROXY host:port`，连 `no_proxy` 都不过。
///
/// 于是「把某条链路接进代理层」在本仓一直是个危险动作：AnkiConnect（`127.0.0.1:8765`）、
/// Yomitan 本地端口、Mihon sidecar、桌面 OAuth 回环回调（BUG-1348 的原始症状之一）、
/// 互联局域网 peer、qBittorrent WebUI、自建 WebDAV，任何一条被卷进去都是功能当场坏掉。
/// 把闸门放在**解析层**而不是每个调用点，这个风险就一次性消失了：接不接代理不再需要
/// 逐点判断「它会不会打到本机」。
///
/// 覆盖（与 Windows `<local>` / 常见 `no_proxy` 默认值对齐）：
/// * `localhost` / `*.localhost`（RFC 6761）、`*.local`（mDNS——互联 peer 发现用 Bonsoir
///   广播的正是这种名字）；
/// * IPv4：`127.0.0.0/8`、`0.0.0.0`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、
///   `169.254.0.0/16`（link-local）；
/// * IPv6：`::1`、`::`、`fc00::/7`（ULA）、`fe80::/10`（link-local）。
///
/// **不覆盖**用户自填的公网自建服务（自建 dandanplay 镜像、公网 WebDAV）：那些确实该跟着
/// 全局代理走，与浏览器行为一致。
bool isDirectProxyTarget(String host) {
  String h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  // `Uri.host` 对 IPv6 字面量已剥方括号，但调用方也可能直接喂原始 authority。
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  // IPv6 的 zone id（`fe80::1%eth0`）不参与判定。
  final int zone = h.indexOf('%');
  if (zone >= 0) h = h.substring(0, zone);
  if (h.isEmpty) return false;

  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  if (h == 'local' || h.endsWith('.local')) return true;

  final List<int>? v4 = _parseIpv4(h);
  if (v4 != null) {
    if (v4[0] == 127 || v4[0] == 0) return true; // loopback / 未指定
    if (v4[0] == 10) return true; // 10.0.0.0/8
    if (v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31) return true; // 172.16/12
    if (v4[0] == 192 && v4[1] == 168) return true; // 192.168/16
    if (v4[0] == 169 && v4[1] == 254) return true; // link-local
    return false;
  }

  if (!h.contains(':')) return false; // 普通主机名 → 公网，走代理
  // 到这里当 IPv6 字面量处理。`::ffff:127.0.0.1` 这类映射地址交给尾部的 IPv4 段判定。
  final int lastColon = h.lastIndexOf(':');
  final String tail = h.substring(lastColon + 1);
  final List<int>? mapped = _parseIpv4(tail);
  if (mapped != null) return isDirectProxyTarget(tail);
  if (h == '::1' || h == '::') return true;
  // fc00::/7（ULA：fc / fd 开头）与 fe80::/10（link-local：fe8 / fe9 / fea / feb）。
  if (h.startsWith('fc') || h.startsWith('fd')) return true;
  if (RegExp(r'^fe[89ab]').hasMatch(h)) return true;
  return false;
}

/// 把点分四段解析成 0-255 的四元组；非 IPv4 字面量返回 null。
List<int>? _parseIpv4(String host) {
  final List<String> parts = host.split('.');
  if (parts.length != 4) return null;
  final List<int> out = <int>[];
  for (final String part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    if (!RegExp(r'^\d+$').hasMatch(part)) return null;
    final int value = int.parse(part);
    if (value > 255) return null;
    out.add(value);
  }
  return out;
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
    debugPrint('[AppProxy] read windows system proxy failed: $e');
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
        '[AppProxy] 检测到 macOS PAC 自动代理，降级直连（不解析 PAC）',
      );
    }
    return proxy;
  } catch (e) {
    // 读不到系统代理（权限/环境异常）就当没有，回退 env / 直连——best-effort。
    debugPrint('[AppProxy] read macOS system proxy failed: $e');
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
        '[AppProxy] 检测到 Linux PAC 自动代理，降级直连（不解析 PAC）',
      );
    }
    return proxy;
  } catch (e) {
    // gsettings 不存在（非 GNOME / 无 glib）或读取异常 → 当没有系统代理，回退 env / 直连。
    debugPrint('[AppProxy] read Linux system proxy failed: $e');
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
