import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group() =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == 'web');

CtlCommandSpec _spec(String command) => _group().find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('web 组只注册一次、子命令不重名', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'web'),
      hasLength(1),
    );
    final List<String> names = <String>[
      for (final CtlCommandSpec s in _group().commands) s.name,
    ];
    expect(names.toSet(), hasLength(names.length));
    expect(
      names,
      containsAll(<String>[
        'open',
        'history',
        'history-clear',
        'bookmarks',
        'bookmark-add',
        'folder-add',
        'bookmark-edit',
        'bookmark-rm',
        'adblock',
        'adblock-on',
        'adblock-off',
        'adblock-list',
        'adblock-update',
        'adblock-allow',
        'adblock-disallow',
        'adblock-allowlist-set',
      ]),
    );
  });

  test('open：多个词拼成一句交给地址栏判据', () {
    final CtlRequestSpec open = _build('open', <String>['日本語', '辞書']);
    expect(open.method, 'POST');
    expect(open.path, '/api/admin/web/open');
    expect(open.body, <String, Object?>{'url': '日本語 辞書'});
    expect(() => _build('open', <String>[]), _usageError());
  });

  test('history：关键词 / --limit / --offset', () {
    final CtlRequestSpec h = _build('history', <String>[
      'wiki',
      '--limit',
      '5',
      '--offset',
      '10',
    ]);
    expect(h.method, 'GET');
    expect(h.path, '/api/admin/web/history');
    expect(h.query, <String, String>{
      'search': 'wiki',
      'limit': '5',
      'offset': '10',
    });
    expect(() => _build('history', <String>['--limit', '0']), _usageError());
    expect(() => _build('history', <String>['--offset', '-1']), _usageError());
  });

  test('history-clear：range 与 id 二选一、必须 --yes', () {
    final CtlRequestSpec range = _build('history-clear', <String>[
      '--range',
      'day',
      '--yes',
    ]);
    expect(range.path, '/api/admin/web/history/clear');
    expect(range.body, <String, Object?>{'range': 'day', 'confirm': true});
    final CtlRequestSpec ids = _build('history-clear', <String>[
      '--id',
      '3',
      '--id',
      '4',
      '-y',
    ]);
    expect(ids.body, <String, Object?>{
      'ids': <String>['3', '4'],
      'confirm': true,
    });
    expect(
      () => _build('history-clear', <String>['--range', 'day']),
      _usageError(),
    );
    expect(() => _build('history-clear', <String>['--yes']), _usageError());
    expect(
      () => _build('history-clear', <String>[
        '--range',
        'all',
        '--id',
        '1',
        '--yes',
      ]),
      _usageError(),
    );
    expect(
      () => _build('history-clear', <String>['--id', 'x', '--yes']),
      _usageError(),
    );
  });

  test('bookmarks：--folder / --all 互斥', () {
    expect(_build('bookmarks', <String>[]).query, isEmpty);
    expect(
      _build('bookmarks', <String>['--folder', '7']).query,
      <String, String>{'folder': '7'},
    );
    expect(_build('bookmarks', <String>['--all']).query, <String, String>{
      'recursive': 'true',
    });
    expect(
      () => _build('bookmarks', <String>['--folder', '7', '--all']),
      _usageError(),
    );
  });

  test('bookmark-add / folder-add：type 区分，--folder 成 parent', () {
    final CtlRequestSpec add = _build('bookmark-add', <String>[
      'example.com',
      '--title',
      'Ex',
      '--folder',
      '2',
    ]);
    expect(add.method, 'POST');
    expect(add.path, '/api/admin/web/bookmarks');
    expect(add.body, <String, Object?>{
      'type': 'bookmark',
      'url': 'example.com',
      'title': 'Ex',
      'parent': 2,
    });
    final CtlRequestSpec folder = _build('folder-add', <String>['日语', '学习']);
    expect(folder.body, <String, Object?>{'type': 'folder', 'title': '日语 学习'});
    expect(() => _build('bookmark-add', <String>[]), _usageError());
    expect(() => _build('folder-add', <String>[]), _usageError());
  });

  test('bookmark-edit：只带给了的字段，--folder 与 --root 互斥', () {
    final CtlRequestSpec edit = _build('bookmark-edit', <String>[
      '5',
      '--title',
      'New',
      '--root',
      '--index',
      '0',
    ]);
    expect(edit.method, 'PUT');
    expect(edit.path, '/api/admin/web/bookmarks/5');
    expect(edit.body, <String, Object?>{
      'title': 'New',
      'root': true,
      'index': 0,
    });
    expect(() => _build('bookmark-edit', <String>['5']), _usageError());
    expect(
      () => _build('bookmark-edit', <String>['5', '--folder', '1', '--root']),
      _usageError(),
    );
    expect(
      () => _build('bookmark-edit', <String>['x', '--title', 'a']),
      _usageError(),
    );
  });

  test('bookmark-rm：--yes 带 confirm', () {
    final CtlRequestSpec rm = _build('bookmark-rm', <String>['9']);
    expect(rm.method, 'DELETE');
    expect(rm.path, '/api/admin/web/bookmarks/9');
    expect(rm.body, isEmpty);
    expect(
      _build('bookmark-rm', <String>['9', '--yes']).body,
      <String, Object?>{'confirm': true},
    );
  });

  test('adblock：开关 / 列表 / 更新 / 白名单', () {
    expect(_build('adblock', <String>[]).path, '/api/admin/web/adblock');
    expect(_build('adblock-on', <String>[]).body, <String, Object?>{
      'enabled': true,
    });
    final CtlRequestSpec off = _build('adblock-off', <String>[]);
    expect(off.path, '/api/admin/web/adblock/enabled');
    expect(off.body, <String, Object?>{'enabled': false});
    final CtlRequestSpec list = _build('adblock-list', <String>[
      'easylist',
      'OFF',
    ]);
    expect(list.path, '/api/admin/web/adblock/lists/easylist');
    expect(list.body, <String, Object?>{'enabled': false});
    expect(
      () => _build('adblock-list', <String>['easylist', 'maybe']),
      _usageError(),
    );
    expect(
      _build('adblock-update', <String>[]).path,
      '/api/admin/web/adblock/update',
    );
    expect(
      _build('adblock-allow', <String>['example.com']).body,
      <String, Object?>{'host': 'example.com'},
    );
    final CtlRequestSpec disallow = _build('adblock-disallow', <String>[
      'example.com',
    ]);
    expect(disallow.method, 'DELETE');
    expect(disallow.path, '/api/admin/web/adblock/allowlist/example.com');
    final CtlRequestSpec set = _build('adblock-allowlist-set', <String>[
      'a.com',
      'b.org',
    ]);
    expect(set.method, 'PUT');
    expect(set.body, <String, Object?>{'allowlist': 'a.com, b.org'});
    expect(_build('adblock-allowlist-set', <String>[]).body, <String, Object?>{
      'allowlist': '',
    });
  });

  test('render：广告拦截状态与书签表', () {
    final String text = _spec('adblock').render!(<String, Object?>{
      'enabled': true,
      'status': 'ready',
      'ruleCount': 12,
      'lists': <Object?>[
        <String, Object?>{
          'id': 'easylist',
          'title': 'EasyList',
          'enabled': true,
          'ruleCount': 12,
        },
      ],
      'allowlistHosts': <Object?>['example.com'],
    });
    expect(text, contains('网页广告拦截：开'));
    expect(text, contains('EasyList'));
    expect(text, contains('白名单：example.com'));
    final String table = _spec('bookmarks').render!(<String, Object?>{
      'bookmarks': <Object?>[
        <String, Object?>{'id': 1, 'title': 'Dir', 'folder': true},
        <String, Object?>{
          'id': 2,
          'title': 'Ex',
          'url': 'https://example.com/',
          'parentId': 1,
        },
      ],
    });
    expect(table, contains('文件夹'));
    expect(table, contains('https://example.com/'));
  });
}
