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
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/video_cli_support.dart';
import 'package:fushi_server/src/leaderboard_store.dart';
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
    return (code: kExitTempFail, message: '本账户的上传设备是另一台设备；要改由这台服务端上传，跑 leaderboard sync --claim（会全量重传）');
  }
  if (e is LeaderboardApiException) {
    if (e.status == 401 && e.code == kLeaderboardAccountGoneCode) {
      return (code: kExitNoPerm, message: '服务端已不认识这把设备钥匙（账户已在别处删除，或本设备已被解绑）；leaderboard logout 后重新 login / import');
    }
    if (e.status == 401 || e.status == 403) {
      return (code: kExitNoPerm, message: '鉴权失败（${e.status} ${e.code}）：签名 / 验证码 / 恢复码被服务端拒绝；签名被拒时先检查本机时钟');
    }
    if (e.status == 409 && e.code == 'upload_owned_by_other_device') {
      return describeLeaderboardError(const LeaderboardUploadOwnedElsewhere());
    }
    if (e.status == 409 || e.status == 429) {
      return (code: kExitTempFail, message: '服务端暂时拒绝（${e.status} ${e.code}），稍后重试');
    }
    if (e.status >= 500) {
      return (code: kExitUnavailable, message: '排行榜服务不可用（${e.status} ${e.code}）');
    }
    return (code: kExitFailure, message: '排行榜服务拒绝了请求（${e.status} ${e.code}${e.detail == null ? '' : ': ${e.detail}'}）');
  }
  if (e is TimeoutException) return (code: kExitUnavailable, message: '请求排行榜服务超时');
  if (e is SocketException || e is http.ClientException || e is TlsException || e is HttpException) {
    return (code: kExitUnavailable, message: '连不上排行榜服务: $e');
  }
  return (code: kExitFailure, message: '排行榜操作失败: $e');
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
      ? (decoded.width > maxEdge ? img.copyResize(decoded, width: maxEdge) : decoded)
      : (decoded.height > maxEdge ? img.copyResize(decoded, height: maxEdge) : decoded);
  return img.encodeJpg(scaled, quality: 80);
}

const String _usage =
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
  （绝不收 argv）。--consent = 同意把本机书架公开上传到排行榜。每个子命令都支持 --json。''';

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
    void profile(ArgParser a) => a.addOption('profile', help: 'Profile id（缺省 = 当前激活 Profile）');
    void server(ArgParser a) => a.addOption('server', help: '排行榜服务地址（缺省 $kLeaderboardDefaultBaseUrl）');
    void account(ArgParser a) {
      profile(a);
      server(a);
      a
        ..addFlag('consent', negatable: false, help: '同意把本机书架公开上传到排行榜')
        ..addFlag('force', negatable: false, help: '本 Profile 已有账户时覆盖（旧恢复码没备份就永远丢了）');
    }

    addJsonFlag(lb.addCommand('status'))
      ..addFlag('offline', negatable: false, help: '只看本机，不连服务端')
      ..addOption('profile', help: 'Profile id（缺省 = 当前激活 Profile）');
    addJsonFlag(lb.addCommand('sync'))
      ..addFlag('claim', negatable: false, help: '由这台服务端接管上传（强制全量重传）')
      ..addFlag('consent', negatable: false, help: '同意公开上传（账户建立时没同意过才需要）')
      ..addOption('profile', help: 'Profile id（缺省 = 当前激活 Profile）');
    final ArgParser rank = addJsonFlag(lb.addCommand('rank'))
      ..addOption(
        'metric',
        allowed: <String>[for (final LeaderboardMetric m in LeaderboardMetric.values) m.wire],
        defaultsTo: 'book',
      )
      ..addOption(
        'window',
        allowed: <String>[for (final LeaderboardWindow w in LeaderboardWindow.values) w.wire],
        defaultsTo: 'week',
      )
      ..addOption(
        'scope',
        allowed: <String>[for (final LeaderboardScope s in LeaderboardScope.values) s.wire],
        defaultsTo: 'global',
      )
      ..addOption('limit', defaultsTo: '20', help: '1..100');
    profile(rank);
    server(rank);
    final ArgParser code = addJsonFlag(lb.addCommand('request-code'))
      ..addOption('email', help: '邮箱')
      ..addFlag('login', negatable: false, help: '登录用验证码（缺省是注册用）')
      ..addOption('lang', allowed: <String>['zh', 'en', 'ja'], help: '邮件语言');
    server(code);
    account(
      addJsonFlag(lb.addCommand('register'))
        ..addOption('email', help: '邮箱')
        ..addOption('nickname', help: '昵称'),
    );
    account(addJsonFlag(lb.addCommand('login'))..addOption('email', help: '邮箱'));
    account(addJsonFlag(lb.addCommand('import')));
    profile(addJsonFlag(lb.addCommand('logout')));
  }

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final ArgResults? sub = command.command;
    final CliIo io = CliIo(out: out ?? stdout, err: err ?? stderr, json: sub != null && jsonFlag(sub));
    if (sub == null) {
      io.err.writeln(_usage);
      return kExitUsage;
    }
    final int? profileArg = _intOption(sub, 'profile');
    if (sub.options.contains('profile') && sub['profile'] != null && (profileArg == null || profileArg < 0)) {
      return io.fail(kExitUsage, '--profile 需要非负整数');
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
            return await s.sync(claim: sub['claim'] as bool, consent: sub['consent'] as bool);
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
        return io.fail(kExitDataError, '${e.message}；修不好就 leaderboard logout 后重新 import 恢复码');
      }
    });
  }

  Future<int> _requestCode(ArgResults sub, CliIo io) async {
    final String email = ((sub['email'] as String?) ?? '').trim();
    if (!isPlausibleLeaderboardEmail(email)) {
      return io.fail(kExitUsage, '用法: leaderboard request-code --email <邮箱> [--login]');
    }
    final Uri? base = _baseUrl(sub['server'] as String?, null);
    if (base == null) return io.fail(kExitUsage, '--server 不是 http(s) 地址: ${sub['server']}');
    final bool forLogin = sub['login'] as bool;
    try {
      await _client(
        base,
        null,
      ).requestEmailCode(email: email, purpose: forLogin ? 'login' : 'register', lang: sub['lang'] as String?);
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
        '已请求验证码（若该邮箱可用，几分钟内会收到）；收到后用 $kLeaderboardEmailCodeEnv 或 stdin 交给 leaderboard ${forLogin ? 'login' : 'register'}',
      );
    }
    return kExitOk;
  }

  Map<String, String> get _env => env ?? Platform.environment;

  int _now() => (clockMs ?? () => DateTime.now().millisecondsSinceEpoch)();

  /// 共用同一个服务器时钟偏移（一次命令里多次建客户端时不丢校准）。
  static final LeaderboardServerClock _serverClock = LeaderboardServerClock();

  LeaderboardClient _client(Uri base, LeaderboardIdentity? identity) => LeaderboardClient(
    baseUrl: base,
    // 出站必须经全应用代理装配。
    httpClientFactory: httpClientFactory ?? () async => createAppHttpIoClient(),
    identity: identity,
    clockMs: clockMs,
    serverClock: _serverClock,
  );

  /// `--server` > 账户文件里的地址 > 默认。不是 http(s) 绝对地址返回 null。
  static Uri? _baseUrl(String? flag, String? stored) {
    final String raw = (flag ?? stored ?? kLeaderboardDefaultBaseUrl).trim();
    final Uri? u = Uri.tryParse(raw);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) return null;
    return u;
  }

  static int? _intOption(ArgResults r, String name) {
    if (!r.options.contains(name) || r[name] == null) return null;
    return int.tryParse(r[name] as String);
  }
}

/// 一次命令的上下文（运行时 + Profile + 账户文件）。
class _Session {
  _Session({required this.module, required this.rt, required this.io, required this.profileId})
    : store = ServerLeaderboardStore(supportRoot: rt.paths.support, profileId: profileId);

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
    'Profile $profileId 没有排行榜账户：先 leaderboard import（恢复码经 $kLeaderboardRecoveryCodeEnv / stdin），'
    '或 leaderboard request-code + login / register（验证码经 $kLeaderboardEmailCodeEnv / stdin）；'
    '也可以把 app 的 <数据目录>/leaderboard/profile_<id>.json 拷到 ${store.file.path}',
  );

  /// 账户文件里的恢复码 → 签名身份；恢复码坏了按文件损坏处理。
  LeaderboardIdentity identityOf(ServerLeaderboardAccount account) {
    try {
      return LeaderboardIdentity.fromRecoveryCode(account.recoveryCode);
    } on FormatException {
      throw ServerLeaderboardStoreException('排行榜账户文件里的恢复码无效: ${store.file.path}');
    }
  }

  /// 本机书架（同机多 Profile 时只有代表 Profile 计入「谁都没记录」的作品，BUG-2870）。
  Future<LocalShelf> buildShelf(DateTime now) async {
    final int? owner = leaderboardUnattributedOwner(
      uploading: await ServerLeaderboardStore.uploadingProfileIds(rt.paths.support),
      existing: <int>[for (final ProfileRow p in await rt.db.select(rt.db.profiles).get()) p.id],
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
        io.writeJson(<String, Object?>{'ok': true, 'profileId': profileId, 'configured': false});
      } else {
        io.out.writeln('Profile $profileId 没有排行榜账户（leaderboard import / login / register 建立）');
      }
      return kExitOk;
    }
    final LeaderboardIdentity identity = identityOf(account);
    final Uri base = LeaderboardModule._baseUrl(null, account.serverUrl) ?? Uri.parse(kLeaderboardDefaultBaseUrl);
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
      'pendingCovers': account.syncState.pendingCovers.length,
      'localShelf': <String, Object?>{
        'entries': shelf.entries.length,
        'finished': shelf.entries.where((LocalShelfEntry e) => e.upload.finished).length,
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
    final ({int code, String message})? failure = remoteError == null ? null : describeLeaderboardError(remoteError);
    if (io.json) {
      io.writeJson(<String, Object?>{
        'ok': failure == null,
        if (failure != null) ...<String, Object?>{'exitCode': failure.code, 'error': failure.message},
        ...local,
        if (self != null) 'remote': self.toJson(),
      });
    } else {
      io.out.writeln('账户 ${self?.account.tag ?? account.accountId}  （设备钥匙 ${identity.accountId}）  服务 $base');
      io.out.writeln(
        '上传 ${account.uploadEnabled ? '开' : '关（未同意公开，sync --consent 打开）'}'
        '${account.uploadBlockedByOtherDevice ? '  被另一台上传设备挡住（sync --claim 接管）' : ''}'
        '  上次同步 ${account.lastSyncAt == null ? '从未' : DateTime.fromMillisecondsSinceEpoch(account.lastSyncAt!).toIso8601String()}',
      );
      io.out.writeln(
        '本机书架 ${shelf.entries.length} 部（读完 ${(local['localShelf']! as Map<String, Object?>)['finished']}）'
        '  已同步 ${account.syncState.workIds.length} 部${self?.shelfCount == null ? '' : '  服务端 ${self!.shelfCount} 部'}',
      );
      if (self != null) {
        io.out.writeln(
          '公开范围 ${self.visibility}  上传设备 ${self.uploadDevice == null ? '未知' : (self.uploadDevice! ? '是本机' : '是另一台')}',
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
      return io.fail(kExitUnavailable, '本机账户没同意公开上传书架；确认后加 --consent 重跑（会公开读完 / 在读的作品与每日字数）');
    }
    final LeaderboardIdentity identity = identityOf(account);
    final Uri base = LeaderboardModule._baseUrl(null, account.serverUrl) ?? Uri.parse(kLeaderboardDefaultBaseUrl);
    final int now = module._now();
    if (consent && (account.consentAt == null || !account.uploadEnabled)) {
      account = account.copyWith(consentAt: account.consentAt ?? now, uploadEnabled: true);
      await store.write(account);
    }
    if (!account.uploadEnabled) {
      return io.fail(kExitUnavailable, '本机账户的上传开关是关的；加 --consent 打开');
    }
    if (claim) {
      account = account.copyWith(syncState: LeaderboardSyncState.empty, uploadBlockedByOtherDevice: false);
      await store.write(account);
    }
    account = await _maybeBackfillIsbns(account, now);
    final LeaderboardClient client = module._client(base, identity);
    final LocalShelf shelf = await buildShelf(DateTime.fromMillisecondsSinceEpoch(client.serverNowMs()));
    io.err.writeln('同步书架（本机 ${shelf.entries.length} 部${claim ? '，接管上传、全量重传' : ''}）…');
    try {
      final ShelfSyncOutcome outcome = await syncShelf(
        client,
        shelf,
        account.syncState,
        claim: claim,
        coverThumb: module.coverThumb,
      );
      await store.write(
        account.copyWith(syncState: outcome.state, lastSyncAt: module._now(), uploadBlockedByOtherDevice: false),
      );
      final Object? coverError = outcome.coverError;
      if (coverError != null) io.err.writeln('封面补传中断（下次同步再补）: $coverError');
      if (io.json) {
        io.writeJson(<String, Object?>{
          'ok': true,
          'exitCode': kExitOk,
          'profileId': profileId,
          'localEntries': shelf.entries.length,
          'syncedWorks': outcome.state.workIds.length,
          'serverShelfCount': outcome.state.shelfCount,
          'droppedForShelfLimit': outcome.droppedForShelfLimit,
          'pendingCovers': outcome.state.pendingCovers.length,
          if (coverError != null) 'coverError': '$coverError',
        });
      } else {
        io.out.writeln(
          '已同步：服务端书架 ${outcome.state.shelfCount ?? 0} 部'
          '${outcome.droppedForShelfLimit > 0 ? '，超出上限未上传 ${outcome.droppedForShelfLimit} 部' : ''}'
          '${outcome.state.pendingCovers.isEmpty ? '' : '，待补封面 ${outcome.state.pendingCovers.length}'}',
        );
      }
      return kExitOk;
    } on LeaderboardUploadOwnedElsewhere catch (e) {
      await store.write(account.copyWith(uploadBlockedByOtherDevice: true));
      return fail(e);
    } on LeaderboardSyncException catch (e) {
      // 已推进的部分落盘，下次从断点续（与 app 同一纪律）。
      await store.write(
        account.copyWith(syncState: e.partialState, uploadBlockedByOtherDevice: e.anyBatchAccepted ? false : null),
      );
      return fail(e.error);
    } on Object catch (e) {
      return fail(e);
    }
  }

  Future<ServerLeaderboardAccount> _maybeBackfillIsbns(ServerLeaderboardAccount account, int now) async {
    final int? last = account.isbnBackfilledAt;
    if (last != null && now - last < kServerLeaderboardIsbnBackfillInterval.inMilliseconds) return account;
    try {
      await backfillEpubIsbns(rt.db);
    } on Object catch (e, st) {
      rt.log.log('LeaderboardCli.isbnBackfill', e, st);
    }
    final ServerLeaderboardAccount next = account.copyWith(isbnBackfilledAt: now);
    await store.write(next);
    return next;
  }

  Future<int> rank(ArgResults sub) async {
    final int? limit = LeaderboardModule._intOption(sub, 'limit');
    if (limit == null || limit < 1 || limit > 100) return io.fail(kExitUsage, '--limit 需要 1..100');
    final ServerLeaderboardAccount? account = await store.read();
    final Uri? base = LeaderboardModule._baseUrl(sub['server'] as String?, account?.serverUrl);
    if (base == null) return io.fail(kExitUsage, '--server 不是 http(s) 地址: ${sub['server']}');
    final LeaderboardScope scope = LeaderboardScope.fromWire(sub['scope']);
    if (scope == LeaderboardScope.friends && account == null) return noAccount();
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
      io.writeJson(<String, Object?>{'ok': true, 'exitCode': kExitOk, ...page.toJson()});
      return kExitOk;
    }
    io.out.writeln(
      '${page.metric.wire} / ${page.window.wire} / ${page.scope.wire}'
      '${page.from == null ? '' : '（自 ${page.from}）'}  共 ${page.total} 人'
      '${page.computedAt == null ? '  榜单生成中' : ''}',
    );
    for (final RankRow r in page.rows) {
      io.out.writeln('${r.rank.toString().padLeft(4)}  ${r.value.toString().padLeft(8)}  ${r.account.tag}');
    }
    final UserStanding? me = page.me;
    if (me != null) io.out.writeln('我：${me.rank == null ? '未上榜' : '第 ${me.rank} 名'}（${me.value}）');
    return kExitOk;
  }

  /// register / login / import：建本机账户。
  Future<int> adopt(ArgResults sub) async {
    final String kind = sub.name!;
    final ServerLeaderboardAccount? existing = await store.read();
    if (existing != null && !(sub['force'] as bool)) {
      return io.fail(
        kExitFailure,
        'Profile $profileId 已有排行榜账户 ${existing.accountId}；要换账户先 leaderboard logout（或加 --force 覆盖，'
        '旧恢复码没备份就永远丢了）',
      );
    }
    final String? serverFlag = sub['server'] as String?;
    final Uri? base = LeaderboardModule._baseUrl(serverFlag, null);
    if (base == null) return io.fail(kExitUsage, '--server 不是 http(s) 地址: $serverFlag');
    final String email = ((sub.options.contains('email') ? sub['email'] as String? : null) ?? '').trim();
    if (kind != 'import' && !isPlausibleLeaderboardEmail(email)) {
      return io.fail(kExitUsage, '用法: leaderboard $kind --email <邮箱>${kind == 'register' ? ' --nickname <昵称>' : ''}');
    }
    final String nickname = ((sub.options.contains('nickname') ? sub['nickname'] as String? : null) ?? '').trim();
    if (kind == 'register' && nickname.isEmpty) {
      return io.fail(kExitUsage, '用法: leaderboard register --email <邮箱> --nickname <昵称>');
    }

    final String? secret = await _secret(
      kind == 'import' ? kLeaderboardRecoveryCodeEnv : kLeaderboardEmailCodeEnv,
      kind == 'import' ? '恢复码（FUSHI1-…）: ' : '邮箱验证码: ',
    );
    if (secret == null || secret.isEmpty) {
      return io.fail(
        kExitUsage,
        kind == 'import'
            ? '没拿到恢复码：设置环境变量 $kLeaderboardRecoveryCodeEnv，或经 stdin 传一行'
            : '没拿到验证码：先 leaderboard request-code --email $email${kind == 'login' ? ' --login' : ''}，'
                  '再经环境变量 $kLeaderboardEmailCodeEnv 或 stdin 传入',
      );
    }
    final LeaderboardIdentity identity;
    if (kind == 'import') {
      try {
        identity = LeaderboardIdentity.fromRecoveryCode(secret);
      } on FormatException catch (e) {
        return io.fail(kExitUsage, '恢复码格式不对（${e.message}）');
      }
    } else {
      identity = LeaderboardIdentity.generate();
    }
    final LeaderboardClient client = module._client(base, identity);
    final LeaderboardSelf self;
    try {
      self = switch (kind) {
        'register' => await client.register(nickname: nickname, email: email, code: secret),
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
        '已${switch (kind) {
          'register' => '注册',
          'login' => '登录',
          _ => '导入',
        }}排行榜账户 ${self.account.tag}（Profile $profileId）',
      );
      io.out.writeln(
        consent ? '已同意公开上传；跑 leaderboard sync 上报书架' : '上传未开启（没给 --consent）；确认后 leaderboard sync --consent',
      );
      if (kind != 'import') {
        io.out.writeln('设备钥匙只存在 ${store.file.path}（含私钥，0600）；丢了它这台设备就要重新登录');
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
      io.writeJson(<String, Object?>{'ok': true, 'exitCode': kExitOk, 'profileId': profileId, 'removed': removed});
    } else {
      io.out.writeln(removed ? '已删除 Profile $profileId 的本机排行榜账户（服务端账户不受影响）' : 'Profile $profileId 本来就没有本机排行榜账户');
    }
    return kExitOk;
  }
}
