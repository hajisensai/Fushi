import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/library_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

CtlCommandSpec _spec(String name) =>
    libraryCommandGroups.single.find(name) ?? (throw StateError(name));

/// 与 CLI 主循环同样装配解析器（`--help` + 命令自己的 option）后 build。
CtlRequestSpec _build(String name, List<String> args) {
  final CtlCommandSpec spec = _spec(name);
  final ArgParser parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false);
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

void main() {
  test('命令组与子命令齐全', () {
    expect(libraryCommandGroups, hasLength(1));
    expect(libraryCommandGroups.single.name, 'library');
    expect(
      libraryCommandGroups.single.commands.map((CtlCommandSpec s) => s.name),
      <String>[
        'ls',
        'get',
        'rm',
        'import',
        'open',
        'history',
        'sources',
        'scan',
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
}
