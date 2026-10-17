import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

/// 总表里唯一的 `collection` 组（定序子命令由 shelf_commands 展开进来）。
CtlCommandGroup _collectionGroup() => kCtlCommandGroups.singleWhere(
  (CtlCommandGroup g) => g.name == 'collection',
);

CtlCommandSpec _spec(String command) => _collectionGroup().find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('命令组名在总表里全局唯一（同名组会让 CLI 解析器启动即撞名）', () {
    final Set<String> names = <String>{};
    for (final CtlCommandGroup g in kCtlCommandGroups) {
      expect(names.add(g.name), isTrue, reason: '命令组 ${g.name} 注册了两次');
    }
  });

  test('collection 组只注册一次，含 AI 排序在内的定序子命令都在同一组里', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'collection'),
      hasLength(1),
    );
    final List<String> names = <String>[
      for (final CtlCommandSpec s in _collectionGroup().commands) s.name,
    ];
    expect(names.toSet(), hasLength(names.length), reason: '子命令重名：$names');
    expect(
      names,
      containsAll(<String>['ls', 'get', 'add', 'remove', 'order', 'sort']),
    );
    // 旧的平行实现（独立 `items` 子命令、`/api/admin/collections` 路由根）已并入
    // `get` 与 `/api/admin/library/collections`。
    expect(names, isNot(contains('items')));
    expect(_spec('order').render, isNotNull);
    expect(_spec('sort').render, isNotNull);
  });

  test('CLI 能真的装出解析器并跑到 collection sort 的 usage（不撞名）', () async {
    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final int code = await runFushiCli(
      <String>['collection', 'sort', '--help'],
      environment: const <String, String>{},
      out: out,
      err: err,
    );
    expect(code, kCliExitOk, reason: '$err');
    expect(out.toString(), contains('--by'));
  });

  test('order：位置参数逐个成为成员键，路径在 library/collections 下', () {
    final CtlRequestSpec order = _build('order', <String>[
      '3',
      'video:a/b',
      'book:c',
    ]);
    expect(order.method, 'PUT');
    expect(order.path, '/api/admin/library/collections/3/order');
    expect(order.body, <String, Object?>{
      'keys': <String>['video:a/b', 'book:c'],
    });
    expect(() => _build('order', <String>['3']), _usageError());
    expect(() => _build('order', <String>['abc', 'video:a']), _usageError());
    expect(() => _build('order', <String>['0', 'video:a']), _usageError());
  });

  test('sort：--by 必填且限值域，--dry-run 只在给出时带上', () {
    final CtlRequestSpec ai = _build('sort', <String>['7', '--by', 'AI']);
    expect(ai.method, 'POST');
    expect(ai.path, '/api/admin/library/collections/7/sort');
    expect(ai.body, <String, Object?>{'by': 'ai'});
    final CtlRequestSpec dry = _build('sort', <String>[
      '7',
      '--by',
      'title',
      '--dry-run',
    ]);
    expect(dry.body, <String, Object?>{'by': 'title', 'dryRun': true});
    expect(() => _build('sort', <String>['7']), _usageError());
    expect(
      () => _build('sort', <String>['7', '--by', 'rating']),
      _usageError(),
    );
  });

  test('render：ls 带手动排过列；sort 标出 AI 定位的成员与是否落盘', () {
    final String ls = _spec('ls').render!(<String, Object?>{
      'collections': <Object?>[
        <String, Object?>{
          'id': 1,
          'name': 'Show',
          'type': 'playlist',
          'members': 3,
          'manualOrder': true,
        },
      ],
    });
    expect(ls, contains('Show'));
    expect(ls, contains('playlist'));
    expect(ls, contains('手动排过'));

    final String sorted = _spec('sort').render!(<String, Object?>{
      'id': 1,
      'status': 'aiOrdered',
      'changed': true,
      'persisted': false,
      'dryRun': true,
      'order': <Object?>[
        <String, Object?>{
          'key': 'video:v1',
          'title': 'E01',
          'ambiguous': false,
        },
        <String, Object?>{'key': 'video:sp', 'title': 'SP', 'ambiguous': true},
      ],
    });
    expect(sorted, contains('已按 AI 建议排序'));
    expect(sorted, contains('未落盘'));
    expect(sorted, contains('video:sp'));
    expect(
      sorted.split('\n').where((String l) => l.contains('*')),
      hasLength(1),
    );

    expect(
      _spec('sort').render!(<String, Object?>{
        'id': 1,
        'status': 'failed',
        'failure': 'network_error',
      }),
      contains('network_error'),
    );
  });
}
