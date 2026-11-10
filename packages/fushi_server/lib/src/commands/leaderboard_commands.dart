/// `fushi_server leaderboard …`：排行榜账户与书架同步（引擎 `fushi_engine/leaderboard/`）。
///
/// ```
/// leaderboard status       [--offline]           本机账户 + 服务端资料 + 本机书架概况
/// leaderboard sync         [--claim] [--consent] 书架增量上报（引擎 syncShelf）
/// leaderboard rank         [--metric … --window … --scope … --limit N]  只读看榜
/// leaderboard request-code --email E [--login]   请求邮箱验证码
/// leaderboard register     --email E --nickname N [--consent]   验证码走环境变量 / stdin
/// leaderboard login        --email E [--consent]                验证码走环境变量 / stdin
/// leaderboard import       [--consent]                          恢复码走环境变量 / stdin
/// leaderboard logout                                            删除本机账户文件
/// ```
///
/// 装配与 app 的 `LeaderboardService` 对偶（那个类在 `fushi/` 里，服务端 import 不到）：
/// - 身份 = ECDSA 设备钥匙，持久化为恢复码，落 `<support>/leaderboard/profile_<id>.json`
///   （[ServerLeaderboardStore]，与 app 同格式同落点，0600，不进偏好表）；
/// - Profile 默认取 DB 的当前激活 Profile（`resolveActiveProfileId`，与 app 同口径），
///   `--profile` 可指定；
/// - 服务地址：账户文件里的 `serverUrl` > 默认 [kLeaderboardDefaultBaseUrl]；建账户时
///   `--server` 写进账户文件；
/// - 出站一律 `createAppHttpIoClient()`（全应用代理装配）；
/// - 公开上传需要显式同意：建账户时不带 `--consent` 则上传关闭，`sync --consent` 补同意。
///
/// 凭据纪律：恢复码（= 私钥）与邮箱验证码只从环境变量（[kLeaderboardRecoveryCodeEnv] /
/// [kLeaderboardEmailCodeEnv]）或 stdin 读，绝不收 argv（会进 shell 历史 / `ps`）。
///
/// 退出码：0 成功；1 业务失败；64 用法；65 账户文件损坏；69 缺账户 / 未同意上传 /
/// 网络不通 / 服务端 5xx；75 暂时失败（409 上传设备是另一台、409 并发冲突、429 限流）；
/// 77 鉴权失败（401 / 403：签名被拒、设备钥匙已被解绑、验证码不对）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_isbn_backfill.dart';
import 'package:fushi_engine/leaderboard/cover_hash.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/video_cli_support.dart';
import 'package:fushi_server/src/leaderboard_store.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// 排行榜服务默认地址（与 app `kLeaderboardDefaultBaseUrl` 同值）。
const String kLeaderboardDefaultBaseUrl = 'https://rank.fushi.moe';

/// 恢复码（`FUSHI1-…`，含私钥）的环境变量。
const String kLeaderboardRecoveryCodeEnv = 'FUSHI_LEADERBOARD_RECOVERY_CODE';

/// 邮箱验证码的环境变量。
const String kLeaderboardEmailCodeEnv = 'FUSHI_LEADERBOARD_EMAIL_CODE';

/// 账户文件损坏（EX_DATAERR）。
const int kExitDataError = 65;

/// 暂时失败，稍后重试（EX_TEMPFAIL）。
const int kExitTempFail = 75;

/// 鉴权失败（EX_NOPERM）。
const int kExitNoPerm = 77;

/// ISBN 回填重跑间隔（与 app `kLeaderboardIsbnBackfillInterval` 同值）。
const Duration kServerLeaderboardIsbnBackfillInterval = Duration(days: 7);

/// 一次排行榜调用失败 → 退出码 + 给人看的原因。
({int code, String message}) describeLeaderboardError(Object e) {
  if (e is LeaderboardUploadOwnedElsewhere) {
    return (
      code: kExitTempFail,
      message: tr(
        '本账户的上传设备是另一台设备；要改由这台服务端上传，跑 leaderboard sync --claim（会全量重传）',
        'This account uploads from another device; to upload from this server instead, run leaderboard sync --claim (full re-upload)',
      ),
    );
  }
  if (e is LeaderboardApiException) {
    if (e.status == 401 && e.code == kLeaderboardAccountGoneCode) {
      return (
        code: kExitNoPerm,
        message: tr(
          '服务端已不认识这把设备钥匙（账户已在别处删除，或本设备已被解绑）；leaderboard logout 后重新 login / import',
          'The server no longer recognizes this device key (the account was deleted elsewhere, or this device was unlinked); run leaderboard logout, then login / import again',
        ),
      );
    }
    if (e.status == 401 || e.status == 403) {
      return (
        code: kExitNoPerm,
        message: tr(
          '鉴权失败（${e.status} ${e.code}）：签名 / 验证码 / 恢复码被服务端拒绝；签名被拒时先检查本机时钟',
          'Authentication failed (${e.status} ${e.code}): the signature / email code / recovery code was rejected by the server; if the signature was rejected, check the local clock first',
        ),
      );
    }
    if (e.status == 409 && e.code == 'upload_owned_by_other_device') {
      return describeLeaderboardError(const LeaderboardUploadOwnedElsewhere());
    }
    if (e.status == 409 || e.status == 429) {
      return (
        code: kExitTempFail,
        message: tr(
          '服务端暂时拒绝（${e.status} ${e.code}），稍后重试',
          'The server temporarily refused the request (${e.status} ${e.code}); try again later',
        ),
      );
    }
    if (e.status >= 500) {
      return (
        code: kExitUnavailable,
        message: tr(
          '排行榜服务不可用（${e.status} ${e.code}）',
          'Leaderboard service unavailable (${e.status} ${e.code})',
        ),
      );
    }
    return (
      code: kExitFailure,
      message: tr(
        '排行榜服务拒绝了请求（${e.status} ${e.code}${e.detail == null ? '' : ': ${e.detail}'}）',
        'The leaderboard service rejected the request (${e.status} ${e.code}${e.detail == null ? '' : ': ${e.detail}'})',
      ),
    );
  }
  if (e is TimeoutException) {
    return (
      code: kExitUnavailable,
      message: tr('请求排行榜服务超时', 'Leaderboard service request timed out'),
    );
  }
  if (e is SocketException ||
      e is http.ClientException ||
      e is TlsException ||
      e is HttpException) {
    return (
      code: kExitUnavailable,
      message: tr('连不上排行榜服务: $e', 'Cannot reach the leaderboard service: $e'),
    );
  }
  return (
    code: kExitFailure,
    message: tr('排行榜操作失败: $e', 'Leaderboard operation failed: $e'),
  );
}

/// 读一个秘密值：环境变量优先，其次 stdin 一行（终端上关回显并提示）。
typedef LeaderboardSecretReader = Future<String?> Function(String prompt);

Future<String?> _readSecretFromStdin(String prompt) async {
  final bool tty = stdin.hasTerminal;
  if (tty) {
    stderr.write(prompt);
    try {
      stdin.echoMode = false;
    } on StdinException {
      // 关不掉回显（非真终端）就照常读。
    }
  }
  try {
    return stdin.readLineSync()?.trim();
  } finally {
    if (tty) {
      try {
        stdin.echoMode = true;
      } on StdinException {
        // 同上。
      }
      stderr.writeln();
    }
  }
}

/// 本地封面 → ≤300px JPEG 缩略图（后台 isolate；与 app `leaderboardCoverThumb` 同尺寸同质量）。
/// 没有本地封面 / 文件不在 / 解不开返回 null（跳过该作品的补传）。
Future<Uint8List?> serverLeaderboardCoverThumb(LocalShelfEntry entry) async {
  final String? path = entry.localCoverPath;
  if (path == null) return null;
  final File file = File(path);
  if (!await file.exists()) return null;
  final Uint8List bytes = await file.readAsBytes();
  return Isolate.run<Uint8List?>(() => encodeLeaderboardCoverThumb(bytes));
}

/// 缩略图的 dHash（封面投票按它归并相近的图），解码在后台 isolate。
Future<String?> serverLeaderboardCoverHash(Uint8List thumb) =>
    Isolate.run<String?>(() => coverDHash(thumb));

/// 纯函数：任意图片字节 → 长边 ≤300 的 JPEG（quality 80）；解不开返回 null。
Uint8List? encodeLeaderboardCoverThumb(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    decoded = null;
  }
  if (decoded == null) return null;
  const int maxEdge = 300;
  final img.Image scaled = decoded.width >= decoded.height
      ? (decoded.width > maxEdge
            ? img.copyResize(decoded, width: maxEdge)
            : decoded)
      : (decoded.height > maxEdge
            ? img.copyResize(decoded, height: maxEdge)
            : decoded);
  return img.encodeJpg(scaled, quality: 80);
}

String get _usage => tr(
  '''
leaderboard（排行榜账户与书架同步）:
  leaderboard status       [--offline] [--profile N]
  leaderboard sync         [--claim] [--consent] [--profile N]
  leaderboard rank         [--metric book|manga|video|game|chars] [--window week|month|all] [--scope global|friends] [--limit N] [--server URL]
  leaderboard request-code --email E [--login] [--lang zh|en|ja] [--server URL]
  leaderboard register     --email E --nickname N [--consent] [--server URL] [--force] [--profile N]
  leaderboard login        --email E [--consent] [--server URL] [--force] [--profile N]
  leaderboard import       [--consent] [--server URL] [--force] [--profile N]
  leaderboard logout       [--profile N]
  验证码取环境变量 $kLeaderboardEmailCodeEnv、恢复码取 $kLeaderboardRecoveryCodeEnv，没设就从 stdin 读一行
  （绝不收 argv）。--consent = 同意把本机书架公开上传到排行榜。每个子命令都支持 --json。''',
  '''
leaderboard (leaderboard account and shelf sync):
  leaderboard status       [--offline] [--profile N]
  leaderboard sync         [--claim] [--consent] [--profile N]
  leaderboard rank         [--metric book|manga|video|game|chars] [--window week|month|all] [--scope global|friends] [--limit N] [--server URL]
  leaderboard request-code --email E [--login] [--lang zh|en|ja] [--server URL]
  leaderboard register     --email E --nickname N [--consent] [--server URL] [--force] [--profile N]
  leaderboard login        --email E [--consent] [--server URL] [--force] [--profile N]
  leaderboard import       [--consent] [--server URL] [--force] [--profile N]
  leaderboard logout       [--profile N]
  The email code is read from the environment variable $kLeaderboardEmailCodeEnv and the recovery code from $kLeaderboardRecoveryCodeEnv; if unset, one line is read from stdin
  (never accepted via argv). --consent = agree to publicly upload this machine's shelf to the leaderboard. Every subcommand supports --json.''',
);

class LeaderboardModule extends CliModule {
  const LeaderboardModule({
    this.out,
    this.err,
    this.env,
    this.readSecret,
    this.httpClientFactory,
    this.clockMs,
    this.coverThumb = serverLeaderboardCoverThumb,
  });

  final StringSink? out;
  final StringSink? err;

  /// 测试注入点：环境变量 / stdin / 出站 client / 时钟 / 封面缩略图。
  final Map<String, String>? env;
  final LeaderboardSecretReader? readSecret;
  final Future<http.Client> Function()? httpClientFactory;
  final int Function()? clockMs;
  final Future<Uint8List?> Function(LocalShelfEntry entry)? coverThumb;

  @override
  List<String> get commands => const <String>['leaderboard'];

  @override
  String get usage => _usage;

  @override
  void register(ArgParser parser) {
    final ArgParser lb = parser.addCommand('leaderboard');
    void profile(ArgParser a) => a.addOption(
      'profile',
      help: tr(
        'Profile id（缺省 = 当前激活 Profile）',
        'Profile id (default: the active profile)',
      ),
    );
    void server(ArgParser a) => a.addOption(
      'server',
      help: tr(
        '排行榜服务地址（缺省 $kLeaderboardDefaultBaseUrl）',
        'Leaderboard service URL (default $kLeaderboardDefaultBaseUrl)',
      ),
    );
    void account(ArgParser a) {
      profile(a);
      server(a);
      a
        ..addFlag(
          'consent',
          negatable: false,
          help: tr(
            '同意把本机书架公开上传到排行榜',
            'Agree to publicly upload the local shelf to the leaderboard',
          ),
        )
        ..addFlag(
          'force',
          negatable: false,
          help: tr(
            '本 Profile 已有账户时覆盖（旧恢复码没备份就永远丢了）',
            'Overwrite when this profile already has an account (the old recovery code is lost for good if not backed up)',
          ),
        );
    }

    addJsonFlag(lb.addCommand('status'))
      ..addFlag(
        'offline',
        negatable: false,
        help: tr('只看本机，不连服务端', 'Local only, do not contact the server'),
      )
      ..addOption(
        'profile',
        help: tr(
          'Profile id（缺省 = 当前激活 Profile）',
          'Profile id (default: the active profile)',
        ),
      );
    addJsonFlag(lb.addCommand('sync'))
      ..addFlag(
        'claim',
        negatable: false,
        help: tr(
          '由这台服务端接管上传（强制全量重传）',
          'Take over uploading from this server (forces a full re-upload)',
        ),
      )
      ..addFlag(
        'consent',
        negatable: false,
        help: tr(
          '同意公开上传（账户建立时没同意过才需要）',
          'Agree to public upload (only needed if not agreed when the account was created)',
        ),
      )
      ..addOption(
        'profile',
        help: tr(
          'Profile id（缺省 = 当前激活 Profile）',
          'Profile id (default: the active profile)',
        ),
      );
    final ArgParser rank = addJsonFlag(lb.addCommand('rank'))
      ..addOption(
        'metric',
        allowed: <String>[
          for (final LeaderboardMetric m in LeaderboardMetric.values) m.wire,
        ],
        defaultsTo: 'book',
      )
      ..addOption(
        'window',
        allowed: <String>[
          for (final LeaderboardWindow w in LeaderboardWindow.values) w.wire,
        ],
        defaultsTo: 'week',
      )
      ..addOption(
        'scope',
        allowed: <String>[
          for (final LeaderboardScope s in LeaderboardScope.values) s.wire,
        ],
        defaultsTo: 'global',
      )
      ..addOption('limit', defaultsTo: '20', help: '1..100');
    profile(rank);
    server(rank);
    final ArgParser code = addJsonFlag(lb.addCommand('request-code'))
      ..addOption('email', help: tr('邮箱', 'Email'))
      ..addFlag(
        'login',
        negatable: false,
        help: tr(
          '登录用验证码（缺省是注册用）',
          'Email code for login (default is for registration)',
        ),
      )
      ..addOption(
        'lang',
        allowed: <String>['zh', 'en', 'ja'],
        help: tr('邮件语言', 'Email language'),
      );
    server(code);
    account(
      addJsonFlag(lb.addCommand('register'))
        ..addOption('email', help: tr('邮箱', 'Email'))
        ..addOption('nickname', help: tr('昵称', 'Nickname')),
    );
    account(
      addJsonFlag(lb.addCommand('login'))
        ..addOption('email', help: tr('邮箱', 'Email')),
    );
    account(addJsonFlag(lb.addCommand('import')));
    profile(addJsonFlag(lb.addCommand('logout')));
  }

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final ArgResults? sub = command.command;
    final CliIo io = CliIo(
      out: out ?? stdout,
      err: err ?? stderr,
      json: sub != null && jsonFlag(sub),
    );
    if (sub == null) {
      io.err.writeln(_usage);
      return kExitUsage;
    }
    final int? profileArg = _intOption(sub, 'profile');
    if (sub.options.contains('profile') &&
        sub['profile'] != null &&
        (profileArg == null || profileArg < 0)) {
      return io.fail(
        kExitUsage,
        tr('--profile 需要非负整数', '--profile needs a non-negative integer'),
      );
    }
    // 不需要数据库的两条：只读看榜（无账户时匿名）在下面单独处理；请求验证码完全不碰本机。
    if (sub.name == 'request-code') return _requestCode(sub, io);
    return ctx.withRuntime((ServerRuntime rt) async {
      final _Session s = _Session(
        module: this,
        rt: rt,
        io: io,
        profileId: profileArg ?? await rt.db.resolveActiveProfileId(),
      );
      try {
        switch (sub.name) {
          case 'status':
            return await s.status(offline: sub['offline'] as bool);
          case 'sync':
            return await s.sync(
              claim: sub['claim'] as bool,
              consent: sub['consent'] as bool,
            );
          case 'rank':
            return await s.rank(sub);
          case 'register':
          case 'login':
          case 'import':
            return await s.adopt(sub);
          case 'logout':
            return await s.logout();
        }
        return io.fail(kExitUsage, _usage);
      } on ServerLeaderboardStoreException catch (e) {
        return io.fail(
          kExitDataError,
          tr(
            '${e.message}；修不好就 leaderboard logout 后重新 import 恢复码',
            '${e.message}; if it cannot be repaired, run leaderboard logout and import the recovery code again',
          ),
        );
      }
    });
  }

  Future<int> _requestCode(ArgResults sub, CliIo io) async {
    final String email = ((sub['email'] as String?) ?? '').trim();
    if (!isPlausibleLeaderboardEmail(email)) {
      return io.fail(
        kExitUsage,
        tr(
          '用法: leaderboard request-code --email <邮箱> [--login]',
          'Usage: leaderboard request-code --email <email> [--login]',
        ),
      );
    }
    final Uri? base = _baseUrl(sub['server'] as String?, null);
    if (base == null) {
      return io.fail(
        kExitUsage,
        tr(
          '--server 不是 http(s) 地址: ${sub['server']}',
          '--server is not an http(s) address: ${sub['server']}',
        ),
      );
    }
    final bool forLogin = sub['login'] as bool;
    try {
      await _client(base, null).requestEmailCode(
        email: email,
        purpose: forLogin ? 'login' : 'register',
        lang: sub['lang'] as String?,
      );
    } on Object catch (e) {
      final ({int code, String message}) d = describeLeaderboardError(e);
      return io.fail(d.code, d.message);
    }
    if (io.json) {
      io.writeJson(<String, Object?>{
        'ok': true,
        'exitCode': kExitOk,
        'email': email,
        'purpose': forLogin ? 'login' : 'register',
      });
    } else {
      io.out.writeln(
        tr(
          '已请求验证码（若该邮箱可用，几分钟内会收到）；收到后用 $kLeaderboardEmailCodeEnv 或 stdin 交给 leaderboard ${forLogin ? 'login' : 'register'}',
          'Email code requested (if the address is valid, it arrives within a few minutes); then pass it to leaderboard ${forLogin ? 'login' : 'register'} via $kLeaderboardEmailCodeEnv or stdin',
        ),
      );
    }
    return kExitOk;
  }

  Map<String, String> get _env => env ?? Platform.environment;

  int _now() => (clockMs ?? () => DateTime.now().millisecondsSinceEpoch)();

  /// 共用同一个服务器时钟偏移（一次命令里多次建客户端时不丢校准）。
  static final LeaderboardServerClock _serverClock = LeaderboardServerClock();

  LeaderboardClient _client(Uri base, LeaderboardIdentity? identity) =>
      LeaderboardClient(
        baseUrl: base,
        // 出站必须经全应用代理装配。
        httpClientFactory:
            httpClientFactory ?? () async => createAppHttpIoClient(),
        identity: identity,
        clockMs: clockMs,
        serverClock: _serverClock,
      );

  /// `--server` > 账户文件里的地址 > 默认。不是 http(s) 绝对地址返回 null。
  static Uri? _baseUrl(String? flag, String? stored) {
    final String raw = (flag ?? stored ?? kLeaderboardDefaultBaseUrl).trim();
    final Uri? u = Uri.tryParse(raw);
    if (u == null ||
        !(u.scheme == 'http' || u.scheme == 'https') ||
        u.host.isEmpty) {
      return null;
    }
    return u;
  }

  static int? _intOption(ArgResults r, String name) {
    if (!r.options.contains(name) || r[name] == null) return null;
    return int.tryParse(r[name] as String);
  }
}

/// 一次命令的上下文（运行时 + Profile + 账户文件）。
class _Session {
  _Session({
    required this.module,
    required this.rt,
    required this.io,
    required this.profileId,
  }) : store = ServerLeaderboardStore(
         supportRoot: rt.paths.support,
         profileId: profileId,
       );

  final LeaderboardModule module;
  final ServerRuntime rt;
  final CliIo io;
  final int profileId;
  final ServerLeaderboardStore store;

  int fail(Object e) {
    final ({int code, String message}) d = describeLeaderboardError(e);
    return io.fail(d.code, d.message);
  }

  int noAccount() => io.fail(
    kExitUnavailable,
    tr(
      'Profile $profileId 没有排行榜账户：先 leaderboard import（恢复码经 $kLeaderboardRecoveryCodeEnv / stdin），'
          '或 leaderboard request-code + login / register（验证码经 $kLeaderboardEmailCodeEnv / stdin）；'
          '也可以把 app 的 <数据目录>/leaderboard/profile_<id>.json 拷到 ${store.file.path}',
      'Profile $profileId has no leaderboard account: first run leaderboard import (recovery code via $kLeaderboardRecoveryCodeEnv / stdin), '
          'or leaderboard request-code + login / register (email code via $kLeaderboardEmailCodeEnv / stdin); '
          'or copy the app\'s <data dir>/leaderboard/profile_<id>.json to ${store.file.path}',
    ),
  );

  /// 账户文件里的恢复码 → 签名身份；恢复码坏了按文件损坏处理。
  LeaderboardIdentity identityOf(ServerLeaderboardAccount account) {
    try {
      return LeaderboardIdentity.fromRecoveryCode(account.recoveryCode);
    } on FormatException {
      throw ServerLeaderboardStoreException(
        tr(
          '排行榜账户文件里的恢复码无效: ${store.file.path}',
          'The recovery code in the leaderboard account file is invalid: ${store.file.path}',
        ),
      );
    }
  }

  /// 本机书架（同机多 Profile 时只有代表 Profile 计入「谁都没记录」的作品，BUG-2870）。
  Future<LocalShelf> buildShelf(DateTime now) async {
    final int? owner = leaderboardUnattributedOwner(
      uploading: await ServerLeaderboardStore.uploadingProfileIds(
        rt.paths.support,
      ),
      existing: <int>[
        for (final ProfileRow p in await rt.db.select(rt.db.profiles).get())
          p.id,
      ],
    );
    return buildLocalShelf(
      rt.db,
      profileId: profileId,
      now: now,
      countsUnattributed: owner == null || owner == profileId,
    );
  }

  Future<int> status({required bool offline}) async {
    final ServerLeaderboardAccount? account = await store.read();
    if (account == null) {
      if (io.json) {
        io.writeJson(<String, Object?>{
          'ok': true,
          'profileId': profileId,
          'configured': false,
        });
      } else {
        io.out.writeln(
          tr(
            'Profile $profileId 没有排行榜账户（leaderboard import / login / register 建立）',
            'Profile $profileId has no leaderboard account (create one with leaderboard import / login / register)',
          ),
        );
      }
      return kExitOk;
    }
    final LeaderboardIdentity identity = identityOf(account);
    final Uri base =
        LeaderboardModule._baseUrl(null, account.serverUrl) ??
        Uri.parse(kLeaderboardDefaultBaseUrl);
    final LocalShelf shelf = await buildShelf(DateTime.now());
    final Map<String, Object?> local = <String, Object?>{
      'profileId': profileId,
      'configured': true,
      'accountId': account.accountId,
      'deviceKeyId': identity.accountId,
      'server': base.toString(),
      'uploadEnabled': account.uploadEnabled,
      'consentAt': account.consentAt,
      'lastSyncAt': account.lastSyncAt,
      'uploadBlockedByOtherDevice': account.uploadBlockedByOtherDevice,
      'syncedEntries': account.syncState.entries.length,
      'syncedWorks': account.syncState.workIds.length,
      'coverVotes': account.syncState.coverVotes.length,
      'localShelf': <String, Object?>{
        'entries': shelf.entries.length,
        'finished': shelf.entries
            .where((LocalShelfEntry e) => e.upload.finished)
            .length,
        'dailyDays': shelf.daily.length,
      },
    };
    LeaderboardSelf? self;
    Object? remoteError;
    if (!offline) {
      try {
        self = await module._client(base, identity).me();
      } on Object catch (e) {
        remoteError = e;
      }
    }
    final ({int code, String message})? failure = remoteError == null
        ? null
        : describeLeaderboardError(remoteError);
    if (io.json) {
      io.writeJson(<String, Object?>{
        'ok': failure == null,
        if (failure != null) ...<String, Object?>{
          'exitCode': failure.code,
          'error': failure.message,
        },
        ...local,
        if (self != null) 'remote': self.toJson(),
      });
    } else {
      io.out.writeln(
        tr(
          '账户 ${self?.account.tag ?? account.accountId}  （设备钥匙 ${identity.accountId}）  服务 $base',
          'Account ${self?.account.tag ?? account.accountId}  (device key ${identity.accountId})  service $base',
        ),
      );
      io.out.writeln(
        tr(
          '上传 ${account.uploadEnabled ? '开' : '关（未同意公开，sync --consent 打开）'}'
              '${account.uploadBlockedByOtherDevice ? '  被另一台上传设备挡住（sync --claim 接管）' : ''}'
              '  上次同步 ${account.lastSyncAt == null ? '从未' : DateTime.fromMillisecondsSinceEpoch(account.lastSyncAt!).toIso8601String()}',
          'Upload ${account.uploadEnabled ? 'on' : 'off (public sharing not agreed; enable with sync --consent)'}'
              '${account.uploadBlockedByOtherDevice ? '  blocked by another upload device (take over with sync --claim)' : ''}'
              '  last sync ${account.lastSyncAt == null ? 'never' : DateTime.fromMillisecondsSinceEpoch(account.lastSyncAt!).toIso8601String()}',
        ),
      );
      io.out.writeln(
        tr(
          '本机书架 ${shelf.entries.length} 部（读完 ${(local['localShelf']! as Map<String, Object?>)['finished']}）'
              '  已同步 ${account.syncState.workIds.length} 部${self?.shelfCount == null ? '' : '  服务端 ${self!.shelfCount} 部'}',
          'Local shelf ${shelf.entries.length} works (${(local['localShelf']! as Map<String, Object?>)['finished']} finished)'
              '  synced ${account.syncState.workIds.length}${self?.shelfCount == null ? '' : '  on server ${self!.shelfCount}'}',
        ),
      );
      if (self != null) {
        io.out.writeln(
          tr(
            '公开范围 ${self.visibility}  上传设备 ${self.uploadDevice == null ? '未知' : (self.uploadDevice! ? '是本机' : '是另一台')}',
            'Visibility ${self.visibility}  upload device ${self.uploadDevice == null ? 'unknown' : (self.uploadDevice! ? 'this machine' : 'another device')}',
          ),
        );
      }
    }
    if (failure != null) {
      io.err.writeln(failure.message);
      return failure.code;
    }
    return kExitOk;
  }

  Future<int> sync({required bool claim, required bool consent}) async {
    ServerLeaderboardAccount? account = await store.read();
    if (account == null) return noAccount();
    if (account.consentAt == null && !consent) {
      return io.fail(
        kExitUnavailable,
        tr(
          '本机账户没同意公开上传书架；确认后加 --consent 重跑（会公开读完 / 在读的作品与每日字数）',
          'This account has not agreed to publicly upload the shelf; rerun with --consent to confirm (finished / in-progress works and daily character counts become public)',
        ),
      );
    }
    final LeaderboardIdentity identity = identityOf(account);
    final Uri base =
        LeaderboardModule._baseUrl(null, account.serverUrl) ??
        Uri.parse(kLeaderboardDefaultBaseUrl);
    final int now = module._now();
    if (consent && (account.consentAt == null || !account.uploadEnabled)) {
      account = account.copyWith(
        consentAt: account.consentAt ?? now,
        uploadEnabled: true,
      );
      await store.write(account);
    }
    if (!account.uploadEnabled) {
      return io.fail(
        kExitUnavailable,
        tr(
          '本机账户的上传开关是关的；加 --consent 打开',
          'Upload is turned off for this account; add --consent to turn it on',
        ),
      );
    }
    if (claim) {
      account = account.copyWith(
        syncState: LeaderboardSyncState.empty,
        uploadBlockedByOtherDevice: false,
      );
      await store.write(account);
    }
    account = await _maybeBackfillIsbns(account, now);
    final LeaderboardClient client = module._client(base, identity);
    final LocalShelf shelf = await buildShelf(
      DateTime.fromMillisecondsSinceEpoch(client.serverNowMs()),
    );
    io.err.writeln(
      tr(
        '同步书架（本机 ${shelf.entries.length} 部${claim ? '，接管上传、全量重传' : ''}）…',
        'Syncing shelf (${shelf.entries.length} local works${claim ? ', taking over upload, full re-upload' : ''})...',
      ),
    );
    try {
      final ShelfSyncOutcome outcome = await syncShelf(
        client,
        shelf,
        account.syncState,
        claim: claim,
        coverThumb: module.coverThumb,
        coverHash: serverLeaderboardCoverHash,
      );
      await store.write(
        account.copyWith(
          syncState: outcome.state,
          lastSyncAt: module._now(),
          uploadBlockedByOtherDevice: false,
        ),
      );
      final Object? coverError = outcome.coverError;
      if (coverError != null) {
        io.err.writeln(
          tr(
            '封面投票中断（下次同步再投）: $coverError',
            'Cover voting interrupted (will retry on next sync): $coverError',
          ),
        );
      }
      if (io.json) {
        io.writeJson(<String, Object?>{
          'ok': true,
          'exitCode': kExitOk,
          'profileId': profileId,
          'localEntries': shelf.entries.length,
          'syncedWorks': outcome.state.workIds.length,
          'serverShelfCount': outcome.state.shelfCount,
          'droppedForShelfLimit': outcome.droppedForShelfLimit,
          'coverVotes': outcome.state.coverVotes.length,
          if (coverError != null) 'coverError': '$coverError',
        });
      } else {
        io.out.writeln(
          tr(
            '已同步：服务端书架 ${outcome.state.shelfCount ?? 0} 部'
                '${outcome.droppedForShelfLimit > 0 ? '，超出上限未上传 ${outcome.droppedForShelfLimit} 部' : ''}'
                '${outcome.state.coverVotes.isEmpty ? '' : '，已投封面 ${outcome.state.coverVotes.length} 部'}',
            'Synced: ${outcome.state.shelfCount ?? 0} works on the server shelf'
                '${outcome.droppedForShelfLimit > 0 ? ', ${outcome.droppedForShelfLimit} over the limit not uploaded' : ''}'
                '${outcome.state.coverVotes.isEmpty ? '' : ', ${outcome.state.coverVotes.length} cover votes cast'}',
          ),
        );
      }
      return kExitOk;
    } on LeaderboardUploadOwnedElsewhere catch (e) {
      await store.write(account.copyWith(uploadBlockedByOtherDevice: true));
      return fail(e);
    } on LeaderboardSyncException catch (e) {
      // 已推进的部分落盘，下次从断点续（与 app 同一纪律）。
      await store.write(
        account.copyWith(
          syncState: e.partialState,
          uploadBlockedByOtherDevice: e.anyBatchAccepted ? false : null,
        ),
      );
      return fail(e.error);
    } on Object catch (e) {
      return fail(e);
    }
  }

  Future<ServerLeaderboardAccount> _maybeBackfillIsbns(
    ServerLeaderboardAccount account,
    int now,
  ) async {
    final int? last = account.isbnBackfilledAt;
    if (last != null &&
        now - last < kServerLeaderboardIsbnBackfillInterval.inMilliseconds) {
      return account;
    }
    try {
      await backfillEpubIsbns(rt.db);
    } on Object catch (e, st) {
      rt.log.log('LeaderboardCli.isbnBackfill', e, st);
    }
    final ServerLeaderboardAccount next = account.copyWith(
      isbnBackfilledAt: now,
    );
    await store.write(next);
    return next;
  }

  Future<int> rank(ArgResults sub) async {
    final int? limit = LeaderboardModule._intOption(sub, 'limit');
    if (limit == null || limit < 1 || limit > 100) {
      return io.fail(
        kExitUsage,
        tr('--limit 需要 1..100', '--limit must be 1..100'),
      );
    }
    final ServerLeaderboardAccount? account = await store.read();
    final Uri? base = LeaderboardModule._baseUrl(
      sub['server'] as String?,
      account?.serverUrl,
    );
    if (base == null) {
      return io.fail(
        kExitUsage,
        tr(
          '--server 不是 http(s) 地址: ${sub['server']}',
          '--server is not an http(s) address: ${sub['server']}',
        ),
      );
    }
    final LeaderboardScope scope = LeaderboardScope.fromWire(sub['scope']);
    if (scope == LeaderboardScope.friends && account == null) {
      return noAccount();
    }
    final RankPage page;
    try {
      page = await module
          ._client(base, account == null ? null : identityOf(account))
          .rank(
            metric: LeaderboardMetric.fromWire(sub['metric']),
            window: LeaderboardWindow.fromWire(sub['window']),
            scope: scope,
            limit: limit,
          );
    } on Object catch (e) {
      return fail(e);
    }
    if (io.json) {
      io.writeJson(<String, Object?>{
        'ok': true,
        'exitCode': kExitOk,
        ...page.toJson(),
      });
      return kExitOk;
    }
    io.out.writeln(
      tr(
        '${page.metric.wire} / ${page.window.wire} / ${page.scope.wire}'
            '${page.from == null ? '' : '（自 ${page.from}）'}  共 ${page.total} 人'
            '${page.computedAt == null ? '  榜单生成中' : ''}',
        '${page.metric.wire} / ${page.window.wire} / ${page.scope.wire}'
            '${page.from == null ? '' : ' (since ${page.from})'}  ${page.total} people'
            '${page.computedAt == null ? '  leaderboard is being generated' : ''}',
      ),
    );
    for (final RankRow r in page.rows) {
      io.out.writeln(
        '${r.rank.toString().padLeft(4)}  ${r.value.toString().padLeft(8)}  ${r.account.tag}',
      );
    }
    final UserStanding? me = page.me;
    if (me != null) {
      io.out.writeln(
        tr(
          '我：${me.rank == null ? '未上榜' : '第 ${me.rank} 名'}（${me.value}）',
          'Me: ${me.rank == null ? 'unranked' : 'rank ${me.rank}'} (${me.value})',
        ),
      );
    }
    return kExitOk;
  }

  /// register / login / import：建本机账户。
  Future<int> adopt(ArgResults sub) async {
    final String kind = sub.name!;
    final ServerLeaderboardAccount? existing = await store.read();
    if (existing != null && !(sub['force'] as bool)) {
      return io.fail(
        kExitFailure,
        tr(
          'Profile $profileId 已有排行榜账户 ${existing.accountId}；要换账户先 leaderboard logout（或加 --force 覆盖，'
              '旧恢复码没备份就永远丢了）',
          'Profile $profileId already has leaderboard account ${existing.accountId}; to switch accounts, run leaderboard logout first (or add --force to overwrite; '
              'the old recovery code is lost for good if not backed up)',
        ),
      );
    }
    final String? serverFlag = sub['server'] as String?;
    final Uri? base = LeaderboardModule._baseUrl(serverFlag, null);
    if (base == null) {
      return io.fail(
        kExitUsage,
        tr(
          '--server 不是 http(s) 地址: $serverFlag',
          '--server is not an http(s) address: $serverFlag',
        ),
      );
    }
    final String email =
        ((sub.options.contains('email') ? sub['email'] as String? : null) ?? '')
            .trim();
    if (kind != 'import' && !isPlausibleLeaderboardEmail(email)) {
      return io.fail(
        kExitUsage,
        tr(
          '用法: leaderboard $kind --email <邮箱>${kind == 'register' ? ' --nickname <昵称>' : ''}',
          'Usage: leaderboard $kind --email <email>${kind == 'register' ? ' --nickname <nickname>' : ''}',
        ),
      );
    }
    final String nickname =
        ((sub.options.contains('nickname')
                    ? sub['nickname'] as String?
                    : null) ??
                '')
            .trim();
    if (kind == 'register' && nickname.isEmpty) {
      return io.fail(
        kExitUsage,
        tr(
          '用法: leaderboard register --email <邮箱> --nickname <昵称>',
          'Usage: leaderboard register --email <email> --nickname <nickname>',
        ),
      );
    }

    final String? secret = await _secret(
      kind == 'import' ? kLeaderboardRecoveryCodeEnv : kLeaderboardEmailCodeEnv,
      kind == 'import'
          ? tr('恢复码（FUSHI1-…）: ', 'Recovery code (FUSHI1-...): ')
          : tr('邮箱验证码: ', 'Email code: '),
    );
    if (secret == null || secret.isEmpty) {
      return io.fail(
        kExitUsage,
        kind == 'import'
            ? tr(
                '没拿到恢复码：设置环境变量 $kLeaderboardRecoveryCodeEnv，或经 stdin 传一行',
                'No recovery code received: set the environment variable $kLeaderboardRecoveryCodeEnv, or pass one line via stdin',
              )
            : tr(
                '没拿到验证码：先 leaderboard request-code --email $email${kind == 'login' ? ' --login' : ''}，'
                    '再经环境变量 $kLeaderboardEmailCodeEnv 或 stdin 传入',
                'No email code received: first run leaderboard request-code --email $email${kind == 'login' ? ' --login' : ''}, '
                    'then pass it via the environment variable $kLeaderboardEmailCodeEnv or stdin',
              ),
      );
    }
    final LeaderboardIdentity identity;
    if (kind == 'import') {
      try {
        identity = LeaderboardIdentity.fromRecoveryCode(secret);
      } on FormatException catch (e) {
        return io.fail(
          kExitUsage,
          tr(
            '恢复码格式不对（${e.message}）',
            'Invalid recovery code format (${e.message})',
          ),
        );
      }
    } else {
      identity = LeaderboardIdentity.generate();
    }
    final LeaderboardClient client = module._client(base, identity);
    final LeaderboardSelf self;
    try {
      self = switch (kind) {
        'register' => await client.register(
          nickname: nickname,
          email: email,
          code: secret,
        ),
        'login' => await client.login(email: email, code: secret),
        _ => await client.me(),
      };
    } on Object catch (e) {
      return fail(e);
    }
    final bool consent = sub['consent'] as bool;
    await store.write(
      ServerLeaderboardAccount(
        recoveryCode: identity.toRecoveryCode(),
        accountId: self.account.id,
        consentAt: consent ? module._now() : null,
        uploadEnabled: consent,
        serverUrl: serverFlag == null ? null : base.toString(),
      ),
    );
    if (io.json) {
      io.writeJson(<String, Object?>{
        'ok': true,
        'exitCode': kExitOk,
        'profileId': profileId,
        'accountId': self.account.id,
        'tag': self.account.tag,
        'deviceKeyId': identity.accountId,
        'uploadEnabled': consent,
        'accountFile': store.file.path,
      });
    } else {
      io.out.writeln(
        tr(
          '已${switch (kind) {
            'register' => '注册',
            'login' => '登录',
            _ => '导入',
          }}排行榜账户 ${self.account.tag}（Profile $profileId）',
          '${switch (kind) {
            'register' => 'Registered',
            'login' => 'Logged in to',
            _ => 'Imported',
          }} leaderboard account ${self.account.tag} (Profile $profileId)',
        ),
      );
      io.out.writeln(
        consent
            ? tr(
                '已同意公开上传；跑 leaderboard sync 上报书架',
                'Public upload agreed; run leaderboard sync to report the shelf',
              )
            : tr(
                '上传未开启（没给 --consent）；确认后 leaderboard sync --consent',
                'Upload is not enabled (--consent not given); after confirming, run leaderboard sync --consent',
              ),
      );
      if (kind != 'import') {
        io.out.writeln(
          tr(
            '设备钥匙只存在 ${store.file.path}（含私钥，0600）；丢了它这台设备就要重新登录',
            'The device key exists only at ${store.file.path} (contains the private key, 0600); if it is lost this device has to log in again',
          ),
        );
      }
    }
    return kExitOk;
  }

  Future<String?> _secret(String envName, String prompt) async {
    final String fromEnv = (module._env[envName] ?? '').trim();
    if (fromEnv.isNotEmpty) return fromEnv;
    return (module.readSecret ?? _readSecretFromStdin)(prompt);
  }

  Future<int> logout() async {
    final bool removed = await store.delete();
    if (io.json) {
      io.writeJson(<String, Object?>{
        'ok': true,
        'exitCode': kExitOk,
        'profileId': profileId,
        'removed': removed,
      });
    } else {
      io.out.writeln(
        removed
            ? tr(
                '已删除 Profile $profileId 的本机排行榜账户（服务端账户不受影响）',
                'Deleted the local leaderboard account of Profile $profileId (the server account is unaffected)',
              )
            : tr(
                'Profile $profileId 本来就没有本机排行榜账户',
                'Profile $profileId had no local leaderboard account',
              ),
      );
    }
    return kExitOk;
  }
}
