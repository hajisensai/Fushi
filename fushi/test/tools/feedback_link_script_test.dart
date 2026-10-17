import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 反馈修复标记脚本 `tool/feedback_link.mjs` 的离线测试（真脚本，node 跑）。
///
/// * `--parse`：从 stdin 读文本，钉死行格式——多 id、逗号 / 空格分隔、
///   `Feedback-NoApp:`、大小写、非法 id、不在行首的 `Feedback:` 不算；
/// * `--dry-run`：喂合成的 push 事件 + 假 GitHub API，钉死 commit / PR 描述的取舍与 sha 归属；
/// * 真 POST：127.0.0.1 假反馈服务，钉死接口形状、鉴权头与「失败不变红」。
void main() {
  // 相对路径字面量 `../tool/…` 让 ci-config-gate.yml 的磁盘枚举把本测试收进去。
  final File script = File('../tool/feedback_link.mjs').absolute;

  setUpAll(() {
    expect(script.existsSync(), isTrue, reason: '缺 ${script.path}');
  });

  Future<Map<String, dynamic>> parse(String text) async {
    final Process proc = await Process.start('node', <String>[
      script.path,
      '--parse',
    ]);
    proc.stdin.write(text);
    await proc.stdin.close();
    final String out = await proc.stdout.transform(utf8.decoder).join();
    final String err = await proc.stderr.transform(utf8.decoder).join();
    expect(await proc.exitCode, 0, reason: err);
    return jsonDecode(out.trim()) as Map<String, dynamic>;
  }

  group('行格式解析', () {
    test('多 id：逗号、空格、逗号加空格混用', () async {
      final Map<String, dynamic> r = await parse(
        'Feedback: abcd1234, EFGH_5678 ijkl-9012,mnop3456\n',
      );
      expect(r['app'], <String>[
        'abcd1234',
        'EFGH_5678',
        'ijkl-9012',
        'mnop3456',
      ]);
      expect(r['none'], isEmpty);
      expect(r['invalid'], isEmpty);
    });

    test('Feedback-NoApp → scope none；多行累加且去重', () async {
      final Map<String, dynamic> r = await parse(
        'fix: crash\n\n'
        'Feedback: abcd1234\n'
        'Feedback-NoApp: zzzz0000, yyyy1111\n'
        'Feedback: abcd1234 qqqq2222\n',
      );
      expect(r['app'], <String>['abcd1234', 'qqqq2222']);
      expect(r['none'], <String>['zzzz0000', 'yyyy1111']);
    });

    test('不区分大小写，行首允许空白，兼容 CRLF', () async {
      final Map<String, dynamic> r = await parse(
        'FEEDBACK: abcd1234\r\n  feedback-noapp :zzzz0000\r\n\tFeedBack:  qqqq2222\r\n',
      );
      expect(r['app'], <String>['abcd1234', 'qqqq2222']);
      expect(r['none'], <String>['zzzz0000']);
    });

    test('非法 id 忽略并报出：太短、太长、含非法字符', () async {
      final Map<String, dynamic> r = await parse(
        'Feedback: short, abcd1234, waytoolongid1234567, bad!id99, abcd.123\n',
      );
      expect(r['app'], <String>['abcd1234']);
      expect(r['invalid'], <String>[
        'short',
        'waytoolongid1234567',
        'bad!id99',
        'abcd.123',
      ]);
    });

    test('不在行首的 Feedback: 不算', () async {
      final Map<String, dynamic> r = await parse(
        'This addresses Feedback: abcd1234 from the tracker.\n'
        '- Feedback: efgh5678\n'
        '<!-- Feedback: ijkl9012 -->\n'
        '> Feedback-NoApp: mnop3456\n',
      );
      expect(r['app'], isEmpty);
      expect(r['none'], isEmpty);
    });

    test('同一 id 同时写了两种：按需要新 App 算', () async {
      final Map<String, dynamic> r = await parse(
        'Feedback-NoApp: abcd1234\nFeedback: abcd1234\n',
      );
      expect(r['app'], <String>['abcd1234']);
      expect(r['none'], isEmpty);
    });
  });

  group('push 事件 + 假 GitHub API + 假反馈服务', () {
    late Directory tmp;
    late _FakeApis apis;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_feedback_link_');
      apis = await _FakeApis.start();
    });
    tearDown(() async {
      await apis.close();
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Windows 偶有句柄未释放，留给系统清理。
      }
    });

    Future<ProcessResult> runPush(
      String branch,
      List<Map<String, Object?>> commits, {
      bool dryRun = true,
      String token = 'ci-token',
      String? feedbackBase,
      String eventName = 'push',
    }) async {
      final File f = File(p.join(tmp.path, 'event.json'))
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'ref': 'refs/heads/$branch',
            'commits': commits,
          }),
        );
      return Process.run(
        'node',
        <String>[script.path, if (dryRun) '--dry-run'],
        environment: <String, String>{
          'GITHUB_EVENT_NAME': eventName,
          'GITHUB_EVENT_PATH': f.path,
          'GITHUB_REPOSITORY': 'owner/repo',
          'GITHUB_API_URL': apis.baseUrl,
          'GITHUB_TOKEN': 'gh-token',
          'FEEDBACK_CI_TOKEN': token,
          'FEEDBACK_API_BASE': feedbackBase ?? '${apis.baseUrl}/',
          'NO_PROXY': '127.0.0.1,localhost',
          'no_proxy': '127.0.0.1,localhost',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    }

    List<Map<String, dynamic>> plans(ProcessResult r) => (r.stdout as String)
        .split(RegExp(r'\r?\n'))
        .where((String l) => l.startsWith('PLAN '))
        .map((String l) => jsonDecode(l.substring(5)) as Map<String, dynamic>)
        .toList();

    Map<String, Object?> commit(
      String sha,
      String message, {
      bool distinct = true,
    }) => <String, Object?>{
      'id': sha,
      'distinct': distinct,
      'message': message,
    };

    Map<String, Object?> pr(
      int number,
      String body, {
      bool merged = true,
      String base = 'develop',
    }) => <String, Object?>{
      'number': number,
      'merged_at': merged ? '2026-10-13T00:00:00Z' : null,
      'base': <String, Object?>{'ref': base},
      'body': body,
    };

    final String a = 'a' * 40;
    final String b = 'b' * 40;
    final String c = 'c' * 40;
    final String d = 'd' * 40;

    test('commit message 里的 id → 该 commit 的 sha；app / none 分开', () async {
      final ProcessResult r = await runPush('develop', <Map<String, Object?>>[
        commit(a, 'fix(x): crash\n\nFeedback: abcd1234', distinct: false),
        commit(b, 'chore: nothing'),
        commit(c, 'fix(y)\n\nfeedback-noapp: zzzz0000'),
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(plans(r), <Map<String, Object>>[
        <String, Object>{
          'sha': a,
          'scope': 'app',
          'ids': <String>['abcd1234'],
        },
        <String, Object>{
          'sha': c,
          'scope': 'none',
          'ids': <String>['zzzz0000'],
        },
      ]);
      // develop 上 distinct=false 的提交同样查了关联 PR。
      expect(apis.githubShas, <String>[a, b, c]);
      expect(apis.githubAuth.toSet(), <String?>{'Bearer gh-token'});
    });

    test('PR 描述里的 id → 该 PR 在本次 push 里出现的最后一个 commit；'
        '只认已合并、base 是本分支的 PR', () async {
      apis.prsBySha[a] = <Map<String, Object?>>[
        pr(7, 'Fixes it.\n\nFeedback: prfix001'),
      ];
      apis.prsBySha[b] = <Map<String, Object?>>[
        pr(7, 'Fixes it.\n\nFeedback: prfix001'),
        pr(8, 'Feedback: unmerged1', merged: false),
        pr(9, 'Feedback: otherbase', base: 'main'),
      ];
      final ProcessResult r = await runPush('develop', <Map<String, Object?>>[
        commit(a, 'part 1'),
        commit(b, 'part 2'),
        commit(c, 'unrelated'),
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(plans(r), <Map<String, Object>>[
        <String, Object>{
          'sha': b,
          'scope': 'app',
          'ids': <String>['prfix001'],
        },
      ]);
    });

    test('同一 id 在一次 push 里出现多次：取 push 顺序最后的 sha', () async {
      // abcd1234：commit a 的 message、PR(关联 a,c) 的描述 → c 最晚。
      // efgh5678：commit c 的 message、commit d 的 message → d。
      apis.prsBySha[a] = <Map<String, Object?>>[pr(5, 'Feedback: abcd1234')];
      apis.prsBySha[c] = <Map<String, Object?>>[pr(5, 'Feedback: abcd1234')];
      final ProcessResult r = await runPush('develop', <Map<String, Object?>>[
        commit(a, 'Feedback: abcd1234'),
        commit(b, 'noise'),
        commit(c, 'Feedback: efgh5678'),
        commit(d, 'Feedback: efgh5678'),
      ]);
      expect(plans(r), <Map<String, Object>>[
        <String, Object>{
          'sha': c,
          'scope': 'app',
          'ids': <String>['abcd1234'],
        },
        <String, Object>{
          'sha': d,
          'scope': 'app',
          'ids': <String>['efgh5678'],
        },
      ]);
    });

    test('main 只处理 distinct 的提交（develop 同步进来的不重登记、不查 PR）', () async {
      final ProcessResult r = await runPush('main', <Map<String, Object?>>[
        commit(a, 'Feedback: abcd1234', distinct: false),
        commit(b, 'hotfix\n\nFeedback: efgh5678'),
      ]);
      expect(plans(r), <Map<String, Object>>[
        <String, Object>{
          'sha': b,
          'scope': 'app',
          'ids': <String>['efgh5678'],
        },
      ]);
      expect(apis.githubShas, <String>[b]);
    });

    test('其它分支 / 非 push 事件：什么都不做', () async {
      final ProcessResult other = await runPush(
        'pr/foo',
        <Map<String, Object?>>[commit(a, 'Feedback: abcd1234')],
      );
      expect(plans(other), isEmpty);
      final ProcessResult prt = await runPush('develop', <Map<String, Object?>>[
        commit(a, 'Feedback: abcd1234'),
      ], eventName: 'pull_request_target');
      expect(plans(prt), isEmpty);
      expect(apis.githubShas, isEmpty);
    });

    test('超过 50 个 id 拆成多次请求', () async {
      final String ids = List<String>.generate(
        60,
        (int i) => 'id${i.toString().padLeft(6, '0')}',
      ).join(' ');
      final ProcessResult r = await runPush('develop', <Map<String, Object?>>[
        commit(a, 'Feedback: $ids'),
      ]);
      expect(
        plans(r).map((Map<String, dynamic> m) => (m['ids'] as List).length),
        <int>[50, 10],
      );
    });

    test('GitHub API 失败只 warning，commit message 里的 id 照常登记', () async {
      apis.githubStatus = 500;
      final ProcessResult r = await runPush('develop', <Map<String, Object?>>[
        commit(a, 'Feedback: abcd1234'),
      ]);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('::warning'));
      expect(plans(r), hasLength(1));
    });

    test('真 POST：接口形状 + 鉴权 + unchanged 进日志；没 token 只 notice；'
        '接口失败 / 不可达只 warning', () async {
      apis.prsBySha[a] = <Map<String, Object?>>[pr(3, 'Feedback: prfix001')];
      final List<Map<String, Object?>> push = <Map<String, Object?>>[
        commit(a, 'Feedback-NoApp: abcd1234'),
      ];

      final ProcessResult ok = await runPush('develop', push, dryRun: false);
      expect(ok.exitCode, 0, reason: '${ok.stdout}${ok.stderr}');
      expect(apis.fixed, hasLength(2), reason: '${ok.stdout}');
      expect(apis.fixedAuth.toSet(), <String?>{'Bearer ci-token'});
      // 同一 commit 位次：message 里的先记、PR 描述后记，按 (sha, scope) 归组的顺序固定。
      expect(apis.fixed, <Map<String, Object>>[
        <String, Object>{
          'sha': a,
          'scope': 'none',
          'ids': <String>['abcd1234'],
        },
        <String, Object>{
          'sha': a,
          'scope': 'app',
          'ids': <String>['prfix001'],
        },
      ]);
      expect(ok.stdout, contains('unchanged [prfix001]'));

      apis
        ..fixed.clear()
        ..githubShas.clear();
      final ProcessResult noToken = await runPush(
        'develop',
        push,
        dryRun: false,
        token: '',
      );
      expect(noToken.exitCode, 0);
      expect(noToken.stdout, contains('::notice'));
      expect(apis.fixed, isEmpty);
      expect(apis.githubShas, isEmpty, reason: '没 token 时不该先去查 GitHub');

      apis.fixedStatus = 500;
      final ProcessResult fail = await runPush('develop', push, dryRun: false);
      expect(fail.exitCode, 0);
      expect(fail.stdout, contains('::warning'));

      apis.fixedStatus = 200;
      final ProcessResult down = await runPush(
        'develop',
        push,
        dryRun: false,
        feedbackBase: 'http://127.0.0.1:1',
      );
      expect(down.exitCode, 0);
      expect(down.stdout, contains('::warning'));
    });
  });
}

/// 一个 127.0.0.1 服务同时扮演 GitHub API（commits/{sha}/pulls）与反馈服务（fixed）。
class _FakeApis {
  _FakeApis._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  final Map<String, List<Map<String, Object?>>> prsBySha =
      <String, List<Map<String, Object?>>>{};
  final List<String> githubShas = <String>[];
  final List<String?> githubAuth = <String?>[];
  final List<Map<String, dynamic>> fixed = <Map<String, dynamic>>[];
  final List<String?> fixedAuth = <String?>[];
  int githubStatus = 200;
  int fixedStatus = 200;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeApis> start() async =>
      _FakeApis._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  static final RegExp _pulls = RegExp(
    r'^/repos/owner/repo/commits/([0-9a-f]{40})/pulls$',
  );

  Future<void> _handle(HttpRequest req) async {
    final String body = await utf8.decoder.bind(req).join();
    final HttpResponse res = req.response;
    final RegExpMatch? m = _pulls.firstMatch(req.uri.path);
    if (req.method == 'GET' && m != null) {
      githubShas.add(m.group(1)!);
      githubAuth.add(req.headers.value(HttpHeaders.authorizationHeader));
      res.statusCode = githubStatus;
      res.write(jsonEncode(prsBySha[m.group(1)!] ?? <Map<String, Object?>>[]));
    } else if (req.method == 'POST' &&
        req.uri.path == '/v1/ci/feedback/fixed') {
      final Map<String, dynamic> json =
          jsonDecode(body) as Map<String, dynamic>;
      fixed.add(json);
      fixedAuth.add(req.headers.value(HttpHeaders.authorizationHeader));
      res.statusCode = fixedStatus;
      final bool fromPr = json['scope'] == 'app';
      res.write(
        jsonEncode(<String, Object>{
          'updated': fromPr ? <String>[] : json['ids'] as List<dynamic>,
          'missing': <String>[],
          'unchanged': fromPr ? json['ids'] as List<dynamic> : <String>[],
        }),
      );
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }

  Future<void> close() => _server.close(force: true);
}
