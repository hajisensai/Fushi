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

void main() {
  test('sub-fill：语言必填，开关只在关掉时进 body', () {
    final CtlRequestSpec all = _build('sub-fill', <String>['--lang', 'ja']);
    expect(all.method, 'POST');
    expect(all.path, '/api/admin/video/subtitle-fill');
    expect(all.body, <String, Object?>{'language': 'ja'});

    final CtlRequestSpec some = _build('sub-fill', <String>[
      '--lang',
      'zh',
      '--collection',
      '7',
      '--dry-run',
      '--no-generate',
      '--no-ocr',
      '--no-download',
      '--no-retime',
      '--wait',
    ]);
    expect(some.body, <String, Object?>{
      'language': 'zh',
      'collectionId': 7,
      'dryRun': true,
      'generate': false,
      'ocr': false,
      'download': false,
      'retime': false,
      'wait': true,
    });
    expect(
      _build('sub-fill', <String>['--lang', 'ja', '--books', 'a,b']).body,
      <String, Object?>{'language': 'ja', 'bookUids': 'a,b'},
    );
  });

  test('sub-fill：缺 --lang / --collection 不是数字 → 用法错', () {
    expect(() => _build('sub-fill', <String>[]), throwsA(isA<CtlUsageError>()));
    expect(
      () => _build('sub-fill', <String>['--lang', 'ja', '--collection', 'x']),
      throwsA(isA<CtlUsageError>()),
    );
  });

  test('sub-fill --status 走 GET，不要语言', () {
    final CtlRequestSpec status = _build('sub-fill', <String>['--status']);
    expect(status.method, 'GET');
    expect(status.path, '/api/admin/video/subtitle-fill');
  });

  test('sub-fill-undo 带任务 id', () {
    final CtlRequestSpec undo = _build('sub-fill-undo', <String>['fill-1']);
    expect(undo.path, '/api/admin/video/subtitle-fill-undo');
    expect(undo.body, <String, Object?>{'jobId': 'fill-1'});
    expect(
      _spec('sub-fill-undo').render!(<String, Object?>{
        'jobId': 'fill-1',
        'undone': 3,
      }),
      contains('3'),
    );
  });

  test('sub-fill render：表头、计数与逐集结果', () {
    final String out = _spec('sub-fill').render!(<String, Object?>{
      'jobId': 'fill-1',
      'language': 'ja',
      'dryRun': true,
      'total': 2,
      'done': 2,
      'counts': <String, int>{'planned': 1, 'alreadyCovered': 1},
      'outcomes': <Map<String, Object?>>[
        <String, Object?>{
          'title': 'EP1',
          'action': 'planned',
          'plan': 'missing',
        },
        <String, Object?>{'title': 'EP2', 'action': 'alreadyCovered'},
      ],
    });
    expect(
      out,
      allOf(contains('fill-1'), contains('planned 1'), contains('EP2')),
    );
  });
}
