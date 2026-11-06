import 'dart:collection';

import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group(String name) =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == name);

CtlCommandContext _context(CtlCommandSpec spec, List<String> args) {
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return CtlCommandContext(parser.parse(args));
}

/// 脚本化的 app：按顺序回放 GET 会话状态，记下所有请求。
class _ScriptedApp {
  _ScriptedApp(List<Map<String, Object?>> states)
    : _states = Queue<Map<String, Object?>>.of(states);

  final Queue<Map<String, Object?>> _states;
  final List<(String, String, Map<String, Object?>?)> requests =
      <(String, String, Map<String, Object?>?)>[];

  Future<Object?> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    requests.add((method, path, body));
    if (method == 'GET') return _states.removeFirst();
    return const <String, Object?>{'ok': true};
  }
}

(String, String, Map<String, Object?>?) _lastPost(_ScriptedApp app) => app
    .requests
    .lastWhere(((String, String, Map<String, Object?>?) r) => r.$1 == 'POST');

Map<String, Object?> _entry(
  String id,
  String kind,
  String status, {
  Map<String, Object?> extra = const <String, Object?>{},
}) => <String, Object?>{'id': id, 'kind': kind, 'status': status, ...extra};

void main() {
  final CtlCommandSpec ask = _group('ai').find('ask')!;

  test('ai 组同时有提供商命令与 AI 助手的 ask / undo / log', () {
    final List<String> names = <String>[
      for (final CtlCommandSpec s in _group('ai').commands) s.name,
    ];
    expect(names.toSet(), hasLength(names.length));
    expect(names, containsAll(<String>['ls', 'assign', 'ask', 'undo', 'log']));
  });

  test('ask：一句话拼进 text，--session 接着说', () {
    final CtlRequestSpec req = ask.build(
      _context(ask, <String>['把', '字幕', '调大', '--session', 'ai1']),
    );
    expect(req.method, 'POST');
    expect(req.path, '/api/admin/ai/agent/ask');
    expect(req.body, <String, Object?>{'text': '把 字幕 调大', 'sessionId': 'ai1'});
  });

  test('ask 跟进：打印结果与撤销命令；装扩展的确认卡片按终端 y/N 作答', () async {
    final _ScriptedApp app = _ScriptedApp(<Map<String, Object?>>[
      <String, Object?>{
        'running': true,
        'entries': <Object?>[
          _entry(
            's-1',
            'toolCall',
            'done',
            extra: <String, Object?>{
              'toolName': 'settings.set',
              'before': '20',
              'after': '28',
              'actionId': '7',
              'undoable': true,
            },
          ),
          _entry(
            's-2',
            'confirm',
            'pending',
            extra: <String, Object?>{
              'toolName': 'online.extension.install',
              'risk': 'write',
              'arguments': <String, Object?>{'pkg': 'x.y'},
            },
          ),
        ],
        'pending': <String, Object?>{'kind': 'confirm', 'entryId': 's-2'},
      },
      <String, Object?>{
        'running': false,
        'tokens': 42,
        'entries': <Object?>[
          _entry('s-1', 'toolCall', 'done'),
          _entry('s-2', 'confirm', 'declined'),
          _entry(
            's-3',
            'assistant',
            'none',
            extra: <String, Object?>{'text': '好的，没装。'},
          ),
        ],
      },
    ]);
    final StringBuffer out = StringBuffer();
    final int code = await ask.follow!(
      CtlFollowContext(
        command: _context(ask, <String>['x']),
        call: app.call,
        out: out,
        err: StringBuffer(),
        json: false,
        readLine: () async => 'n',
        delay: () async {},
      ),
      const <String, Object?>{'sessionId': 'ai1'},
    );
    expect(code, 0);
    final String text = out.toString();
    expect(text, contains('✓ settings.set：20 → 28（撤销：fushi_cli ai undo 7）'));
    expect(text, contains('要安装这个扩展吗？ online.extension.install'));
    expect(text, contains('执行后可以撤销'));
    expect(text, contains('好的，没装。'));
    final (String, String, Map<String, Object?>?) answer = _lastPost(app);
    expect(answer.$2, '/api/admin/ai/agent/sessions/ai1/answer');
    expect(answer.$3, <String, Object?>{'approve': false});
  });

  test('ask 跟进：候选按序号选；回车 = 都不是', () async {
    for (final (String input, Map<String, Object?> body)
        in <(String, Map<String, Object?>)>[
          ('2', <String, Object?>{'choice': 'b'}),
          ('', <String, Object?>{}),
        ]) {
      final _ScriptedApp app = _ScriptedApp(<Map<String, Object?>>[
        <String, Object?>{
          'running': true,
          'entries': <Object?>[
            _entry(
              's-1',
              'choice',
              'pending',
              extra: <String, Object?>{
                'text': '哪一部？',
                'options': <Object?>[
                  <String, Object?>{'id': 'a', 'label': 'A'},
                  <String, Object?>{'id': 'b', 'label': 'B', 'detail': '2019'},
                ],
              },
            ),
          ],
          'pending': <String, Object?>{'kind': 'choice', 'entryId': 's-1'},
        },
        <String, Object?>{'running': false, 'entries': const <Object?>[]},
      ]);
      final StringBuffer out = StringBuffer();
      await ask.follow!(
        CtlFollowContext(
          command: _context(ask, <String>['x']),
          call: app.call,
          out: out,
          err: StringBuffer(),
          json: false,
          readLine: () async => input,
          delay: () async {},
        ),
        const <String, Object?>{'sessionId': 'ai1'},
      );
      expect(out.toString(), contains('2. B · 2019'));
      expect(_lastPost(app).$3, body);
    }
  });

  test('ask --yes：确认卡片自动回答执行，不读终端', () async {
    final _ScriptedApp app = _ScriptedApp(<Map<String, Object?>>[
      <String, Object?>{
        'running': true,
        'entries': <Object?>[
          _entry(
            's-1',
            'confirm',
            'pending',
            extra: <String, Object?>{
              'toolName': 'library.item.remove',
              'risk': 'irreversible',
            },
          ),
        ],
        'pending': <String, Object?>{'kind': 'confirm', 'entryId': 's-1'},
      },
      <String, Object?>{'running': false, 'entries': const <Object?>[]},
    ]);
    final StringBuffer out = StringBuffer();
    await ask.follow!(
      CtlFollowContext(
        command: _context(ask, <String>['x', '--yes']),
        call: app.call,
        out: out,
        err: StringBuffer(),
        json: false,
        readLine: () async => fail('不该读终端'),
        delay: () async {},
      ),
      const <String, Object?>{'sessionId': 'ai1'},
    );
    expect(out.toString(), contains('这一步无法撤销'));
    expect(_lastPost(app).$3, <String, Object?>{'approve': true});
  });

  test('undo / log 的请求形状', () {
    final CtlCommandSpec undo = _group('ai').find('undo')!;
    final CtlRequestSpec u = undo.build(_context(undo, <String>['12']));
    expect((u.method, u.path), ('POST', '/api/admin/ai/agent/actions/12/undo'));
    expect(
      undo.render!(const <String, Object?>{'status': 'superseded'}),
      contains('保留现状'),
    );
    final CtlCommandSpec log = _group('ai').find('log')!;
    final CtlRequestSpec l = log.build(
      _context(log, <String>['--session', 'ai1']),
    );
    expect((l.method, l.path), ('GET', '/api/admin/ai/agent/actions'));
    expect(l.query, <String, String>{'sessionId': 'ai1'});
  });

  test('op 组：ls 带关键词、describe 编码 id、call 合并 --args 与 --arg 并带 --yes', () {
    final CtlCommandGroup op = _group('op');
    final CtlCommandSpec ls = op.find('ls')!;
    expect(
      ls.build(_context(ls, <String>['subtitle', 'size'])).query,
      <String, String>{'q': 'subtitle size'},
    );
    final CtlCommandSpec describe = op.find('describe')!;
    expect(
      describe.build(_context(describe, <String>['settings.set'])).path,
      '/api/admin/ops/describe/settings.set',
    );
    final CtlCommandSpec call = op.find('call')!;
    final CtlRequestSpec req = call.build(
      _context(call, <String>[
        'settings.set',
        '--args',
        '{"key":"a"}',
        '--arg',
        'value=28',
        '--yes',
      ]),
    );
    expect(req.body, <String, Object?>{
      'id': 'settings.set',
      'args': <String, Object?>{'key': 'a', 'value': '28'},
      'yes': true,
    });
    expect(
      () => call.build(_context(call, <String>['x', '--arg', 'novalue'])),
      throwsA(isA<CtlUsageError>()),
    );
  });
}
