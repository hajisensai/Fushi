import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/srs_commands.dart';
import 'package:test/test.dart';

CtlCommandSpec _spec(String command) =>
    srsCommandGroups.single.find(command) ??
    (throw StateError('srs 组没有 $command'));

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

String _render(String command, Object? data) => _spec(command).render!(data);

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('srs 组在总表里只注册一次，命令不重名、都有 summary 与 render', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'srs'),
      hasLength(1),
    );
    final Set<String> names = <String>{};
    for (final CtlCommandSpec s in srsCommandGroups.single.commands) {
      expect(names.add(s.name), isTrue, reason: s.name);
      expect(s.summary, isNotEmpty);
      expect(s.render, isNotNull, reason: s.name);
    }
  });

  test('decks / conflicts / stats：只读请求', () {
    expect(
      (_build('decks', <String>[]).method, _build('decks', <String>[]).path),
      ('GET', '/api/admin/srs/decks'),
    );
    expect(_build('conflicts', <String>[]).path, '/api/admin/srs/conflicts');
    final CtlRequestSpec stats = _build('stats', <String>['--deck', '日本語']);
    expect((stats.method, stats.path), ('GET', '/api/admin/srs/stats'));
    expect(stats.query, <String, String>{'deck': '日本語'});
    expect(_build('stats', <String>[]).query, isEmpty);
  });

  test('notes：位置参数拼成查询，--field / --deck / --cards / 分页', () {
    final CtlRequestSpec plain = _build('notes', <String>['tag:n5', 'is:due']);
    expect(plain.path, '/api/admin/srs/notes');
    expect(plain.query, <String, String>{
      'q': 'tag:n5 is:due',
      'mode': 'notes',
    });
    final CtlRequestSpec field = _build('notes', <String>[
      '魚',
      '--field',
      'Expression',
      '--deck',
      'JP::N5',
      '--cards',
      '--limit',
      '10',
      '--offset',
      '20',
    ]);
    expect(field.query, <String, String>{
      'q': '魚',
      'field': 'Expression',
      'deck': 'JP::N5',
      'mode': 'cards',
      'limit': '10',
      'offset': '20',
    });
    expect(
      () => _build('notes', <String>['--field', 'Expression']),
      _usageError(),
    );
    expect(() => _build('notes', <String>['--limit', '0']), _usageError());
    expect(() => _build('notes', <String>['--limit', 'x']), _usageError());
  });

  test('note：id 进路径（URL 编码）', () {
    expect(_build('note', <String>['a/b']).path, '/api/admin/srs/notes/a%2Fb');
    expect(() => _build('note', <String>[]), _usageError());
  });

  test('conflict-delete / conflict-keep：keep 必须 --yes，带 confirm', () {
    final CtlRequestSpec del = _build('conflict-delete', <String>['c1']);
    expect(
      (del.method, del.path),
      ('POST', '/api/admin/srs/conflicts/held/c1/delete'),
    );
    expect(() => _build('conflict-keep', <String>['c1']), _usageError());
    final CtlRequestSpec keep = _build('conflict-keep', <String>[
      'c1',
      '--yes',
    ]);
    expect(keep.path, '/api/admin/srs/conflicts/held/c1/keep');
    expect(keep.body, <String, Object?>{'confirm': true});
  });

  test('conflict-resolve：三个位置参数 + --keep，kind 限值域', () {
    final CtlRequestSpec r = _build('conflict-resolve', <String>[
      'card',
      'c9',
      'flag',
      '--keep',
      'replaced',
    ]);
    expect(
      (r.method, r.path),
      ('POST', '/api/admin/srs/conflicts/fields/resolve'),
    );
    expect(r.body, <String, Object?>{
      'kind': 'card',
      'entity': 'c9',
      'key': 'flag',
      'keep': 'replaced',
    });
    expect(
      () => _build('conflict-resolve', <String>['card', 'c9', 'flag']),
      _usageError(),
    );
    expect(
      () => _build('conflict-resolve', <String>[
        'book',
        'c9',
        'flag',
        '--keep',
        'current',
      ]),
      _usageError(),
    );
    expect(
      () => _build('conflict-resolve', <String>[
        'card',
        'c9',
        'flag',
        '--keep',
        'both',
      ]),
      throwsA(isA<FormatException>()),
    );
  });

  test('merge / not-duplicate：参数个数校验', () {
    final CtlRequestSpec merge = _build('merge', <String>['k', 'a', 'b', 'k']);
    expect(
      (merge.method, merge.path),
      ('POST', '/api/admin/srs/duplicates/merge'),
    );
    expect(merge.body, <String, Object?>{
      'keep': 'k',
      'absorb': <String>['a', 'b'],
    });
    expect(() => _build('merge', <String>['k']), _usageError());
    expect(() => _build('merge', <String>['k', 'k']), _usageError());
    final CtlRequestSpec dismiss = _build('not-duplicate', <String>[
      'a',
      'b',
      'a',
    ]);
    expect(dismiss.path, '/api/admin/srs/duplicates/dismiss');
    expect(dismiss.body, <String, Object?>{
      'notes': <String>['a', 'b'],
    });
    expect(() => _build('not-duplicate', <String>['a']), _usageError());
  });

  test('render：人类可读', () {
    expect(
      _render('decks', <String, Object?>{
        'decks': <Object?>[
          <String, Object?>{
            'id': 'd1',
            'name': 'JP',
            'new': 3,
            'learn': 1,
            'review': 7,
            'total': 20,
          },
        ],
      }),
      allOf(contains('JP'), contains('7')),
    );
    expect(
      _render('stats', <String, Object?>{
        'today': <String, Object?>{
          'reviews': 5,
          'correctRate': 0.8,
          'again': 1,
          'hard': 0,
          'good': 3,
          'easy': 1,
        },
        'due': <String, Object?>{
          'today': 4,
          'tomorrow': 2,
          'overdue': 1,
          'next7Days': 9,
        },
        'cards': <String, Object?>{'new': 10, 'total': 30},
        'retention30d': <String, Object?>{'rate': 0.9, 'reviews': 40},
        'desiredRetention': 0.9,
        'streak': <String, Object?>{'current': 3, 'longest': 8},
      }),
      allOf(contains('复习 5 次'), contains('80.0%'), contains('今天 4')),
    );
    expect(
      _render('conflicts', <String, Object?>{
        'held': <Object?>[],
        'fields': <Object?>[],
        'pendingNotes': <Object?>[],
        'duplicates': <Object?>[],
      }),
      '没有冲突',
    );
    final String conflicts = _render('conflicts', <String, Object?>{
      'held': <Object?>[
        <String, Object?>{
          'id': 'c1',
          'label': '魚',
          'kind': 'delete_edit',
          'others': 1,
        },
      ],
      'duplicates': <Object?>[
        <String, Object?>{
          'notes': <Object?>[
            <String, Object?>{'id': 'n1', 'label': '雪', 'reviews': 2},
            <String, Object?>{'id': 'n2', 'label': '雪', 'reviews': 0},
          ],
        },
      ],
    });
    expect(conflicts, allOf(contains('c1'), contains('n1'), contains('n2')));
    expect(
      _render('merge', <String, Object?>{
        'keep': 'n1',
        'absorbed': <String>['n2'],
        'linkedCards': 1,
        'unmatchedCards': 0,
      }),
      contains('n2 并进 n1'),
    );
    expect(
      _render('notes', <String, Object?>{
        'mode': 'notes',
        'total': 1,
        'items': <Object?>[
          <String, Object?>{'noteId': 'n1', 'sortField': '魚', 'cards': 2},
        ],
      }),
      allOf(contains('共 1 条'), contains('魚')),
    );
  });
}
