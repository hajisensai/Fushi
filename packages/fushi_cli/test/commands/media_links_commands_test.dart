import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group(String name) =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == name);

CtlRequestSpec _build(String group, String command, List<String> args) {
  final CtlCommandSpec spec = _group(group).find(command)!;
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

String _render(String group, String command, Object? data) =>
    _group(group).find(command)!.render!(data);

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('links / people 两组各注册一次，子命令齐全', () {
    for (final String name in <String>['links', 'people']) {
      expect(
        kCtlCommandGroups.where((CtlCommandGroup g) => g.name == name),
        hasLength(1),
      );
    }
    expect(
      <String>[for (final CtlCommandSpec s in _group('links').commands) s.name],
      <String>['ls', 'accept', 'reject', 'find', 'add', 'remove', 'infer'],
    );
    expect(
      <String>[
        for (final CtlCommandSpec s in _group('people').commands) s.name,
      ],
      <String>['ls', 'get', 'same', 'not-same'],
    );
  });

  test('links ls：端点整段编码进路径；--state 限值域；种类不认识报用法错', () {
    final CtlRequestSpec ls = _build('links', 'ls', <String>[
      'video_episode:video/a b',
      '--state',
      'suggested',
    ]);
    expect(ls.method, 'GET');
    expect(
      ls.path,
      '/api/admin/links/${Uri.encodeComponent('video_episode:video/a b')}',
    );
    expect(ls.query, <String, String>{'state': 'suggested'});
    expect(() => _build('links', 'ls', <String>['anime:1']), _usageError());
    expect(() => _build('links', 'ls', <String>['book:']), _usageError());
    expect(
      () => _build('links', 'ls', <String>['book:x', '--state', 'x']),
      throwsA(isA<ArgParserException>()),
    );
  });

  test('accept / reject：另一端进 body，--relation 可选', () {
    final CtlRequestSpec accept = _build('links', 'accept', <String>[
      'book:原作',
      'game:g1',
    ]);
    expect(accept.method, 'POST');
    expect(
      accept.path,
      '/api/admin/links/${Uri.encodeComponent('book:原作')}/accept',
    );
    expect(accept.body, <String, Object?>{'other': 'game:g1'});
    final CtlRequestSpec reject = _build('links', 'reject', <String>[
      'book:原作',
      'video_collection:3',
      '--relation',
      'adaptation',
    ]);
    expect(reject.path, endsWith('/reject'));
    expect(reject.body, <String, Object?>{
      'other': 'video_collection:3',
      'relation': 'adaptation',
    });
    expect(() => _build('links', 'accept', <String>['book:x']), _usageError());
  });

  test('find：种类 + 标题查候选端点；种类不认识 / --limit 非法报用法错', () {
    final CtlRequestSpec find = _build('links', 'find', <String>[
      'music_album',
      'ヤマノススメ',
      '特典',
      '--limit',
      '5',
    ]);
    expect(find.method, 'GET');
    expect(find.path, '/api/admin/link-candidates');
    expect(find.query, <String, String>{
      'kind': 'music_album',
      'search': 'ヤマノススメ 特典',
      'limit': '5',
    });
    expect(_build('links', 'find', <String>['game']).query, <String, String>{
      'kind': 'game',
    });
    expect(() => _build('links', 'find', <String>['anime']), _usageError());
    expect(
      () => _build('links', 'find', <String>['game', '--limit', '0']),
      _usageError(),
    );
    expect(
      _render('links', 'find', <String, Object?>{
        'total': 1,
        'items': <Object?>[
          <String, Object?>{'endpoint': 'music_album:a1', 'title': '特典CD'},
        ],
      }),
      allOf(contains('music_album:a1'), contains('特典CD')),
    );
  });

  test('add：关系必填、adaptation 要 --self-is；remove 同 reject 的形状', () {
    final CtlRequestSpec add = _build('links', 'add', <String>[
      'music_album:a1',
      'video_collection:3',
      '--relation',
      'same_work',
    ]);
    expect(add.method, 'POST');
    expect(
      add.path,
      '/api/admin/links/${Uri.encodeComponent('music_album:a1')}/add',
    );
    expect(add.body, <String, Object?>{
      'other': 'video_collection:3',
      'relation': 'same_work',
    });
    final CtlRequestSpec song = _build('links', 'add', <String>[
      'music_track:t1',
      'video_collection:3',
      '--relation',
      'theme_song',
      '--role',
      'ed',
      '--episodes',
      '1-12',
    ]);
    expect(song.body, <String, Object?>{
      'other': 'video_collection:3',
      'relation': 'theme_song',
      'role': 'ed',
      'episodes': '1-12',
    });
    expect(
      _build('links', 'add', <String>[
        'book:原作',
        'video_collection:3',
        '--relation',
        'adaptation',
        '--self-is',
        'original',
      ]).body,
      <String, Object?>{
        'other': 'video_collection:3',
        'relation': 'adaptation',
        'selfIs': 'original',
      },
    );
    expect(
      () => _build('links', 'add', <String>[
        'book:原作',
        'video_collection:3',
        '--relation',
        'adaptation',
      ]),
      _usageError(),
    );
    expect(
      () => _build('links', 'add', <String>[
        'book:原作',
        'video_collection:3',
        '--relation',
        'soundtrack',
      ]),
      throwsA(isA<ArgParserException>()),
    );

    final CtlRequestSpec remove = _build('links', 'remove', <String>[
      'book:原作',
      'game:g1',
    ]);
    expect(remove.method, 'POST');
    expect(remove.path, endsWith('/remove'));
    expect(remove.body, <String, Object?>{'other': 'game:g1'});
  });

  test('infer：POST 到端点的 infer', () {
    final CtlRequestSpec infer = _build('links', 'infer', <String>['game:g1']);
    expect(infer.method, 'POST');
    expect(
      infer.path,
      '/api/admin/links/${Uri.encodeComponent('game:g1')}/infer',
    );
  });

  test('people：ls 搜索词与 --limit；get / same / not-same 的节点校验', () {
    final CtlRequestSpec ls = _build('people', 'ls', <String>[
      '花澤',
      '香菜',
      '--limit',
      '10',
    ]);
    expect(ls.path, '/api/admin/people');
    expect(ls.query, <String, String>{'search': '花澤 香菜', 'limit': '10'});
    expect(_build('people', 'ls', <String>[]).query, isEmpty);
    expect(
      () => _build('people', 'ls', <String>['--limit', '0']),
      _usageError(),
    );

    final CtlRequestSpec get = _build('people', 'get', <String>[
      'ref:video:p1',
    ]);
    expect(
      get.path,
      '/api/admin/people/${Uri.encodeComponent('ref:video:p1')}',
    );

    final CtlRequestSpec same = _build('people', 'same', <String>[
      'ref:video:p1',
      'ref:music:a1',
    ]);
    expect(same.method, 'POST');
    expect(same.path, endsWith('/same'));
    expect(same.body, <String, Object?>{'other': 'ref:music:a1', 'same': true});
    expect(
      _build('people', 'not-same', <String>[
        'ref:video:p1',
        'ref:music:a1',
      ]).body,
      <String, Object?>{'other': 'ref:music:a1', 'same': false},
    );
    expect(() => _build('people', 'get', <String>['p1']), _usageError());
  });

  test('render：关联表、推断结果标出 AI、人物详情', () {
    final Map<String, Object?> link = <String, Object?>{
      'state': 'suggested',
      'relation': 'adaptation',
      'other': <String, Object?>{
        'endpoint': 'book:原作',
        'title': '原作',
        'inLibrary': false,
      },
      'source': 'mal',
      'confidence': 0.8,
    };
    final String ls = _render('links', 'ls', <String, Object?>{
      'endpoint': 'video_episode:v',
      'title': 'アニメ',
      'links': <Object?>[link],
    });
    expect(ls, allOf(contains('建议'), contains('未入库'), contains('mal 0.8')));
    expect(
      _render('links', 'infer', <String, Object?>{
        'endpoint': 'book:x',
        'added': 1,
        'ai': true,
        'suggestions': <Object?>[link],
      }),
      allOf(contains('新增建议 1 条'), contains('AI')),
    );
    final String person = _render('people', 'get', <String, Object?>{
      'node': 'ref:video:p1',
      'name': '花澤香菜',
      'voiceRoles': <Object?>[
        <String, Object?>{
          'work': <String, Object?>{'title': 'アニメ'},
          'character': '千石撫子',
        },
      ],
      'suggestions': <Object?>[
        <String, Object?>{'node': 'ref:music:a1', 'name': '花澤香菜'},
      ],
    });
    expect(person, allOf(contains('千石撫子'), contains('ref:music:a1')));
  });
}
