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
}
