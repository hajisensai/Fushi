import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/video_commands.dart';
import 'package:test/test.dart';

CtlCommandSpec _spec(String command) => videoCommandGroups
    .firstWhere((CtlCommandGroup g) => g.name == 'video')
    .find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('video 组注册进总表，组名唯一、命令名不重复', () {
    expect(videoCommandGroups.map((CtlCommandGroup g) => g.name), <String>[
      'video',
    ]);
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'video'),
      hasLength(1),
    );
    final Set<String> names = <String>{};
    for (final CtlCommandSpec s in videoCommandGroups.single.commands) {
      expect(names.add(s.name), isTrue, reason: s.name);
      expect(s.render, isNotNull, reason: '${s.name} 缺 render');
    }
  });

  group('刮削', () {
    test('works / works --pending', () {
      final CtlRequestSpec all = _build('works', <String>[]);
      expect(all.method, 'GET');
      expect(all.path, '/api/admin/video/works');
      expect(all.query, isEmpty);
      final CtlRequestSpec pending = _build('works', <String>['--pending']);
      expect(pending.query, <String, String>{'pending': 'true'});
    });

    test('scrape 来源 / 作品 / --wait', () {
      final CtlRequestSpec source = _build('scrape', <String>['3']);
      expect(source.method, 'POST');
      expect(source.path, '/api/admin/video/scrape');
      expect(source.body, <String, Object?>{'target': '3'});

      final CtlRequestSpec work = _build('scrape', <String>[
        'collection:12',
        '--wait',
      ]);
      expect(work.body, <String, Object?>{
        'target': 'collection:12',
        'wait': true,
      });

      final CtlRequestSpec book = _build('scrape', <String>['book:a/b']);
      expect(book.body, <String, Object?>{'target': 'book:a/b'});
    });

    test('scrape --allow-overwrite 需要 --yes，且只用于来源', () {
      expect(
        () => _build('scrape', <String>['3', '--allow-overwrite']),
        _usageError(),
      );
      expect(
        () =>
            _build('scrape', <String>['book:x', '--allow-overwrite', '--yes']),
        _usageError(),
      );
      final CtlRequestSpec ok = _build('scrape', <String>[
        '3',
        '--allow-overwrite',
        '--yes',
      ]);
      expect(ok.body, <String, Object?>{
        'target': '3',
        'allowOverwrite': true,
        'confirm': true,
      });
    });

    test('scrape 目标格式不对 / 缺失', () {
      expect(() => _build('scrape', <String>[]), _usageError());
      expect(() => _build('scrape', <String>['abc']), _usageError());
      expect(() => _build('scrape', <String>['0']), _usageError());
      expect(() => _build('scrape', <String>['book:']), _usageError());
      expect(() => _build('scrape', <String>['collection:x']), _usageError());
    });

    test('status / cancel', () {
      final CtlRequestSpec status = _build('status', <String>['--limit', '5']);
      expect(status.method, 'GET');
      expect(status.path, '/api/admin/video/scrape');
      expect(status.query, <String, String>{'limit': '5'});
      expect(() => _build('status', <String>['--limit', '0']), _usageError());

      final CtlRequestSpec cancel = _build('cancel', <String>[]);
      expect(cancel.method, 'POST');
      expect(cancel.path, '/api/admin/video/scrape/cancel');
    });

    test('candidates：作品 id 编码进路径，provider 白名单', () {
      final CtlRequestSpec spec = _build('candidates', <String>[
        'book:a b',
        '--provider',
        'TMDB',
        '--query',
        '葬送のフリーレン',
      ]);
      expect(spec.method, 'GET');
      expect(spec.path, '/api/admin/video/works/book%3Aa%20b/candidates');
      expect(spec.query, <String, String>{'provider': 'tmdb', 'q': '葬送のフリーレン'});
      expect(
        () => _build('candidates', <String>['book:x', '--provider', 'bangumi']),
        _usageError(),
      );
      expect(() => _build('candidates', <String>['x']), _usageError());
    });

    test('identify：provider / id / type 校验与 body', () {
      final CtlRequestSpec spec = _build('identify', <String>[
        'collection:7',
        '--provider',
        'tmdb',
        '--id',
        '209867',
        '--type',
        'tv',
      ]);
      expect(spec.method, 'POST');
      expect(spec.path, '/api/admin/video/works/collection%3A7/identify');
      expect(spec.body, <String, Object?>{
        'provider': 'tmdb',
        'externalId': '209867',
        'type': 'tv',
      });

      final CtlRequestSpec noWait = _build('identify', <String>[
        'book:x',
        '--provider',
        'anidb',
        '--id',
        '17617',
        '--no-wait',
      ]);
      expect(noWait.body, <String, Object?>{
        'provider': 'anidb',
        'externalId': '17617',
        'wait': false,
      });

      expect(
        () => _build('identify', <String>['book:x', '--id', '1']),
        _usageError(),
      );
      expect(
        () => _build('identify', <String>['book:x', '--provider', 'mal']),
        _usageError(),
      );
      expect(
        () => _build('identify', <String>[
          'book:x',
          '--provider',
          'anilist',
          '--id',
          '1',
        ]),
        _usageError(),
      );
      for (final String bad in <String>['0', '-3', 'abc', '12a']) {
        expect(
          () => _build('identify', <String>[
            'book:x',
            '--provider',
            'mal',
            '--id',
            bad,
          ]),
          _usageError(),
          reason: bad,
        );
      }
      expect(
        () => _build('identify', <String>[
          'book:x',
          '--provider',
          'tmdb',
          '--id',
          '1',
          '--type',
          'ova',
        ]),
        _usageError(),
      );
    });
  });

  group('发现', () {
    test('discover：关键词拼接、分类与页码', () {
      final CtlRequestSpec spec = _build('discover', <String>[
        'Sousou',
        'no',
        'Frieren',
        '--category',
        'anime',
        '--page',
        '2',
      ]);
      expect(spec.method, 'GET');
      expect(spec.path, '/api/admin/video/discovery/search');
      expect(spec.query, <String, String>{
        'q': 'Sousou no Frieren',
        'category': 'anime',
        'page': '2',
      });
      expect(() => _build('discover', <String>[]), _usageError());
      expect(
        () => _build('discover', <String>['x', '--category', 'music']),
        _usageError(),
      );
      expect(
        () => _build('discover', <String>['x', '--page', '0']),
        _usageError(),
      );
    });

    test('resources', () {
      final CtlRequestSpec spec = _build('resources', <String>[
        'vw3',
        '-q',
        'Frieren 1080p',
      ]);
      expect(spec.method, 'GET');
      expect(spec.path, '/api/admin/video/discovery/works/vw3/resources');
      expect(spec.query, <String, String>{'q': 'Frieren 1080p'});
      expect(() => _build('resources', <String>[]), _usageError());
    });

    test('get：来源与字幕策略', () {
      final CtlRequestSpec spec = _build('get', <String>[
        'vr9',
        '--source',
        '4',
        '--subtitles',
        'required',
      ]);
      expect(spec.method, 'POST');
      expect(spec.path, '/api/admin/video/discovery/acquire');
      expect(spec.body, <String, Object?>{
        'id': 'vr9',
        'sourceId': 4,
        'subtitles': 'required',
      });
      expect(_build('get', <String>['vr1']).body, <String, Object?>{
        'id': 'vr1',
      });
      expect(() => _build('get', <String>[]), _usageError());
      expect(
        () => _build('get', <String>['vr1', '--subtitles', 'some']),
        _usageError(),
      );
      expect(
        () => _build('get', <String>['vr1', '--source', 'x']),
        _usageError(),
      );
    });
  });

  test('render 不崩（表格 / 摘要）', () {
    expect(
      _spec('works').render!(<String, Object?>{
        'pending': true,
        'works': <Object?>[
          <String, Object?>{
            'id': 'book:x',
            'title': 'T',
            'source': 'S',
            'members': 1,
            'reason': 'not_found',
          },
        ],
      }),
      contains('not_found'),
    );
    expect(
      _spec('scrape').render!(<String, Object?>{
        'mode': 'source',
        'source': 'Anime',
        'sourceId': 3,
        'started': true,
      }),
      contains('已开始'),
    );
    expect(
      _spec('identify').render!(<String, Object?>{
        'workId': 'book:x',
        'identity': <String, Object?>{'provider': 'mal', 'externalId': '1'},
        'title': 'T',
        'ok': true,
        'report': <String, Object?>{
          'succeededWorks': 1,
          'failedWorks': 0,
          'pendingConfirmations': 0,
          'totalWorks': 1,
          'errors': <Object?>[],
          'warnings': <Object?>[],
        },
      }),
      contains('mal:1'),
    );
    expect(
      _spec('status').render!(<String, Object?>{
        'busy': false,
        'runs': <Object?>[],
      }),
      contains('空闲'),
    );
    expect(
      _spec('get').render!(<String, Object?>{
        'title': 'R',
        'source': 'S',
        'jobId': 'j1',
      }),
      contains('dl get j1'),
    );
  });
}
