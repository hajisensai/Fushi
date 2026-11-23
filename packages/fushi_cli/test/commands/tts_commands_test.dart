import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

CtlCommandGroup _group() =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == 'tts');

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _group().find(command)!;
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

const String _item = '/api/admin/tts/manga/book%3Avol-1';

void main() {
  test('tts 组只注册一次、子命令齐全不重名', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'tts'),
      hasLength(1),
    );
    final List<String> names = <String>[
      for (final CtlCommandSpec s in _group().commands) s.name,
    ];
    expect(names.toSet(), hasLength(names.length));
    expect(names, <String>[
      'voices',
      'script',
      'page',
      'status',
      'annotate',
      'annotate-cancel',
      'line',
      'character',
      'regenerate',
      'regenerate-character',
      'replace',
      'render',
      'render-cancel',
      'import',
      'export',
      'import-package',
      'package-task',
      'package-cancel',
    ]);
  });

  test('读：voices / script / page / status 的路径；页码不是整数是用法错误', () {
    expect(_build('voices', <String>[]).path, '/api/admin/tts/voices');
    final CtlRequestSpec script = _build('script', <String>['book:vol-1']);
    expect(script.method, 'GET');
    expect(script.path, _item);
    expect(_build('page', <String>['book:vol-1', '3']).path, '$_item/pages/3');
    expect(() => _build('page', <String>['book:vol-1', 'x']), _usageError());
    expect(_build('status', <String>['book:vol-1']).path, '$_item/status');
    expect(() => _build('script', <String>[]), _usageError());
  });

  test('annotate：页码、角色表、同意上传进 body；不给的不带', () {
    final CtlRequestSpec all = _build('annotate', <String>[
      'book:vol-1',
      '--pages',
      '1, 3',
      '--no-roster',
      '--consent-upload',
    ]);
    expect(all.method, 'POST');
    expect(all.path, '$_item/annotate');
    expect(all.body, <String, Object?>{
      'pages': <int>[1, 3],
      'roster': false,
      'consentUpload': true,
    });
    expect(_build('annotate', <String>['book:vol-1']).body, isEmpty);
    expect(
      () => _build('annotate', <String>['book:vol-1', '--pages', '0']),
      _usageError(),
    );
    expect(
      _build('annotate-cancel', <String>['book:vol-1']).path,
      '$_item/annotate/cancel',
    );
  });

  test('line：PUT 行 id；字段进 body；--fix 解析块下标；一个字段都不给是用法错误', () {
    final CtlRequestSpec line = _build('line', <String>[
      'book:vol-1',
      'p0b1.2',
      '--speaker',
      '花子',
      '--new-character',
      '--kind',
      'thought',
      '--beat',
      '300',
      '--position',
      '1',
      '--say',
      '',
      '--fix',
      '1=直した',
    ]);
    expect(line.method, 'PUT');
    expect(line.path, '$_item/lines/p0b1.2');
    expect(line.body, <String, Object?>{
      'speaker': '花子',
      'newCharacter': true,
      'kind': 'thought',
      'beat': 300,
      'position': 1,
      'say': '',
      'fixes': <String, String>{'1': '直した'},
    });
    expect(() => _build('line', <String>['book:vol-1', 'p0b1']), _usageError());
    expect(
      () => _build('line', <String>['book:vol-1', 'p0b1', '--fix', 'a=b']),
      _usageError(),
    );
    expect(
      () => _build('line', <String>['book:vol-1', 'p0b1', '--beat', 'x']),
      _usageError(),
    );
  });

  test('line：--emotion / --intensity 进 body；none 清掉强度；非整数是用法错误', () {
    expect(
      _build('line', <String>[
        'book:vol-1',
        'p0b1',
        '--emotion',
        'anger',
        '--intensity',
        '80',
      ]).body,
      <String, Object?>{'emotion': 'anger', 'intensity': 80},
    );
    expect(
      _build('line', <String>[
        'book:vol-1',
        'p0b1',
        '--emotion',
        'none',
        '--intensity',
        'none',
      ]).body,
      <String, Object?>{'emotion': 'none', 'intensity': -1},
    );
    expect(
      () => _build('line', <String>['book:vol-1', 'p0b1', '--intensity', 'x']),
      _usageError(),
    );
  });

  test('character：改名 / 指派 / 清掉指派；--voice 与 --clear-voice 互斥', () {
    final CtlRequestSpec rename = _build('character', <String>[
      'book:vol-1',
      '太郎',
      '--rename',
      '次郎',
    ]);
    expect(rename.method, 'PUT');
    expect(rename.path, '$_item/characters/${Uri.encodeComponent('太郎')}');
    expect(rename.body, <String, Object?>{'rename': '次郎'});
    expect(
      _build('character', <String>[
        'book:vol-1',
        'narrator',
        '--voice',
        'v1',
        '--scope',
        'series',
      ]).body,
      <String, Object?>{'voice': 'v1', 'scope': 'series'},
    );
    expect(
      _build('character', <String>[
        'book:vol-1',
        '太郎',
        '--clear-voice',
        '--kind',
        'thought',
      ]).body,
      <String, Object?>{'voice': '', 'kind': 'thought'},
    );
    expect(
      () => _build('character', <String>['book:vol-1', '太郎']),
      _usageError(),
    );
    expect(
      () => _build('character', <String>[
        'book:vol-1',
        '太郎',
        '--voice',
        'v1',
        '--clear-voice',
      ]),
      _usageError(),
    );
  });

  test('regenerate / render / render-cancel', () {
    final CtlRequestSpec regen = _build('regenerate', <String>[
      'book:vol-1',
      'p2b0',
      '--seed',
      '42',
    ]);
    expect(regen.method, 'POST');
    expect(regen.path, '$_item/lines/p2b0/regenerate');
    expect(regen.body, <String, Object?>{'seed': 42});
    expect(_build('regenerate', <String>['book:vol-1', 'p2b0']).body, isEmpty);
    final CtlRequestSpec render = _build('render', <String>[
      'book:vol-1',
      '--voice',
      'v1',
    ]);
    expect(render.path, '$_item/render');
    expect(render.body, <String, Object?>{'voice': 'v1'});
    expect(
      _build('render-cancel', <String>['book:vol-1']).path,
      '$_item/render/cancel',
    );
  });

  test('regenerate-character：角色名进路径；--kind / --dry-run 进 body', () {
    final CtlRequestSpec all = _build('regenerate-character', <String>[
      'book:vol-1',
      '花 子',
      '--kind',
      'spoken',
      '--dry-run',
    ]);
    expect(all.method, 'POST');
    expect(all.path, '$_item/characters/%E8%8A%B1%20%E5%AD%90/regenerate');
    expect(all.body, <String, Object?>{'kind': 'spoken', 'dryRun': true});
    expect(
      _build('regenerate-character', <String>['book:vol-1', 'narrator']).body,
      isEmpty,
    );
    expect(
      () => _build('regenerate-character', <String>['book:vol-1']),
      _usageError(),
    );
  });

  test('replace：行 id=路径（转绝对路径）或 --map 二选一；--dry-run 进 body', () {
    final CtlRequestSpec pairs = _build('replace', <String>[
      'book:vol-1',
      'p0b0=out/a.wav',
      'p2b0=out/b.wav',
      '--dry-run',
    ]);
    expect(pairs.method, 'POST');
    expect(pairs.path, '$_item/lines/replace');
    expect(pairs.body, <String, Object?>{
      'files': <String, String>{
        'p0b0': p.normalize(p.absolute('out/a.wav')),
        'p2b0': p.normalize(p.absolute('out/b.wav')),
      },
      'dryRun': true,
    });
    final CtlRequestSpec mapped = _build('replace', <String>[
      'book:vol-1',
      '--map',
      'map.json',
    ]);
    expect(mapped.body, <String, Object?>{
      'mapping': p.normalize(p.absolute('map.json')),
    });
    expect(() => _build('replace', <String>['book:vol-1']), _usageError());
    expect(
      () => _build('replace', <String>[
        'book:vol-1',
        'p0b0=a.wav',
        '--map',
        'm.json',
      ]),
      _usageError(),
    );
    expect(
      () => _build('replace', <String>['book:vol-1', 'p0b0']),
      _usageError(),
    );
  });

  test('import：清单路径在 CLI 侧转绝对路径；--yes 才带 confirm；缺清单是用法错误', () {
    final CtlRequestSpec plain = _build('import', <String>[
      'book:vol-1',
      'out/manifest.json',
    ]);
    expect(plain.method, 'POST');
    expect(plain.path, '$_item/import');
    expect(plain.body, <String, Object?>{
      'manifest': p.normalize(p.absolute('out/manifest.json')),
    });
    final CtlRequestSpec yes = _build('import', <String>[
      'book:vol-1',
      'out/manifest.json',
      '--yes',
    ]);
    expect(yes.body, containsPair('confirm', true));
    expect(() => _build('import', <String>['book:vol-1']), _usageError());
  });

  test(
    'export：卷 key 与 --series 二选一；--volumes 只跟 --series；--out 转绝对路径；默认等写完',
    () {
      const String root = '/api/admin/tts/manga-packages';
      final CtlRequestSpec keys = _build('export', <String>[
        'book:vol-1',
        'book:vol-2',
        '--out',
        'out.fushi-manga-audio',
      ]);
      expect(keys.method, 'POST');
      expect(keys.path, '$root/export');
      expect(
        keys.body,
        containsPair('keys', <String>['book:vol-1', 'book:vol-2']),
      );
      expect(
        keys.body,
        containsPair('out', p.absolute('out.fushi-manga-audio')),
      );
      expect(keys.body, containsPair('wait', true));
      expect(keys.body!.containsKey('series'), isFalse);

      final CtlRequestSpec series = _build('export', <String>[
        '--series',
        'collection:3',
        '--volumes',
        'book:a, book:b',
        '--script-only',
        '--no-wait',
        '--out',
        '/x/y',
      ]);
      expect(series.body, containsPair('series', 'collection:3'));
      expect(
        series.body,
        containsPair('volumes', <String>['book:a', 'book:b']),
      );
      expect(series.body, containsPair('scriptOnly', true));
      expect(series.body!.containsKey('wait'), isFalse);

      expect(() => _build('export', <String>['book:a']), _usageError());
      expect(() => _build('export', <String>['--out', 'x']), _usageError());
      expect(
        () =>
            _build('export', <String>['book:a', '--series', 's', '--out', 'x']),
        _usageError(),
      );
      expect(
        () => _build('export', <String>[
          'book:a',
          '--volumes',
          'b',
          '--out',
          'x',
        ]),
        _usageError(),
      );
    },
  );

  test('import-package / package-task / package-cancel', () {
    const String root = '/api/admin/tts/manga-packages';
    final CtlRequestSpec plain = _build('import-package', <String>[
      'p.fushi-manga-audio',
    ]);
    expect(plain.path, '$root/import');
    expect(plain.body, containsPair('file', p.absolute('p.fushi-manga-audio')));
    expect(plain.body, containsPair('wait', true));
    expect(plain.body!.containsKey('confirm'), isFalse);
    final CtlRequestSpec dry = _build('import-package', <String>[
      'p',
      '--dry-run',
      '--as-new',
      '--yes',
    ]);
    expect(dry.body, containsPair('dryRun', true));
    expect(dry.body, containsPair('asNew', true));
    expect(dry.body, containsPair('confirm', true));
    expect(dry.body!.containsKey('wait'), isFalse, reason: '预检不用等');
    expect(() => _build('import-package', <String>[]), _usageError());

    final CtlRequestSpec task = _build('package-task', <String>[
      't 1',
      '--wait',
    ]);
    expect(task.method, 'GET');
    expect(task.path, '$root/tasks/t%201');
    expect(task.query, containsPair('wait', 'true'));
    final CtlRequestSpec cancel = _build('package-cancel', <String>['t1']);
    expect(cancel.method, 'POST');
    expect(cancel.path, '$root/tasks/t1/cancel');
  });

  test('包任务的人类可读输出：预检逐卷、导出结果带大小、导入结果逐卷', () {
    final CtlCommandSpec spec = _group().find('import-package')!;
    final String plan = spec.render!(<String, Object?>{
      'dryRun': true,
      'path': '/p.fushi-manga-audio',
      'volumes': <Object?>[
        <String, Object?>{
          'id': 'v1',
          'title': '第1巻',
          'pages': 180,
          'action': 'useExisting',
          'key': 'book:vol-1',
          'hasAudio': true,
          'lines': 12,
          'durationMs': 34500,
          'replacesAudio': true,
          'missingVoices': <String>['voice-x'],
        },
      ],
    });
    expect(plan, contains('用本机已有的同一卷 book:vol-1'));
    expect(plan, contains('12 句 34.5 秒'));
    expect(plan, contains('要 --yes'));
    expect(plan, contains('本机缺声音：voice-x'));

    final String exported = _group().find('export')!.render!(<String, Object?>{
      'taskId': 'pkg-1',
      'kind': 'export',
      'status': 'done',
      'result': <String, Object?>{
        'path': '/out.fushi-manga-audio',
        'bytes': 3 * 1048576,
        'volumes': <Object?>[
          <String, Object?>{'id': 'v1', 'title': '第1巻', 'scriptOnly': true},
        ],
      },
    });
    expect(exported, contains('导出完成：pkg-1'));
    expect(exported, contains('/out.fushi-manga-audio（3.0 MB）'));
    expect(exported, contains('v1 第1巻：仅演出稿'));
  });
}
