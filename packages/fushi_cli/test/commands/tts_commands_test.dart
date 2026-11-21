import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
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
      'render',
      'render-cancel',
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
}
