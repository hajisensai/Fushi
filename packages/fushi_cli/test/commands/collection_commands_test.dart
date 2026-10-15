import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/collection_commands.dart';
import 'package:test/test.dart';

CtlCommandSpec _spec(String command) => collectionCommandGroups
    .firstWhere((CtlCommandGroup g) => g.name == 'collection')
    .find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('collection 组注册进总表，命令名不重复且都有 render', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'collection'),
      hasLength(1),
    );
    final Set<String> names = <String>{};
    for (final CtlCommandSpec s in collectionCommandGroups.single.commands) {
      expect(names.add(s.name), isTrue, reason: s.name);
      expect(s.render, isNotNull, reason: '${s.name} 缺 render');
    }
    expect(names, <String>{'ls', 'items', 'order', 'sort'});
  });

  test('ls / items', () {
    final CtlRequestSpec ls = _build('ls', <String>[]);
    expect(ls.method, 'GET');
    expect(ls.path, '/api/admin/collections');
    final CtlRequestSpec items = _build('items', <String>['12']);
    expect(items.method, 'GET');
    expect(items.path, '/api/admin/collections/12/items');
    expect(() => _build('items', <String>[]), _usageError());
    expect(() => _build('items', <String>['abc']), _usageError());
    expect(() => _build('items', <String>['0']), _usageError());
  });

  test('order：位置参数逐个成为成员键', () {
    final CtlRequestSpec order = _build('order', <String>[
      '3',
      'video:a/b',
      'video:c',
    ]);
    expect(order.method, 'PUT');
    expect(order.path, '/api/admin/collections/3/order');
    expect(order.body, <String, Object?>{
      'keys': <String>['video:a/b', 'video:c'],
    });
    expect(() => _build('order', <String>['3']), _usageError());
  });

  test('sort：--by 必填且限值域，--dry-run 只在给出时带上', () {
    final CtlRequestSpec ai = _build('sort', <String>['7', '--by', 'AI']);
    expect(ai.method, 'POST');
    expect(ai.path, '/api/admin/collections/7/sort');
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

  test('render：ls 表格、sort 标出 AI 定位的成员与是否落盘', () {
    final String ls = _spec('ls').render!(<String, Object?>{
      'collections': <Object?>[
        <String, Object?>{
          'id': 1,
          'name': 'Show',
          'type': 'playlist',
          'members': 3,
          'manualOrder': false,
        },
      ],
    });
    expect(ls, contains('Show'));
    expect(ls, contains('playlist'));

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
