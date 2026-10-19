import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/video_commands.dart';
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
  group('subtitle-gen', () {
    test('缺省：bookUid + AI 校对开', () {
      final CtlRequestSpec r = _build('subtitle-gen', <String>['book-1']);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/video/subtitle-gen');
      expect(r.body, <String, Object?>{'bookUid': 'book-1', 'proofread': true});
    });

    test('整季 + 全部选项', () {
      final CtlRequestSpec r = _build('subtitle-gen', <String>[
        '--collection',
        '12',
        '--no-ai',
        '--segmenter',
        'moss',
        '--moss-backend',
        'vulkan',
        '--regen-glossary',
        '--consent-ai',
        '--wait',
      ]);
      expect(r.body, <String, Object?>{
        'collectionId': 12,
        'proofread': false,
        'segmenter': 'moss',
        'mossBackend': 'vulkan',
        'regenerateGlossary': true,
        'consentAi': true,
        'wait': true,
      });
    });

    test('bookUid 与 --collection 恰好一个；collection 必须是正整数；枚举值受限', () {
      expect(() => _build('subtitle-gen', <String>[]), _usageError());
      expect(
        () => _build('subtitle-gen', <String>['b', '--collection', '3']),
        _usageError(),
      );
      expect(
        () => _build('subtitle-gen', <String>['--collection', 'x']),
        _usageError(),
      );
      expect(
        () => _build('subtitle-gen', <String>['b', '--segmenter', 'magic']),
        throwsA(isA<ArgParserException>()),
      );
    });

    test('render：运行中给出查询 / 取消提示；完成列出各集与用量', () {
      final String Function(Object?) render = _spec('subtitle-gen').render!;
      expect(
        render(<String, Object?>{
          'id': 'vj3',
          'status': 'running',
          'title': 'K-ON',
          'episodes': 12,
        }),
        allOf(contains('vj3 running'), contains('video job vj3 --wait')),
      );
      final String done = render(<String, Object?>{
        'id': 'vj3',
        'status': 'succeeded',
        'title': 'K-ON',
        'episodes': 1,
        'result': <String, Object?>{
          'episodes': <Object?>[
            <String, Object?>{'status': 'exported', 'output': '/v/ep01.ja.srt'},
          ],
          'usage': <String, Object?>{
            'calls': 3,
            'input': 10,
            'cacheRead': 0,
            'cacheWrite': 0,
            'output': 5,
            'callsWithoutUsage': 1,
          },
        },
      });
      expect(done, contains('exported  /v/ep01.ja.srt'));
      expect(done, contains('1 次未报用量'));
    });
  });

  group('subtitle-glossary', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cli_gloss_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('不带 --set：GET，目标进 query', () {
      final CtlRequestSpec book = _build('subtitle-glossary', <String>['b1']);
      expect(book.method, 'GET');
      expect(book.path, '/api/admin/video/subtitle-glossary');
      expect(book.query, <String, String>{'bookUid': 'b1'});
      final CtlRequestSpec season = _build('subtitle-glossary', <String>[
        '--collection',
        '4',
      ]);
      expect(season.query, <String, String>{'collectionId': '4'});
    });

    test('--set：读文件（数组或带 entries 的对象）→ PUT', () {
      final File arrayFile = File(p.join(tmp.path, 'a.json'))
        ..writeAsStringSync(
          jsonEncode(<Object?>[
            <String, Object?>{'ja': '唯', 'reading': 'ゆい'},
          ]),
        );
      final CtlRequestSpec r = _build('subtitle-glossary', <String>[
        'b1',
        '--set',
        arrayFile.path,
      ]);
      expect(r.method, 'PUT');
      expect(r.body, <String, Object?>{
        'bookUid': 'b1',
        'entries': <Object?>[
          <String, Object?>{'ja': '唯', 'reading': 'ゆい'},
        ],
      });

      final File objectFile = File(p.join(tmp.path, 'o.json'))
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'workKey': 'collection:4',
            'entries': <Object?>[
              <String, Object?>{'ja': '澪'},
            ],
          }),
        );
      final CtlRequestSpec r2 = _build('subtitle-glossary', <String>[
        '--collection',
        '4',
        '--set',
        objectFile.path,
      ]);
      expect((r2.body!['entries']! as List<Object?>).single, <String, Object?>{
        'ja': '澪',
      });
    });

    test('--set：文件不存在 / 不是 JSON / 缺 ja 都是用法错误', () {
      expect(
        () => _build('subtitle-glossary', <String>[
          'b1',
          '--set',
          p.join(tmp.path, 'missing.json'),
        ]),
        _usageError(),
      );
      final File bad = File(p.join(tmp.path, 'bad.json'))
        ..writeAsStringSync('{not json');
      expect(
        () => _build('subtitle-glossary', <String>['b1', '--set', bad.path]),
        _usageError(),
      );
      final File noJa = File(p.join(tmp.path, 'noja.json'))
        ..writeAsStringSync(
          jsonEncode(<Object?>[
            <String, Object?>{'reading': 'ゆい'},
          ]),
        );
      expect(
        () => _build('subtitle-glossary', <String>['b1', '--set', noJa.path]),
        _usageError(),
      );
    });

    test('render：表头带作品与键，空表给提示', () {
      final String Function(Object?) render = _spec(
        'subtitle-glossary',
      ).render!;
      expect(
        render(<String, Object?>{
          'workKey': 'collection:4',
          'japaneseTitle': 'けいおん!',
          'hasScrapedData': false,
          'entries': <Object?>[],
        }),
        allOf(contains('けいおん!  collection:4（未刮削）'), contains('专名表为空')),
      );
      expect(
        render(<String, Object?>{
          'workKey': 'collection:4',
          'japaneseTitle': 'けいおん!',
          'hasScrapedData': true,
          'entries': <Object?>[
            <String, Object?>{
              'ja': '唯',
              'misrecognitions': <String>['結衣'],
              'userEdited': true,
            },
          ],
        }),
        allOf(contains('唯'), contains('結衣'), contains('✓')),
      );
    });
  });
}
