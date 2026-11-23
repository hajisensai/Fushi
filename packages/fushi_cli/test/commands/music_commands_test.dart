import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group() =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == 'music');

CtlCommandSpec _spec(String command) => _group().find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('music 组只注册一次、子命令不重名', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'music'),
      hasLength(1),
    );
    final List<String> names = <String>[
      for (final CtlCommandSpec s in _group().commands) s.name,
    ];
    expect(names.toSet(), hasLength(names.length));
    expect(
      names,
      containsAll(<String>[
        'albums',
        'tracks',
        'track',
        'playlists',
        'scrape',
        'scrape-all',
        'sources',
        'source-add',
        'play',
        'pause',
        'next',
        'prev',
        'now',
      ]),
    );
  });

  test('列表：关键词拼成 search，--limit 必须是正整数', () {
    final CtlRequestSpec albums = _build('albums', <String>[
      'the',
      'book',
      '--limit',
      '5',
    ]);
    expect(albums.method, 'GET');
    expect(albums.path, '/api/admin/music/albums');
    expect(albums.query, <String, String>{'search': 'the book', 'limit': '5'});
    expect(_build('artists', <String>[]).query, isEmpty);
    expect(() => _build('albums', <String>['--limit', '0']), _usageError());
    expect(() => _build('albums', <String>['--limit', 'x']), _usageError());
    final CtlRequestSpec tracks = _build('tracks', <String>[
      '--album',
      'al-1',
      '--artist',
      'ar',
    ]);
    expect(tracks.path, '/api/admin/music/tracks');
    expect(tracks.query, <String, String>{'album': 'al-1', 'artist': 'ar'});
  });

  test('album-dlsite：POST 到专辑的 dlsite 子路径，输出资料行', () {
    final CtlRequestSpec spec = _build('album-dlsite', <String>['a/b']);
    expect(spec.method, 'POST');
    expect(spec.path, '/api/admin/music/albums/a%2Fb/dlsite');
    final String text = _spec('album-dlsite').render!(<String, Object?>{
      'workId': 'RJ01109339',
      'status': 'matched',
      'circle': 'チームランドセル',
      'voiceActors': <String>['耳恋なか', 'そよかぜみらい'],
      'tags': <String>['癒し'],
    });
    expect(text, contains('RJ01109339 · matched'));
    expect(text, contains('社团：チームランドセル'));
    expect(text, contains('声优：耳恋なか / そよかぜみらい'));
    expect(text, contains('标签：癒し'));
    expect(text, isNot(contains('剧本')));
  });

  test('详情：uid 进路径并做 URL 编码', () {
    expect(
      _build('album', <String>['a/b']).path,
      '/api/admin/music/albums/a%2Fb',
    );
    expect(
      _build('track', <String>['t-1']).path,
      '/api/admin/music/tracks/t-1',
    );
    expect(() => _build('track', <String>[]), _usageError());
  });

  test('scrape：--recording 必须是 MBID，可省略', () {
    final CtlRequestSpec plain = _build('scrape', <String>['t-1']);
    expect(plain.method, 'POST');
    expect(plain.path, '/api/admin/music/tracks/t-1/scrape');
    expect(plain.body, isEmpty);
    final CtlRequestSpec manual = _build('scrape', <String>[
      't-1',
      '--recording',
      '22222222-2222-2222-2222-222222222222',
    ]);
    expect(manual.body, <String, Object?>{
      'recordingId': '22222222-2222-2222-2222-222222222222',
    });
    expect(
      () => _build('scrape', <String>['t-1', '--recording', 'abc']),
      _usageError(),
    );
    expect(_build('scrape-all', <String>[]).path, '/api/admin/music/scrape');
    expect(_build('scrape-all', <String>[]).method, 'POST');
    expect(_build('scrape-status', <String>[]).method, 'GET');
    expect(
      _build('scrape-cancel', <String>[]).path,
      '/api/admin/music/scrape/cancel',
    );
  });

  test('扫描根：source-add 转绝对路径；source-rm 要 --yes 与正整数 id', () {
    final CtlRequestSpec add = _build('source-add', <String>['music']);
    expect(add.path, '/api/admin/music/sources');
    expect((add.body!['path']! as String).endsWith('music'), isTrue);
    expect(add.body!['path'], isNot('music'));
    final CtlRequestSpec rm = _build('source-rm', <String>['3', '--yes']);
    expect(rm.method, 'DELETE');
    expect(rm.path, '/api/admin/music/sources/3');
    expect(rm.body, <String, Object?>{'confirm': true});
    expect(() => _build('source-rm', <String>['3']), _usageError());
    expect(() => _build('source-rm', <String>['x', '--yes']), _usageError());
    expect(_build('scan', <String>['--source', '2']).body, <String, Object?>{
      'source': 2,
    });
    expect(_build('scan', <String>[]).body, isEmpty);
  });

  test('play：续播 / 专辑 / 曲目三种形状，冲突与悬空参数报用法错误', () {
    expect(_build('play', <String>[]).body, isEmpty);
    expect(
      _build('play', <String>['--album', 'al-1', '--shuffle']).body,
      <String, Object?>{'album': 'al-1', 'shuffle': true},
    );
    final CtlRequestSpec tracks = _build('play', <String>[
      '--track',
      't-3',
      '--track',
      't-1',
      '--index',
      '1',
    ]);
    expect(tracks.path, '/api/admin/music/player/play');
    expect(tracks.body, <String, Object?>{
      'tracks': <String>['t-3', 't-1'],
      'index': 1,
    });
    expect(
      () => _build('play', <String>['--album', 'a', '--track', 't']),
      _usageError(),
    );
    expect(() => _build('play', <String>['--index', '1']), _usageError());
    expect(
      () => _build('play', <String>['--album', 'a', '--index', '-1']),
      _usageError(),
    );
  });

  test('遥控路径：pause / next / prev / jump / now', () {
    expect(_build('pause', <String>[]).path, '/api/admin/music/player/pause');
    expect(_build('next', <String>[]).path, '/api/admin/music/player/next');
    expect(_build('prev', <String>[]).path, '/api/admin/music/player/previous');
    expect(_build('now', <String>[]).path, '/api/admin/music/player');
    expect(_build('jump', <String>['2']).body, <String, Object?>{'index': 2});
    expect(() => _build('jump', <String>['--', '-1']), _usageError());
    expect(() => _build('jump', <String>['x']), _usageError());
  });

  test('render：播放器、识别结论与候选、整库任务', () {
    expect(_spec('now').render!(<String, Object?>{'active': false}), '没有在放音乐');
    final String now = _spec('now').render!(<String, Object?>{
      'active': true,
      'playing': true,
      'track': <String, Object?>{
        'uid': 't-1',
        'title': '夜に駆ける',
        'artist': 'YOASOBI',
      },
      'index': 0,
      'positionMs': 12000,
      'durationMs': 180000,
      'queue': <String>['t-1', 't-2'],
    });
    expect(now, contains('播放中'));
    expect(now, contains('夜に駆ける · YOASOBI'));
    expect(now, contains('0:12 / 3:00'));
    expect(now, contains('队列 1/2'));

    final String track = _spec('track').render!(<String, Object?>{
      'uid': 't-3',
      'title': '残響散歌',
      'identification': <String, Object?>{
        'status': 'unmatched',
        'candidates': <Object?>[
          <String, Object?>{
            'recordingId': '22222222-2222-2222-2222-222222222222',
            'title': '残響散歌',
          },
        ],
      },
    });
    expect(track, contains('没找到匹配'));
    expect(track, contains('--recording'));
    expect(track, contains('22222222-2222-2222-2222-222222222222'));

    expect(
      _spec('scrape-status').render!(<String, Object?>{'active': false}),
      '还没有跑过整库识别',
    );
    final String job = _spec('scrape-status').render!(<String, Object?>{
      'id': 'music-scrape-1',
      'status': 'done',
      'done': 3,
      'total': 3,
      'report': <String, Object?>{
        'total': 3,
        'matched': 2,
        'unmatched': 1,
        'failed': 0,
      },
    });
    expect(job, contains('已完成'));
    expect(job, contains('识别 2'));
  });

  group('导入 / 导出（music_import_commands）', () {
    test('import：文件转绝对路径，一个都不给是用法错误', () {
      final CtlRequestSpec r = _build('import', <String>['a.flac', 'b.mp4']);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/music/import');
      final List<Object?> paths = r.body!['paths']! as List<Object?>;
      expect(paths, hasLength(2));
      expect('${paths.first}', endsWith('a.flac'));
      expect('${paths.last}', endsWith('b.mp4'));
      expect(() => _build('import', <String>[]), _usageError());
    });

    test('光盘：add / titles / chapters（--title 可重复且必须是数字）/ rm 要 --yes', () {
      expect(_build('discs', <String>[]).path, '/api/admin/music/discs');
      final CtlRequestSpec add = _build('disc-add', <String>['/discs/live']);
      expect(add.method, 'POST');
      expect(add.path, '/api/admin/music/discs');
      expect(
        _build('disc-titles', <String>['d1']).path,
        '/api/admin/music/discs/d1/titles',
      );
      final CtlRequestSpec chapters = _build('disc-chapters', <String>[
        'd1',
        '--title',
        '1',
        '--title',
        '3',
      ]);
      expect(chapters.path, '/api/admin/music/discs/d1/chapters');
      expect(chapters.body, <String, Object?>{
        'titles': <String>['1', '3'],
      });
      expect(_build('disc-chapters', <String>['d1']).body, isEmpty);
      expect(
        () => _build('disc-chapters', <String>['d1', '--title', 'x']),
        _usageError(),
      );
      expect(() => _build('disc-rm', <String>['d1']), _usageError());
      final CtlRequestSpec rm = _build('disc-rm', <String>['d1', '--yes']);
      expect(rm.method, 'DELETE');
      expect(rm.body, <String, Object?>{'confirm': true});
    });

    test('插件：inspect / install 要 --yes 且带 digest / 启停 / 卸载', () {
      final CtlRequestSpec inspect = _build('plugin-inspect', <String>[
        '/p/a.fushiplug',
      ]);
      expect(inspect.path, '/api/admin/music/plugins/inspect');
      expect(
        () => _build('plugin-install', <String>['/p/a.fushiplug']),
        _usageError(),
      );
      final CtlRequestSpec install = _build('plugin-install', <String>[
        '/p/a.fushiplug',
        '--yes',
        '--digest',
        'abc',
      ]);
      expect(install.body!['confirm'], isTrue);
      expect(install.body!['digest'], 'abc');
      final CtlRequestSpec off = _build('plugin-disable', <String>['lyr']);
      expect(off.method, 'PUT');
      expect(off.path, '/api/admin/music/plugins/lyr/enabled');
      expect(off.body, <String, Object?>{'enabled': false});
      expect(_build('plugin-enable', <String>['lyr']).body, <String, Object?>{
        'enabled': true,
      });
      expect(() => _build('plugin-rm', <String>['lyr']), _usageError());
      expect(_build('plugin-rm', <String>['lyr', '-y']).method, 'DELETE');
    });

    test('lyrics-export：默认 ttml，--format lrc / --overwrite', () {
      final CtlRequestSpec r = _build('lyrics-export', <String>['t-1']);
      expect(r.path, '/api/admin/music/tracks/t-1/lyrics/export');
      expect(r.body, <String, Object?>{'format': 'ttml'});
      expect(
        _build('lyrics-export', <String>[
          't-1',
          '--format',
          'lrc',
          '--overwrite',
        ]).body,
        <String, Object?>{'format': 'lrc', 'overwrite': true},
      );
    });

    test('audio-cd：起任务 / 查进度 / 取消', () {
      final CtlRequestSpec start = _build('audio-cd', <String>['E:/']);
      expect(start.method, 'POST');
      expect(start.path, '/api/admin/music/audio-cd');
      expect(start.body!['dir'], isA<String>());
      expect(_build('audio-cd-status', <String>[]).method, 'GET');
      expect(
        _build('audio-cd-cancel', <String>[]).path,
        '/api/admin/music/audio-cd/cancel',
      );
      final String Function(Object?) render = _spec('audio-cd-status').render!;
      expect(
        render(<String, Object?>{
          'id': 'x',
          'status': 'running',
          'track': 1,
          'trackCount': 9,
        }),
        contains('1/9'),
      );
      expect(
        render(<String, Object?>{'id': 'x', 'status': 'done', 'imported': 9}),
        contains('导入 9 首'),
      );
    });
  });
}
