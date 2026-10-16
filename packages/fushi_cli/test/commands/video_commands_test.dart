import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/video_commands.dart';
import 'package:fushi_cli/src/commands/video_player_commands.dart';
import 'package:path/path.dart' as p;
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

  group('刮削待确认', () {
    test('scrape --interactive 只用于来源，带进 body', () {
      expect(
        _build('scrape', <String>['3', '--interactive']).body,
        <String, Object?>{'target': '3', 'interactive': true},
      );
      expect(
        () => _build('scrape', <String>['book:x', '--interactive']),
        _usageError(),
      );
    });

    test('confirm 不带回答 = 查看（可 --wait）', () {
      final CtlRequestSpec view = _build('confirm', <String>[]);
      expect(view.method, 'GET');
      expect(view.path, '/api/admin/video/scrape/confirmation');
      expect(view.query, isEmpty);
      expect(
        _build('confirm', <String>['--wait', '--timeout', '30']).query,
        <String, String>{'wait': 'true', 'timeout': '30'},
      );
      expect(
        () => _build('confirm', <String>['--wait', '--timeout', '0']),
        _usageError(),
      );
      expect(
        () => _build('confirm', <String>['--expect', 'sc1']),
        _usageError(),
      );
    });

    test('confirm <序号> / --provider --id / --skip', () {
      final CtlRequestSpec pick = _build('confirm', <String>[
        '2',
        '--expect',
        'sc4',
      ]);
      expect(pick.method, 'POST');
      expect(pick.path, '/api/admin/video/scrape/confirmation');
      expect(pick.body, <String, Object?>{
        'id': 'sc4',
        'action': 'pick',
        'index': 2,
      });
      expect(
        _build('confirm', <String>[
          '--provider',
          'TMDB',
          '--id',
          '42',
          '--type',
          'movie',
        ]).body,
        <String, Object?>{
          'action': 'identity',
          'provider': 'tmdb',
          'externalId': '42',
          'type': 'movie',
        },
      );
      expect(_build('confirm', <String>['--skip']).body, <String, Object?>{
        'action': 'skip',
      });
    });

    test('confirm 参数冲突 / 非法值', () {
      for (final List<String> bad in <List<String>>[
        <String>['1', '--skip'],
        <String>['1', '--provider', 'mal', '--id', '1'],
        <String>['0'],
        <String>['x'],
        <String>['--provider', 'bangumi', '--id', '1'],
        <String>['--provider', 'mal'],
        <String>['--provider', 'mal', '--id', '-3'],
        <String>['1', '--wait'],
      ]) {
        expect(() => _build('confirm', bad), _usageError(), reason: '$bad');
      }
    });

    test('confirm render：候选表 / 作答结论', () {
      final String view = _spec('confirm').render!(<String, Object?>{
        'busy': true,
        'pending': <String, Object?>{
          'id': 'sc2',
          'work': 'Local Work',
          'source': 'Anime',
          'candidates': <Object?>[
            <String, Object?>{
              'index': 1,
              'identity': 'anidb:1',
              'title': 'A',
              'aiSuggested': true,
            },
          ],
          'ai': <String, Object?>{'index': 1, 'confidence': 70},
        },
      });
      expect(view, contains('sc2'));
      expect(view, contains('anidb:1'));
      expect(view, contains('AI 建议第 1 个'));
      expect(
        _spec('confirm').render!(<String, Object?>{
          'id': 'sc2',
          'work': 'W',
          'answer': 'pick',
          'picked': <String, Object?>{'identity': 'mal:5', 'title': 'T'},
        }),
        contains('mal:5'),
      );
      expect(
        _spec('confirm').render!(<String, Object?>{
          'busy': false,
          'pending': null,
        }),
        contains('没有等待确认'),
      );
    });
  });

  group('播放页', () {
    test('player：状态查询与渲染', () {
      final CtlRequestSpec player = _build('player', <String>[]);
      expect(player.method, 'GET');
      expect(player.path, '/api/admin/video/player');
      final String text = _spec('player').render!(<String, Object?>{
        'active': true,
        'ready': true,
        'title': 'EP1',
        'playing': true,
        'positionMs': 3725000,
        'durationMs': 5400000,
        'speed': 1.0,
        'volume': 70,
        'audioTrack': '2',
        'subtitle': 'embedded:1',
        'secondarySubtitle': 'off:',
        'cue': '台詞',
      });
      expect(text, contains('1:02:05'));
      expect(text, contains('音量 70'));
      expect(text, contains('副字幕：关闭'));
      expect(text, contains('当前句：台詞'));
      expect(
        _spec('player').render!(<String, Object?>{'active': false}),
        contains('没有打开'),
      );
    });

    test('volume：数值 / --mute 二选一', () {
      expect(_build('volume', <String>['35']).body, <String, Object?>{
        'volume': 35.0,
      });
      expect(_build('volume', <String>['--mute']).body, <String, Object?>{
        'mute': true,
      });
      expect(
        _build('volume', <String>['35']).path,
        '/api/admin/video/player/volume',
      );
      for (final List<String> bad in <List<String>>[
        <String>[],
        <String>['101'],
        <String>['x'],
        <String>['10', '--mute'],
      ]) {
        expect(() => _build('volume', bad), _usageError(), reason: '$bad');
      }
    });

    test('audio：无参列出、有参切换', () {
      final CtlRequestSpec list = _build('audio', <String>[]);
      expect(list.method, 'GET');
      expect(list.path, '/api/admin/video/player/audio-tracks');
      final CtlRequestSpec pick = _build('audio', <String>['2']);
      expect(pick.method, 'POST');
      expect(pick.path, '/api/admin/video/player/audio-track');
      expect(pick.body, <String, Object?>{'id': '2'});
    });

    test('subs / sub / sub2 / sub-import', () {
      expect(
        _build('subs', <String>[]).path,
        '/api/admin/video/player/subtitles',
      );
      expect(_build('sub', <String>['3']).body, <String, Object?>{
        'source': '3',
      });
      expect(_build('sub', <String>['OFF']).body, <String, Object?>{
        'off': true,
      });
      expect(_build('sub2', <String>['embedded:2']).body, <String, Object?>{
        'source': 'embedded:2',
        'secondary': true,
      });
      expect(_build('sub2', <String>['off']).body, <String, Object?>{
        'off': true,
        'secondary': true,
      });
      expect(() => _build('sub', <String>[]), _usageError());
      final CtlRequestSpec import = _build('sub-import', <String>['a.srt']);
      expect(import.path, '/api/admin/video/player/subtitle/import');
      expect(
        p.isAbsolute(import.body!['path']! as String),
        isTrue,
        reason: '相对路径要在 CLI 侧转成绝对路径',
      );
    });

    test('sub-ocr 同意参数：--consent-llm 三态、--consent-upload', () {
      expect(
        _build('sub-ocr', <String>[
          '2',
          '--yes',
          '--consent-llm',
          '--consent-upload',
        ]).body,
        <String, Object?>{
          'source': '2',
          'confirm': true,
          'consentLlm': true,
          'consentUpload': true,
        },
      );
      expect(
        _build('sub-ocr', <String>['2', '--yes', '--no-consent-llm']).body,
        <String, Object?>{'source': '2', 'confirm': true, 'consentLlm': false},
      );
      expect(
        _build('sub-ocr', <String>[
          '2',
          '--yes',
        ]).body!.containsKey('consentLlm'),
        isFalse,
        reason: '不给参数 = 未回答，交给 app 判断要不要报 consent_required',
      );
    });

    test('sub-import --secondary', () {
      expect(
        _build('sub-import', <String>['/x/a.srt', '--secondary']).body,
        containsPair('secondary', true),
      );
      expect(
        _build('sub-import', <String>[
          '/x/a.srt',
        ]).body!.containsKey('secondary'),
        isFalse,
      );
    });

    test('sub-ocr 需要 --yes；asr / retime / align 的 body', () {
      expect(() => _build('sub-ocr', <String>['2']), _usageError());
      expect(
        _build('sub-ocr', <String>['2', '--yes', '--wait']).body,
        <String, Object?>{'source': '2', 'confirm': true, 'wait': true},
      );
      expect(
        _build('sub-asr', <String>['--language', 'ja']).body,
        <String, Object?>{'language': 'ja'},
      );
      expect(
        _build('sub-asr', <String>[]).path,
        '/api/admin/video/player/subtitle/transcribe',
      );
      expect(_build('sub-retime', <String>['--wait']).body, <String, Object?>{
        'retime': true,
        'wait': true,
      });
      expect(_build('sub-align', <String>[]).body, isEmpty);
      expect(_build('sub-align', <String>['--yes']).body, <String, Object?>{
        'confirm': true,
      });
    });

    test('clip：秒数 / 时间码，结束必须晚于开始', () {
      expect(parseCliVideoTimeMs('12.5'), 12500);
      expect(parseCliVideoTimeMs('01:02'), 62000);
      expect(parseCliVideoTimeMs('1:00:01.25'), 3601250);
      for (final String bad in <String>['-1', '1:60', 'abc', '1:2:3:4']) {
        expect(() => parseCliVideoTimeMs(bad), _usageError(), reason: bad);
      }
      final CtlRequestSpec clip = _build('clip', <String>[
        '00:10',
        '15',
        '--wait',
      ]);
      expect(clip.path, '/api/admin/video/player/clip');
      expect(clip.body, <String, Object?>{
        'startMs': 10000,
        'endMs': 15000,
        'wait': true,
      });
      expect(() => _build('clip', <String>['20', '10']), _usageError());
      expect(() => _build('clip', <String>['20']), _usageError());
    });

    test('mine：字段与查词开关', () {
      final CtlRequestSpec mine = _build('mine', <String>[
        '食べる',
        '--reading',
        'たべる',
        '--field',
        'tags=x=y',
        '--no-lookup',
        '--allow-duplicate',
      ]);
      expect(mine.path, '/api/admin/video/player/mine');
      expect(mine.body, <String, Object?>{
        'word': '食べる',
        'reading': 'たべる',
        'fields': <String, String>{'tags': 'x=y'},
        'allowDuplicate': true,
        'lookup': false,
      });
      expect(
        () => _build('mine', <String>['w', '--field', 'novalue']),
        _usageError(),
      );
    });

    test('暂存队列：book 可选，丢弃要 --yes', () {
      expect(_build('mine-queue', <String>[]).query, isEmpty);
      expect(
        _build('mine-queue', <String>['--book', 'v1']).query,
        <String, String>{'bookUid': 'v1'},
      );
      expect(
        _build('mine-send', <String>[]).path,
        '/api/admin/video/mine-queue/commit',
      );
      expect(() => _build('mine-discard', <String>['3']), _usageError());
      expect(
        () => _build('mine-discard', <String>['x', '--yes']),
        _usageError(),
      );
      final CtlRequestSpec discard = _build('mine-discard', <String>[
        '3',
        '--yes',
        '--book',
        'v1',
      ]);
      expect(discard.path, '/api/admin/video/mine-queue/3/discard');
      expect(discard.body, <String, Object?>{'bookUid': 'v1', 'confirm': true});
    });

    test('jobs / job / job-cancel', () {
      expect(_build('jobs', <String>[]).path, '/api/admin/video/jobs');
      expect(_build('job', <String>['vj3', '--wait']).query, <String, String>{
        'wait': 'true',
      });
      expect(_build('job', <String>['vj3']).path, '/api/admin/video/jobs/vj3');
      expect(
        _build('job-cancel', <String>['vj3']).path,
        '/api/admin/video/jobs/vj3/cancel',
      );
      expect(() => _build('job', <String>['3']), _usageError());
    });

    test('render 不崩', () {
      expect(
        _spec('job').render!(<String, Object?>{
          'id': 'vj1',
          'kind': 'subtitleOcr',
          'status': 'running',
          'phase': 'recognizing',
          'progress': 0.5,
          'detail': '5/10',
        }),
        allOf(contains('50%'), contains('job-cancel vj1')),
      );
      expect(
        _spec('job').render!(<String, Object?>{
          'id': 'vj2',
          'kind': 'clip',
          'status': 'succeeded',
          'phase': 'succeeded',
          'result': <String, Object?>{'path': 'C:/x.mp4'},
        }),
        contains('C:/x.mp4'),
      );
      expect(
        _spec('subs').render!(<String, Object?>{
          'remote': false,
          'primary': 'off:',
          'secondary': null,
          'tracks': <Object?>[
            <String, Object?>{'index': 1, 'label': 'JP', 'kind': 'embedded'},
          ],
        }),
        allOf(contains('JP'), contains('主字幕：关闭')),
      );
      expect(
        _spec('mine').render!(<String, Object?>{
          'ok': true,
          'queued': false,
          'duplicate': false,
          'expression': 'w',
          'noteId': 9,
        }),
        contains('note 9'),
      );
      expect(
        _spec('volume').render!(<String, Object?>{'volume': 42.4}),
        contains('42'),
      );
    });
  });
}
