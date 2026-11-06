import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group() =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == 'book');

CtlCommandSpec _spec(String command) => _group().find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('book 组只注册一次，三个子命令都有人类可读输出', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'book'),
      hasLength(1),
    );
    expect(
      <String>[for (final CtlCommandSpec s in _group().commands) s.name],
      <String>['search', 'get', 'apply'],
    );
    for (final CtlCommandSpec s in _group().commands) {
      expect(s.render, isNotNull, reason: s.name);
    }
  });

  test('search：剩余参数拼成搜索词，--source 限值域', () {
    final CtlRequestSpec plain = _build('search', <String>['四叶', '妹妹']);
    expect(plain.method, 'GET');
    expect(plain.path, '/api/admin/book/scrape');
    expect(plain.query, <String, String>{'query': '四叶 妹妹'});
    final CtlRequestSpec dl = _build('search', <String>[
      'RJ123456',
      '--source',
      'DLsite',
    ]);
    expect(dl.query, <String, String>{'query': 'RJ123456', 'source': 'dlsite'});
    expect(() => _build('search', <String>[]), _usageError());
    expect(
      () => _build('search', <String>['x', '--source', 'amazon']),
      _usageError(),
    );
  });

  test('get：源 + id 进路径（编码）', () {
    final CtlRequestSpec get = _build('get', <String>['bangumi', '11']);
    expect(get.method, 'GET');
    expect(get.path, '/api/admin/book/scrape/bangumi/11');
    expect(() => _build('get', <String>['amazon', '1']), _usageError());
    expect(() => _build('get', <String>['bangumi']), _usageError());
  });

  test('apply：默认只换封面；--title / --author 追加；--no-cover 要有别的字段', () {
    final CtlRequestSpec cover = _build('apply', <String>['book:猫/1', '11']);
    expect(cover.method, 'POST');
    expect(
      cover.path,
      '/api/admin/book/items/${Uri.encodeComponent('book:猫/1')}/scrape',
    );
    expect(cover.body, <String, Object?>{
      'id': '11',
      'fields': <String>['cover'],
    });
    final CtlRequestSpec all = _build('apply', <String>[
      'srt:u1',
      'RJ01',
      '--source',
      'dlsite',
      '--title',
      '--author',
      '--no-cover',
    ]);
    expect(all.body, <String, Object?>{
      'id': 'RJ01',
      'source': 'dlsite',
      'fields': <String>['title', 'author'],
    });
    expect(
      () => _build('apply', <String>['book:猫', '11', '--no-cover']),
      _usageError(),
    );
    expect(() => _build('apply', <String>['video:v', '11']), _usageError());
    expect(() => _build('apply', <String>['book:猫']), _usageError());
  });

  test('render：候选表、写回结果标出没写成的字段', () {
    expect(
      _spec('search').render!(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'source': 'bangumi',
            'id': '11',
            'title': '四叶妹妹',
            'year': 2003,
          },
        ],
      }),
      allOf(contains('四叶妹妹'), contains('2003')),
    );
    expect(
      _spec('search').render!(<String, Object?>{'candidates': <Object?>[]}),
      contains('没有匹配'),
    );
    final String applied = _spec('apply').render!(<String, Object?>{
      'key': 'book:猫',
      'candidate': <String, Object?>{'title': '四叶妹妹'},
      'requested': <Object?>['cover', 'author'],
      'applied': <Object?>['cover'],
    });
    expect(applied, contains('已写回：封面'));
    expect(applied, contains('未写回：作者'));
  });
}
