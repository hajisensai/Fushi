import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/settings_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 按命令表解析 [args] 并 build 出请求（与 CLI 主循环同样的 parser 装配）。
CtlRequestSpec build(String group, String command, List<String> args) {
  final CtlCommandSpec spec = settingsCommandGroups
      .firstWhere((CtlCommandGroup g) => g.name == group)
      .find(command)!;
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

void main() {
  test('命令组齐全且命令名不重复', () {
    expect(settingsCommandGroups.map((CtlCommandGroup g) => g.name), <String>[
      'config',
      'module',
      'profile',
      'stats',
      'keys',
    ]);
    for (final CtlCommandGroup group in settingsCommandGroups) {
      final List<String> names = group.commands
          .map((CtlCommandSpec c) => c.name)
          .toList();
      expect(names.toSet().length, names.length, reason: group.name);
    }
  });

  group('config', () {
    test('ls 带 search / all', () {
      final CtlRequestSpec plain = build('config', 'ls', <String>[]);
      expect(plain.method, 'GET');
      expect(plain.path, '/api/admin/settings');
      expect(plain.query, isEmpty);
      final CtlRequestSpec r = build('config', 'ls', <String>[
        '--search',
        'theme',
        '--all',
      ]);
      expect(r.query, <String, String>{'search': 'theme', 'all': 'true'});
    });

    test('get 编码键名', () {
      final CtlRequestSpec r = build('config', 'get', <String>['a.b c']);
      expect(r.method, 'GET');
      expect(r.path, '/api/admin/settings/a.b%20c');
      expect(
        () => build('config', 'get', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('set 位置参数值标记 source=argv', () {
      final CtlRequestSpec r = build('config', 'set', <String>[
        'appearance.eink_mode',
        'true',
      ]);
      expect(r.method, 'PUT');
      expect(r.path, '/api/admin/settings/appearance.eink_mode');
      expect(r.body, <String, Object?>{'value': 'true', 'source': 'argv'});
    });

    test('set --from-env 从环境变量读，source=env', () {
      final String name = Platform.environment.containsKey('PATH')
          ? 'PATH'
          : Platform.environment.keys.first;
      final CtlRequestSpec r = build('config', 'set', <String>[
        'system.network_proxy_password',
        '--from-env',
        name,
      ]);
      expect(r.body, <String, Object?>{
        'value': Platform.environment[name],
        'source': 'env',
      });
    });

    test('set 用法错误：缺值 / 多个来源 / 环境变量缺失 / 多余参数', () {
      expect(
        () => build('config', 'set', <String>['k']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('config', 'set', <String>['k', 'v', '--stdin']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('config', 'set', <String>[
          'k',
          '--from-env',
          'FUSHI_CLI_TEST_SURELY_UNSET_VAR',
        ]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('config', 'set', <String>['k', 'a', 'b']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('module', () {
    test('ls / enable / disable', () {
      final CtlRequestSpec ls = build('module', 'ls', <String>[]);
      expect((ls.method, ls.path), ('GET', '/api/admin/modules'));
      final CtlRequestSpec on = build('module', 'enable', <String>['video']);
      expect((on.method, on.path), ('PUT', '/api/admin/modules/video'));
      expect(on.body, <String, Object?>{'enabled': true});
      final CtlRequestSpec off = build('module', 'disable', <String>['browse']);
      expect(off.body, <String, Object?>{'enabled': false});
      expect(
        () => build('module', 'enable', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('profile', () {
    test('ls / use / new / rename / copy', () {
      expect(build('profile', 'ls', <String>[]).path, '/api/admin/profiles');
      final CtlRequestSpec use = build('profile', 'use', <String>['2']);
      expect(
        (use.method, use.path),
        ('POST', '/api/admin/profiles/2/activate'),
      );
      final CtlRequestSpec created = build('profile', 'new', <String>[
        '日语',
        '精读',
      ]);
      expect((created.method, created.path), ('POST', '/api/admin/profiles'));
      expect(created.body, <String, Object?>{'name': '日语 精读'});
      final CtlRequestSpec renamed = build('profile', 'rename', <String>[
        '3',
        '新名',
      ]);
      expect((renamed.method, renamed.path), ('PUT', '/api/admin/profiles/3'));
      expect(renamed.body, <String, Object?>{'name': '新名'});
      final CtlRequestSpec copied = build('profile', 'copy', <String>[
        '3',
        'B',
      ]);
      expect(copied.path, '/api/admin/profiles/3/copy');
      expect(
        () => build('profile', 'new', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('profile', 'rename', <String>['3']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rm 必须 --yes，带 confirm', () {
      expect(
        () => build('profile', 'rm', <String>['3']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec r = build('profile', 'rm', <String>['3', '--yes']);
      expect((r.method, r.path), ('DELETE', '/api/admin/profiles/3'));
      expect(r.query, <String, String>{'confirm': 'true'});
    });

    test('export 路径转绝对；--yes 才带 confirm', () {
      final CtlRequestSpec r = build('profile', 'export', <String>[
        '3',
        'out.json',
      ]);
      expect((r.method, r.path), ('POST', '/api/admin/profiles/3/export'));
      expect(r.body!['path'], p.normalize(p.absolute('out.json')));
      expect(r.body!.containsKey('confirm'), isFalse);
      final CtlRequestSpec forced = build('profile', 'export', <String>[
        '3',
        'out.json',
        '-y',
      ]);
      expect(forced.body!['confirm'], isTrue);
    });

    test('import 默认新建；--into 必须 --yes', () {
      final CtlRequestSpec r = build('profile', 'import', <String>['in.json']);
      expect((r.method, r.path), ('POST', '/api/admin/profiles/import'));
      expect(r.body, <String, Object?>{
        'path': p.normalize(p.absolute('in.json')),
      });
      expect(
        () => build('profile', 'import', <String>['in.json', '--into', '2']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec over = build('profile', 'import', <String>[
        'in.json',
        '--into',
        '2',
        '--yes',
      ]);
      expect(over.body!['into'], '2');
      expect(over.body!['confirm'], isTrue);
    });
  });

  group('stats', () {
    test('show 默认 7d，可选 kind', () {
      final CtlRequestSpec r = build('stats', 'show', <String>[]);
      expect((r.method, r.path), ('GET', '/api/admin/stats'));
      expect(r.query, <String, String>{'window': '7d'});
      final CtlRequestSpec k = build('stats', 'show', <String>[
        '--window',
        'all',
        '--kind',
        'watch',
      ]);
      expect(k.query, <String, String>{'window': 'all', 'kind': 'watch'});
      expect(
        () => build('stats', 'show', <String>['--window', '9d']),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => build('stats', 'show', <String>['extra']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('sessions [ls] 带 limit', () {
      final CtlRequestSpec r = build('stats', 'sessions', <String>[
        'ls',
        '-n',
        '5',
        '--kind',
        'read',
      ]);
      expect((r.method, r.path), ('GET', '/api/admin/stats/sessions'));
      expect(r.query, <String, String>{
        'window': '7d',
        'kind': 'read',
        'limit': '5',
      });
      expect(build('stats', 'sessions', <String>[]).query!['limit'], '20');
      expect(
        () => build('stats', 'sessions', <String>['rm']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('stats', 'sessions', <String>['--limit', '0']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('export 路径转绝对', () {
      final CtlRequestSpec r = build('stats', 'export', <String>['d.txt']);
      expect((r.method, r.path), ('POST', '/api/admin/stats/export'));
      expect(r.body, <String, Object?>{
        'path': p.normalize(p.absolute('d.txt')),
      });
    });
  });

  test('keys ls 可按作用域过滤', () {
    final CtlRequestSpec r = build('keys', 'ls', <String>[]);
    expect((r.method, r.path), ('GET', '/api/admin/shortcuts'));
    expect(r.query, isEmpty);
    expect(
      build('keys', 'ls', <String>['--scope', 'video']).query,
      <String, String>{'scope': 'video'},
    );
  });

  test('render 不抛且给出摘要', () {
    CtlCommandSpec spec(String g, String c) => settingsCommandGroups
        .firstWhere((CtlCommandGroup x) => x.name == g)
        .find(c)!;
    expect(
      spec('config', 'get').render!(<String, Object?>{
        'key': 'k',
        'type': 'choice',
        'title': 'T',
        'display': 'dark',
        'options': <String>['light', 'dark'],
      }),
      contains('k = dark'),
    );
    expect(
      spec('module', 'enable').render!(<String, Object?>{
        'id': 'video',
        'enabled': true,
      }),
      contains('已打开'),
    );
    expect(
      spec('stats', 'show').render!(<String, Object?>{
        'window': '7d',
        'fromKey': '2026-09-28',
        'toKey': '2026-10-04',
        'totals': <String, Object?>{
          'duration': '1h00m',
          'chars': 10,
          'pages': 0,
          'activeDays': 1,
        },
        'byKind': <String, Object?>{},
        'topMedia': <Object?>[],
      }),
      contains('1h00m'),
    );
    expect(
      spec('profile', 'use').render!(<String, Object?>{
        'action': '已切换到',
        'profile': <String, Object?>{'id': 2, 'name': 'B', 'active': true},
      }),
      contains('#2 B'),
    );
  });
}
