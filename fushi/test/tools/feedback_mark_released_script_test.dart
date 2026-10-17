import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 反馈发布回填脚本 `tool/feedback_mark_released.sh` 的离线测试。
///
/// 跑的是**真脚本**：本地临时 git 仓库造出「本构建包含的修复」（祖先）、「另一条分支上
/// 的修复」（非祖先）与「本 checkout 不认识的 sha」，再在 127.0.0.1 起一个假的反馈服务
/// （GET pending / POST released），断言只有祖先被回填、通道按契约映射、任何失败都不让
/// 发布变红（退出码恒 0，只打 ::warning / ::notice）。
///
/// 写法照 update_manifest_publish_race_test.dart（真脚本 + 本地 bare 仓库）。
void main() {
  // 相对路径字面量 `../tool/…` 让 ci-config-gate.yml 的磁盘枚举把本测试收进去。
  final File script = File('../tool/feedback_mark_released.sh').absolute;

  setUpAll(() {
    expect(script.existsSync(), isTrue, reason: '缺 ${script.path}');
  });

  test('脚本骨架：失败不外溢、curl 带超时、token 不进进程参数', () {
    final String src = script.readAsStringSync();
    expect(src, contains('set -uo pipefail'));
    expect(
      src,
      isNot(contains('set -e')),
      reason: '任何失败都只能 ::warning，set -e 会让脚本半路以非 0 退出',
    );
    expect(
      src.trimRight().endsWith('exit 0'),
      isTrue,
      reason: '脚本最后一行必须是 exit 0：回填失败绝不能让发布变红',
    );
    expect(
      '--max-time'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: 'GET 与 POST 两次 curl 都要带超时',
    );
    expect(
      src,
      contains(r'-H "@$header_file"'),
      reason: 'token 走 header 文件，不出现在 curl 的命令行参数里',
    );
    expect(
      src,
      contains(r'git cat-file -e "${sha}^{commit}"'),
      reason: '祖先判断前先确认 checkout 认识这个提交',
    );
    expect(src, contains(r'git merge-base --is-ancestor "$sha" "$head_sha"'));
  });

  group('真脚本 + 假反馈服务', () {
    late _Repo repo;
    late _FakeFeedbackApi api;

    setUp(() async {
      repo = await _Repo.create();
      api = await _FakeFeedbackApi.start();
    });

    tearDown(() async {
      await api.close();
      await repo.dispose();
    });

    test('formal → stable；只回填祖先，非祖先 / 未知 / 畸形 sha 一律跳过', () async {
      api.pendingBody = jsonEncode(<String, Object>{
        'items': <Map<String, String>>[
          <String, String>{'id': 'fixInBuild1', 'sha': repo.fixInBuild},
          <String, String>{'id': 'fixOnSide01', 'sha': repo.fixOnSide},
          <String, String>{'id': 'unknownSha1', 'sha': 'a' * 40},
          <String, String>{'id': 'badShape001', 'sha': 'not-a-sha'},
          <String, String>{'id': 'x', 'sha': repo.fixInBuild},
        ],
      });

      final ProcessResult r = await _run(script, repo, api, channel: 'formal');

      expect(r.exitCode, 0, reason: _io(r));
      expect(api.requests.first.method, 'GET');
      expect(api.requests.first.uri.path, '/v1/ci/feedback/pending');
      expect(api.requests.first.uri.queryParameters, <String, String>{
        'channel': 'stable',
        'platform': 'windows',
      });
      expect(api.requests.first.authorization, 'Bearer test-token');

      final List<_Req> posts = api.requests
          .where((_Req q) => q.method == 'POST')
          .toList();
      expect(posts, hasLength(1), reason: _io(r));
      expect(posts.single.uri.path, '/v1/ci/feedback/released');
      expect(posts.single.authorization, 'Bearer test-token');
      expect(jsonDecode(posts.single.body), <String, Object>{
        'channel': 'stable',
        'platform': 'windows',
        'version': '2.3.0',
        'ids': <Map<String, String>>[
          <String, String>{'id': 'fixInBuild1', 'sha': repo.fixInBuild},
        ],
      });
      expect(r.stdout, contains('skip fixOnSide01'));
      expect(r.stdout, contains('skip unknownSha1'));
      expect(r.stdout, isNot(contains('badShape001')));
      expect(r.stdout, isNot(contains('::warning')), reason: _io(r));
    });

    test('通道映射：debug / beta 原样，github-release / stable → stable', () async {
      api.pendingBody = '{"items": []}';
      final Map<String, String> expected = <String, String>{
        'debug': 'debug',
        'beta': 'beta',
        'github-release': 'stable',
        'stable': 'stable',
      };
      for (final MapEntry<String, String> e in expected.entries) {
        api.requests.clear();
        final ProcessResult r = await _run(script, repo, api, channel: e.key);
        expect(r.exitCode, 0, reason: _io(r));
        expect(api.requests, hasLength(1), reason: _io(r));
        expect(
          api.requests.single.uri.queryParameters['channel'],
          e.value,
          reason: 'CHANNEL=${e.key}',
        );
      }
    });

    test('多个祖先一次 POST（大写 sha 也认、原样带回）；没有包含的修复就不 POST', () async {
      api.pendingBody = jsonEncode(<String, Object>{
        'items': <Map<String, String>>[
          <String, String>{'id': 'fixInBuild1', 'sha': repo.fixInBuild},
          <String, String>{'id': 'rootFix0001', 'sha': repo.root.toUpperCase()},
        ],
      });
      final ProcessResult r = await _run(script, repo, api, channel: 'debug');
      expect(r.exitCode, 0, reason: _io(r));
      final _Req post = api.requests.singleWhere(
        (_Req q) => q.method == 'POST',
      );
      // 每条带回 pending 给的 sha：服务端只在 fix_sha 仍等于它时写入，
      // 防止「拉 pending 之后、回填之前被重新标记」的竞态。
      expect(
        (jsonDecode(post.body) as Map<String, dynamic>)['ids'],
        <Map<String, String>>[
          <String, String>{'id': 'fixInBuild1', 'sha': repo.fixInBuild},
          <String, String>{'id': 'rootFix0001', 'sha': repo.root.toUpperCase()},
        ],
      );

      api
        ..requests.clear()
        ..pendingBody = jsonEncode(<String, Object>{
          'items': <Map<String, String>>[
            <String, String>{'id': 'fixOnSide01', 'sha': repo.fixOnSide},
          ],
        });
      final ProcessResult none = await _run(
        script,
        repo,
        api,
        channel: 'debug',
      );
      expect(none.exitCode, 0, reason: _io(none));
      expect(api.requests.where((_Req q) => q.method == 'POST'), isEmpty);
    });

    test('--dry-run 只打印、不 POST', () async {
      api.pendingBody = jsonEncode(<String, Object>{
        'items': <Map<String, String>>[
          <String, String>{'id': 'fixInBuild1', 'sha': repo.fixInBuild},
        ],
      });
      final ProcessResult r = await _run(
        script,
        repo,
        api,
        channel: 'beta',
        args: <String>['--dry-run'],
      );
      expect(r.exitCode, 0, reason: _io(r));
      expect(r.stdout, contains('DRY RUN'));
      expect(r.stdout, contains('fixInBuild1'));
      expect(api.requests.where((_Req q) => q.method == 'POST'), isEmpty);
    });

    test('没配 token：::notice 后退出，一个请求都不发', () async {
      final ProcessResult r = await _run(
        script,
        repo,
        api,
        channel: 'debug',
        token: '',
      );
      expect(r.exitCode, 0, reason: _io(r));
      expect(r.stdout, contains('::notice'));
      expect(api.requests, isEmpty);
    });

    test('不是更新通道 / HEAD_SHA 不认识：跳过，不发请求', () async {
      final ProcessResult channel = await _run(
        script,
        repo,
        api,
        channel: 'nightly',
      );
      expect(channel.exitCode, 0, reason: _io(channel));
      expect(channel.stdout, contains('::notice'));

      final ProcessResult head = await _run(
        script,
        repo,
        api,
        channel: 'debug',
        headSha: 'b' * 40,
      );
      expect(head.exitCode, 0, reason: _io(head));
      expect(head.stdout, contains('::warning'));
      expect(api.requests, isEmpty);
    });

    test('接口 5xx / JSON 坏 / 端点不可达 / POST 失败：只 ::warning，退出码 0', () async {
      api.pendingStatus = 500;
      final ProcessResult e500 = await _run(
        script,
        repo,
        api,
        channel: 'debug',
      );
      expect(e500.exitCode, 0, reason: _io(e500));
      expect(e500.stdout, contains('::warning'));
      expect(api.requests.where((_Req q) => q.method == 'POST'), isEmpty);

      api
        ..pendingStatus = 200
        ..pendingBody = '<html>not json';
      final ProcessResult bad = await _run(script, repo, api, channel: 'debug');
      expect(bad.exitCode, 0, reason: _io(bad));
      expect(bad.stdout, contains('::warning'));

      api
        ..pendingBody = jsonEncode(<String, Object>{
          'items': <Map<String, String>>[
            <String, String>{'id': 'fixInBuild1', 'sha': repo.fixInBuild},
          ],
        })
        ..releasedStatus = 503;
      final ProcessResult postFail = await _run(
        script,
        repo,
        api,
        channel: 'debug',
      );
      expect(postFail.exitCode, 0, reason: _io(postFail));
      expect(postFail.stdout, contains('::warning'));

      final String deadBase = api.baseUrl;
      await api.close();
      final ProcessResult down = await _run(
        script,
        repo,
        api,
        channel: 'debug',
        apiBase: deadBase,
      );
      expect(down.exitCode, 0, reason: _io(down));
      expect(down.stdout, contains('::warning'));
    });
  });
}

String _io(ProcessResult r) =>
    'exit=${r.exitCode}\nstdout=${r.stdout}\nstderr=${r.stderr}';

/// Windows 上 `Process.start('bash')` 先命中 System32 的 WSL bash（路径、git 全对不上），
/// 所以顺着 git 的安装位置找 Git Bash。
String _bashExecutable() {
  if (!Platform.isWindows) return 'bash';
  final ProcessResult where = Process.runSync('where', <String>['git']);
  for (final String line in (where.stdout as String).split(RegExp(r'\r?\n'))) {
    final String gitPath = line.trim();
    if (gitPath.isEmpty) continue;
    Directory dir = File(gitPath).parent;
    for (int i = 0; i < 3; i++) {
      final File bash = File(p.join(dir.path, 'bin', 'bash.exe'));
      if (bash.existsSync()) return bash.path;
      dir = dir.parent;
    }
  }
  return 'bash';
}

Future<ProcessResult> _run(
  File script,
  _Repo repo,
  _FakeFeedbackApi api, {
  required String channel,
  String token = 'test-token',
  String? headSha,
  String? apiBase,
  List<String> args = const <String>[],
}) async {
  final Process process = await Process.start(
    _bashExecutable(),
    <String>[script.path, ...args],
    workingDirectory: repo.dir.path,
    environment: <String, String>{
      'FEEDBACK_CI_TOKEN': token,
      'FEEDBACK_API_BASE': apiBase ?? api.baseUrl,
      'CHANNEL': channel,
      'PLATFORM': 'windows',
      'VERSION': '2.3.0',
      'HEAD_SHA': headSha ?? repo.head,
      // 本机代理不能拦到 127.0.0.1 的假服务。
      'NO_PROXY': '127.0.0.1,localhost',
      'no_proxy': '127.0.0.1,localhost',
      'HTTP_PROXY': '',
      'HTTPS_PROXY': '',
      'http_proxy': '',
      'https_proxy': '',
      'ALL_PROXY': '',
      'all_proxy': '',
    },
  );
  final Future<String> out = process.stdout.transform(utf8.decoder).join();
  final Future<String> err = process.stderr.transform(utf8.decoder).join();
  final int code = await process.exitCode.timeout(const Duration(minutes: 2));
  return ProcessResult(process.pid, code, await out, await err);
}

class _Req {
  _Req(this.method, this.uri, this.authorization, this.body);
  final String method;
  final Uri uri;
  final String? authorization;
  final String body;
}

class _FakeFeedbackApi {
  _FakeFeedbackApi._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  final List<_Req> requests = <_Req>[];
  int pendingStatus = 200;
  String pendingBody = '{"items": []}';
  int releasedStatus = 200;
  bool _closed = false;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeFeedbackApi> start() async => _FakeFeedbackApi._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  Future<void> _handle(HttpRequest req) async {
    final String body = await utf8.decoder.bind(req).join();
    requests.add(
      _Req(
        req.method,
        req.uri,
        req.headers.value(HttpHeaders.authorizationHeader),
        body,
      ),
    );
    final HttpResponse res = req.response;
    if (req.method == 'GET' && req.uri.path == '/v1/ci/feedback/pending') {
      res.statusCode = pendingStatus;
      res.write(pendingBody);
    } else if (req.method == 'POST' &&
        req.uri.path == '/v1/ci/feedback/released') {
      res.statusCode = releasedStatus;
      res.write('{"updated": 1}');
    } else {
      res.statusCode = 404;
      res.write('{"error": "not_found"}');
    }
    await res.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
  }
}

/// root ── fixInBuild ── head          （本次构建）
///   └──── fixOnSide                    （别的分支上的修复，不是 head 的祖先）
class _Repo {
  _Repo._(this.dir);

  final Directory dir;
  late final String root;
  late final String fixInBuild;
  late final String head;
  late final String fixOnSide;

  static Future<_Repo> create() async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'fushi_feedback_released_',
    );
    final _Repo repo = _Repo._(dir);
    await repo._git(<String>['init', '-q', '-b', 'develop', '.']);
    repo.root = await repo._commit('root');
    repo.fixInBuild = await repo._commit('fix: included');
    repo.head = await repo._commit('head of this build');
    await repo._git(<String>['checkout', '-q', '-b', 'side', repo.root]);
    repo.fixOnSide = await repo._commit('fix: on another branch');
    await repo._git(<String>['checkout', '-q', 'develop']);
    return repo;
  }

  Future<String> _commit(String message) async {
    await _git(<String>[
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      'commit',
      '-q',
      '--allow-empty',
      '-m',
      message,
    ]);
    return (await _git(<String>['rev-parse', 'HEAD'])).trim();
  }

  Future<String> _git(List<String> args) async {
    final ProcessResult r = await Process.run(
      'git',
      args,
      workingDirectory: dir.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      fail('git ${args.join(' ')} failed: ${r.stderr}');
    }
    return r.stdout as String;
  }

  Future<void> dispose() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶有句柄未释放；临时目录留给系统清理，不影响断言。
    }
  }
}
