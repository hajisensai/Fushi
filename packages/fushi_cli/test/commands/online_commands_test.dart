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
    expect(names, <String>['ext', 'source', 'discover', 'aidl', 'play', 'nav']);
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
      // 没给的扩展字段不出现。
      expect(video, isNot(contains('音量')));
      expect(video, isNot(contains('音轨')));
      expect(video, isNot(contains('字幕：')));

      final String extended = status.render!(<String, Object?>{
        'active': true,
        'kind': 'video',
        'ready': true,
        'title': '第1話',
        'playing': false,
        'positionMs': 0,
        'durationMs': 1000,
        'speed': 1.5,
        'volume': 72.6,
        'audioTrack': '2',
        'subtitle': 'embedded:3',
        'secondarySubtitle': 'off:',
      });
      expect(extended, contains('×1.5  音量 73'));
      expect(extended, contains('音轨：2'));
      expect(extended, contains('字幕：内嵌轨 3'));
      expect(extended, contains('副字幕：关闭'));
      expect(
        status.render!(<String, Object?>{
          'active': true,
          'kind': 'video',
          'ready': true,
          'speed': 1.0,
          'subtitle': r'D:\subs\ep1.ja.srt',
        }),
        contains(r'字幕：D:\subs\ep1.ja.srt'),
      );
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

  group('ext 启停', () {
    test('enable / disable 走 /extensions/<id>/enabled', () {
      final CtlRequestSpec on = _build('ext', 'enable', <String>[
        'eu.kanade.x',
        '--kind',
        'manga',
      ]);
      expect(on.method, 'POST');
      expect(on.path, '/api/admin/extensions/eu.kanade.x/enabled');
      expect(on.body, <String, Object?>{'kind': 'manga', 'enabled': true});
      final CtlRequestSpec off = _build('ext', 'disable', <String>[
        'plugin/x',
        '--kind',
        'novel',
      ]);
      expect(off.path, '/api/admin/extensions/plugin%2Fx/enabled');
      expect(off.body, <String, Object?>{'kind': 'novel', 'enabled': false});
      expect(() => _build('ext', 'enable', <String>['x']), _usageError());
      expect(
        () => _build('ext', 'enable', <String>['--kind', 'manga']),
        _usageError(),
      );
    });
  });

  group('source 管理', () {
    test('enable / disable / pin / unpin 走 settings', () {
      Map<String, Object?>? body(String command) =>
          _build('source', command, <String>['pkg:12', '--kind', 'anime']).body;
      final CtlRequestSpec pin = _build('source', 'pin', <String>[
        'pkg:12',
        '--kind',
        'anime',
      ]);
      expect(pin.method, 'POST');
      expect(pin.path, '/api/admin/sources/pkg%3A12/settings');
      expect(body('enable'), <String, Object?>{
        'kind': 'anime',
        'enabled': true,
      });
      expect(body('disable'), <String, Object?>{
        'kind': 'anime',
        'enabled': false,
      });
      expect(body('pin'), <String, Object?>{'kind': 'anime', 'pinned': true});
      expect(body('unpin'), <String, Object?>{
        'kind': 'anime',
        'pinned': false,
      });
    });

    test('prefs：列出 / 位置参数取值 / --value 空串', () {
      final CtlRequestSpec ls = _build('source', 'prefs', <String>[
        '7',
        '--kind',
        'manga',
      ]);
      expect(ls.method, 'GET');
      expect(ls.path, '/api/admin/sources/7/preferences');
      expect(ls.query, <String, String>{'kind': 'manga'});

      final CtlRequestSpec set = _build('source', 'prefs', <String>[
        '7',
        'quality',
        'High',
        'res',
        '--kind',
        'manga',
      ]);
      expect(set.method, 'POST');
      expect(set.body, <String, Object?>{
        'kind': 'manga',
        'key': 'quality',
        'value': 'High res',
      });

      final CtlRequestSpec empty = _build('source', 'prefs', <String>[
        '7',
        'token',
        '--value',
        '',
        '--kind',
        'manga',
      ]);
      expect(empty.body?['value'], '');
      expect(
        () => _build('source', 'prefs', <String>[
          '7',
          'token',
          '--kind',
          'manga',
        ]),
        _usageError(),
      );
    });

    test('clear-data 需要 --yes', () {
      final CtlRequestSpec ok = _build('source', 'clear-data', <String>[
        'p',
        '--kind',
        'novel',
        '--yes',
      ]);
      expect(ok.method, 'DELETE');
      expect(ok.path, '/api/admin/sources/p/data');
      expect(ok.query, <String, String>{'kind': 'novel', 'confirm': 'true'});
      expect(
        () => _build('source', 'clear-data', <String>['p', '--kind', 'novel']),
        _usageError(),
      );
    });

    test('filters / browse：筛选、列表、分页', () {
      final CtlRequestSpec filters = _build('source', 'filters', <String>[
        '7',
        '--kind',
        'manga',
      ]);
      expect(filters.method, 'GET');
      expect(filters.path, '/api/admin/sources/7/filters');

      final CtlRequestSpec browse = _build('source', 'browse', <String>[
        '7',
        '--kind',
        'manga',
        '--filter',
        'Genre/Action=include',
        '--filter',
        'Sort=Latest:desc',
        '--filter',
        'Title=a=b, c',
        '--page',
        '2',
      ]);
      expect(browse.method, 'POST');
      expect(browse.path, '/api/admin/sources/7/browse');
      expect(browse.body, <String, Object?>{
        'kind': 'manga',
        'filters': <String, String>{
          'Genre/Action': 'include',
          'Sort': 'Latest:desc',
          'Title': 'a=b, c',
        },
        'page': 2,
      });

      final CtlRequestSpec latest = _build('source', 'browse', <String>[
        'p',
        '--kind',
        'novel',
        '--listing',
        'latest',
      ]);
      expect(latest.body, <String, Object?>{
        'kind': 'novel',
        'listing': 'latest',
      });

      expect(
        () => _build('source', 'browse', <String>[
          '7',
          '--kind',
          'manga',
          '--listing',
          'popular',
          '--query',
          'x',
        ]),
        _usageError(),
      );
      expect(
        () => _build('source', 'browse', <String>[
          '7',
          '--kind',
          'manga',
          '--filter',
          'noequals',
        ]),
        _usageError(),
      );
      expect(
        () => _build('source', 'browse', <String>[
          '7',
          '--kind',
          'manga',
          '--page',
          '0',
        ]),
        _usageError(),
      );
    });

    test('task --cancel', () {
      final CtlRequestSpec cancel = _build('source', 'task', <String>[
        't3',
        '--cancel',
      ]);
      expect(cancel.method, 'POST');
      expect(cancel.path, '/api/admin/online/tasks/t3/cancel');
      expect(
        () => _build('source', 'task', <String>['--cancel']),
        _usageError(),
      );
    });

    test('filters / prefs 渲染', () {
      final String filters = _spec('source', 'filters').render!(
        <String, Object?>{
          'appliesTo': 'search',
          'filters': <Object?>[
            <String, Object?>{
              'path': '1',
              'name': 'Genre',
              'kind': 'group',
              'children': <Object?>[
                <String, Object?>{
                  'path': '1.1',
                  'name': 'Action',
                  'kind': 'triState',
                  'state': 0,
                },
              ],
            },
            <String, Object?>{
              'path': '2',
              'name': 'Sort',
              'kind': 'sort',
              'state': <String, Object?>{'index': 0, 'ascending': true},
              'options': <String>['Popular', 'Latest'],
            },
          ],
        },
      );
      expect(filters, contains('作用于搜索'));
      expect(filters, contains('1.1'));
      expect(filters, contains('Popular,Latest'));
      final String prefs = _spec('source', 'prefs').render!(<String, Object?>{
        'preferences': <Object?>[
          <String, Object?>{
            'key': 'q',
            'title': '画质',
            'kind': 'list',
            'value': 1,
            'valueLabel': '高',
            'entries': <String>['低', '高'],
          },
        ],
      });
      expect(prefs, contains('高'));
      expect(prefs, contains('低,高'));
    });
  });

  group('aidl', () {
    CtlRequestSpec aidl(String command, List<String> args) =>
        _build('aidl', command, args);

    test('start 需要 --domain，带 wait 与整句', () {
      final CtlRequestSpec start = aidl('start', <String>[
        '--domain',
        'video',
        '--wait',
        '20',
        '下载',
        '葬送的芙莉莲',
      ]);
      expect(start.method, 'POST');
      expect(start.path, '/api/admin/ai-download/sessions');
      expect(start.body, <String, Object?>{
        'domain': 'video',
        'text': '下载 葬送的芙莉莲',
        'wait': 20,
      });
      expect(() => aidl('start', <String>['x']), _usageError());
      expect(() => aidl('start', <String>['--domain', 'novel']), _usageError());
      expect(
        () => aidl('start', <String>['--domain', 'novel', '--wait', '99', 'x']),
        _usageError(),
      );
    });

    test('status / say / choose / confirm / cancel / toggle / close', () {
      final CtlRequestSpec status = aidl('status', <String>[
        'abc',
        '--wait',
        '5',
      ]);
      expect(status.method, 'GET');
      expect(status.path, '/api/admin/ai-download/sessions/abc');
      expect(status.query, <String, String>{'wait': '5'});

      expect(aidl('say', <String>['abc', '换成', '第二季']).body, <String, Object?>{
        'text': '换成 第二季',
      });

      final CtlRequestSpec choose = aidl('choose', <String>[
        'abc',
        '2',
        '5',
        '--no-remember',
      ]);
      expect(choose.path, '/api/admin/ai-download/sessions/abc/choose');
      expect(choose.body, <String, Object?>{
        'answers': <String>['2', '5'],
        'remember': false,
      });
      expect(
        aidl('choose', <String>['abc', 'quality:1080p']).body,
        <String, Object?>{
          'answers': <String>['quality:1080p'],
        },
      );
      expect(() => aidl('choose', <String>['abc']), _usageError());

      expect(
        aidl('confirm', <String>['abc']).path,
        '/api/admin/ai-download/sessions/abc/confirm',
      );
      expect(
        aidl('cancel', <String>['abc']).path,
        '/api/admin/ai-download/sessions/abc/cancel',
      );
      final CtlRequestSpec toggle = aidl('toggle', <String>['abc', '3']);
      expect(toggle.path, '/api/admin/ai-download/sessions/abc/franchise');
      expect(toggle.body, <String, Object?>{'index': 3});
      expect(() => aidl('toggle', <String>['abc', '0']), _usageError());
      final CtlRequestSpec close = aidl('close', <String>['abc']);
      expect(close.method, 'DELETE');
      expect(() => aidl('status', <String>[]), _usageError());
    });

    test('渲染：视频问题与选项、AI 下载候选', () {
      final CtlCommandSpec spec = _spec('aidl', 'status');
      final String video = spec.render!(<String, Object?>{
        'id': 'abc',
        'domain': 'video',
        'view': <String, Object?>{
          'stage': 'awaitingWorkChoice',
          'busy': false,
          'transcript': <Object?>[
            <String, Object?>{'role': 'user', 'text': '芙莉莲'},
            <String, Object?>{
              'role': 'assistant',
              'kind': 'question',
              'args': <String, Object?>{'count': 2},
            },
          ],
          'question': <String, Object?>{
            'slot': 'work',
            'options': <Object?>[
              <String, Object?>{'id': 'work:0', 'label': '葬送的芙莉莲'},
              <String, Object?>{'id': 'alt:0'},
            ],
            'preselectedIndex': 0,
          },
          'alternativeLabels': <String>['LoliHouse · 1080p'],
        },
      });
      expect(video, contains('待回答（work）'));
      expect(video, contains('1) work:0  葬送的芙莉莲 *'));
      expect(video, contains('2) alt:0  LoliHouse · 1080p'));
      expect(video, contains('我：芙莉莲'));

      final String media = spec.render!(<String, Object?>{
        'id': 'def',
        'domain': 'manga',
        'view': <String, Object?>{
          'stage': 'ready',
          'busy': true,
          'queries': <String>['葬送のフリーレン'],
          'candidates': <Object?>[
            <String, Object?>{
              'no': 1,
              'title': 'A',
              'source': 'Nyaa',
              'method': 'torrent',
              'recommended': true,
              'selected': true,
              'status': 'started',
              'taskId': 't1',
            },
          ],
        },
      });
      expect(media, contains('处理中'));
      expect(media, contains('★✓'));
      expect(media, contains('任务 t1'));
    });
  });

  group('source 下载任务', () {
    test('manga-dl：ls 过滤 / cancel / retry / rm / clear', () {
      final CtlRequestSpec ls = _build('source', 'manga-dl', <String>[
        'ls',
        '--book',
        'bk1',
        '--status',
        'queued,running',
      ]);
      expect(ls.method, 'GET');
      expect(ls.path, '/api/admin/online/manga-downloads');
      expect(ls.query, <String, String>{
        'book': 'bk1',
        'status': 'queued,running',
      });
      expect(
        _build('source', 'manga-dl', <String>['cancel', 'j 1']).path,
        '/api/admin/online/manga-downloads/j%201/cancel',
      );
      expect(
        _build('source', 'manga-dl', <String>['retry', 'j1']).path,
        '/api/admin/online/manga-downloads/j1/retry',
      );
      final CtlRequestSpec rm = _build('source', 'manga-dl', <String>[
        'rm',
        'j1',
        '--yes',
      ]);
      expect(rm.method, 'DELETE');
      expect(rm.query, <String, String>{'confirm': 'true'});
      final CtlRequestSpec clear = _build('source', 'manga-dl', <String>[
        'clear',
        '--yes',
      ]);
      expect(clear.path, '/api/admin/online/manga-downloads');
      expect(clear.query, <String, String>{
        'finished': 'true',
        'confirm': 'true',
      });
      expect(
        () => _build('source', 'manga-dl', <String>['rm', 'j1']),
        _usageError(),
      );
      expect(
        () => _build('source', 'manga-dl', <String>['clear']),
        _usageError(),
      );
      expect(
        () => _build('source', 'manga-dl', <String>['cancel']),
        _usageError(),
      );
      expect(
        () => _build('source', 'manga-dl', <String>['zap']),
        _usageError(),
      );
    });

    test('anime-dl：ls / get / pause / resume / rm', () {
      expect(
        _build('source', 'anime-dl', <String>['ls', '--all']).query,
        <String, String>{'all': 'true'},
      );
      expect(
        _build('source', 'anime-dl', <String>['get', 'ep/1']).path,
        '/api/admin/online/episode-downloads/ep%2F1',
      );
      expect(
        _build('source', 'anime-dl', <String>['pause', 'e']).path,
        '/api/admin/online/episode-downloads/e/pause',
      );
      expect(
        _build('source', 'anime-dl', <String>['resume', 'e']).path,
        '/api/admin/online/episode-downloads/e/resume',
      );
      final CtlRequestSpec rm = _build('source', 'anime-dl', <String>[
        'rm',
        'e',
        '--yes',
        '--delete-files',
      ]);
      expect(rm.method, 'DELETE');
      expect(rm.query, <String, String>{
        'confirm': 'true',
        'deleteFiles': 'true',
      });
      expect(
        () => _build('source', 'anime-dl', <String>['rm', 'e']),
        _usageError(),
      );
    });

    test('渲染：任务表、单任务、dl 结果给出进度入口、discover get 带原因', () {
      final String manga = _spec('source', 'manga-dl').render!(
        <String, Object?>{
          'jobs': <Object?>[
            <String, Object?>{
              'id': 'j1',
              'title': 'T',
              'chapter': '第1话',
              'status': 'running',
              'pagesDone': 3,
              'pagesTotal': 20,
            },
          ],
        },
      );
      expect(manga, contains('3/20'));
      final String anime = _spec('source', 'anime-dl').render!(
        <String, Object?>{
          'id': 'e',
          'title': '第1集',
          'status': 'running',
          'progress': 0.5,
        },
      );
      expect(anime, contains('50.0%'));
      expect(
        _spec('source', 'anime-dl').render!(<String, Object?>{
          'id': 'e',
          'deletedRows': 1,
          'deletedFile': 'D:/v/ep1.mp4',
        }),
        '已删除成品 D:/v/ep1.mp4（连同 1 条媒体库行）',
      );
      expect(
        _spec('source', 'dl').render!(<String, Object?>{
          'title': 'A',
          'queued': 2,
          'taskIds': <String>['e1', 'e2'],
        }),
        contains('source anime-dl ls'),
      );
      expect(
        _spec('source', 'dl').render!(<String, Object?>{
          'title': 'M',
          'queued': 2,
          'bookKey': 'bk',
        }),
        contains('manga-dl ls --book bk'),
      );
      expect(
        _spec('discover', 'get').render!(<String, Object?>{
          'title': 'X',
          'started': false,
          'reason': '源站要求登录',
        }),
        contains('源站要求登录'),
      );
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
