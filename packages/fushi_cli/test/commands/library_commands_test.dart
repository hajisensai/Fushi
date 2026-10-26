import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/library_commands.dart';
import 'package:fushi_cli/src/commands/reader_commands.dart'
    show kOcrEngineKeys;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

CtlCommandGroup _group(String name) =>
    libraryCommandGroups.singleWhere((CtlCommandGroup g) => g.name == name);

CtlCommandSpec _spec(String name, {String group = 'library'}) =>
    _group(group).find(name) ?? (throw StateError('$group $name'));

/// 与 CLI 主循环同样装配解析器（`--help` + 命令自己的 option）后 build。
CtlRequestSpec _build(
  String name,
  List<String> args, {
  String group = 'library',
}) {
  final CtlCommandSpec spec = _spec(name, group: group);
  final ArgParser parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false);
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

void main() {
  group('library organize（AI 整理库）', () {
    test('organize：--domain 必填、--yes 才带同意', () {
      expect(
        () => _build('organize', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec r = _build('organize', <String>[
        '--domain',
        'books',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/organize');
      expect(r.body, <String, Object?>{'domain': 'books'});
      expect(
        _build('organize', <String>['--domain', 'video', '--yes']).body,
        <String, Object?>{'domain': 'video', 'yes': true},
      );
      expect(
        () => _build('organize', <String>['--domain', 'music']),
        throwsA(isA<FormatException>()),
      );
    });

    test('organize-history / organize-undo 的路径', () {
      final CtlRequestSpec h = _build('organize-history', <String>[
        '--limit',
        '5',
      ]);
      expect(h.method, 'GET');
      expect(h.path, '/api/admin/library/organize/runs');
      expect(h.query, <String, String>{'limit': '5'});
      final CtlRequestSpec u = _build('organize-undo', <String>['12']);
      expect(u.method, 'POST');
      expect(u.path, '/api/admin/library/organize/runs/12/undo');
      expect(
        () => _build('organize-undo', <String>['x']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  test('命令组与子命令齐全', () {
    expect(libraryCommandGroups.map((CtlCommandGroup g) => g.name), <String>[
      'library',
      'collection',
      'tag',
      'bookmark',
      'favorite',
      'reader',
      'audiobook',
      'ocr',
    ]);
    expect(
      _group('library').commands.map((CtlCommandSpec s) => s.name),
      <String>[
        'ls',
        'get',
        'rm',
        'import',
        'open',
        'history',
        'sources',
        'scan',
        'organize',
        'organize-history',
        'organize-undo',
        'source-add',
        'source-rename',
        'source-rm',
        'rename',
        'cover',
        'complete',
        'reset',
      ],
    );
  });

  test('全部请求都落在 /api/admin/library/ 下', () {
    final List<CtlRequestSpec> requests = <CtlRequestSpec>[
      _build('ls', const <String>[]),
      _build('get', const <String>['book:x']),
      _build('rm', const <String>['book:x', '--yes']),
      _build('import', const <String>['/a.epub']),
      _build('open', const <String>['book:x']),
      _build('history', const <String>[]),
      _build('sources', const <String>[]),
      _build('scan', const <String>[]),
    ];
    for (final CtlRequestSpec request in requests) {
      expect(request.path, startsWith('/api/admin/library/'));
    }
  });

  group('ls', () {
    test('无参数：GET items、空 query', () {
      final CtlRequestSpec r = _build('ls', const <String>[]);
      expect(r.method, 'GET');
      expect(r.path, '/api/admin/library/items');
      expect(r.query, isEmpty);
    });

    test('--kind / --search / --limit 进 query；kind 规整成小写', () {
      final CtlRequestSpec r = _build('ls', const <String>[
        '--kind',
        'Book, manga',
        '--search',
        '猫',
        '--limit',
        '5',
      ]);
      expect(r.query, <String, String>{
        'kind': 'book,manga',
        'search': '猫',
        'limit': '5',
      });
    });

    test('位置参数当搜索词并拼起来', () {
      final CtlRequestSpec r = _build('ls', const <String>['吾輩は', '猫']);
      expect(r.query, <String, String>{'search': '吾輩は 猫'});
    });

    test('未知 kind / 非法 limit → 用法错误', () {
      expect(
        () => _build('ls', const <String>['--kind', 'comic']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('ls', const <String>['--limit', '0']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('ls', const <String>['--limit', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('表格渲染带截断与隐藏模块提示', () {
      final String text = _spec('ls').render!(<String, Object?>{
        'total': 3,
        'items': <Object?>[
          <String, Object?>{
            'key': 'book:猫',
            'kind': 'book',
            'progress': '37%',
            'title': '猫',
          },
        ],
        'hiddenKinds': <String>['game'],
      });
      expect(text, contains('book:猫'));
      expect(text, contains('37%'));
      expect(text, contains('共 3 条'));
      expect(text, contains('game'));
    });
  });

  group('get', () {
    test('键整体编码成一段路径（id 里的 / 不拆段）', () {
      final CtlRequestSpec r = _build('get', const <String>[
        'video:video/ext/ab c',
      ]);
      expect(r.method, 'GET');
      expect(r.path, '/api/admin/library/items/video%3Avideo%2Fext%2Fab%20c');
      expect(
        Uri.parse('http://h${r.path}').pathSegments.last,
        'video:video/ext/ab c',
      );
    });

    test('缺 key → 用法错误', () {
      expect(
        () => _build('get', const <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('rm', () {
    test('没有 --yes → 用法错误', () {
      expect(
        () => _build('rm', const <String>['book:x']),
        throwsA(
          isA<CtlUsageError>().having(
            (CtlUsageError e) => e.message,
            'message',
            contains('--yes'),
          ),
        ),
      );
    });

    test('缺 key → 用法错误', () {
      expect(
        () => _build('rm', const <String>['--yes']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('--yes：DELETE + body 带 confirm 与三个选项', () {
      final CtlRequestSpec r = _build('rm', const <String>[
        'srt:srtbook_1',
        '--yes',
        '--everywhere',
        '--delete-files',
      ]);
      expect(r.method, 'DELETE');
      expect(r.path, '/api/admin/library/items/srt%3Asrtbook_1');
      expect(r.body, <String, Object?>{
        'confirm': true,
        'everywhere': true,
        'deleteFiles': true,
        'deleteStatistics': false,
      });
    });
  });

  group('import', () {
    test('相对路径在 CLI 侧转绝对路径；缺省 duplicate=skip', () {
      final CtlRequestSpec r = _build('import', const <String>[
        'a.epub',
        'dir/b.cbz',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/import');
      expect(r.body, <String, Object?>{
        'paths': <String>[
          p.normalize(p.absolute('a.epub')),
          p.normalize(p.absolute('dir/b.cbz')),
        ],
        'duplicate': 'skip',
      });
    });

    test('--kind / --duplicate 透传', () {
      final CtlRequestSpec r = _build('import', const <String>[
        '/x/book.epub',
        '/x/book.srt',
        '/x/01.mp3',
        '--kind',
        'audiobook',
        '--duplicate',
        'suffix',
      ]);
      expect(r.body!['kind'], 'audiobook');
      expect(r.body!['duplicate'], 'suffix');
      expect(r.body!['paths'], hasLength(3));
    });

    test('没有路径 → 用法错误；非法 kind → 解析失败', () {
      expect(
        () => _build('import', const <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('import', const <String>['/a', '--kind', 'pdf']),
        throwsA(isA<FormatException>()),
      );
    });

    test('渲染逐条结果', () {
      final String text = _spec('import').render!(<String, Object?>{
        'ok': false,
        'results': <Object?>[
          <String, Object?>{
            'path': '/a.epub',
            'status': 'imported',
            'keys': <String>['book:a'],
          },
          <String, Object?>{
            'path': '/b.mkv',
            'status': 'unsupported',
            'message': '视频文件请用 open',
          },
        ],
      });
      expect(text, contains('[已导入] /a.epub → book:a'));
      expect(text, contains('[不支持] /b.mkv'));
      expect(text, contains('视频文件请用 open'));
    });
  });

  group('open', () {
    test('POST …/open，--at 进 body', () {
      final CtlRequestSpec r = _build('open', const <String>[
        'video:v1',
        '--at',
        '1:30',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/items/video%3Av1/open');
      expect(r.body, <String, Object?>{'at': '1:30'});
    });

    test('不给 --at 时 body 为空对象', () {
      final CtlRequestSpec r = _build('open', const <String>['book:x']);
      expect(r.body, isEmpty);
    });

    test('缺 key → 用法错误', () {
      expect(
        () => _build('open', const <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('history', () {
    test('缺省不带 limit；-n 透传；非法值报错', () {
      expect(_build('history', const <String>[]).query, isEmpty);
      final CtlRequestSpec r = _build('history', const <String>['-n', '5']);
      expect(r.path, '/api/admin/library/history');
      expect(r.query, <String, String>{'limit': '5'});
      expect(
        () => _build('history', const <String>['-n', '-1']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('sources / scan', () {
    test('sources --kind 进 query', () {
      final CtlRequestSpec r = _build('sources', const <String>[
        '--kind',
        'video',
      ]);
      expect(r.method, 'GET');
      expect(r.path, '/api/admin/library/sources');
      expect(r.query, <String, String>{'kind': 'video'});
    });

    test('scan --kind / --source 进 body', () {
      final CtlRequestSpec r = _build('scan', const <String>[
        '--kind',
        'book',
        '--source',
        '3',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/scan');
      expect(r.body, <String, Object?>{'kind': 'book', 'source': 3});
    });

    test('scan --source 非整数 → 用法错误', () {
      expect(
        () => _build('scan', const <String>['--source', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('scan 渲染带错误', () {
      final String text = _spec('scan').render!(<String, Object?>{
        'results': <Object?>[
          <String, Object?>{
            'id': 1,
            'label': '动画',
            'discovered': 10,
            'imported': 2,
            'error': '目录不存在',
          },
        ],
      });
      expect(text, contains('#1 动画：发现 10 个，入库 2 个'));
      expect(text, contains('目录不存在'));
    });
  });
  test('新增命令组的请求同样落在 /api/admin/library/ 下', () {
    final List<CtlRequestSpec> requests = <CtlRequestSpec>[
      _build('source-add', const <String>['/d', '--kind', 'video']),
      _build('source-rename', const <String>['3', '新名']),
      _build('source-rm', const <String>['3', '--yes']),
      _build('rename', const <String>['book:x', '新书名']),
      _build('cover', const <String>['book:x', '/a.png']),
      _build('complete', const <String>['book:x']),
      _build('reset', const <String>['book:x', '--yes']),
      _build('ls', const <String>[], group: 'collection'),
      _build('ls', const <String>[], group: 'tag'),
      _build('ls', const <String>['book:x'], group: 'bookmark'),
      _build('ls', const <String>[], group: 'favorite'),
      _build('status', const <String>[], group: 'reader'),
      _build('jobs', const <String>[], group: 'audiobook'),
      _build('status', const <String>[], group: 'ocr'),
    ];
    for (final CtlRequestSpec request in requests) {
      expect(request.path, startsWith('/api/admin/library/'));
    }
  });

  group('open 位置参数', () {
    test('--chapter / --progress / --page 进 body', () {
      final CtlRequestSpec r = _build('open', const <String>[
        'book:x',
        '--chapter',
        '3',
        '--progress',
        '40',
      ]);
      expect(r.body, <String, Object?>{'chapter': 3, 'progress': 40.0});
      expect(
        _build('open', const <String>['book:m', '--page', '12']).body,
        <String, Object?>{'page': 12},
      );
    });

    test('从 0 数 / 非数字 → 用法错误', () {
      expect(
        () => _build('open', const <String>['book:x', '--chapter', '0']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('open', const <String>['book:x', '--page', '0']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('open', const <String>['book:x', '--progress', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('library 来源 / 改名 / 封面 / 读完 / 重置', () {
    test('source-add 必须给 --kind，路径转绝对', () {
      final CtlRequestSpec r = _build('source-add', const <String>[
        'anime',
        '--kind',
        'video',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/sources');
      expect(r.body, <String, Object?>{
        'path': p.normalize(p.absolute('anime')),
        'kind': 'video',
      });
      expect(
        () => _build('source-add', const <String>['/d']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('source-rename / source-rm', () {
      final CtlRequestSpec rename = _build('source-rename', const <String>[
        '4',
        '新',
        '名字',
      ]);
      expect(rename.method, 'PUT');
      expect(rename.path, '/api/admin/library/sources/4');
      expect(rename.body, <String, Object?>{'label': '新 名字'});
      expect(
        () => _build('source-rm', const <String>['4']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec rm = _build('source-rm', const <String>[
        '4',
        '--yes',
        '--migrate-to',
        '7',
      ]);
      expect(rm.method, 'DELETE');
      expect(rm.body, <String, Object?>{'confirm': true, 'migrateTo': 7});
      expect(
        () => _build('source-rm', const <String>['x', '--yes']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rename：新名字拼起来；--reset 清除改名且不带名字', () {
      final CtlRequestSpec r = _build('rename', const <String>[
        'srt:u1',
        '銀河',
        '鉄道',
      ]);
      expect(r.method, 'PUT');
      expect(r.path, '/api/admin/library/items/srt%3Au1/title');
      expect(r.body, <String, Object?>{'title': '銀河 鉄道'});
      expect(
        _build('rename', const <String>['book:x', '--reset']).body,
        <String, Object?>{'reset': true},
      );
      expect(
        () => _build('rename', const <String>['book:x', '--reset', 'y']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('rename', const <String>['book:x']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('cover：URL 原样、本地路径转绝对、--reset', () {
      expect(
        _build('cover', const <String>[
          'video:v',
          'https://example.com/a.jpg',
        ]).body,
        <String, Object?>{'url': 'https://example.com/a.jpg'},
      );
      final CtlRequestSpec local = _build('cover', const <String>[
        'book:x',
        'c.png',
      ]);
      expect(local.path, '/api/admin/library/items/book%3Ax/cover');
      expect(local.body, <String, Object?>{
        'path': p.normalize(p.absolute('c.png')),
      });
      expect(
        _build('cover', const <String>['book:x', '--reset']).body,
        <String, Object?>{'reset': true},
      );
    });

    test('complete / --undo；reset 需 --yes 并带 stats', () {
      expect(
        _build('complete', const <String>['book:x']).body,
        <String, Object?>{'completed': true},
      );
      expect(
        _build('complete', const <String>['book:x', '--undo']).body,
        <String, Object?>{'completed': false},
      );
      expect(
        () => _build('reset', const <String>['book:x']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec reset = _build('reset', const <String>[
        'video:v',
        '--yes',
        '--stats',
        'last',
      ]);
      expect(reset.method, 'POST');
      expect(reset.path, '/api/admin/library/items/video%3Av/reset');
      expect(reset.body, <String, Object?>{'confirm': true, 'stats': 'last'});
    });
  });

  group('collection', () {
    test('ls --item / get / create / rename', () {
      expect(
        _build('ls', const <String>[
          '--item',
          'book:x',
        ], group: 'collection').query,
        <String, String>{'key': 'book:x'},
      );
      expect(
        _build('get', const <String>['5'], group: 'collection').path,
        '/api/admin/library/collections/5',
      );
      final CtlRequestSpec create = _build('create', const <String>[
        '夏の',
        '合集',
        '--type',
        'playlist',
      ], group: 'collection');
      expect(create.method, 'POST');
      expect(create.body, <String, Object?>{
        'name': '夏の 合集',
        'type': 'playlist',
      });
      final CtlRequestSpec rename = _build('rename', const <String>[
        '5',
        '新名',
      ], group: 'collection');
      expect(rename.method, 'PUT');
      expect(rename.body, <String, Object?>{'name': '新名'});
      expect(
        () => _build('get', const <String>['x'], group: 'collection'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rm 需 --yes；add / remove 带 keys', () {
      expect(
        () => _build('rm', const <String>['5'], group: 'collection'),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec rm = _build('rm', const <String>[
        '5',
        '--yes',
      ], group: 'collection');
      expect(rm.method, 'DELETE');
      expect(rm.body, <String, Object?>{'confirm': true});
      final CtlRequestSpec add = _build('add', const <String>[
        '5',
        'book:a',
        'srt:b',
      ], group: 'collection');
      expect(add.method, 'POST');
      expect(add.path, '/api/admin/library/collections/5/members');
      expect(add.body, <String, Object?>{
        'keys': <String>['book:a', 'srt:b'],
      });
      final CtlRequestSpec remove = _build('remove', const <String>[
        '5',
        'book:a',
      ], group: 'collection');
      expect(remove.method, 'DELETE');
      expect(remove.body, <String, Object?>{
        'keys': <String>['book:a'],
      });
      expect(
        () => _build('add', const <String>['5'], group: 'collection'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('cover：本地 / URL / --reset', () {
      expect(
        _build('cover', const <String>[
          '5',
          'http://x/a.jpg',
        ], group: 'collection').body,
        <String, Object?>{'url': 'http://x/a.jpg'},
      );
      expect(
        _build('cover', const <String>[
          '5',
          '--reset',
        ], group: 'collection').body,
        <String, Object?>{'reset': true},
      );
    });

    test('渲染成员结果与移空提示', () {
      final String text = _spec('remove', group: 'collection').render!(
        <String, Object?>{
          'collectionDeleted': true,
          'results': <Object?>[
            <String, Object?>{'key': 'book:a', 'status': 'removed'},
          ],
        },
      );
      expect(text, contains('[已移除] book:a'));
      expect(text, contains('自动删除'));
    });
  });

  group('tag', () {
    test('ls 不带键列全部，带键列条目的标签', () {
      expect(
        _build('ls', const <String>[], group: 'tag').path,
        '/api/admin/library/tags',
      );
      expect(
        _build('ls', const <String>['book:x'], group: 'tag').path,
        '/api/admin/library/items/book%3Ax/tags',
      );
    });

    test('create / edit / rm', () {
      final CtlRequestSpec create = _build('create', const <String>[
        '名作',
        '--color',
        '#FF0000',
      ], group: 'tag');
      expect(create.body, <String, Object?>{'name': '名作', 'color': '#FF0000'});
      expect(
        () => _build('edit', const <String>['3'], group: 'tag'),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec edit = _build('edit', const <String>[
        '3',
        '--name',
        '新',
      ], group: 'tag');
      expect(edit.method, 'PUT');
      expect(edit.path, '/api/admin/library/tags/3');
      expect(edit.body, <String, Object?>{'name': '新'});
      expect(
        () => _build('rm', const <String>['3'], group: 'tag'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('add / remove：条目键与 collection:<id> 走不同路径', () {
      final CtlRequestSpec item = _build('add', const <String>[
        'video:v',
        '名作',
        '再看',
        '--create',
      ], group: 'tag');
      expect(item.method, 'POST');
      expect(item.path, '/api/admin/library/items/video%3Av/tags');
      expect(item.body, <String, Object?>{
        'tags': <String>['名作', '再看'],
        'create': true,
      });
      final CtlRequestSpec collection = _build('remove', const <String>[
        'collection:9',
        '名作',
      ], group: 'tag');
      expect(collection.method, 'DELETE');
      expect(collection.path, '/api/admin/library/collections/9/tags');
      expect(
        () => _build('add', const <String>['collection:x', 'a'], group: 'tag'),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('bookmark', () {
    test('add：EPUB 用 --chapter，PDF 用 --page，二选一', () {
      final CtlRequestSpec epub = _build('add', const <String>[
        'book:x',
        '--chapter',
        '2',
        '--progress',
        '50',
        '--label',
        '名场面',
      ], group: 'bookmark');
      expect(epub.path, '/api/admin/library/items/book%3Ax/bookmarks');
      expect(epub.body, <String, Object?>{
        'chapter': 2,
        'progress': 50.0,
        'label': '名场面',
      });
      expect(
        _build('add', const <String>[
          'book:p',
          '--page',
          '7',
        ], group: 'bookmark').body,
        <String, Object?>{'page': 7},
      );
      expect(
        () => _build('add', const <String>['book:x'], group: 'bookmark'),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('add', const <String>[
          'book:x',
          '--chapter',
          '1',
          '--page',
          '1',
        ], group: 'bookmark'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rm 走 DELETE bookmarks/<id>；渲染位置', () {
      final CtlRequestSpec rm = _build('rm', const <String>[
        '12',
      ], group: 'bookmark');
      expect(rm.method, 'DELETE');
      expect(rm.path, '/api/admin/library/bookmarks/12');
      final String text = _spec('ls', group: 'bookmark').render!(
        <String, Object?>{
          'bookmarks': <Object?>[
            <String, Object?>{
              'id': 1,
              'chapter': 3,
              'progress': 25,
              'label': 'Ch.3',
            },
            <String, Object?>{'id': 2, 'page': 9, 'label': 'P.9'},
          ],
        },
      );
      expect(text, contains('#1 第 3 章 25%'));
      expect(text, contains('#2 P.9'));
    });
  });

  group('favorite', () {
    test('ls 按条目筛 + limit；rm 编码 id；clear 需 --yes', () {
      expect(
        _build('ls', const <String>[
          'book:x',
          '-n',
          '3',
        ], group: 'favorite').query,
        <String, String>{'key': 'book:x', 'limit': '3'},
      );
      expect(
        _build('rm', const <String>['hl_1_2'], group: 'favorite').path,
        '/api/admin/library/favorites/hl_1_2',
      );
      expect(
        () => _build('clear', const <String>[], group: 'favorite'),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        _build('clear', const <String>['--yes'], group: 'favorite').body,
        <String, Object?>{'confirm': true},
      );
    });

    test('export：输出路径转绝对，格式 / 条目 / 去重透传', () {
      final CtlRequestSpec r = _build('export', const <String>[
        'out.csv',
        '--format',
        'csv',
        '--item',
        'video:v',
        '--dedupe',
      ], group: 'favorite');
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/favorites/export');
      expect(r.body, <String, Object?>{
        'path': p.normalize(p.absolute('out.csv')),
        'format': 'csv',
        'key': 'video:v',
        'dedupe': true,
      });
    });
  });

  group('reader', () {
    test('next / prev 带 count；越界报错', () {
      expect(
        _build('next', const <String>['-n', '3'], group: 'reader').body,
        <String, Object?>{'direction': 'next', 'count': 3},
      );
      expect(
        _build('prev', const <String>[], group: 'reader').body,
        <String, Object?>{'direction': 'prev'},
      );
      expect(
        () => _build('next', const <String>['-n', '0'], group: 'reader'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('goto：chapter 与 percent 二选一，progress 只配 chapter', () {
      expect(
        _build('goto', const <String>[
          '--chapter',
          '4',
          '--progress',
          '10',
        ], group: 'reader').body,
        <String, Object?>{'chapter': 4, 'progress': 10.0},
      );
      expect(
        _build('goto', const <String>[
          '--percent',
          '55.5',
        ], group: 'reader').body,
        <String, Object?>{'percent': 55.5},
      );
      expect(
        () => _build('goto', const <String>[], group: 'reader'),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('goto', const <String>[
          '--percent',
          '5',
          '--progress',
          '1',
        ], group: 'reader'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('渲染当前位置与无阅读器', () {
      final CtlCommandSpec status = _spec('status', group: 'reader');
      expect(
        status.render!(<String, Object?>{'active': false}),
        contains('没有打开'),
      );
      final String text = status.render!(<String, Object?>{
        'active': true,
        'title': '猫',
        'chapter': 2,
        'chapterCount': 10,
        'chapterProgress': 30.0,
        'percent': 12.5,
        'ready': true,
      });
      expect(text, contains('第 2/10 章'));
      expect(text, contains('全书 12.5%'));
    });
  });

  group('audiobook', () {
    test('attach：音频可重复，路径转绝对；什么都不给报错', () {
      final CtlRequestSpec r = _build('attach', const <String>[
        'book:x',
        '-a',
        '01.mp3',
        '-a',
        '02.mp3',
        '--subtitle',
        'book.srt',
      ], group: 'audiobook');
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/items/book%3Ax/audiobook');
      expect(r.body, <String, Object?>{
        'audio': <String>[
          p.normalize(p.absolute('01.mp3')),
          p.normalize(p.absolute('02.mp3')),
        ],
        'subtitle': <String>[p.normalize(p.absolute('book.srt'))],
      });
      expect(
        () => _build('attach', const <String>['book:x'], group: 'audiobook'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rematch：window / threshold 透传', () {
      final CtlRequestSpec r = _build('rematch', const <String>[
        'srt:u',
        '--window',
        '300',
        '--threshold',
        '0.6',
      ], group: 'audiobook');
      expect(r.path, '/api/admin/library/items/srt%3Au/audiobook/rematch');
      expect(r.body, <String, Object?>{'window': 300, 'threshold': 0.6});
      expect(
        () => _build('rematch', const <String>[
          'srt:u',
          '--window',
          '0',
        ], group: 'audiobook'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('transcribe / jobs / job / cancel / retry / job-rm', () {
      final CtlRequestSpec t = _build('transcribe', const <String>[
        'a.mp3',
        'b.mp3',
        '--text',
        'book.epub',
        '--title',
        '銀河',
      ], group: 'audiobook');
      expect(t.method, 'POST');
      expect(t.path, '/api/admin/library/audiobook/jobs');
      expect(t.body, <String, Object?>{
        'audio': <String>[
          p.normalize(p.absolute('a.mp3')),
          p.normalize(p.absolute('b.mp3')),
        ],
        'text': <String>[p.normalize(p.absolute('book.epub'))],
        'title': '銀河',
      });
      expect(
        () => _build('transcribe', const <String>[], group: 'audiobook'),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        _build('job', const <String>['1-0'], group: 'audiobook').path,
        '/api/admin/library/audiobook/jobs/1-0',
      );
      expect(
        _build('cancel', const <String>['1-0'], group: 'audiobook').path,
        '/api/admin/library/audiobook/jobs/1-0/cancel',
      );
      expect(
        _build('retry', const <String>['1-0'], group: 'audiobook').path,
        '/api/admin/library/audiobook/jobs/1-0/retry',
      );
      expect(
        _build('job-rm', const <String>['1-0'], group: 'audiobook').method,
        'DELETE',
      );
    });

    test('渲染任务进度', () {
      final String text = _spec('jobs', group: 'audiobook').render!(
        <String, Object?>{
          'jobs': <Object?>[
            <String, Object?>{
              'id': '1-0',
              'title': '銀河',
              'status': 'running',
              'phase': 'transcribing',
              'progress': 42.5,
            },
          ],
        },
      );
      expect(text, contains('1-0  running/transcribing 42.5%  銀河'));
    });
  });

  group('ocr', () {
    test('start / status / cancel', () {
      final CtlRequestSpec start = _build('start', const <String>[
        'book:m',
      ], group: 'ocr');
      expect(start.method, 'POST');
      expect(start.path, '/api/admin/library/ocr');
      expect(start.body, <String, Object?>{'key': 'book:m'});
      expect(
        _build('status', const <String>['book:m'], group: 'ocr').query,
        <String, String>{'key': 'book:m'},
      );
      expect(
        _build('cancel', const <String>['book:m'], group: 'ocr').path,
        '/api/admin/library/ocr/cancel',
      );
      expect(
        () => _build('start', const <String>[], group: 'ocr'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('渲染进度', () {
      final String text = _spec('status', group: 'ocr').render!(
        <String, Object?>{
          'jobs': <Object?>[
            <String, Object?>{
              'key': 'book:m',
              'state': 'running',
              'pagesDone': 3,
              'pagesTotal': 20,
              'queued': 2,
            },
          ],
        },
      );
      expect(text, contains('book:m  running 3/20 页'));
      expect(text, contains('排队 2 个'));
    });
  });
  group('补缺口：任务 / 跳页 / 转录挂到已有书 / OCR 强制与同意', () {
    test('attach / rematch 带 --wait；tasks / task / task-cancel 路径', () {
      expect(
        _build('attach', const <String>[
          'book:x',
          '-s',
          '/b.srt',
          '--wait',
        ], group: 'audiobook').body!['wait'],
        isTrue,
      );
      expect(
        _build('rematch', const <String>[
          'book:x',
        ], group: 'audiobook').body!.containsKey('wait'),
        isFalse,
      );
      expect(
        _build('tasks', const <String>[], group: 'audiobook').path,
        '/api/admin/library/audiobook/tasks',
      );
      final CtlRequestSpec task = _build('task', const <String>[
        'attach-1-0',
        '--wait',
      ], group: 'audiobook');
      expect(task.path, '/api/admin/library/audiobook/tasks/attach-1-0');
      expect(task.query, <String, String>{'wait': 'true'});
      final CtlRequestSpec cancel = _build('task-cancel', const <String>[
        'attach-1-0',
      ], group: 'audiobook');
      expect(cancel.method, 'POST');
      expect(
        cancel.path,
        '/api/admin/library/audiobook/tasks/attach-1-0/cancel',
      );
    });

    test('任务渲染：进行中给出查看 / 取消提示，完成带结果', () {
      final CtlCommandSpec task = _spec('task', group: 'audiobook');
      final String running = task.render!(<String, Object?>{
        'id': 'attach-1-0',
        'kind': 'attach',
        'key': 'book:x',
        'status': 'running',
        'phase': 'matching',
        'progress': 55.0,
      });
      expect(running, contains('进行中 matching 55.0%'));
      expect(running, contains('task-cancel attach-1-0'));
      final String done = task.render!(<String, Object?>{
        'id': 'rematch-1-0',
        'kind': 'rematch',
        'key': 'book:x',
        'status': 'done',
        'result': <String, Object?>{
          'key': 'book:x',
          'matched': 90,
          'total': 100,
          'rate': 90.0,
          'window': 300,
        },
      });
      expect(done, contains('90/100 句'));
    });

    test('transcribe --into 透传，且与 --text 互斥', () {
      expect(
        _build('transcribe', const <String>[
          '/a.mp3',
          '--into',
          'book:猫',
        ], group: 'audiobook').body!['into'],
        'book:猫',
      );
      expect(
        () => _build('transcribe', const <String>[
          '/a.mp3',
          '--into',
          'book:猫',
          '--text',
          '/b.txt',
        ], group: 'audiobook'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('reader goto --page；三者只给一个；渲染 PDF / 漫画', () {
      expect(
        _build('goto', const <String>['--page', '12'], group: 'reader').body,
        <String, Object?>{'page': 12},
      );
      expect(
        () => _build('goto', const <String>[
          '--page',
          '1',
          '--chapter',
          '1',
        ], group: 'reader'),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlCommandSpec status = _spec('status', group: 'reader');
      expect(
        status.render!(<String, Object?>{
          'active': true,
          'kind': 'pdf',
          'title': '文書',
          'page': 3,
          'pageCount': 30,
          'ready': true,
        }),
        '[pdf] 文書：第 3/30 页',
      );
      expect(
        status.render!(<String, Object?>{
          'active': true,
          'kind': 'manga',
          'title': '漫',
          'chapter': 2,
          'chapterCount': 9,
          'page': 5,
          'pageCount': 20,
          'ready': true,
        }),
        '[manga] 漫：第 2/9 话，第 5/20 页',
      );
    });

    test('ocr start --force / --consent-upload', () {
      expect(
        _build('start', const <String>[
          'book:m',
          '--force',
          '--consent-upload',
        ], group: 'ocr').body,
        <String, Object?>{
          'key': 'book:m',
          'force': true,
          'consentUpload': true,
        },
      );
      expect(
        _build('start', const <String>['book:m'], group: 'ocr').body,
        <String, Object?>{'key': 'book:m'},
      );
    });
  });
  test('ocr start --engine 透传；值域外解析失败', () {
    expect(
      _build('start', const <String>[
        'book:m',
        '--engine',
        'local_onnx',
      ], group: 'ocr').body,
      <String, Object?>{'key': 'book:m', 'engine': 'local_onnx'},
    );
    expect(
      () => _build('start', const <String>[
        'book:m',
        '--engine',
        'auto',
      ], group: 'ocr'),
      throwsA(isA<FormatException>()),
    );
    expect(kOcrEngineKeys, hasLength(5));
  });
}
