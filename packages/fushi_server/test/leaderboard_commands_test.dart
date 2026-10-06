/// `leaderboard …` 契约：用本机回环上的假排行榜服务（逐请求验签）跑真实的
/// `withServerRuntime` + 引擎 `syncShelf`，覆盖成功、鉴权失败（401）、网络不通、
/// 缺账户 / 未同意上传、上传设备是另一台（409），以及凭据只走环境变量 / stdin。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_signing.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/leaderboard_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 一次被假服务收下的请求。
class _Req {
  _Req(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final HttpHeaders headers;
  final Uint8List body;

  Map<String, Object?> get json => (jsonDecode(utf8.decode(body)) as Map<Object?, Object?>).cast<String, Object?>();
}

/// 假排行榜 Worker：认识 [known] 里的设备钥匙，签名不对 / 钥匙不认识回 401。
class _FakeLeaderboard {
  _FakeLeaderboard._(this._server);

  static Future<_FakeLeaderboard> start() async {
    final _FakeLeaderboard f = _FakeLeaderboard._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f._server.listen(f._handle);
    return f;
  }

  final HttpServer _server;
  final List<_Req> requests = <_Req>[];

  /// 设备钥匙 id → SPKI。
  final Map<String, Uint8List> known = <String, Uint8List>{};

  /// 置非空时所有签名请求一律回这个 401 错误码。
  String? force401;

  /// 置 true 时书架上报回 409 `upload_owned_by_other_device`。
  bool ownedElsewhere = false;

  int serverShelfCount = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  static const Map<String, Object?> _account = <String, Object?>{
    'id': 'acct0000000000AA',
    'nickname': '猫',
    'discriminator': 42,
  };

  Future<void> _handle(HttpRequest req) async {
    final Uint8List body = Uint8List.fromList(
      await req.fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b)),
    );
    final String path = req.uri.path;
    requests.add(_Req(req.method, path, req.headers, body));
    Future<void> reply(int status, Object? json) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(json));
      await req.response.close();
    }

    if (path == '/v1/email/code') return reply(202, <String, Object?>{});
    // 验签：注册 / 登录只自签（body 里带公钥），其余带 X-Fushi-Account。
    final String? sig = req.headers.value('x-fushi-sig');
    final String? time = req.headers.value('x-fushi-time');
    final String? keyId = req.headers.value('x-fushi-account');
    Uint8List? spki;
    if (path == '/v1/login' || path == '/v1/register') {
      spki = leaderboardBase64UrlDecode(
        ((jsonDecode(utf8.decode(body)) as Map<Object?, Object?>)['pubkey'] as String?) ?? '',
      );
    } else if (keyId != null) {
      spki = known[keyId];
      if (spki == null) return reply(401, <String, Object?>{'error': 'unknown_account'});
    }
    if (spki != null) {
      final String pathWithQuery = req.uri.hasQuery ? '${req.uri.path}?${req.uri.query}' : req.uri.path;
      final String message = leaderboardSigningString(req.method, pathWithQuery, int.parse(time ?? '0'), body);
      if (sig == null || !LeaderboardIdentity.verify(spki, message, sig)) {
        return reply(401, <String, Object?>{'error': 'bad_signature'});
      }
      if (force401 != null) return reply(401, <String, Object?>{'error': force401});
    }
    Map<String, Object?> self() => <String, Object?>{
      ..._account,
      'visibility': 'public',
      'createdAt': 1,
      'shelfCount': serverShelfCount,
      'emailVerified': true,
      'uploadDevice': !ownedElsewhere,
    };
    switch ('${req.method} $path') {
      case 'POST /v1/login':
        final Map<String, Object?> j = (jsonDecode(utf8.decode(body)) as Map<Object?, Object?>).cast<String, Object?>();
        if (j['code'] != '123456') return reply(401, <String, Object?>{'error': 'bad_code'});
        known[leaderboardAccountIdFromSpki(spki!)] = spki;
        return reply(200, self());
      case 'GET /v1/me':
        return reply(200, self());
      case 'POST /v1/shelf':
        if (ownedElsewhere) return reply(409, <String, Object?>{'error': 'upload_owned_by_other_device'});
        final List<Object?> put = (jsonDecode(utf8.decode(body)) as Map<Object?, Object?>)['put']! as List<Object?>;
        serverShelfCount = put.length;
        return reply(200, <String, Object?>{
          'works': <Object?>[
            for (int i = 0; i < put.length; i++) <String, Object?>{'i': i, 'workId': 'w$i', 'needsCover': false},
          ],
          'shelfCount': serverShelfCount,
        });
      case 'GET /v1/rank':
        return reply(200, <String, Object?>{
          'metric': req.uri.queryParameters['metric'],
          'window': req.uri.queryParameters['window'],
          'scope': req.uri.queryParameters['scope'],
          'from': null,
          'computedAt': 1,
          'total': 1,
          'me': keyId == null ? null : <String, Object?>{'value': 3, 'rank': 1},
          'rows': <Object?>[
            <String, Object?>{'rank': 1, 'value': 3, 'account': _account},
          ],
        });
    }
    return reply(404, <String, Object?>{'error': 'not_found'});
  }
}

void main() {
  late Directory tmp;
  late File configFile;
  late _FakeLeaderboard server;
  late StringBuffer out;
  late StringBuffer err;
  late LeaderboardIdentity identity;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_leaderboard_cli_');
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    await ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).save(configFile);
    server = await _FakeLeaderboard.start();
    identity = LeaderboardIdentity.generate();
    server.known[identity.accountId] = identity.spki;
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    await server.close();
    enginePaths = const UninstalledEnginePaths();
    await tmp.delete(recursive: true);
  });

  Future<int> lb(
    List<String> args, {
    Map<String, String> env = const <String, String>{},
    Future<String?> Function(String prompt)? stdinSecret,
  }) {
    out.clear();
    err.clear();
    final LeaderboardModule module = LeaderboardModule(
      out: out,
      err: err,
      env: env,
      readSecret: stdinSecret ?? (String _) async => null,
      httpClientFactory: () async => http.Client(),
    );
    final ArgParser parser = ArgParser();
    module.register(parser);
    return module.run(
      'leaderboard',
      parser.parse(<String>['leaderboard', ...args]).command!,
      CliContext(configFile: configFile, verbose: false),
    );
  }

  Map<String, Object?> json() => (jsonDecode(out.toString()) as Map<Object?, Object?>).cast<String, Object?>();

  File accountFile(int profileId) =>
      File(p.join(tmp.path, 'data', 'support', 'leaderboard', 'profile_$profileId.json'));

  Future<int> importAccount({bool consent = false}) async {
    final int code = await lb(
      <String>['import', '--server', server.url, if (consent) '--consent', '--json'],
      env: <String, String>{kLeaderboardRecoveryCodeEnv: identity.toRecoveryCode()},
    );
    expect(code, 0, reason: '$out\n$err');
    return json()['profileId']! as int;
  }

  test('没有账户：sync → 69 并给出建立方式，不发任何请求；status → 0 configured=false', () async {
    expect(await lb(<String>['sync']), 69);
    expect(err.toString(), contains(kLeaderboardRecoveryCodeEnv));
    expect(await lb(<String>['status', '--json']), 0);
    expect(json()['configured'], isFalse);
    expect(server.requests, isEmpty);
  });

  test('import（恢复码走环境变量）→ 未同意时 sync 69；sync --consent 验签上报书架成功并落盘状态', () async {
    final int profileId = await importAccount();
    final File file = accountFile(profileId);
    expect(file.existsSync(), isTrue);
    if (!Platform.isWindows) {
      expect(file.statSync().modeString(), 'rw-------');
    }
    final Map<String, Object?> stored = (jsonDecode(file.readAsStringSync()) as Map<Object?, Object?>)
        .cast<String, Object?>();
    expect(stored['recoveryCode'], identity.toRecoveryCode());
    expect(stored['accountId'], 'acct0000000000AA');
    expect(stored['uploadEnabled'], isFalse);
    expect(stored['serverUrl'], server.url);

    expect(await lb(<String>['sync']), 69);
    expect(err.toString(), contains('--consent'));

    expect(await lb(<String>['sync', '--consent', '--json']), 0, reason: '$out\n$err');
    expect(json()['ok'], isTrue);
    final Iterable<_Req> shelf = server.requests.where((_Req r) => r.path == '/v1/shelf');
    expect(shelf, hasLength(1));
    expect(shelf.single.json['reset'], isTrue);
    expect(shelf.single.headers.value('x-fushi-account'), identity.accountId);
    final Map<String, Object?> after = (jsonDecode(file.readAsStringSync()) as Map<Object?, Object?>)
        .cast<String, Object?>();
    expect(after['uploadEnabled'], isTrue);
    expect(after['consentAt'], isNotNull);
    expect(after['lastSyncAt'], isNotNull);
    expect((after['syncState']! as Map<Object?, Object?>)['shelfCount'], 0);

    // 再跑一次是增量：先问 me() 核对书架行数，没变化就不必 reset。
    expect(await lb(<String>['sync']), 0, reason: '$err');
    expect(server.requests.where((_Req r) => r.path == '/v1/me'), isNotEmpty);

    expect(await lb(<String>['status', '--json']), 0, reason: '$err');
    final Map<String, Object?> status = json();
    expect(status['configured'], isTrue);
    expect(status['deviceKeyId'], identity.accountId);
    expect((status['remote']! as Map<Object?, Object?>)['nickname'], '猫');
  });

  test('凭据只走环境变量 / stdin：都没有 → 64；stdin 给恢复码 → 0', () async {
    expect(await lb(<String>['import', '--server', server.url]), 64);
    expect(err.toString(), contains(kLeaderboardRecoveryCodeEnv));
    String? prompted;
    final int code = await lb(
      <String>['import', '--server', server.url],
      stdinSecret: (String prompt) async {
        prompted = prompt;
        return identity.toRecoveryCode();
      },
    );
    expect(code, 0, reason: '$err');
    expect(prompted, contains('恢复码'));
    // 已有账户不覆盖。
    expect(
      await lb(
        <String>['import', '--server', server.url],
        env: <String, String>{kLeaderboardRecoveryCodeEnv: identity.toRecoveryCode()},
      ),
      1,
    );
  });

  test('鉴权失败：签名被拒 → 77；未知设备钥匙 → 77 且不落账户文件；验证码不对 → 77', () async {
    final int profileId = await importAccount(consent: true);
    server.force401 = 'bad_signature';
    expect(await lb(<String>['sync', '--json']), 77);
    expect(json()['exitCode'], 77);
    expect(await lb(<String>['status']), 77);
    server.force401 = null;

    expect(await lb(<String>['logout']), 0);
    expect(accountFile(profileId).existsSync(), isFalse);
    final LeaderboardIdentity stranger = LeaderboardIdentity.generate();
    expect(
      await lb(
        <String>['import', '--server', server.url],
        env: <String, String>{kLeaderboardRecoveryCodeEnv: stranger.toRecoveryCode()},
      ),
      77,
    );
    expect(err.toString(), contains('解绑'));
    expect(accountFile(profileId).existsSync(), isFalse);

    expect(
      await lb(
        <String>['login', '--email', 'a@b.cd', '--server', server.url],
        env: <String, String>{kLeaderboardEmailCodeEnv: '000000'},
      ),
      77,
    );
    expect(accountFile(profileId).existsSync(), isFalse);
    expect(
      await lb(
        <String>['login', '--email', 'a@b.cd', '--server', server.url, '--consent', '--json'],
        env: <String, String>{kLeaderboardEmailCodeEnv: '123456'},
      ),
      0,
      reason: '$err',
    );
    expect(json()['uploadEnabled'], isTrue);
    expect(accountFile(profileId).existsSync(), isTrue);
  });

  test('网络不通 → 69（import 与 sync 都是）', () async {
    await importAccount(consent: true);
    final String deadUrl = server.url;
    await server.close();
    expect(await lb(<String>['sync', '--json']), 69);
    expect(json()['error'], contains('连不上'));
    expect(
      await lb(
        <String>['import', '--server', deadUrl, '--force'],
        env: <String, String>{kLeaderboardRecoveryCodeEnv: identity.toRecoveryCode()},
      ),
      69,
    );
  });

  test('上传设备是另一台 → 75 并记下；rank 匿名 / 带签名只读看榜', () async {
    final int profileId = await importAccount(consent: true);
    server.ownedElsewhere = true;
    expect(await lb(<String>['sync']), 75);
    expect(err.toString(), contains('--claim'));
    final Map<String, Object?> stored = (jsonDecode(accountFile(profileId).readAsStringSync()) as Map<Object?, Object?>)
        .cast<String, Object?>();
    expect(stored['uploadBlockedByOtherDevice'], isTrue);

    expect(await lb(<String>['rank', '--metric', 'chars', '--json']), 0, reason: '$err');
    final Map<String, Object?> page = json();
    expect(page['metric'], 'chars');
    expect(page['me'], isNotNull);
    expect((page['rows']! as List<Object?>), hasLength(1));
    final _Req rankReq = server.requests.lastWhere((_Req r) => r.path == '/v1/rank');
    expect(rankReq.headers.value('x-fushi-account'), identity.accountId);

    expect(await lb(<String>['logout']), 0);
    expect(await lb(<String>['rank', '--server', server.url]), 0, reason: '$err');
    expect(out.toString(), contains('猫#0042'));
    expect(server.requests.last.headers.value('x-fushi-account'), isNull);
    expect(await lb(<String>['rank', '--scope', 'friends', '--server', server.url]), 69);
  });

  test('封面缩略图：长边缩到 300 的 JPEG；解不开返回 null', () {
    final Uint8List png = img.encodePng(img.Image(width: 600, height: 900));
    final img.Image thumb = img.decodeJpg(encodeLeaderboardCoverThumb(png)!)!;
    expect((thumb.width, thumb.height), (200, 300));
    expect(encodeLeaderboardCoverThumb(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });

  test('request-code 不碰数据库；邮箱不对 64', () async {
    expect(await lb(<String>['request-code', '--email', 'nope', '--server', server.url]), 64);
    expect(await lb(<String>['request-code', '--email', 'a@b.cd', '--login', '--server', server.url, '--json']), 0);
    expect(json()['purpose'], 'login');
    expect(server.requests.single.json, containsPair('purpose', 'login'));
  });
}
