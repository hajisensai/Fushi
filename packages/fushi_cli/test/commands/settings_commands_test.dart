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
      'ai',
      'models',
      'voice',
      'task',
      'update',
      'audiosrc',
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

  group('config 扩展', () {
    test('ls --kind 透传；reset / run 路径与确认', () {
      expect(
        build('config', 'ls', <String>['--kind', 'action']).query,
        <String, String>{'kind': 'action'},
      );
      final CtlRequestSpec reset = build('config', 'reset', <String>['a.b']);
      expect(
        (reset.method, reset.path),
        ('POST', '/api/admin/settings/a.b/reset'),
      );
      final CtlRequestSpec run = build('config', 'run', <String>['x.y']);
      expect((run.method, run.path), ('POST', '/api/admin/settings/x.y/run'));
      expect(run.body, isEmpty);
      expect(
        build('config', 'run', <String>['x.y', '--yes']).body,
        <String, Object?>{'confirm': true},
      );
    });

    test('run：--value / --arg / 凭据只走环境变量或 stdin', () {
      final String env = Platform.environment.containsKey('PATH')
          ? 'PATH'
          : Platform.environment.keys.first;
      final CtlRequestSpec r = build('config', 'run', <String>[
        'x.y',
        '--value',
        'C:/a b',
        '--arg',
        'overwrite=true',
        '--secret-from-env',
        'token=$env',
      ]);
      expect(r.body, <String, Object?>{
        'args': <String, String>{'overwrite': 'true', 'value': 'C:/a b'},
        'secrets': <String, String>{'token': Platform.environment[env]!},
        'secretSource': 'env',
      });
      expect(
        () => build('config', 'run', <String>['x', '--arg', 'novalue']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('config', 'run', <String>[
          'x',
          '--value',
          'a',
          '--arg',
          'value=b',
        ]),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('items：ls / add / set / rm（rm 需 --yes）', () {
      final CtlRequestSpec ls = build('config', 'items', <String>['k', 'ls']);
      expect((ls.method, ls.path), ('GET', '/api/admin/settings/k/items'));
      final CtlRequestSpec add = build('config', 'items', <String>[
        'k',
        'add',
        '--arg',
        'label=Wiki',
      ]);
      expect((add.method, add.path), ('POST', '/api/admin/settings/k/items'));
      expect(add.body, <String, Object?>{
        'args': <String, String>{'label': 'Wiki'},
      });
      final CtlRequestSpec set = build('config', 'items', <String>[
        'k',
        'set',
        'a b',
        '--arg',
        'enabled=false',
      ]);
      expect(
        (set.method, set.path),
        ('PUT', '/api/admin/settings/k/items/a%20b'),
      );
      expect(
        () => build('config', 'items', <String>['k', 'set', 'a']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('config', 'items', <String>['k', 'rm', 'a']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec rm = build('config', 'items', <String>[
        'k',
        'rm',
        'a',
        '--yes',
      ]);
      expect((rm.method, rm.path), ('DELETE', '/api/admin/settings/k/items/a'));
      expect(rm.query, <String, String>{'confirm': 'true'});
      expect(
        () => build('config', 'items', <String>['k', 'drop']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  test('models start / stop 只认 gpt-sovits；voice speed 查看与设置', () {
    expect(
      build('models', 'start', <String>['gpt-sovits']).path,
      '/api/admin/models/gpt-sovits/local/start',
    );
    expect(
      build('models', 'stop', <String>[]).path,
      '/api/admin/models/gpt-sovits/local/stop',
    );
    expect(
      () => build('models', 'start', <String>['asr']),
      throwsA(isA<CtlUsageError>()),
    );
    expect(build('voice', 'speed', <String>[]).path, '/api/admin/voices');
    final CtlRequestSpec speed = build('voice', 'speed', <String>['1.25']);
    expect((speed.method, speed.path), ('PUT', '/api/admin/tts/speed'));
    expect(speed.body, <String, Object?>{'speed': 1.25});
    expect(
      () => build('voice', 'speed', <String>['fast']),
      throwsA(isA<CtlUsageError>()),
    );
  });

  test('module order：无参查看，有参排序', () {
    final CtlRequestSpec view = build('module', 'order', <String>[]);
    expect((view.method, view.path), ('GET', '/api/admin/modules'));
    final CtlRequestSpec set = build('module', 'order', <String>[
      'video',
      'library',
    ]);
    expect((set.method, set.path), ('POST', '/api/admin/modules/order'));
    expect(set.body, <String, Object?>{
      'order': <String>['video', 'library'],
    });
  });

  test('profile bindings / bind', () {
    expect(
      build('profile', 'bindings', <String>[]).path,
      '/api/admin/profiles/bindings',
    );
    final CtlRequestSpec media = build('profile', 'bind', <String>[
      'media',
      'video',
      '2',
    ]);
    expect(
      (media.method, media.path),
      ('PUT', '/api/admin/profiles/bindings/media/video'),
    );
    expect(media.body, <String, Object?>{'profile': '2'});
    final CtlRequestSpec lang = build('profile', 'bind', <String>[
      'lang',
      'zh-Hant',
      'none',
    ]);
    expect(lang.path, '/api/admin/profiles/bindings/language/zh-Hant');
    expect(lang.body, <String, Object?>{'profile': 'none'});
    expect(
      () => build('profile', 'bind', <String>['book', 'x', '1']),
      throwsA(isA<CtlUsageError>()),
    );
  });

  group('keys 改绑', () {
    test('set：替换 / 追加 / 冲突策略', () {
      final CtlRequestSpec r = build('keys', 'set', <String>[
        'readerSearch',
        'Ctrl+F',
        'pad:Y',
      ]);
      expect((r.method, r.path), ('PUT', '/api/admin/shortcuts/readerSearch'));
      expect(r.body, <String, Object?>{
        'bindings': <String>['Ctrl+F', 'pad:Y'],
        'mode': 'replace',
        'conflict': 'fail',
      });
      final CtlRequestSpec add = build('keys', 'set', <String>[
        'a',
        'F2',
        '--add',
        '--steal',
      ]);
      expect(add.body!['mode'], 'add');
      expect(add.body!['conflict'], 'steal');
      expect(
        build('keys', 'set', <String>[
          'a',
          'F2',
          '--keep-both',
        ]).body!['conflict'],
        'keep',
      );
      expect(
        () => build('keys', 'set', <String>['a']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () =>
            build('keys', 'set', <String>['a', 'F', '--steal', '--keep-both']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('unbind：具体绑定，或 --all 必须 --yes', () {
      final CtlRequestSpec r = build('keys', 'unbind', <String>['a', 'F2']);
      expect((r.method, r.path), ('POST', '/api/admin/shortcuts/a/unbind'));
      expect(r.body, <String, Object?>{
        'bindings': <String>['F2'],
      });
      expect(
        () => build('keys', 'unbind', <String>['a', '--all']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        build('keys', 'unbind', <String>['a', '--all', '--yes']).body,
        <String, Object?>{'all': true, 'confirm': true},
      );
      expect(
        () => build('keys', 'unbind', <String>['a']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('reset：单个不需确认；--scope / --all 需 --yes；三选一', () {
      expect(build('keys', 'reset', <String>['a']).body, <String, Object?>{
        'action': 'a',
      });
      expect(
        () => build('keys', 'reset', <String>['--all']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        build('keys', 'reset', <String>['--scope', 'video', '--yes']).body,
        <String, Object?>{'scope': 'video', 'confirm': true},
      );
      expect(
        () => build('keys', 'reset', <String>['a', '--all', '--yes']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('keys', 'reset', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('ai', () {
    test('ls / presets / features', () {
      expect(build('ai', 'ls', <String>[]).path, '/api/admin/ai/providers');
      expect(build('ai', 'presets', <String>[]).path, '/api/admin/ai/presets');
      expect(
        build('ai', 'features', <String>[]).path,
        '/api/admin/ai/features',
      );
    });

    test('add：字段与 Key 只走环境变量 / stdin', () {
      final String env = Platform.environment.containsKey('PATH')
          ? 'PATH'
          : Platform.environment.keys.first;
      final CtlRequestSpec r = build('ai', 'add', <String>[
        'openai',
        '--model',
        'gpt-x',
        '--rpm',
        '30',
        '--key-from-env',
        env,
        '--default',
        '--no-allow-http',
      ]);
      expect((r.method, r.path), ('POST', '/api/admin/ai/providers'));
      expect(r.body, <String, Object?>{
        'preset': 'openai',
        'model': 'gpt-x',
        'rpm': 30,
        'allowInsecureHttp': false,
        'apiKey': Platform.environment[env],
        'apiKeySource': 'env',
        'makeDefault': true,
      });
      expect(
        () => build('ai', 'add', <String>[
          'openai',
          '--key-from-env',
          'FUSHI_CLI_TEST_SURELY_UNSET_VAR',
        ]),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('set：至少一个字段；--append-key 要配 Key；启停互斥', () {
      final CtlRequestSpec r = build('ai', 'set', <String>[
        'ai-1',
        '--disable',
        '--clear-keys',
      ]);
      expect((r.method, r.path), ('PUT', '/api/admin/ai/providers/ai-1'));
      expect(r.body, <String, Object?>{'enabled': false, 'clearKeys': true});
      expect(
        () => build('ai', 'set', <String>['ai-1']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('ai', 'set', <String>['ai-1', '--append-key']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('ai', 'set', <String>['ai-1', '--enable', '--disable']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rm 需 --yes；probe / assign / default', () {
      expect(
        () => build('ai', 'rm', <String>['ai-1']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec rm = build('ai', 'rm', <String>['ai-1', '--yes']);
      expect((rm.method, rm.path), ('DELETE', '/api/admin/ai/providers/ai-1'));
      expect(rm.query, <String, String>{'confirm': 'true'});
      final CtlRequestSpec probe = build('ai', 'probe', <String>[
        'ai-1',
        '--models',
      ]);
      expect(probe.path, '/api/admin/ai/providers/ai-1/probe');
      expect(probe.body, <String, Object?>{'models': true});
      final CtlRequestSpec assign = build('ai', 'assign', <String>[
        'mangaOcr',
        'off',
      ]);
      expect(
        (assign.method, assign.path),
        ('PUT', '/api/admin/ai/features/mangaOcr'),
      );
      expect(assign.body, <String, Object?>{'provider': 'off'});
      expect(build('ai', 'default', <String>['none']).body, <String, Object?>{
        'provider': 'none',
      });
    });
  });

  group('models', () {
    test('kind / id 路径：asr 必须给 id，ocr / gpt-sovits 有缺省', () {
      expect(build('models', 'ls', <String>[]).path, '/api/admin/models');
      expect(
        build('models', 'status', <String>['asr', 'ja']).path,
        '/api/admin/models/asr/ja',
      );
      expect(
        () => build('models', 'status', <String>['asr']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        build('models', 'status', <String>['ocr']).path,
        '/api/admin/models/ocr/default',
      );
      expect(
        build('models', 'cancel', <String>['gpt-sovits']).path,
        '/api/admin/models/gpt-sovits/local/cancel',
      );
      expect(
        () => build('models', 'status', <String>['llm']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('download：gpt-sovits 专属选项；rm 需 --yes', () {
      final CtlRequestSpec d = build('models', 'download', <String>[
        'gpt-sovits',
        '--variant',
        'nvidia50',
        '--dir',
        'gsv',
        '--source',
        'ms',
      ]);
      expect(d.path, '/api/admin/models/gpt-sovits/local/download');
      expect(d.body, <String, Object?>{
        'variant': 'nvidia50',
        'dir': p.normalize(p.absolute('gsv')),
        'source': 'ms',
      });
      expect(
        () => build('models', 'download', <String>[
          'ocr',
          '--variant',
          'standard',
        ]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('models', 'rm', <String>['ocr']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec rm = build('models', 'rm', <String>[
        'asr',
        'ja',
        '--yes',
      ]);
      expect((rm.method, rm.path), ('DELETE', '/api/admin/models/asr/ja'));
      expect(rm.query, <String, String>{'confirm': 'true'});
      final CtlRequestSpec link = build('models', 'link', <String>['pkg']);
      expect(link.path, '/api/admin/models/gpt-sovits/local/link');
      expect(link.body, <String, Object?>{
        'dir': p.normalize(p.absolute('pkg')),
      });
    });
  });

  group('voice', () {
    test('add：参数 / 凭据来源 / --use', () {
      final String env = Platform.environment.containsKey('PATH')
          ? 'PATH'
          : Platform.environment.keys.first;
      final CtlRequestSpec r = build('voice', 'add', <String>[
        'openai_tts',
        '--name',
        'N',
        '-p',
        'voice=alloy',
        '--param',
        'speed=',
        '--secret-from-env',
        'apiKey=$env',
        '--use',
      ]);
      expect((r.method, r.path), ('POST', '/api/admin/voices'));
      expect(r.body, <String, Object?>{
        'engine': 'openai_tts',
        'name': 'N',
        'params': <String, String>{'voice': 'alloy', 'speed': ''},
        'secrets': <String, String>{'apiKey': Platform.environment[env]!},
        'secretSource': 'env',
        'use': true,
      });
      expect(
        () => build('voice', 'add', <String>['e', '-p', 'novalue']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('set / use / rm / voices', () {
      expect(
        () => build('voice', 'set', <String>['v1']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec set = build('voice', 'set', <String>[
        'v1',
        '--regenerate',
      ]);
      expect((set.method, set.path), ('PUT', '/api/admin/voices/v1'));
      expect(set.body, <String, Object?>{'regenerate': true});
      expect(
        build('voice', 'use', <String>['v1']).path,
        '/api/admin/voices/v1/activate',
      );
      expect(
        () => build('voice', 'rm', <String>['v1']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        build('voice', 'rm', <String>['v1', '--yes']).query,
        <String, String>{'confirm': 'true'},
      );
      expect(
        build('voice', 'voices', <String>['v1']).path,
        '/api/admin/voices/v1/voices',
      );
    });
  });

  test('新命令的 render 不抛且给出摘要', () {
    CtlCommandSpec spec(String g, String c) => settingsCommandGroups
        .firstWhere((CtlCommandGroup x) => x.name == g)
        .find(c)!;
    expect(
      spec('keys', 'set').render!(<String, Object?>{
        'shortcut': <String, Object?>{
          'scope': 'reader',
          'action': 'readerSearch',
          'keyboard': <String>['Ctrl+F'],
        },
        'conflicts': <Object?>[
          <String, Object?>{
            'binding': 'Ctrl+F',
            'action': 'other',
            'resolution': 'removed',
          },
        ],
      }),
      allOf(contains('readerSearch'), contains('已从原动作摘掉')),
    );
    expect(
      spec('ai', 'features').render!(<String, Object?>{
        'defaultProvider': 'OpenAI',
        'features': <Object?>[
          <String, Object?>{
            'feature': 'mangaOcr',
            'assignment': 'off',
            'usable': false,
          },
        ],
      }),
      allOf(contains('OpenAI'), contains('mangaOcr')),
    );
    expect(
      spec('ai', 'probe').render!(<String, Object?>{
        'ok': true,
        'models': <String>['a', 'b'],
      }),
      contains('2 个'),
    );
    expect(
      spec('models', 'ls').render!(<String, Object?>{
        'asr': <String, Object?>{
          'packs': <Object?>[
            <String, Object?>{
              'kind': 'asr',
              'id': 'reazon',
              'name': 'Reazon',
              'ready': false,
              'totalBytes': 1048576,
              'download': <String, Object?>{
                'state': 'downloading',
                'receivedBytes': 524288,
                'totalBytes': 1048576,
              },
            },
          ],
        },
        'ocr': <String, Object?>{'models': <Object?>[]},
        'gptSovits': <String, Object?>{
          'kind': 'gpt-sovits',
          'supported': false,
        },
      }),
      allOf(contains('downloading 0.5 MB / 1.0 MB'), contains('本平台不支持')),
    );
    expect(
      spec('profile', 'bindings').render!(<String, Object?>{
        'media': <Object?>[
          <String, Object?>{
            'scope': 'media',
            'key': 'video',
            'profileId': 2,
            'profile': 'B',
          },
        ],
        'language': <Object?>[],
      }),
      contains('video'),
    );
    expect(
      spec('voice', 'add').render!(<String, Object?>{
        'action': '已添加',
        'voice': <String, Object?>{
          'id': 'tts_1',
          'name': 'N',
          'engine': 'e',
          'active': true,
          'problems': <String>['apiKey'],
        },
      }),
      allOf(contains('默认'), contains('apiKey')),
    );
  });
}
