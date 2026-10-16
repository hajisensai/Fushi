import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/game_commands.dart';
import 'package:test/test.dart';

CtlCommandSpec _spec(String command) => gameCommandGroups
    .firstWhere((CtlCommandGroup g) => g.name == 'game')
    .find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('game 组注册进总表，命令名不重复且都有 render', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'game'),
      hasLength(1),
    );
    final Set<String> names = <String>{};
    for (final CtlCommandSpec s in gameCommandGroups.single.commands) {
      expect(names.add(s.name), isTrue, reason: s.name);
      expect(s.render, isNotNull, reason: '${s.name} 缺 render');
    }
  });

  test('ls / windows / threads 是 GET', () {
    expect(_build('ls', <String>[]).path, '/api/admin/game/games');
    expect(_build('windows', <String>[]).path, '/api/admin/game/windows');
    expect(_build('threads', <String>[]).method, 'GET');
  });

  test('launch 接受 game: 前缀，--replace 显式透传', () {
    final CtlRequestSpec plain = _build('launch', <String>['123']);
    expect(plain.method, 'POST');
    expect(plain.path, '/api/admin/game/launch');
    expect(plain.body, <String, Object?>{'id': '123'});
    expect(
      _build('launch', <String>['game:123', '--replace']).body,
      <String, Object?>{'id': '123', 'replace': true},
    );
    expect(() => _build('launch', <String>[]), _usageError());
    expect(() => _build('launch', <String>['game:']), _usageError());
  });

  test('attach：--hwnd / --pid 二选一且为正整数', () {
    expect(_build('attach', <String>['--hwnd', '42']).body, <String, Object?>{
      'hwnd': 42,
    });
    expect(_build('attach', <String>['--pid', '7']).body, <String, Object?>{
      'pid': 7,
    });
    expect(() => _build('attach', <String>[]), _usageError());
    expect(
      () => _build('attach', <String>['--hwnd', '1', '--pid', '2']),
      _usageError(),
    );
    expect(() => _build('attach', <String>['--hwnd', 'x']), _usageError());
    expect(() => _build('attach', <String>['--pid', '0']), _usageError());
  });

  test('stop / status / text 参数', () {
    expect(_build('stop', <String>[]).body, isEmpty);
    expect(_build('stop', <String>['--unbind']).body, <String, Object?>{
      'unbind': true,
    });
    expect(_build('status', <String>['--events', '5']).query, <String, String>{
      'events': '5',
    });
    expect(() => _build('status', <String>['--events', '-1']), _usageError());
    expect(_build('text', <String>[]).query, isEmpty);
    expect(() => _build('text', <String>['--limit', '0']), _usageError());
  });

  test('select：key 与 --clear 二选一', () {
    expect(_build('select', <String>['t1']).body, <String, Object?>{
      'key': 't1',
    });
    expect(_build('select', <String>['--clear']).body, <String, Object?>{
      'clear': true,
    });
    expect(() => _build('select', <String>[]), _usageError());
    expect(() => _build('select', <String>['t1', '--clear']), _usageError());
  });

  test('mine 拼完整参数', () {
    final CtlRequestSpec spec = _build('mine', <String>[
      '食べる',
      '--line',
      'l9',
      '--reading',
      'たべる',
      '--no-lookup',
      '--allow-duplicate',
      '--update',
      '55',
    ]);
    expect(spec.path, '/api/admin/game/mine');
    expect(spec.body, <String, Object?>{
      'word': '食べる',
      'lineId': 'l9',
      'reading': 'たべる',
      'lookup': false,
      'allowDuplicate': true,
      'updateNoteId': 55,
    });
    expect(_build('mine', <String>['猫']).body, <String, Object?>{'word': '猫'});
    expect(() => _build('mine', <String>[]), _usageError());
    expect(() => _build('mine', <String>['猫', '--update', '0']), _usageError());
  });

  test('status 渲染逐级列出阶段，不压成一个结论', () {
    final String out = _spec('status').render!(<String, Object?>{
      'session': <String, Object?>{
        'phase': 'degraded',
        'mode': 'launch',
        'pid': 10,
        'audioBackend': 'systemLoopback',
        'injectorFailure': 'none',
      },
      'stages': <Object?>[
        <String, Object?>{'stage': 'process_found', 'status': 'observed'},
        <String, Object?>{'stage': 'resource/pcm_ready', 'status': 'degraded'},
        <String, Object?>{'stage': 'paired', 'status': 'degraded'},
        <String, Object?>{'stage': 'e2e_verified', 'status': 'not_verifiable'},
      ],
      'events': <Object?>[],
    });
    expect(out, contains('process_found'));
    expect(out, contains('resource/pcm_ready'));
    expect(out, contains('degraded'));
    expect(out, contains('not_verifiable'));
  });

  test('launch 渲染区分降级与失败', () {
    final String Function(Object?) render = _spec('launch').render!;
    expect(
      render(<String, Object?>{'outcome': 'degradedLoopback', 'title': 'G'}),
      contains('整机混音'),
    );
    expect(
      render(<String, Object?>{
        'outcome': 'failed',
        'title': 'G',
        'reason': 'injectionFailed',
      }),
      contains('injectionFailed'),
    );
  });

  group('工作台细项', () {
    test('config：三项可组合，至少一项，取值校验', () {
      final CtlRequestSpec spec = _build('config', <String>[
        'game:g/1',
        '--locale',
        'ON',
        '--upscaling',
        'installed_only',
        '--language',
        'ja',
      ]);
      expect(spec.method, 'PUT');
      expect(spec.path, '/api/admin/game/games/g%2F1/config');
      expect(spec.body, <String, Object?>{
        'locale': 'on',
        'upscaling': 'installed_only',
        'language': 'ja',
      });
      expect(
        _build('config', <String>['g', '--clear-language']).body,
        <String, Object?>{'clearLanguage': true},
      );
      expect(() => _build('config', <String>['g']), _usageError());
      expect(
        () => _build('config', <String>['g', '--locale', 'maybe']),
        _usageError(),
      );
      expect(
        () => _build('config', <String>[
          'g',
          '--language',
          'ja',
          '--clear-language',
        ]),
        _usageError(),
      );
    });

    test('bind 三选一；window-mode on/off', () {
      expect(_build('bind', <String>['--hwnd', '3']).body, <String, Object?>{
        'hwnd': 3,
      });
      expect(_build('bind', <String>['--clear']).body, <String, Object?>{
        'clear': true,
      });
      expect(() => _build('bind', <String>[]), _usageError());
      expect(
        () => _build('bind', <String>['--hwnd', '3', '--clear']),
        _usageError(),
      );
      expect(_build('window-mode', <String>['on']).body, <String, Object?>{
        'enabled': true,
      });
      expect(_build('window-mode', <String>['OFF']).body, <String, Object?>{
        'enabled': false,
      });
      expect(() => _build('window-mode', <String>['maybe']), _usageError());
    });

    test('音轨：tracks / select / exclude / preview', () {
      expect(_build('tracks', <String>[]).query, isEmpty);
      expect(_build('tracks', <String>['--no-refresh']).query, <String, String>{
        'refresh': 'false',
      });
      expect(_build('track-select', <String>['77']).body, <String, Object?>{
        'ptr': 77,
      });
      expect(() => _build('track-select', <String>['x']), _usageError());
      expect(() => _build('track-select', <String>['0']), _usageError());
      expect(_build('track-exclude', <String>['77']).body, <String, Object?>{
        'ptr': 77,
        'excluded': true,
      });
      expect(
        _build('track-exclude', <String>['77', '--include']).body,
        <String, Object?>{'ptr': 77, 'excluded': false},
      );
      expect(
        _build('track-preview', <String>['77', '--line', 'l1', '--play']).body,
        <String, Object?>{'ptr': 77, 'lineId': 'l1', 'play': true},
      );
      expect(
        _build('audio-stop', <String>[]).path,
        '/api/admin/game/audio/stop',
      );
    });

    test('audio-policy 校验取值', () {
      expect(
        _build('audio-policy', <String>['cleanOnly']).body,
        <String, Object?>{'policy': 'cleanOnly'},
      );
      expect(() => _build('audio-policy', <String>['loud']), _usageError());
    });

    test(
      '逐句：line-tracks / line-track / line-preview / recapture / favorite',
      () {
        expect(
          _build('line-tracks', <String>['a b']).path,
          '/api/admin/game/lines/a%20b/tracks',
        );
        final CtlRequestSpec track = _build('line-track', <String>['l1', '9']);
        expect(track.path, '/api/admin/game/lines/l1/track');
        expect(track.body, <String, Object?>{'ptr': 9});
        expect(() => _build('line-track', <String>['l1']), _usageError());
        expect(
          _build('line-preview', <String>['l1', '--play']).body,
          <String, Object?>{'play': true},
        );
        expect(
          _build('recapture', <String>['l1', 'FINISH']).body,
          <String, Object?>{'action': 'finish'},
        );
        expect(() => _build('recapture', <String>['l1', 'go']), _usageError());
        expect(
          _build('favorite', <String>['l1']).path,
          '/api/admin/game/lines/l1/favorite',
        );
      },
    );

    test('textproc：无参查看，--set-json 解析成数组', () {
      expect(_build('textproc', <String>[]).method, 'GET');
      final CtlRequestSpec set = _build('textproc', <String>[
        '--set-json',
        '[{"id":"a","kind":"trim"}]',
      ]);
      expect(set.method, 'PUT');
      expect(set.body!['pipeline'], <Object?>[
        <String, Object?>{'id': 'a', 'kind': 'trim'},
      ]);
      expect(
        () => _build('textproc', <String>['--set-json', '{}']),
        _usageError(),
      );
      expect(
        () => _build('textproc', <String>['--set-json', 'nope']),
        _usageError(),
      );
      expect(
        () => _build('textproc', <String>['--set-file', 'does/not/exist.json']),
        _usageError(),
      );
    });

    test('lookup-mode / lookup-clear / events-clear', () {
      expect(_build('lookup-mode', <String>[]).method, 'GET');
      expect(
        _build('lookup-mode', <String>['attachedOnly']).body,
        <String, Object?>{'mode': 'attachedOnly'},
      );
      expect(() => _build('lookup-mode', <String>['weird']), _usageError());
      expect(() => _build('lookup-clear', <String>[]), _usageError());
      expect(_build('lookup-clear', <String>['--yes']).body, <String, Object?>{
        'confirm': true,
      });
      expect(
        _build('events-clear', <String>[]).path,
        '/api/admin/game/events/clear',
      );
    });
  });

  group('游戏条目管理', () {
    test('rename：名字拼接 / --clear 二选一', () {
      final CtlRequestSpec spec = _build('rename', <String>['g1', '新', '名字']);
      expect(spec.method, 'PUT');
      expect(spec.path, '/api/admin/game/games/g1/name');
      expect(spec.body, <String, Object?>{'name': '新 名字'});
      expect(
        _build('rename', <String>['game:g1', '--clear']).body,
        <String, Object?>{'clear': true},
      );
      expect(() => _build('rename', <String>['g1']), _usageError());
      expect(
        () => _build('rename', <String>['g1', 'x', '--clear']),
        _usageError(),
      );
    });

    test('play-status 大小写不敏感、取值校验', () {
      expect(
        _build('play-status', <String>['g1', 'onhold']).body,
        <String, Object?>{'status': 'onHold'},
      );
      expect(() => _build('play-status', <String>['g1', 'x']), _usageError());
    });

    test('cover：--file 转绝对路径 / --auto', () {
      final CtlRequestSpec file = _build('cover', <String>[
        'g1',
        '--file',
        'a.png',
      ]);
      expect(file.path, '/api/admin/game/games/g1/cover');
      expect((file.body!['file']! as String).endsWith('a.png'), isTrue);
      expect(file.body!['file'], isNot('a.png'));
      expect(_build('cover', <String>['g1', '--auto']).body, <String, Object?>{
        'auto': true,
      });
      expect(() => _build('cover', <String>['g1']), _usageError());
    });

    test('edit：字段映射、--clear 可重复、取值校验', () {
      final CtlRequestSpec spec = _build('edit', <String>[
        'g1',
        '--args',
        '-w 1',
        '--tags',
        'a,b',
        '--no-nsfw',
        '--rating',
        '8.5',
        '--release-date',
        '2020-01-02',
        '--clear',
        'summary',
        '--clear',
        'review',
      ]);
      expect(spec.path, '/api/admin/game/games/g1/details');
      expect(spec.body, <String, Object?>{
        'launchArgs': '-w 1',
        'tags': 'a,b',
        'nsfw': false,
        'rating': '8.5',
        'releaseDate': '2020-01-02',
        'clear': <String>['summary', 'review'],
      });
      expect(() => _build('edit', <String>['g1']), _usageError());
      expect(
        () => _build('edit', <String>['g1', '--rating', '11']),
        _usageError(),
      );
      expect(
        () => _build('edit', <String>['g1', '--release-date', '2020']),
        _usageError(),
      );
      expect(
        () => _build('edit', <String>['g1', '--clear', 'exePath']),
        _usageError(),
      );
    });

    test('remove 需要 --yes；--delete-stats 透传', () {
      expect(() => _build('remove', <String>['g1']), _usageError());
      final CtlRequestSpec spec = _build('remove', <String>[
        'g1',
        '--yes',
        '--delete-stats',
      ]);
      expect(spec.method, 'DELETE');
      expect(spec.path, '/api/admin/game/games/g1');
      expect(spec.query, <String, String>{
        'confirm': 'true',
        'deleteStatistics': 'true',
      });
    });

    test('sessions / session-delete', () {
      expect(
        _build('sessions', <String>['g1', '--limit', '5']).query,
        <String, String>{'limit': '5'},
      );
      expect(
        () => _build('session-delete', <String>['g1', '3']),
        _usageError(),
      );
      expect(
        () => _build('session-delete', <String>['g1', 'x', '--yes']),
        _usageError(),
      );
      final CtlRequestSpec del = _build('session-delete', <String>[
        'g1',
        '3',
        '--yes',
      ]);
      expect(del.path, '/api/admin/game/games/g1/sessions/3');
      expect(del.query, <String, String>{'confirm': 'true'});
    });

    test('scrape / scrape-apply / sources / source-remove', () {
      expect(
        _build('scrape', <String>['g1', '-q', 'ef', '--source', 'VNDB']).query,
        <String, String>{'q': 'ef', 'source': 'vndb'},
      );
      expect(
        () => _build('scrape', <String>['g1', '--source', 'anidb']),
        _usageError(),
      );
      expect(
        _build('scrape-apply', <String>['g1', 'vndb:v17']).body,
        <String, Object?>{'candidate': 'vndb:v17'},
      );
      expect(
        () => _build('scrape-apply', <String>['g1', 'v17']),
        _usageError(),
      );
      expect(
        _build('sources', <String>['g1']).path,
        '/api/admin/game/games/g1/sources',
      );
      final CtlRequestSpec rm = _build('source-remove', <String>['g1', 'bgm']);
      expect(rm.method, 'DELETE');
      expect(rm.path, '/api/admin/game/games/g1/sources/bgm');
      expect(() => _build('source-remove', <String>['g1', 'x']), _usageError());
    });
  });

  group('内嵌查词截图校准', () {
    test('screenshot：--output 转绝对路径', () {
      expect(_build('screenshot', <String>[]).body, isEmpty);
      final CtlRequestSpec spec = _build('screenshot', <String>['-o', 'a.png']);
      expect(spec.path, '/api/admin/game/screenshot');
      expect((spec.body!['output']! as String).endsWith('a.png'), isTrue);
      expect(spec.body!['output'], isNot('a.png'));
      expect(_build('lookup-profile', <String>[]).method, 'GET');
    });

    test('lookup-calibrate：grid 形态完整透传', () {
      final CtlRequestSpec spec = _build('lookup-calibrate', <String>[
        '--rect',
        '100,500,1000,180',
        '--px',
        '--grid',
        '36,48,34,26',
        '--indent',
        '-1',
        '--slot',
        'dialogue',
        '--from-screenshot',
        '--accept-risk',
      ]);
      expect(spec.path, '/api/admin/game/lookup-calibrate');
      expect(spec.body, <String, Object?>{
        'rect': '100,500,1000,180',
        'px': true,
        'grid': '36,48,34,26',
        'indent': '-1',
        'slot': 'dialogue',
        'fromScreenshot': true,
        'acceptRisk': true,
      });
    });

    test('lookup-calibrate：layout-json 与参数校验', () {
      final CtlRequestSpec spec = _build('lookup-calibrate', <String>[
        '--rect',
        '0.1,0.7,0.8,0.2',
        '--layout-json',
        '{"fontFamily":""}',
      ]);
      expect(spec.body!['layout'], <String, Object?>{'fontFamily': ''});
      expect(() => _build('lookup-calibrate', <String>[]), _usageError());
      expect(
        () => _build('lookup-calibrate', <String>['--rect', '1,2,3']),
        _usageError(),
      );
      expect(
        () => _build('lookup-calibrate', <String>['--rect', '0,0,1,1']),
        _usageError(),
      );
      expect(
        () => _build('lookup-calibrate', <String>[
          '--rect',
          '0,0,1,1',
          '--grid',
          '1,2,3',
        ]),
        _usageError(),
      );
      expect(
        () => _build('lookup-calibrate', <String>[
          '--rect',
          '0,0,1,1',
          '--grid',
          '1,2,3,4',
          '--layout-json',
          '{}',
        ]),
        _usageError(),
      );
      expect(
        () => _build('lookup-calibrate', <String>[
          '--rect',
          '0,0,1,1',
          '--layout-json',
          '[]',
        ]),
        _usageError(),
      );
      expect(
        () => _build('lookup-calibrate', <String>[
          '--rect',
          '0,0,1,1',
          '--grid',
          '1,2,3,4',
          '--slot',
          'menu',
        ]),
        _usageError(),
      );
    });
  });
}
