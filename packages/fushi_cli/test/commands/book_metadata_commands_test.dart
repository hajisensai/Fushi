import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/book_metadata_commands.dart'
    show kBookScrapeSources;
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
      <String>[
        'search',
        'get',
        'volumes',
        'apply',
        'art',
        'art-clear',
        'art-remove',
      ],
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

  test('search --nsfw：带上 nsfw=true；不加不传（拍板台 pr3497）', () {
    expect(_build('search', <String>['x', '--nsfw']).query, <String, String>{
      'query': 'x',
      'nsfw': 'true',
    });
    expect(_build('search', <String>['x']).query, <String, String>{
      'query': 'x',
    });
    expect(
      _spec('search').render!(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{'source': 'bangumi', 'id': '11', 'title': '四叶'},
        ],
        'hiddenNsfw': 2,
      }),
      allOf(contains('四叶'), contains('2 条 NSFW'), contains('--nsfw')),
    );
  });

  test('--source 认 mangabaka 与书目四源：anilist / openbd / ndl / rakuten', () {
    expect(kBookScrapeSources, <String>[
      'bangumi',
      'dlsite',
      'mangabaka',
      'anilist',
      'openbd',
      'ndl',
      'rakuten',
    ]);
    for (final String source in <String>[
      'anilist',
      'openbd',
      'ndl',
      'rakuten',
    ]) {
      final CtlRequestSpec spec = _build('search', <String>[
        '9784480432292',
        '--source',
        source.toUpperCase(),
      ]);
      expect(spec.query, <String, String>{
        'query': '9784480432292',
        'source': source,
      });
      expect(
        _build('get', <String>[source, '978-4-480-43229-2']).path,
        '/api/admin/book/scrape/$source/978-4-480-43229-2',
      );
    }
    final CtlRequestSpec apply = _build('apply', <String>[
      'book:猫',
      '99026',
      '--source',
      'anilist',
    ]);
    expect(apply.body, <String, Object?>{
      'id': '99026',
      'source': 'anilist',
      'fields': <String>['cover', 'details'],
    });
  });

  test('get：源 + id 进路径（编码）', () {
    final CtlRequestSpec get = _build('get', <String>['bangumi', '11']);
    expect(get.method, 'GET');
    expect(get.path, '/api/admin/book/scrape/bangumi/11');
    expect(() => _build('get', <String>['amazon', '1']), _usageError());
    expect(() => _build('get', <String>['bangumi']), _usageError());
  });

  test('apply：默认换封面 + 写条目资料；--title / --author 追加；都关掉要有别的字段', () {
    final CtlRequestSpec cover = _build('apply', <String>['book:猫/1', '11']);
    expect(cover.method, 'POST');
    expect(
      cover.path,
      '/api/admin/book/items/${Uri.encodeComponent('book:猫/1')}/scrape',
    );
    expect(cover.body, <String, Object?>{
      'id': '11',
      'fields': <String>['cover', 'details'],
    });
    final CtlRequestSpec all = _build('apply', <String>[
      'srt:u1',
      'RJ01',
      '--source',
      'dlsite',
      '--title',
      '--author',
      '--no-cover',
      '--no-details',
    ]);
    expect(all.body, <String, Object?>{
      'id': 'RJ01',
      'source': 'dlsite',
      'fields': <String>['title', 'author'],
    });
    expect(
      () => _build('apply', <String>[
        'book:猫',
        '11',
        '--no-cover',
        '--no-details',
      ]),
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

  test('mangabaka 是合法源', () {
    expect(
      _build('get', <String>['mangabaka', '8940']).path,
      '/api/admin/book/scrape/mangabaka/8940',
    );
    expect(
      _build('search', <String>['x', '--source', 'mangabaka']).query,
      <String, String>{'query': 'x', 'source': 'mangabaka'},
    );
  });

  test('art：合集 id 进路径；钉死参数三个一起给', () {
    final CtlRequestSpec plain = _build('art', <String>['7']);
    expect(plain.method, 'POST');
    expect(plain.path, '/api/admin/book/collections/7/scrape-art');
    expect(plain.body, <String, Object?>{});
    final CtlRequestSpec dry = _build('art', <String>['7', '--dry-run']);
    expect(dry.body, <String, Object?>{'dryRun': true});
    final CtlRequestSpec pinned = _build('art', <String>[
      '7',
      '--series-key',
      'k',
      '--pin-source',
      'MangaBaka',
      '--series-id',
      '8940',
    ]);
    expect(pinned.body, <String, Object?>{
      'seriesKey': 'k',
      'source': 'mangabaka',
      'seriesId': '8940',
    });
    expect(() => _build('art', <String>['x']), _usageError());
    expect(
      () => _build('art', <String>['7', '--series-key', 'k']),
      _usageError(),
    );
    expect(
      () => _build('art', <String>[
        '7',
        '--series-key',
        'k',
        '--pin-source',
        'dlsite',
        '--series-id',
        '1',
      ]),
      _usageError(),
    );
  });

  test('art-clear / art-remove：DELETE；art-remove 只收 book: 键', () {
    final CtlRequestSpec clear = _build('art-clear', <String>['7']);
    expect(clear.method, 'DELETE');
    expect(clear.path, '/api/admin/book/collections/7/scrape-art');
    final CtlRequestSpec remove = _build('art-remove', <String>['book:abc']);
    expect(remove.method, 'DELETE');
    expect(remove.path, '/api/admin/book/items/book%3Aabc/scraped-art');
    expect(() => _build('art-remove', <String>['srt:1']), _usageError());
    final String rendered = _spec('art-remove').render!(<String, Object?>{
      'removed': <Object?>['a', 'b'],
    });
    expect(rendered, contains('2'));
  });

  test('volumes / apply --volume：只对 mangabaka', () {
    expect(
      _build('volumes', <String>['8940']).path,
      '/api/admin/book/scrape/mangabaka/8940/volumes',
    );
    final CtlRequestSpec apply = _build('apply', <String>[
      'book:k',
      '8940',
      '--source',
      'mangabaka',
      '--volume',
      '3',
    ]);
    expect(apply.body!['volume'], 3);
    expect(
      () => _build('apply', <String>['book:k', '1', '--volume', '3']),
      _usageError(),
    );
    expect(
      () => _build('apply', <String>[
        'book:k',
        '1',
        '--source',
        'mangabaka',
        '--volume',
        'x',
      ]),
      _usageError(),
    );
  });
}
