/// 无头服务端当「跟随已配对设备自动登录 Fushi 账户」的 host（协议与安全门见引擎
/// `fushi_engine/sync/interconnect_leaderboard_link.dart` 文件头）。
///
/// 与 app 的 `AppLeaderboardLinkHost` 对偶，区别只在三处装配：
/// - 账户 = DB 当前激活 Profile 的本机排行榜账户（[ServerLeaderboardStore]，与
///   `leaderboard` 命令同口径；每次请求现读，`leaderboard login / logout` 不必重启）；
/// - 总闸 = 配置 `leaderboard_link`（app 的「允许已配对设备自动登录我的账户」，同样默认开），
///   运行期现读，WebUI 改完即生效；
/// - 「我的设备」：无头配对没有「允许 · 这是我的设备」按钮，配对一律只落「仅互联」，由管理员
///   之后在 WebUI / `ctl pairing owner` 里手动标记（与 app 在已配对设备列表里手动标记同一条路）。
///   标记与指纹落 `preferences` 表，实现与 app 共用（[InterconnectOwnerDeviceStore]）。
///
/// 对端只交来它自己的公钥 + 持有证明；本机私钥 / 恢复码从不外传。
library;

import 'dart:io' show Directory;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_device_link.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/sync/interconnect_leaderboard_link.dart';
import 'package:fushi_engine/sync/interconnect_owner_devices.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/commands/leaderboard_commands.dart'
    show kLeaderboardDefaultBaseUrl;
import 'package:fushi_server/src/leaderboard_store.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_server/src/server_language.dart';

class ServerLeaderboardLinkHost implements InterconnectLeaderboardLinkHost {
  ServerLeaderboardLinkHost({
    required FushiDatabase db,
    required Directory supportRoot,
    required bool Function() enabled,
    Future<http.Client> Function()? httpClientFactory,
  }) : _db = db,
       _supportRoot = supportRoot,
       _enabled = enabled,
       _httpClientFactory =
           httpClientFactory ?? (() async => createAppHttpIoClient());

  final FushiDatabase _db;
  final Directory _supportRoot;
  final bool Function() _enabled;

  /// 出站一律经全应用代理装配（与 `leaderboard` 命令同一个工厂）。
  final Future<http.Client> Function() _httpClientFactory;

  @override
  Future<bool> isInterconnectLeaderboardLinkEnabled() async => _enabled();

  @override
  Future<bool> isOwnerDevicePeer(String peerToken) =>
      InterconnectOwnerDeviceStore(_db).isOwnerDevicePeerToken(peerToken);

  @override
  Future<InterconnectLeaderboardLinkResult> linkLeaderboardDevice(
    LeaderboardDeviceLinkRequest request,
  ) => runInterconnectLeaderboardLink(() async {
    final ServerLeaderboardAccount? account = await _activeAccount();
    if (account == null) return null;
    final Uri? base = _baseUrl(account.serverUrl);
    if (base == null) {
      engineLog.logDiagnostic(
        'ServerLeaderboardLinkHost',
        tr(
          '账户文件里的服务地址不是 http(s) 绝对地址，按无账户处理',
          'The server address in the account file is not an absolute http(s) URL; treating as no account',
        ),
      );
      return null;
    }
    final LeaderboardIdentity identity;
    try {
      identity = LeaderboardIdentity.fromRecoveryCode(account.recoveryCode);
    } on FormatException {
      // 只报类型：恢复码就是私钥，绝不回显。
      engineLog.logDiagnostic(
        'ServerLeaderboardLinkHost',
        tr(
          '账户文件里的恢复码解析失败，按无账户处理',
          'Failed to parse the recovery code in the account file; treating as no account',
        ),
      );
      return null;
    }
    final LeaderboardSelf self = await LeaderboardClient(
      baseUrl: base,
      httpClientFactory: _httpClientFactory,
      identity: identity,
    ).linkDevice(request);
    return (self: self, serverUrl: account.serverUrl);
  });

  /// 当前激活 Profile 的本机账户；没有 / 文件坏了返回 null（坏文件只留痕，不覆盖——
  /// 修复走 `leaderboard` 命令）。
  Future<ServerLeaderboardAccount?> _activeAccount() async {
    final int profileId = await _db.resolveActiveProfileId();
    try {
      return await ServerLeaderboardStore(
        supportRoot: _supportRoot,
        profileId: profileId,
      ).read();
    } on ServerLeaderboardStoreException catch (e) {
      engineLog.logDiagnostic(
        'ServerLeaderboardLinkHost',
        tr(
          '${e.message}；已配对设备的自动登录按无账户处理',
          '${e.message}; auto sign-in for paired devices treats this as no account',
        ),
      );
      return null;
    }
  }

  static Uri? _baseUrl(String? stored) {
    final Uri? u = Uri.tryParse((stored ?? kLeaderboardDefaultBaseUrl).trim());
    if (u == null ||
        !(u.scheme == 'http' || u.scheme == 'https') ||
        u.host.isEmpty) {
      return null;
    }
    return u;
  }
}
