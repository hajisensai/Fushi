import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/online_commands.dart';
import 'package:test/test.dart';

CtlCommandSpec _spec(String group, String command) => onlineCommandGroups
    .firstWhere((CtlCommandGroup g) => g.name == group)
    .find(command)!;

CtlRequestSpec _build(String group, String command, List<String> args) {
  final CtlCommandSpec spec = _spec(group, command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('命令组都注册进总表，组名与命令名不重复', () {
    final List<String> names = <String>[
      for (final CtlCommandGroup g in onlineCommandGroups) g.name,
    ];
    expect(names, <String>['ext', 'source', 'discover', 'play', 'nav']);
    for (final CtlCommandGroup g in kCtlCommandGroups) {
      expect(
        kCtlCommandGroups.where((CtlCommandGroup o) => o.name == g.name),
        hasLength(1),
        reason: '组名 ${g.name} 重复',
      );
    }
    for (final CtlCommandGroup g in onlineCommandGroups) {
      final Set<String> commands = <String>{};
      for (final CtlCommandSpec s in g.commands) {
        expect(commands.add(s.name), isTrue, reason: '${g.name} ${s.name}');
      }
    }
  });

  group('ext', () {
    test('repo ls / add / rm / sync', () {
      final CtlRequestSpec ls = _build('ext', 'repo', <String>[
        'ls',
        '--kind',
        'manga',
      ]);
      expect(ls.method, 'GET');
      expect(ls.path, '/api/admin/extensions/repos');
      expect(ls.query, <String, String>{'kind': 'manga'});

      final CtlRequestSpec add = _build('ext', 'repo', <String>[
        'add',
        'http://x/index.json',
        '--kind',
        'anime',
        '--insecure',
      ]);
      expect(add.method, 'POST');
      expect(add.body, <String, Object?>{
        'kind': 'anime',
        'url': 'http://x/index.json',
        'allowInsecure': true,
      });

      final CtlRequestSpec rm = _build('ext', 'repo', <String>[
        'rm',
        'https://r',
        '--kind',
        'novel',
        '--yes',
      ]);
      expect(rm.method, 'DELETE');
      expect(rm.query, <String, String>{
        'kind': 'novel',
        'url': 'https://r',
        'confirm': 'true',
      });

      final CtlRequestSpec sync = _build('ext', 'repo', <String>[
        'sync',
        '--kind',
        'manga',
      ]);
      expect(sync.method, 'POST');
      expect(sync.path, '/api/admin/extensions/repos/sync');
    });

    test('repo 用法错误：缺 kind / 未知操作 / rm 没 --yes / 缺 url', () {
      expect(() => _build('ext', 'repo', <String>['ls']), _usageError());
      expect(
        () => _build('ext', 'repo', <String>['zap', '--kind', 'manga']),
        _usageError(),
      );
      expect(
        () => _build('ext', 'repo', <String>[
          'rm',
          'https://r',
          '--kind',
          'manga',
        ]),
        _usageError(),
      );
      expect(
        () => _build('ext', 'repo', <String>['add', '--kind', 'manga']),
        _usageError(),
      );
      expect(
        () => _build('ext', 'repo', <String>['ls', '--kind', 'comic']),
        throwsA(isA<FormatException>()),
      );
    });

    test('ls / install / update / rm', () {
      final CtlRequestSpec ls = _build('ext', 'ls', <String>[
        '--kind',
        'manga',
        '--available',
        '--lang',
        'ja',
      ]);
      expect(ls.path, '/api/admin/extensions');
      expect(ls.query, <String, String>{
        'kind': 'manga',
        'available': 'true',
        'lang': 'ja',
      });

      final CtlRequestSpec install = _build('ext', 'install', <String>[
        'eu.kanade.x',
        '--kind',
        'manga',
        '--trust-signer',
      ]);
      expect(install.method, 'POST');
      expect(install.path, '/api/admin/extensions/install');
      expect(install.body, <String, Object?>{
        'kind': 'manga',
        'id': 'eu.kanade.x',
        'trustSigner': true,
      });

      final CtlRequestSpec all = _build('ext', 'update', <String>[
        '--kind',
        'novel',
      ]);
      expect(all.body, <String, Object?>{'kind': 'novel'});
      final CtlRequestSpec one = _build('ext', 'update', <String>[
        'p1',
        '--kind',
        'novel',
      ]);
      expect(one.body, <String, Object?>{'kind': 'novel', 'id': 'p1'});

      final CtlRequestSpec rm = _build('ext', 'rm', <String>[
        'a/b',
        '--kind',
        'anime',
        '--yes',
        '--clear-data',
      ]);
      expect(rm.method, 'DELETE');
      expect(rm.path, '/api/admin/extensions/a%2Fb');
      expect(rm.query, <String, String>{
        'kind': 'anime',
        'confirm': 'true',
        'clearData': 'true',
      });
      expect(
        () => _build('ext', 'rm', <String>['x', '--kind', 'anime']),
        _usageError(),
      );
      expect(
        () => _build('ext', 'install', <String>['--kind', 'manga']),
        _usageError(),
      );
    });
  });

  group('source', () {
    test('ls / search / get / add / dl / task', () {
      expect(
        _build('source', 'ls', <String>['--kind', 'novel']).query,
        <String, String>{'kind': 'novel'},
      );

      final CtlRequestSpec search = _build('source', 'search', <String>[
        '123',
        '進撃',
        'の巨人',
        '--kind',
        'manga',
        '--page',
        '2',
      ]);
      expect(search.method, 'GET');
      expect(search.path, '/api/admin/sources/123/search');
      expect(search.query, <String, String>{
        'kind': 'manga',
        'q': '進撃 の巨人',
        'page': '2',
      });

      final CtlRequestSpec get = _build('source', 'get', <String>[
        'pkg:42',
        '/manga/1',
        '--kind',
        'manga',
      ]);
      expect(get.path, '/api/admin/sources/pkg%3A42/work');
      expect(get.query, <String, String>{'kind': 'manga', 'url': '/manga/1'});

      final CtlRequestSpec add = _build('source', 'add', <String>[
        'p',
        '/n/1',
        '--kind',
        'novel',
      ]);
      expect(add.method, 'POST');
      expect(add.path, '/api/admin/sources/p/library');
      expect(add.body, <String, Object?>{'kind': 'novel', 'url': '/n/1'});

      final CtlRequestSpec dl = _build('source', 'dl', <String>[
        'p',
        '/n/1',
        '--kind',
        'novel',
        '--chapters',
        '1-10,15,20-',
      ]);
      expect(dl.path, '/api/admin/sources/p/downloads');
      expect(dl.body, <String, Object?>{
        'kind': 'novel',
        'url': '/n/1',
        'chapters': '1-10,15,20-',
      });
      final CtlRequestSpec dlAll = _build('source', 'dl', <String>[
        'p',
        '/n/1',
        '--kind',
        'anime',
      ]);
      expect(dlAll.body, <String, Object?>{'kind': 'anime', 'url': '/n/1'});

      expect(
        _build('source', 'task', <String>[]).path,
        '/api/admin/online/tasks',
      );
      expect(
        _build('source', 'task', <String>['t3']).path,
        '/api/admin/online/tasks/t3',
      );
    });

    test('用法错误', () {
      expect(
        () => _build('source', 'search', <String>['123', '--kind', 'manga']),
        _usageError(),
      );
      expect(
        () => _build('source', 'search', <String>[
          '1',
          'q',
          '--kind',
          'manga',
          '--page',
          '0',
        ]),
        _usageError(),
      );
      expect(
        () => _build('source', 'get', <String>['1', '--kind', 'manga']),
        _usageError(),
      );
      expect(() => _build('source', 'add', <String>['1', '/x']), _usageError());
      expect(
        () => _build('source', 'dl', <String>[
          '1',
          '/x',
          '--kind',
          'manga',
          '--chapters',
          'abc',
        ]),
        _usageError(),
      );
    });
  });

  group('discover', () {
    test('sources / search / get', () {
      expect(
        _build('discover', 'sources', <String>['--domain', 'manga']).query,
        <String, String>{'domain': 'manga'},
      );
      expect(_build('discover', 'sources', <String>[]).query, isEmpty);

      final CtlRequestSpec search = _build('discover', 'search', <String>[
        'ハルヒ',
        '憂鬱',
        '--source',
        'nyaa',
      ]);
      expect(search.method, 'GET');
      expect(search.path, '/api/admin/discovery/search');
      expect(search.query, <String, String>{
        'q': 'ハルヒ 憂鬱',
        'domain': 'book',
        'source': 'nyaa',
      });

      final CtlRequestSpec get = _build('discover', 'get', <String>['r7']);
      expect(get.method, 'POST');
      expect(get.path, '/api/admin/discovery/acquire');
      expect(get.body, <String, Object?>{'id': 'r7'});
    });

    test('用法错误', () {
      expect(() => _build('discover', 'search', <String>[]), _usageError());
      expect(() => _build('discover', 'get', <String>[]), _usageError());
      expect(
        () => _build('discover', 'search', <String>['x', '--domain', 'video']),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('play', () {
    test('status / 控制动作', () {
      final CtlRequestSpec status = _build('play', 'status', <String>[]);
      expect(status.method, 'GET');
      expect(status.path, '/api/admin/playback');
      for (final (String command, String action) in <(String, String)>[
        ('pause', 'pause'),
        ('resume', 'resume'),
        ('toggle', 'toggle'),
        ('next', 'next'),
        ('prev', 'prev'),
      ]) {
        final CtlRequestSpec spec = _build('play', command, <String>[]);
        expect(spec.method, 'POST');
        expect(spec.path, '/api/admin/playback/control');
        expect(spec.body, <String, Object?>{'action': action});
      }
    });

    test('seek：绝对 / 相对 / 时钟格式', () {
      expect(_build('play', 'seek', <String>['90']).body, <String, Object?>{
        'seconds': 90.0,
        'relative': false,
      });
      expect(_build('play', 'seek', <String>['+10']).body, <String, Object?>{
        'seconds': 10.0,
        'relative': true,
      });
      expect(
        _build('play', 'seek', <String>['--', '-2.5']).body,
        <String, Object?>{'seconds': -2.5, 'relative': true},
      );
      expect(
        _build('play', 'seek', <String>['1:02:03']).body,
        <String, Object?>{'seconds': 3723.0, 'relative': false},
      );
    });

    test('--target 透传：GET 走 query、POST 走 body，缺省不带', () {
      expect(_build('play', 'status', <String>[]).query, isEmpty);
      final CtlRequestSpec status = _build('play', 'status', <String>[
        '--target',
        'video',
      ]);
      expect(status.query, <String, String>{'target': 'video'});
      expect(
        _build('play', 'toggle', <String>['--target', 'audiobook']).body,
        <String, Object?>{'action': 'toggle', 'target': 'audiobook'},
      );
      expect(
        _build('play', 'seek', <String>['+5', '--target', 'video']).body,
        <String, Object?>{'seconds': 5.0, 'relative': true, 'target': 'video'},
      );
      expect(
        _build('play', 'rate', <String>['2', '--target', 'video']).body,
        <String, Object?>{'rate': 2.0, 'target': 'video'},
      );
      expect(
        () => _build('play', 'pause', <String>['--target', 'tv']),
        throwsA(isA<FormatException>()),
      );
    });

    test('render 按 kind 区分视频 / 有声书', () {
      final CtlCommandSpec status = _spec('play', 'status');
      expect(
        status.render!(<String, Object?>{'active': false}),
        '没有正在播放的视频或有声书',
      );
      expect(
        status.render!(<String, Object?>{'active': false, 'kind': 'video'}),
        '没有打开的视频播放页',
      );
      expect(
        status.render!(<String, Object?>{
          'active': true,
          'kind': 'video',
          'ready': false,
        }),
        '[视频] 加载中…',
      );
      final String video = status.render!(<String, Object?>{
        'active': true,
        'kind': 'video',
        'ready': true,
        'title': '第1話',
        'playing': true,
        'positionMs': 61000,
        'durationMs': 1440000,
        'speed': 1.0,
        'cue': 'こんにちは',
      });
      expect(video, contains('[视频] ▶ 播放中  第1話'));
      expect(video, contains('01:01 / 24:00'));
      expect(video, contains('「こんにちは」'));
      expect(
        status.render!(<String, Object?>{
          'active': true,
          'kind': 'audiobook',
          'playing': false,
          'title': 'x',
        }),
        startsWith('[有声书] ⏸ 已暂停  x'),
      );
    });

    test('seek / rate 用法错误', () {
      expect(() => _build('play', 'seek', <String>[]), _usageError());
      expect(() => parseCtlSeekTarget('abc'), _usageError());
      expect(() => parseCtlSeekTarget('1::2'), _usageError());
      expect(() => parseCtlSeekTarget('+'), _usageError());
      expect(() => _build('play', 'rate', <String>['9']), _usageError());
      expect(() => _build('play', 'rate', <String>['fast']), _usageError());
      final CtlRequestSpec rate = _build('play', 'rate', <String>['1.5x']);
      expect(rate.path, '/api/admin/playback/rate');
      expect(rate.body, <String, Object?>{'rate': 1.5});
    });
  });

  group('nav', () {
    test('ls / go', () {
      expect(_build('nav', 'ls', <String>[]).path, '/api/admin/navigation');
      final CtlRequestSpec go = _build('nav', 'go', <String>[
        'settings',
        '--pop',
      ]);
      expect(go.method, 'POST');
      expect(go.path, '/api/admin/navigation');
      expect(go.body, <String, Object?>{'page': 'settings', 'pop': true});
      expect(() => _build('nav', 'go', <String>[]), _usageError());
    });
  });

  test('渲染不抛异常', () {
    for (final CtlCommandGroup g in onlineCommandGroups) {
      for (final CtlCommandSpec s in g.commands) {
        expect(() => s.render?.call(null), returnsNormally);
        expect(
          () => s.render?.call(<String, Object?>{}),
          returnsNormally,
          reason: '${g.name} ${s.name}',
        );
      }
    }
  });
}
