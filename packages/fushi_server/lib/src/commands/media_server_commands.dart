/// `fushi_server media-server plex …`：Plex 账号登录（PIN 流程）与只读浏览。
///
/// 协议层全在引擎（`plex_tv_auth.dart` / `plex_api.dart`），出站一律经引擎缺省的
/// `createAppHttpIoClient()`（全应用代理装配）。这里只补两样服务端没有的东西：
/// - 账号凭据存储：`<support>/media_server/plex.json`（0600，**不进偏好表**——偏好表
///   会被备份 / Profile 迁移带出机器）。`clientIdentifier` 每安装稳定，plex.tv 的
///   「已授权设备」按它归并；
/// - 选连接：账号 resources 的多条 connection 按引擎 [orderPlexConnections] 排序、
///   [firstReachablePlexConnection] 逐条用 `/identity` 探测。
///
/// 也可以绕过账号直连一台 PMS：`--url <pms>` + 环境变量 `FUSHI_PLEX_TOKEN`（不进 argv）。
///
/// 范围：只读浏览。把 Plex 服务器登记成媒体库来源（app 的 `MediaServerConfig` /
/// `SyncRepository.getMediaServers()`）与播放都在 `fushi/` 里，服务端没有对应的库模型。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_tv_auth.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const int _exitOk = 0;
const int _exitFailure = 1;
const int _exitUsage = 64;
const int _exitNoInput = 66;
const int _exitUnavailable = 69;

/// 直连 PMS 时的 token 环境变量。
const String kPlexTokenEnv = 'FUSHI_PLEX_TOKEN';

/// 本机 Plex 账号凭据。
class PlexAccountCredential {
  const PlexAccountCredential({
    required this.clientIdentifier,
    this.accountToken,
    this.username,
  });

  factory PlexAccountCredential.fromJson(Map<String, Object?> j) =>
      PlexAccountCredential(
        clientIdentifier: j['clientIdentifier']! as String,
        accountToken: j['accountToken'] as String?,
        username: j['username'] as String?,
      );

  final String clientIdentifier;
  final String? accountToken;
  final String? username;

  bool get signedIn => accountToken != null && accountToken!.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'clientIdentifier': clientIdentifier,
    if (accountToken != null) 'accountToken': accountToken,
    if (username != null) 'username': username,
  };
}

/// `<support>/media_server/plex.json`。
class PlexCredentialStore {
  PlexCredentialStore(this.file);

  factory PlexCredentialStore.under(Directory support) => PlexCredentialStore(
    File(p.join(support.path, 'media_server', 'plex.json')),
  );

  final File file;

  /// 读凭据；没有就生成一个新的 clientIdentifier（未登录）并落盘，保证每安装稳定。
  Future<PlexAccountCredential> loadOrCreate() async {
    if (await file.exists()) {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['clientIdentifier'] is! String) {
        throw FormatException(
          tr(
            'Plex 凭据文件形状不对: ${file.path}',
            'Malformed Plex credentials file: ${file.path}',
          ),
        );
      }
      return PlexAccountCredential.fromJson(decoded.cast<String, Object?>());
    }
    final Random rng = Random.secure();
    final String id = List<String>.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final PlexAccountCredential fresh = PlexAccountCredential(
      clientIdentifier: 'fushi-server-$id',
    );
    await save(fresh);
    return fresh;
  }

  Future<void> save(PlexAccountCredential credential) async {
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(credential.toJson()),
      flush: true,
    );
    if (!Platform.isWindows) {
      final ProcessResult r = await Process.run('chmod', <String>[
        '600',
        tmp.path,
      ]);
      if (r.exitCode != 0) {
        await tmp.delete();
        throw FileSystemException(
          tr('chmod 600 失败: ${r.stderr}', 'chmod 600 failed: ${r.stderr}'),
          tmp.path,
        );
      }
    }
    await tmp.rename(file.path);
  }
}

/// 按 `--server`（名字或 machineIdentifier，大小写不敏感）选账号下的服务器；
/// 不给时只有一台就用它。选不出返回 null。
PlexResource? pickPlexServer(List<PlexResource> servers, String? selector) {
  if (selector == null || selector.isEmpty) {
    return servers.length == 1 ? servers.single : null;
  }
  final String s = selector.toLowerCase();
  for (final PlexResource r in servers) {
    if (r.clientIdentifier.toLowerCase() == s || r.name.toLowerCase() == s) {
      return r;
    }
  }
  return null;
}

Map<String, Object?> plexMetadataToJson(PlexMetadata m) => <String, Object?>{
  'ratingKey': m.ratingKey,
  'type': m.type,
  'title': m.title,
  'year': m.year,
  'index': m.index,
  'parentTitle': m.parentTitle,
  'grandparentTitle': m.grandparentTitle,
  'leafCount': m.leafCount,
  'viewedLeafCount': m.viewedLeafCount,
  'durationMs': m.durationMs,
  'viewOffsetMs': m.viewOffsetMs,
  'viewCount': m.viewCount,
};

class MediaServerModule extends CliModule {
  const MediaServerModule({
    this.out,
    this.err,
    this.env,
    this.httpClient,
    this.delay,
  });

  final StringSink? out;
  final StringSink? err;

  /// 测试注入点：环境变量 / 出站客户端（缺省引擎的 `createAppHttpIoClient()`）/ 轮询等待。
  final Map<String, String>? env;
  final http.Client Function()? httpClient;
  final Future<void> Function(Duration)? delay;

  @override
  List<String> get commands => const <String>['media-server'];

  @override
  void register(ArgParser parser) {
    final ArgParser plex = parser.addCommand('media-server').addCommand('plex');
    plex
        .addCommand('login')
        .addOption(
          'timeout',
          help: tr('等待浏览器授权的分钟数', 'Minutes to wait for browser authorization'),
          defaultsTo: '10',
        );
    plex.addCommand('logout');
    plex
        .addCommand('status')
        .addFlag('json', negatable: false, help: tr('输出 JSON', 'Output JSON'));
    plex
        .addCommand('servers')
        .addFlag('json', negatable: false, help: tr('输出 JSON', 'Output JSON'));
    plex.addCommand('ls')
      ..addOption(
        'server',
        help: tr(
          '账号下的服务器名或 machineIdentifier（只有一台时可省）',
          'Server name or machineIdentifier under the account (optional when there is only one)',
        ),
      )
      ..addOption(
        'url',
        help: tr(
          '直连某台 PMS（token 取环境变量 $kPlexTokenEnv）',
          'Connect directly to a PMS (the token comes from the environment variable $kPlexTokenEnv)',
        ),
      )
      ..addOption(
        'section',
        help: tr(
          '列某个媒体库的条目（库 key）',
          'List the items of a library (library key)',
        ),
      )
      ..addOption(
        'start',
        help: tr('分页起点', 'Page start offset'),
        defaultsTo: '0',
      )
      ..addOption('size', help: tr('每页条数', 'Items per page'), defaultsTo: '60')
      ..addFlag('json', negatable: false, help: tr('输出 JSON', 'Output JSON'));
  }

  @override
  String get usage => tr(
    '''
media-server plex login [--timeout 10] | logout | status [--json] | servers [--json]
media-server plex ls [--server <name|id> | --url <pms>] [--section <key>] [<ratingKey>] [--json]
    Plex 账号 PIN 登录（在浏览器打开打印出的链接授权）与只读浏览：不带参数列媒体库，
    --section 列库内条目，<ratingKey> 列子级（剧 → 季 → 集）。--url 直连时 token 取
    环境变量 $kPlexTokenEnv。''',
    '''
media-server plex login [--timeout 10] | logout | status [--json] | servers [--json]
media-server plex ls [--server <name|id> | --url <pms>] [--section <key>] [<ratingKey>] [--json]
    Plex account PIN login (authorize in a browser via the printed link) and read-only browsing: without arguments it lists libraries,
    --section lists the items of a library, <ratingKey> lists children (show -> season -> episode). With --url the token comes from
    the environment variable $kPlexTokenEnv.''',
  );

  http.Client? _client() => httpClient?.call();

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final ArgResults? plex = command.command;
    final ArgResults? sub = plex?.command;
    if (plex == null || plex.name != 'plex' || sub == null) {
      e.writeln(
        tr(
          '用法: media-server plex login|logout|status|servers|ls …',
          'Usage: media-server plex login|logout|status|servers|ls …',
        ),
      );
      return _exitUsage;
    }
    if (sub.name == 'ls' && sub.rest.length > 1) {
      e.writeln(
        tr(
          '用法: media-server plex ls [--section <key>] [<ratingKey>]',
          'Usage: media-server plex ls [--section <key>] [<ratingKey>]',
        ),
      );
      return _exitUsage;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      final PlexCredentialStore store = PlexCredentialStore.under(
        rt.paths.support,
      );
      final PlexAccountCredential cred = await store.loadOrCreate();
      final PlexClientInfo info = PlexClientInfo(
        clientIdentifier: cred.clientIdentifier,
        deviceName: rt.config.deviceName,
      );
      try {
        switch (sub.name) {
          case 'login':
            return await _login(sub, store, cred, info, o, e);
          case 'logout':
            await store.save(
              PlexAccountCredential(clientIdentifier: cred.clientIdentifier),
            );
            o.writeln(
              cred.signedIn
                  ? tr(
                      '已退出 Plex 账号 ${cred.username ?? ''}',
                      'Signed out of the Plex account ${cred.username ?? ''}',
                    )
                  : tr('本来就没登录', 'Was not signed in'),
            );
            return _exitOk;
          case 'status':
            final Map<String, Object?> status = <String, Object?>{
              'signedIn': cred.signedIn,
              'username': cred.username,
              'clientIdentifier': cred.clientIdentifier,
            };
            o.writeln(
              sub['json'] as bool
                  ? jsonEncode(status)
                  : (cred.signedIn
                        ? tr(
                            '已登录: ${cred.username}',
                            'Signed in: ${cred.username}',
                          )
                        : tr(
                            '未登录（media-server plex login）',
                            'Not signed in (media-server plex login)',
                          )),
            );
            return _exitOk;
          case 'servers':
            if (!cred.signedIn) {
              e.writeln(
                tr(
                  '未登录 Plex：先 media-server plex login',
                  'Not signed in to Plex: run media-server plex login first',
                ),
              );
              return _exitUnavailable;
            }
            final PlexTvApi tv = PlexTvApi(clientInfo: info, client: _client());
            try {
              final List<PlexResource> servers = await tv.resources(
                cred.accountToken!,
              );
              _renderServers(servers, sub['json'] as bool, o);
              return _exitOk;
            } finally {
              tv.close();
            }
          case 'ls':
            return await _ls(sub, cred, info, o, e);
        }
        e.writeln(tr('未知动作: ${sub.name}', 'Unknown action: ${sub.name}'));
        return _exitUsage;
      } on PlexApiException catch (x) {
        if (x.statusCode == 401 || x.statusCode == 403) {
          e.writeln(
            tr(
              'Plex 拒绝了凭据（${x.statusCode}）：token 失效，重新 media-server plex login',
              'Plex rejected the credentials (${x.statusCode}): the token is no longer valid, run media-server plex login again',
            ),
          );
          return _exitUnavailable;
        }
        if (x.statusCode == 404) {
          e.writeln(tr('Plex 上找不到 ${x.path}', 'Not found on Plex: ${x.path}'));
          return _exitNoInput;
        }
        e.writeln(tr('Plex 请求失败: $x', 'Plex request failed: $x'));
        return _exitFailure;
      } on FormatException catch (x) {
        e.writeln(
          tr(
            'Plex 返回了无法解析的响应: ${x.message}',
            'Plex returned a response that could not be parsed: ${x.message}',
          ),
        );
        return _exitFailure;
      } on Exception catch (x) {
        // 引擎把 http.ClientException 包成凭据已脱敏的普通 Exception 再抛（断网 / 拒连 /
        // 超时）；能走到这里的都是传输层失败。
        e.writeln(tr('连不上 Plex: $x', 'Cannot reach Plex: $x'));
        return _exitUnavailable;
      }
    });
  }

  Future<int> _login(
    ArgResults sub,
    PlexCredentialStore store,
    PlexAccountCredential cred,
    PlexClientInfo info,
    StringSink o,
    StringSink e,
  ) async {
    final int? minutes = int.tryParse(sub['timeout'] as String);
    if (minutes == null || minutes < 1) {
      e.writeln(
        tr('--timeout 需要正整数分钟', '--timeout needs a positive number of minutes'),
      );
      return _exitUsage;
    }
    final PlexTvApi tv = PlexTvApi(clientInfo: info, client: _client());
    try {
      final PlexPin pin = await tv.createPin();
      o.writeln(
        tr(
          '在浏览器打开下面的链接登录并授权「${info.deviceName}」：',
          'Open the link below in a browser to sign in and authorize "${info.deviceName}":',
        ),
      );
      o.writeln(tv.authUrl(pin));
      e.writeln(
        tr(
          '等待授权（最多 $minutes 分钟）…',
          'Waiting for authorization (up to $minutes minutes) …',
        ),
      );
      final ({PlexPinPollOutcome outcome, String? token}) polled =
          await pollPlexPin(
            check: () => tv.checkPin(pin),
            isCancelled: () => false,
            timeout: Duration(minutes: minutes),
            delay: delay,
          );
      if (polled.outcome != PlexPinPollOutcome.authorized ||
          polled.token == null) {
        e.writeln(
          tr('PIN 已过期或超时，未登录', 'The PIN expired or timed out; not signed in'),
        );
        return _exitFailure;
      }
      final PlexTvUser user = await tv.user(polled.token!);
      await store.save(
        PlexAccountCredential(
          clientIdentifier: cred.clientIdentifier,
          accountToken: polled.token,
          username: user.username,
        ),
      );
      o.writeln(
        tr('已登录 Plex: ${user.username}', 'Signed in to Plex: ${user.username}'),
      );
      return _exitOk;
    } finally {
      tv.close();
    }
  }

  void _renderServers(List<PlexResource> servers, bool json, StringSink o) {
    if (json) {
      o.writeln(
        const JsonEncoder.withIndent('  ').convert(<Object?>[
          for (final PlexResource r in servers)
            <String, Object?>{
              'name': r.name,
              'id': r.clientIdentifier,
              'owned': r.owned,
              'connections': <Object?>[
                for (final PlexConnection c in orderPlexConnections(
                  r.connections,
                ))
                  <String, Object?>{
                    'uri': c.uri,
                    'local': c.local,
                    'relay': c.relay,
                  },
              ],
            },
        ]),
      );
      return;
    }
    if (servers.isEmpty) {
      o.writeln(tr('（账号下没有服务器）', '(No servers under this account)'));
    }
    for (final PlexResource r in servers) {
      o.writeln(
        tr(
          '${r.name}  ${r.clientIdentifier}${r.owned ? '' : '  (分享)'}  ${r.connections.length} 条连接',
          '${r.name}  ${r.clientIdentifier}${r.owned ? '' : '  (shared)'}  ${r.connections.length} connections',
        ),
      );
    }
  }

  /// 解出要连的 PMS：`--url` + 环境变量 token，或账号 resources 里选中的服务器。
  Future<(PlexApi?, int, String)> _resolveServer(
    ArgResults sub,
    PlexAccountCredential cred,
    PlexClientInfo info,
  ) async {
    final String? url = sub['url'] as String?;
    if (url != null) {
      final String token =
          (env ?? Platform.environment)[kPlexTokenEnv] ??
          cred.accountToken ??
          '';
      if (token.isEmpty) {
        return (
          null,
          _exitUnavailable,
          tr(
            '--url 直连需要环境变量 $kPlexTokenEnv（或先 login）',
            '--url direct connection needs the environment variable $kPlexTokenEnv (or log in first)',
          ),
        );
      }
      final String normalized = PlexApi.normalizeServerUrl(url);
      if (normalized.isEmpty) {
        return (
          null,
          _exitUsage,
          tr('--url 不是合法地址', '--url is not a valid address'),
        );
      }
      return (
        PlexApi(
          serverUrl: normalized,
          token: token,
          clientInfo: info,
          client: _client(),
        ),
        _exitOk,
        '',
      );
    }
    if (!cred.signedIn) {
      return (
        null,
        _exitUnavailable,
        tr(
          '未登录 Plex：先 media-server plex login，或用 --url 直连',
          'Not signed in to Plex: run media-server plex login first, or use --url to connect directly',
        ),
      );
    }
    final PlexTvApi tv = PlexTvApi(clientInfo: info, client: _client());
    final List<PlexResource> servers;
    try {
      servers = await tv.resources(cred.accountToken!);
    } finally {
      tv.close();
    }
    final String? selector = sub['server'] as String?;
    final PlexResource? server = pickPlexServer(servers, selector);
    if (server == null) {
      final String names = servers.map((PlexResource r) => r.name).join(', ');
      return (
        null,
        selector == null && servers.length > 1 ? _exitUsage : _exitNoInput,
        selector == null
            ? tr(
                '账号下有多台服务器（$names），用 --server 指定',
                'The account has several servers ($names); pick one with --server',
              )
            : tr(
                '账号下没有服务器「$selector」（有: $names）',
                'The account has no server "$selector" (available: $names)',
              ),
      );
    }
    final String token = server.accessToken ?? cred.accountToken!;
    final String? reachable = await firstReachablePlexConnection(
      orderPlexConnections(server.connections),
      (String uri) async {
        final PlexApi probe = PlexApi(
          serverUrl: uri,
          token: token,
          clientInfo: info,
          client: _client(),
        );
        try {
          return (await probe.identity()).isNotEmpty;
        } finally {
          probe.close();
        }
      },
    );
    if (reachable == null) {
      return (
        null,
        _exitUnavailable,
        tr(
          '服务器「${server.name}」的所有连接地址都连不上',
          'None of the connection addresses of server "${server.name}" is reachable',
        ),
      );
    }
    return (
      PlexApi(
        serverUrl: reachable,
        token: token,
        clientInfo: info,
        client: _client(),
      ),
      _exitOk,
      '',
    );
  }

  Future<int> _ls(
    ArgResults sub,
    PlexAccountCredential cred,
    PlexClientInfo info,
    StringSink o,
    StringSink e,
  ) async {
    final int? start = int.tryParse(sub['start'] as String);
    final int? size = int.tryParse(sub['size'] as String);
    final String? section = sub['section'] as String?;
    if (start == null ||
        start < 0 ||
        size == null ||
        size < 1 ||
        (section != null && sub.rest.isNotEmpty)) {
      e.writeln(
        tr(
          '--start 需 ≥0、--size 需 ≥1；--section 与 <ratingKey> 二选一',
          '--start must be >= 0 and --size must be >= 1; use either --section or <ratingKey>',
        ),
      );
      return _exitUsage;
    }
    final (PlexApi? api, int code, String why) = await _resolveServer(
      sub,
      cred,
      info,
    );
    if (api == null) {
      e.writeln(why);
      return code;
    }
    final bool json = sub['json'] as bool;
    try {
      if (section == null && sub.rest.isEmpty) {
        final List<PlexSection> sections = await api.sections();
        if (json) {
          o.writeln(
            const JsonEncoder.withIndent('  ').convert(<String, Object?>{
              'server': api.serverUrl,
              'sections': <Object?>[
                for (final PlexSection s in sections)
                  <String, Object?>{
                    'key': s.key,
                    'title': s.title,
                    'type': s.type,
                  },
              ],
            }),
          );
        } else {
          for (final PlexSection s in sections) {
            o.writeln('${s.key}  ${s.title}  (${s.type})');
          }
        }
        return _exitOk;
      }
      final PlexMetadataPage page = section != null
          ? await api.sectionItems(section, start: start, size: size)
          : await api.children(sub.rest.single, start: start, size: size);
      if (json) {
        o.writeln(
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'server': api.serverUrl,
            'start': start,
            'totalSize': page.totalSize,
            'items': <Object?>[
              for (final PlexMetadata m in page.items) plexMetadataToJson(m),
            ],
          }),
        );
      } else {
        for (final PlexMetadata m in page.items) {
          final String index = m.index == null ? '' : '#${m.index} ';
          o.writeln(
            '${m.ratingKey}  [${m.type}] $index${m.title}${m.year == null ? '' : ' (${m.year})'}',
          );
        }
        if (start + page.rawCount < page.totalSize) {
          o.writeln(
            tr(
              '… 共 ${page.totalSize} 条，下一页 --start ${start + page.rawCount}',
              '… ${page.totalSize} items in total, next page --start ${start + page.rawCount}',
            ),
          );
        }
      }
      return _exitOk;
    } finally {
      api.close();
    }
  }
}
