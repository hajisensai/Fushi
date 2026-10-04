/// `fushi_server ctl`：经 admin API 操作**正在运行**的 `fushi_server serve`。
///
/// 与其它子命令的分工：`scan` / `status` / `pair` 等是离线命令，直接开数据库，
/// 适合服务没跑的时候；`ctl` 只发 HTTP，不碰数据库、不起 host，适合服务在跑、
/// 想从脚本 / 另一台机器上改它的时候（扫描进度、下载队列、订阅、模型下载
/// 这些状态只活在运行中的进程里，离线命令看不到）。
///
/// ```
/// fushi_server ctl status
/// fushi_server ctl logs
/// fushi_server ctl pairing [ls] | pairing revoke <peerId>
/// fushi_server ctl libraries [ls] | libraries add <path> [--kind video|book] [--id x]
///                                 | libraries rm <id> [--purge]
/// fushi_server ctl scan [--prune | --no-prune]
/// fushi_server ctl jobs [ls] | jobs rm <id>
/// fushi_server ctl downloads [ls] | downloads add <magnet> --title t [--media-kind movie|tv]
///                                 | downloads cancel|retry|rm <id>
/// fushi_server ctl subscriptions [ls] | subscriptions add '<json>' | subscriptions check [id]
///                                     | subscriptions enable|disable|rm <id>
/// fushi_server ctl models [ls] | models pull <ja|en|…|ocr|ocr:key>
/// fushi_server ctl settings [get] | settings set '<json>'
/// fushi_server ctl resource-indexers [get] | resource-indexers set '<json>'
/// fushi_server ctl anki [status] | anki sync|refresh|run|retry | anki landing on|off
///                     | anki login --user u [--endpoint e] [--accept-ankiweb]（密码读 stdin）
///                     | anki logout [--discard-unsynced] | anki config '<json>'
/// fushi_server ctl profiles [ls] | profiles share|rm <id>
/// fushi_server ctl p2p
/// fushi_server ctl raw <GET|POST|PUT|DELETE> </api/admin/...> ['<json>']
/// ```
///
/// 公共选项：`--url` / `--token` / `--fingerprint` 覆盖配置推出的地址与凭据，
/// `--json` 原样输出服务端 JSON（脚本用）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/ctl/admin_client.dart';
import 'package:fushi_server/src/ctl/ctl_host_commands.dart';

/// `ctl` 子命令的参数表；所有动作的选项平铺在这一层（动词在 rest 里）。
ArgParser buildCtlParser() {
  final ArgParser parser = _buildBaseCtlParser();
  addCtlHostOptions(parser);
  return parser;
}

ArgParser _buildBaseCtlParser() => ArgParser()
  ..addOption('url', help: 'admin API 地址（缺省按配置推本机地址）')
  ..addOption('token', help: 'admin_token（缺省读配置）')
  ..addOption('fingerprint', help: 'TLS 证书 SHA-256 指纹（缺省读本机服务端证书）')
  ..addFlag('json', negatable: false, help: '原样输出服务端 JSON')
  ..addOption('kind', help: 'libraries add：库类型 video | book', defaultsTo: 'video')
  ..addOption('id', help: 'libraries add：库 id（缺省自动生成）')
  ..addFlag('purge', negatable: false, help: 'libraries rm：移除前回收文件已消失的条目')
  ..addFlag('prune', negatable: true, help: 'scan：回收文件已消失的条目（缺省读配置）')
  ..addOption('title', help: 'downloads add：任务标题')
  ..addOption('media-kind', help: 'downloads add：movie | tv', defaultsTo: 'movie')
  ..addOption('user', help: 'anki login：用户名')
  ..addOption('endpoint', help: 'anki login：自建同步服务器地址（缺省 AnkiWeb）')
  ..addFlag('accept-ankiweb', negatable: false, help: 'anki login：确认使用 AnkiWeb 的条款风险')
  ..addFlag('discard-unsynced', negatable: false, help: 'anki logout：丢弃未同步的卡片')
  ..addOption('lib', help: 'upload：目标库根 id')
  ..addOption('path', help: 'upload：库根下的相对目录（缺省放库根）')
  ..addFlag('follow', abbr: 'f', negatable: false, help: 'logs：持续输出新日志（Ctrl-C 退出）');

/// 短别名 → 规范动作名。
const Map<String, String> _aliases = <String, String>{
  'pair': 'pairing',
  'lib': 'libraries',
  'dl': 'downloads',
  'sub': 'subscriptions',
  'indexers': 'resource-indexers',
  'profile': 'profiles',
  'config': 'settings',
};

/// `ctl` 的用法说明。
const String kCtlUsage =
    '''
fushi_server ctl <action> [args] [--url u] [--token t] [--fingerprint fp] [--json]

  status                                   运行状态
  logs [-f|--follow]                       最近日志（-f 持续跟随）
  pairing [ls] | revoke <peerId>           已配对设备 / 待确认 PIN
  libraries [ls] | add <path> [--kind video|book] [--id x] | rm <id> [--purge]
  scan [--prune|--no-prune]                触发一次库扫描（后台进行）
  jobs [ls] | rm <id>                      通用任务（ASR 等）
  downloads [ls] | add <magnet> --title t [--media-kind movie|tv] | cancel|retry|rm <id>
  subscriptions [ls] | add '<json>' | check [id] | enable|disable|rm <id>
  models [ls] | pull <语言 tag|ocr|ocr:key>
  settings [get] | set '<json>'
  resource-indexers [get] | set '<json>'
  anki [status] | sync | refresh | run | retry | landing on|off | config '<json>'
       login --user u [--endpoint e] [--accept-ankiweb]   密码从 stdin 或 FUSHI_ANKI_PASSWORD 读
       logout [--discard-unsynced]
  profiles [ls] | share|rm <id>
  p2p                                      P2P 隧道状态
  upload <文件…> --lib <id> [--path <目录>] 分块断点续传到库根（传完记得 scan）
  raw <METHOD> </api/admin/...> ['<json>'] 直接调任意 admin 接口
$kCtlHostUsage

  别名：pair=pairing lib=libraries dl=downloads sub=subscriptions
        indexers=resource-indexers profile=profiles config=settings''';

/// 读配置、建客户端、执行一条 `ctl` 动作。退出码见 [runCtlAction]。
Future<int> runCtl(File configFile, ArgResults command, {StringSink? out, StringSink? err}) async {
  final StringSink o = out ?? stdout;
  final StringSink e = err ?? stderr;
  final String? url = command['url'] as String?;
  final ServerConfig config;
  if (await configFile.exists()) {
    try {
      config = await ServerConfig.load(configFile);
    } on FormatException catch (ex) {
      e.writeln('配置文件解析失败: ${ex.message}');
      return 65;
    }
  } else if (url != null && command['token'] != null) {
    // 远程用法：地址与凭据都显式给了，不需要本机配置。
    config = ServerConfig.defaults(dataDir: configFile.parent.path);
  } else {
    e.writeln('找不到配置文件 ${configFile.path}；用 --config 指定，或同时给 --url 与 --token');
    return 66;
  }
  final AdminClient client;
  try {
    client = await AdminClient.fromConfig(
      config,
      url: url,
      token: command['token'] as String?,
      fingerprint: command['fingerprint'] as String?,
    );
  } on AdminApiException catch (ex) {
    e.writeln(ex.message);
    return 69;
  } on FormatException catch (ex) {
    e.writeln('无效的 --url: ${ex.message}');
    return 64;
  }
  try {
    return await runCtlAction(client, command, out: o, err: e);
  } finally {
    client.close();
  }
}

/// 对一个现成的 [client] 执行 [command] 里的动作。
///
/// 退出码：0 成功；1 服务端拒绝（4xx/5xx，或返回 `ok: false`）；64 用法错误；
/// 69 连不上服务；75 冲突（409，状态变了再试）；77 鉴权失败（401）。
///
/// [readSecret] 读机密（Anki 密码），缺省先看环境变量再读 stdin 一行；
/// 机密绝不经 argv（会进 shell 历史与 `ps`）。
Future<int> runCtlAction(
  AdminClient client,
  ArgResults command, {
  required StringSink out,
  required StringSink err,
  String? Function(String envName)? readSecret,
  int uploadChunkBytes = kCtlUploadChunkBytes,
  Duration followInterval = const Duration(seconds: 2),
  bool Function()? keepFollowing,
}) async {
  final List<String> rest = command.rest;
  if (rest.isEmpty) {
    err.writeln(kCtlUsage);
    return 64;
  }
  // 多请求的动作单独走，不进「一个动作 = 一个请求」的表。
  if (rest.first == 'upload') {
    return _upload(client, command, out: out, err: err, chunkBytes: uploadChunkBytes);
  }
  if (rest.first == 'jobs') {
    final Future<int>? jobs = runCtlJobsAction(client, command, out: out, err: err, exitCodeFor: _exitCodeFor);
    if (jobs != null) return jobs;
  }
  if (rest.first == 'logs' && command['follow'] as bool) {
    return _followLogs(client, out: out, err: err, interval: followInterval, keepGoing: keepFollowing ?? () => true);
  }
  final _CtlRequest? request = kCtlHostActions.contains(rest.first)
      ? _fromHost(parseCtlHostAction(rest, command, err))
      : _parseAction(rest, command, err, readSecret ?? _readSecretDefault);
  if (request == null) return 64;
  final Object? response;
  try {
    response = await client.send(request.method, request.path, body: request.body, query: request.query);
  } on AdminApiException catch (ex) {
    err.writeln('${request.method} ${request.path} 失败: $ex');
    if (command['json'] as bool && ex.body != null) out.writeln(_pretty(ex.body));
    return _exitCodeFor(ex);
  }
  if (command['json'] as bool) {
    out.writeln(_pretty(response));
  } else {
    request.render(response, out);
  }
  if (response is Map && response['ok'] == false) return 1;
  return 0;
}

_CtlRequest? _fromHost(CtlHostRequest? r) {
  if (r == null) return null;
  final String? key = r.listKey;
  return _CtlRequest(
    r.method,
    r.path,
    body: r.body,
    query: r.query == null || r.query!.isEmpty ? null : r.query,
    render: key == null
        ? null
        : key.isEmpty
        ? (Object? response, StringSink out) =>
              response is List ? _renderRows(response, out) : _renderGeneric(response, out)
        : _listRenderer(key),
  );
}

int _exitCodeFor(AdminApiException ex) => switch (ex.status) {
  0 => 69,
  401 => 77,
  409 => 75,
  _ => 1,
};

/// 与 WebUI 同一块大小（web_ui.dart 的 `CHUNK`）。
const int kCtlUploadChunkBytes = 8 * 1024 * 1024;

/// `ctl upload`：按 README「上传协议」分块 PUT，先 GET 已收字节数实现断点续传。
Future<int> _upload(
  AdminClient client,
  ArgResults command, {
  required StringSink out,
  required StringSink err,
  required int chunkBytes,
}) async {
  final List<String> files = command.rest.sublist(1);
  final String? library = command['lib'] as String?;
  if (files.isEmpty || library == null || library.trim().isEmpty) {
    err.writeln('用法: fushi_server ctl upload <文件…> --lib <库根 id> [--path <目录>]');
    return 64;
  }
  final String dir = ((command['path'] as String?) ?? '').replaceAll(RegExp(r'^/+|/+$'), '');
  for (final String local in files) {
    if (!File(local).existsSync()) {
      err.writeln('找不到文件: $local');
      return 66;
    }
  }
  final List<Map<String, Object?>> results = <Map<String, Object?>>[];
  for (final String local in files) {
    final File file = File(local);
    final String name = file.uri.pathSegments.last;
    final String rel = dir.isEmpty ? name : '$dir/$name';
    final Map<String, String> query = <String, String>{'library': library.trim(), 'path': rel};
    try {
      final int size = await file.length();
      final Object? status = await client.get('$_api/upload', query: query);
      int offset = status is Map && status['received'] is int ? status['received'] as int : 0;
      if (size == 0) {
        await client.sendBytes(
          'PUT',
          '$_api/upload',
          query: query,
          bytes: const <int>[],
          headers: const <String, String>{'Content-Range': 'bytes 0-0/0'},
        );
      } else if (offset >= size) {
        err.writeln('$rel: 服务端已有完整文件，跳过');
      } else {
        final RandomAccessFile raf = await file.open();
        try {
          while (offset < size) {
            final int end = offset + chunkBytes < size ? offset + chunkBytes : size;
            await raf.setPosition(offset);
            final List<int> chunk = await raf.read(end - offset);
            final Object? r = await client.sendBytes(
              'PUT',
              '$_api/upload',
              query: query,
              bytes: chunk,
              headers: <String, String>{'Content-Range': 'bytes $offset-${end - 1}/$size'},
            );
            final Object? received = r is Map ? r['received'] : null;
            if (received is! int || received <= offset) {
              throw AdminApiException(1, '服务端没有推进已收字节数（$received），停止以免死循环');
            }
            offset = received;
            err.write('\r$rel  ${(offset * 100 / size).toStringAsFixed(1)}%   ');
            if (r is Map && r['complete'] == true) break;
          }
          err.writeln();
        } finally {
          await raf.close();
        }
      }
      results.add(<String, Object?>{'file': local, 'path': rel, 'bytes': size});
      if (!(command['json'] as bool)) out.writeln('已上传 $local → $library:$rel');
    } on AdminApiException catch (ex) {
      err.writeln('\n$rel 上传失败: $ex');
      return _exitCodeFor(ex);
    }
  }
  if (command['json'] as bool) out.writeln(_pretty(<String, Object?>{'uploaded': results}));
  return 0;
}

/// `ctl logs -f`：轮询 `/logs`，只打印新出现的行。
Future<int> _followLogs(
  AdminClient client, {
  required StringSink out,
  required StringSink err,
  required Duration interval,
  required bool Function() keepGoing,
}) async {
  List<String> previous = const <String>[];
  while (true) {
    final Object? response;
    try {
      response = await client.get('$_api/logs');
    } on AdminApiException catch (ex) {
      err.writeln('GET $_api/logs 失败: $ex');
      return _exitCodeFor(ex);
    }
    final Object? raw = response is Map ? response['lines'] : null;
    final List<String> current = raw is List ? raw.map((Object? l) => '$l').toList() : const <String>[];
    for (final String line in newLogLines(previous, current)) {
      out.writeln(line);
    }
    previous = current;
    if (!keepGoing()) return 0;
    await Future<void>.delayed(interval);
  }
}

/// 服务端日志是滑动窗口（最近 N 行）：找 [previous] 的最长后缀与 [current] 的前缀重合，
/// 重合之后的就是新行。没有重合（两次轮询之间滚过了整个窗口）就全部算新。
List<String> newLogLines(List<String> previous, List<String> current) {
  final int maxOverlap = previous.length < current.length ? previous.length : current.length;
  for (int k = maxOverlap; k > 0; k--) {
    bool same = true;
    for (int i = 0; i < k; i++) {
      if (previous[previous.length - k + i] != current[i]) {
        same = false;
        break;
      }
    }
    if (same) return current.sublist(k);
  }
  return current;
}

typedef _Render = void Function(Object? response, StringSink out);

class _CtlRequest {
  const _CtlRequest(this.method, this.path, {this.body, this.query, _Render? render})
    : render = render ?? _renderGeneric;

  final String method;
  final String path;
  final Object? body;
  final Map<String, String>? query;
  final _Render render;
}

const String _api = '/api/admin';

/// 把动词 + 参数翻成一个请求；用法不对时写 [err] 并返回 null。
_CtlRequest? _parseAction(
  List<String> rest,
  ArgResults command,
  StringSink err,
  String? Function(String envName) readSecret,
) {
  final String action = _aliases[rest.first] ?? rest.first;
  final String sub = rest.length > 1 ? rest[1] : '';
  final List<String> args = rest.length > 2 ? rest.sublist(2) : const <String>[];

  _CtlRequest? usage(String text) {
    err.writeln('用法: fushi_server ctl $text');
    return null;
  }

  String? arg(int i) => i < args.length ? args[i] : null;

  switch (action) {
    case 'status':
      return const _CtlRequest('GET', '$_api/status', render: _renderStatus);
    case 'logs':
      return const _CtlRequest('GET', '$_api/logs', render: _renderLogs);
    case 'p2p':
      return const _CtlRequest('GET', '$_api/p2p');

    case 'pairing':
      switch (sub) {
        case '' || 'ls':
          return const _CtlRequest('GET', '$_api/pairing', render: _renderPairing);
        case 'revoke' when arg(0) != null:
          return _CtlRequest('DELETE', '$_api/pairing/peers/${adminPathSegment(arg(0)!)}');
      }
      return usage('pairing [ls] | pairing revoke <peerId>');

    case 'libraries':
      switch (sub) {
        case '' || 'ls':
          return _list('GET', '$_api/libraries', 'libraries');
        case 'add' when arg(0) != null:
          return _CtlRequest(
            'POST',
            '$_api/libraries',
            body: <String, Object?>{
              'path': arg(0),
              'kind': command['kind'] as String,
              if (command['id'] != null) 'id': command['id'] as String,
            },
            render: _listRenderer('libraries'),
          );
        case 'rm' when arg(0) != null:
          return _CtlRequest(
            'DELETE',
            '$_api/libraries/${adminPathSegment(arg(0)!)}',
            query: command['purge'] as bool ? const <String, String>{'purge': 'true'} : null,
            render: _listRenderer('libraries'),
          );
      }
      return usage('libraries [ls] | libraries add <path> [--kind video|book] [--id x] | libraries rm <id> [--purge]');

    case 'scan':
      return _CtlRequest(
        'POST',
        '$_api/scan',
        body: <String, Object?>{if (command.wasParsed('prune')) 'prune': command['prune'] as bool},
      );

    case 'jobs':
      switch (sub) {
        case '' || 'ls':
          return _list('GET', '$_api/jobs', 'jobs');
        case 'rm' when arg(0) != null:
          return _CtlRequest('DELETE', '$_api/jobs/${adminPathSegment(arg(0)!)}');
      }
      return usage('jobs [ls] | jobs rm <id>');

    case 'downloads':
      switch (sub) {
        case '' || 'ls':
          return _list('GET', '$_api/downloads', 'jobs');
        case 'add' when arg(0) != null:
          final String? title = command['title'] as String?;
          if (title == null || title.trim().isEmpty) return usage('downloads add <magnet> --title <标题>');
          return _CtlRequest(
            'POST',
            '$_api/downloads',
            body: <String, Object?>{'magnet': arg(0), 'title': title, 'mediaKind': command['media-kind'] as String},
          );
        case 'cancel' || 'retry' when arg(0) != null:
          return _CtlRequest('POST', '$_api/downloads/${adminPathSegment(arg(0)!)}/$sub');
        case 'rm' when arg(0) != null:
          return _CtlRequest('DELETE', '$_api/downloads/${adminPathSegment(arg(0)!)}');
      }
      return usage('downloads [ls] | downloads add <magnet> --title t | downloads cancel|retry|rm <id>');

    case 'subscriptions':
      switch (sub) {
        case '' || 'ls':
          return _list('GET', '$_api/subscriptions', 'subscriptions');
        case 'add' when arg(0) != null:
          final Object? body = _jsonArg(arg(0)!, err);
          return body == null ? null : _CtlRequest('POST', '$_api/subscriptions', body: body);
        case 'check':
          return _CtlRequest(
            'POST',
            arg(0) == null ? '$_api/subscriptions/check' : '$_api/subscriptions/${adminPathSegment(arg(0)!)}/check',
          );
        case 'enable' || 'disable' when arg(0) != null:
          return _CtlRequest(
            'POST',
            '$_api/subscriptions/${adminPathSegment(arg(0)!)}/enable',
            body: <String, Object?>{'enabled': sub == 'enable'},
          );
        case 'rm' when arg(0) != null:
          return _CtlRequest('DELETE', '$_api/subscriptions/${adminPathSegment(arg(0)!)}');
      }
      return usage(
        "subscriptions [ls] | subscriptions add '<json>' | subscriptions check [id] | "
        'subscriptions enable|disable|rm <id>',
      );

    case 'models':
      switch (sub) {
        case '' || 'ls':
          return const _CtlRequest('GET', '$_api/models', render: _renderModels);
        case 'pull' when arg(0) != null:
          return _CtlRequest('POST', '$_api/models/pull', body: <String, Object?>{'model': arg(0)});
      }
      return usage('models [ls] | models pull <语言 tag|ocr|ocr:key>');

    case 'settings' || 'resource-indexers':
      switch (sub) {
        case '' || 'get':
          return _CtlRequest('GET', '$_api/$action');
        case 'set' when arg(0) != null:
          final Object? body = _jsonArg(arg(0)!, err);
          return body == null ? null : _CtlRequest('PUT', '$_api/$action', body: body);
      }
      return usage("$action [get] | $action set '<json>'");

    case 'anki':
      switch (sub) {
        case '' || 'status':
          return const _CtlRequest('GET', '$_api/anki');
        case 'sync' || 'refresh' || 'run' || 'retry':
          return _CtlRequest('POST', '$_api/anki/$sub');
        case 'landing' when arg(0) == 'on' || arg(0) == 'off':
          return _CtlRequest('POST', '$_api/anki/landing', body: <String, Object?>{'enabled': arg(0) == 'on'});
        case 'config' when arg(0) != null:
          final Object? body = _jsonArg(arg(0)!, err);
          return body == null ? null : _CtlRequest('PUT', '$_api/anki/settings', body: body);
        case 'logout':
          return _CtlRequest(
            'POST',
            '$_api/anki/logout',
            body: <String, Object?>{'discardUnsynced': command['discard-unsynced'] as bool},
          );
        case 'login':
          final String? user = command['user'] as String?;
          if (user == null || user.trim().isEmpty) {
            return usage('anki login --user <用户名> [--endpoint <url>] [--accept-ankiweb]');
          }
          final String? password = readSecret('FUSHI_ANKI_PASSWORD');
          if (password == null || password.isEmpty) {
            err.writeln('没有读到密码：经 stdin 传入，或设置 FUSHI_ANKI_PASSWORD');
            return null;
          }
          return _CtlRequest(
            'POST',
            '$_api/anki/login',
            body: <String, Object?>{
              'username': user.trim(),
              'password': password,
              if (command['endpoint'] != null) 'endpoint': command['endpoint'] as String,
              if (command['accept-ankiweb'] as bool) 'acceptAnkiWeb': true,
            },
          );
      }
      return usage(
        'anki [status] | anki sync|refresh|run|retry | anki landing on|off | '
        "anki config '<json>' | anki login --user u | anki logout [--discard-unsynced]",
      );

    case 'profiles':
      switch (sub) {
        case '' || 'ls':
          return _list('GET', '$_api/profiles', 'profiles');
        case 'share' when arg(0) != null:
          return _CtlRequest(
            'POST',
            '$_api/profiles/${adminPathSegment(arg(0)!)}/share',
            render: _listRenderer('profiles'),
          );
        case 'rm' when arg(0) != null:
          return _CtlRequest(
            'DELETE',
            '$_api/profiles/${adminPathSegment(arg(0)!)}',
            render: _listRenderer('profiles'),
          );
      }
      return usage('profiles [ls] | profiles share|rm <id>');

    case 'raw':
      final String method = sub.toUpperCase();
      final String? path = arg(0);
      if (!const <String>{'GET', 'POST', 'PUT', 'DELETE'}.contains(method) ||
          path == null ||
          !path.startsWith('$_api/')) {
        return usage("raw <GET|POST|PUT|DELETE> </api/admin/...> ['<json>']");
      }
      Object? body;
      if (arg(1) != null) {
        body = _jsonArg(arg(1)!, err);
        if (body == null) return null;
      }
      final Uri parsed = Uri.parse(path);
      return _CtlRequest(
        method,
        parsed.path,
        body: body,
        query: parsed.queryParameters.isEmpty ? null : parsed.queryParameters,
      );
  }
  err.writeln('未知动作 "$action"\n');
  err.writeln(kCtlUsage);
  return null;
}

String? _readSecretDefault(String envName) {
  final String? env = Platform.environment[envName];
  if (env != null && env.isNotEmpty) return env;
  if (stdin.hasTerminal) {
    stderr.write('密码: ');
    stdin.echoMode = false;
    try {
      return stdin.readLineSync();
    } finally {
      stdin.echoMode = true;
      stderr.writeln();
    }
  }
  return stdin.readLineSync();
}

_CtlRequest _list(String method, String path, String key) => _CtlRequest(method, path, render: _listRenderer(key));

Object? _jsonArg(String text, StringSink err) {
  try {
    final Object? decoded = jsonDecode(text);
    if (decoded is Map) return decoded;
    err.writeln('要求 JSON 对象: $text');
  } on FormatException catch (e) {
    err.writeln('JSON 解析失败: ${e.message}');
  }
  return null;
}

// ── 输出 ───────────────────────────────────────────────────────────────

String _pretty(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

String _scalar(Object? value) => switch (value) {
  null => '-',
  String() || num() || bool() => '$value',
  _ => jsonEncode(value),
};

void _renderGeneric(Object? response, StringSink out) {
  if (response is Map && response.length == 1 && response['ok'] == true) {
    out.writeln('ok');
  } else if (response is Map) {
    _renderKeyValues(response, out);
  } else if (response != null) {
    out.writeln(_pretty(response));
  }
}

void _renderKeyValues(Map<dynamic, dynamic> map, StringSink out) {
  if (map.isEmpty) return;
  final int width = map.keys.map((Object? k) => '$k'.length).reduce((int a, int b) => a > b ? a : b);
  map.forEach((Object? key, Object? value) {
    out.writeln('${'$key:'.padRight(width + 2)}${_scalar(value)}');
  });
}

void _renderStatus(Object? response, StringSink out) {
  if (response is! Map) return _renderGeneric(response, out);
  _renderKeyValues(response, out);
}

void _renderLogs(Object? response, StringSink out) {
  final Object? lines = response is Map ? response['lines'] : null;
  if (lines is! List) return _renderGeneric(response, out);
  for (final Object? line in lines) {
    out.writeln('$line');
  }
}

void _renderPairing(Object? response, StringSink out) {
  if (response is! Map) return _renderGeneric(response, out);
  final Object? pending = response['pending'];
  if (pending is Map) {
    out.writeln(
      '待确认: PIN ${pending['pin']}  ${_scalar(pending['deviceName'])}  '
      '${_scalar(pending['remoteAddress'])}',
    );
  }
  _listRenderer('peers')(response, out);
}

void _renderModels(Object? response, StringSink out) {
  if (response is! Map) return _renderGeneric(response, out);
  out.writeln('ASR:');
  _renderRows(response['asr'], out, idKeys: const <String>['tag']);
  out.writeln('OCR:');
  _renderRows(response['ocrModels'], out, idKeys: const <String>['key']);
}

/// 渲染 `{<key>: [...]}` 形状的列表响应；其余字段（capability 之类）不展开，`--json` 可看全量。
_Render _listRenderer(String key) => (Object? response, StringSink out) {
  if (response is Map && response['error'] != null) out.writeln('! ${response['error']}');
  final Object? rows = response is Map ? response[key] : null;
  if (rows is! List) return _renderGeneric(response, out);
  _renderRows(rows, out);
  if (response is Map && response['purge'] is Map) {
    out.writeln('purge: ${jsonEncode(response['purge'])}');
  }
};

const List<String> _idKeys = <String>['id', 'jobId', 'subscriptionId', 'peerId', 'profileId', 'tag', 'key'];
const List<String> _labelKeys = <String>['title', 'name', 'deviceName', 'path', 'query'];
const List<String> _stateKeys = <String>['state', 'status', 'phase', 'kind', 'ready', 'enabled'];

void _renderRows(Object? rows, StringSink out, {List<String> idKeys = _idKeys}) {
  if (rows is! List || rows.isEmpty) {
    out.writeln('  （空）');
    return;
  }
  for (final Object? row in rows) {
    if (row is! Map) {
      out.writeln('  ${_scalar(row)}');
      continue;
    }
    String? pick(List<String> keys) {
      for (final String k in keys) {
        final Object? v = row[k];
        // 布尔状态写成词，`[false]` 看不出是哪个字段。
        if (v is bool) return k == 'ready' ? (v ? 'ready' : 'missing') : (v ? k : 'no-$k');
        if (v != null) return '$v';
      }
      return null;
    }

    final List<String> cells = <String>[
      pick(idKeys) ?? '-',
      if (pick(_stateKeys) case final String state) '[$state]',
      if (pick(_labelKeys) case final String label) label,
      if (row['error'] != null) '! ${row['error']}',
    ];
    out.writeln('  ${cells.join('  ')}');
  }
}
