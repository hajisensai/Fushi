/// Application identity only; this never supplies the user's AniDB login.
class AniDbAppClientIdentity {
  const AniDbAppClientIdentity({required this.name, required this.version});
  const AniDbAppClientIdentity.unregistered()
      : name = '',
        version = null;

  final String name;
  final int? version;

  /// 名 + 正版本号齐全才是一对能发请求的身份。
  bool get isComplete => name.trim().isNotEmpty && (version ?? 0) > 0;

  /// 本仓可以拿它请求 AniDB：齐全，且不是 Shoko 的登记名（不得冒用）。provider
  /// 发请求前的闸与设置页的状态行都问这一处，两边不会各说各话。
  bool get isUsable =>
      isComplete &&
      !kReservedShokoAniDbClientNames.contains(name.trim().toLowerCase());
}

/// Shoko 在 AniDB 登记的客户端名，Fushi 不得冒用。
const Set<String> kReservedShokoAniDbClientNames = <String>{
  'animeplugin',
  'ommserver',
};

/// Registered 2026-09-07: https://anidb.net/software/20715
/// UDP client 29913, active official version 1 (version record 27688).
/// `fushi` was already occupied; this is Fushi's separately registered identity.
///
/// **只是 UDP 登记**：AniDB 的 HTTP API 客户端是另一条登记，`fushiplayer` 从没
/// 登记过 HTTP，拿它请求 httpapi 恒回 `<error code="302">client version missing
/// or invalid</error>`（BUG-2623）。HTTP 身份见 [kBundledAniDbHttpClient]。
const AniDbAppClientIdentity kBundledAniDbClient =
    AniDbAppClientIdentity(name: 'fushiplayer', version: 1);

/// 随包的 AniDB **HTTP API** 客户端身份：尚未登记，所以不存在（BUG-2623）。
///
/// 用随包配置时 anime XML 资料链在发请求前就判不可用（零请求），只剩 UDP 哈希
/// 识别与离线标题目录。所有者在 AniDB 项目 20715 下登记 HTTP 客户端后，把这里
/// 改成登记到的名字 / 版本即可，其它代码不用动。
const AniDbAppClientIdentity kBundledAniDbHttpClient =
    AniDbAppClientIdentity.unregistered();

/// 一次解析得到的两条 AniDB 应用身份：UDP（哈希识别 / 登录）与 HTTP（anime XML）。
///
/// 两者是 AniDB 上两条独立登记，随包时各取各的常量；用户填了自定义客户端时
/// 同一对身份同时用于两条协议（用户自己负责它在两边的登记状态，被 HTTP 拒绝时
/// 走 provider 既有的 302 闩）。
class AniDbAppClients {
  const AniDbAppClients({required this.udp, required this.http});

  final AniDbAppClientIdentity udp;
  final AniDbAppClientIdentity http;
}

/// An explicit custom client replaces the whole application identity pair.
/// Clearing the custom name selects the bundled client, never a mixed pair.
AniDbAppClientIdentity resolveAniDbAppClient({
  required String customName,
  required int? customVersion,
  AniDbAppClientIdentity bundled = kBundledAniDbClient,
}) =>
    customName.trim().isEmpty
        ? bundled
        : AniDbAppClientIdentity(
            name: customName.trim(), version: customVersion);

/// [resolveAniDbAppClient] 的两协议版本：自定义客户端整对替换两条身份，留空时
/// UDP 取 [bundledUdp]、HTTP 取 [bundledHttp]——绝不把 UDP 登记拿去冒充 HTTP。
AniDbAppClients resolveAniDbAppClients({
  required String customName,
  required int? customVersion,
  AniDbAppClientIdentity bundledUdp = kBundledAniDbClient,
  AniDbAppClientIdentity bundledHttp = kBundledAniDbHttpClient,
}) =>
    AniDbAppClients(
      udp: resolveAniDbAppClient(
          customName: customName,
          customVersion: customVersion,
          bundled: bundledUdp),
      http: resolveAniDbAppClient(
          customName: customName,
          customVersion: customVersion,
          bundled: bundledHttp),
    );
