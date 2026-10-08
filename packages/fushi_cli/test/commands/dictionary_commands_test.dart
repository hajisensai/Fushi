import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/dictionary_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

CtlCommandSpec _spec(String group, String command) => dictionaryCommandGroups
    .firstWhere((CtlCommandGroup g) => g.name == group)
    .find(command)!;

/// 按 CLI 主循环同样的方式解析参数并 build。
CtlRequestSpec _build(String group, String command, List<String> args) {
  final CtlCommandSpec spec = _spec(group, command);
  final ArgParser parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false);
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

void main() {
  test('命令组与命令名不重复', () {
    final List<String> groups = dictionaryCommandGroups
        .map((CtlCommandGroup g) => g.name)
        .toList();
    expect(groups, <String>['dict', 'anki']);
    for (final CtlCommandGroup g in dictionaryCommandGroups) {
      final List<String> names = g.commands
          .map((CtlCommandSpec s) => s.name)
          .toList();
      expect(names.toSet().length, names.length, reason: g.name);
      for (final CtlCommandSpec s in g.commands) {
        expect(s.render, isNotNull, reason: '${g.name} ${s.name} 缺 render');
      }
    }
  });

  group('dict', () {
    test('ls', () {
      final CtlRequestSpec plain = _build('dict', 'ls', <String>[]);
      expect(plain.method, 'GET');
      expect(plain.path, '/api/admin/dictionaries');
      expect(plain.query, isNull);
      final CtlRequestSpec typed = _build('dict', 'ls', <String>[
        '--type',
        'pitch',
      ]);
      expect(typed.query, <String, String>{'type': 'pitch'});
      expect(
        () => _build('dict', 'ls', <String>['--type', 'nope']),
        throwsA(isA<ArgParserException>()),
      );
    });

    test('enable / disable 名字编码进路径', () {
      final CtlRequestSpec enable = _build('dict', 'enable', <String>[
        'JMdict',
        '[2024-01-01]',
      ]);
      expect(enable.method, 'PUT');
      expect(
        enable.path,
        '/api/admin/dictionaries/${Uri.encodeComponent('JMdict [2024-01-01]')}',
      );
      expect(enable.body, <String, Object?>{'enabled': true});
      final CtlRequestSpec disable = _build('dict', 'disable', <String>['大辞林']);
      expect(
        disable.path,
        '/api/admin/dictionaries/${Uri.encodeComponent('大辞林')}',
      );
      expect(disable.body, <String, Object?>{'enabled': false});
      expect(
        () => _build('dict', 'enable', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('order：最后一个参数是位置', () {
      final CtlRequestSpec order = _build('dict', 'order', <String>[
        'My',
        'Dict',
        '2',
      ]);
      expect(order.method, 'PUT');
      expect(order.path, '/api/admin/dictionaries/My%20Dict');
      expect(order.body, <String, Object?>{'position': 2});
      expect(
        () => _build('dict', 'order', <String>['JMdict']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('dict', 'order', <String>['JMdict', '0']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('dict', 'order', <String>['JMdict', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rm 需要 --yes', () {
      expect(
        () => _build('dict', 'rm', <String>['JMdict']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec rm = _build('dict', 'rm', <String>[
        'JMdict',
        '--yes',
      ]);
      expect(rm.method, 'DELETE');
      expect(rm.path, '/api/admin/dictionaries/JMdict');
      expect(rm.query, <String, String>{'confirm': 'true'});
    });

    test('import 把路径转成绝对路径', () {
      final CtlRequestSpec import = _build('dict', 'import', <String>[
        'a.zip',
        'style.css',
      ]);
      expect(import.method, 'POST');
      expect(import.path, '/api/admin/dictionaries/import');
      final List<String> paths = (import.body!['paths'] as List<String>);
      expect(paths, hasLength(2));
      expect(paths.every(p.isAbsolute), isTrue);
      expect(p.basename(paths.first), 'a.zip');
      expect(
        () => _build('dict', 'import', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('update / job / cancel', () {
      final CtlRequestSpec all = _build('dict', 'update', <String>[]);
      expect(all.method, 'POST');
      expect(all.path, '/api/admin/dictionaries/update');
      expect(all.body, <String, Object?>{'names': <String>[]});
      final CtlRequestSpec some = _build('dict', 'update', <String>[
        'JMdict',
        '--wait',
      ]);
      expect(some.body, <String, Object?>{
        'names': <String>['JMdict'],
        'wait': true,
      });
      final CtlRequestSpec job = _build('dict', 'job', <String>[]);
      expect((job.method, job.path), ('GET', '/api/admin/dictionaries/job'));
      final CtlRequestSpec cancel = _build('dict', 'cancel', <String>[]);
      expect(
        (cancel.method, cancel.path),
        ('POST', '/api/admin/dictionaries/job/cancel'),
      );
    });

    test('search', () {
      final CtlRequestSpec search = _build('dict', 'search', <String>[
        '食べる',
        '--limit',
        '3',
        '--wildcards',
      ]);
      expect(search.method, 'GET');
      expect(search.path, '/api/admin/dictionaries/search');
      expect(search.query, <String, String>{
        'term': '食べる',
        'limit': '3',
        'wildcards': 'true',
      });
      expect(
        () => _build('dict', 'search', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('dict', 'search', <String>['x', '--limit', 'abc']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('dict', 'search', <String>['x', '--limit', '0']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('search 渲染出词条 / 读音 / 释义前几行', () {
      final String text = _spec('dict', 'search').render!(<String, Object?>{
        'term': '食べる',
        'truncated': false,
        'entries': <Object?>[
          <String, Object?>{
            'word': '食べる',
            'reading': 'たべる',
            'dictionary': 'JMdict',
            'meaning': 'to eat\nto live on\nto earn\nfourth',
          },
        ],
      });
      expect(text, contains('食べる【たべる】'));
      expect(text, contains('JMdict'));
      expect(text, contains('to eat'));
      expect(text, isNot(contains('fourth')));
    });
  });

  group('anki', () {
    test('status / decks / models / sync', () {
      final CtlRequestSpec status = _build('anki', 'status', <String>[]);
      expect(
        (status.method, status.path, status.query),
        ('GET', '/api/admin/anki', null),
      );
      expect(
        _build('anki', 'status', <String>['--no-probe']).query,
        <String, String>{'probe': 'false'},
      );
      expect(_build('anki', 'decks', <String>[]).path, '/api/admin/anki/decks');
      expect(
        _build('anki', 'models', <String>[]).path,
        '/api/admin/anki/models',
      );
      final CtlRequestSpec sync = _build('anki', 'sync', <String>[]);
      expect((sync.method, sync.path), ('POST', '/api/admin/anki/sync'));
    });

    test('set', () {
      expect(
        () => _build('anki', 'set', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec set = _build('anki', 'set', <String>[
        '--deck',
        'Mining',
      ]);
      expect(set.method, 'PUT');
      expect(set.path, '/api/admin/anki/settings');
      expect(set.body, <String, Object?>{'deck': 'Mining'});
    });

    test('mine', () {
      expect(
        () => _build('anki', 'mine', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec mine = _build('anki', 'mine', <String>[
        '--word',
        '食べる',
        '--sentence',
        'ご飯を食べる。',
        '--reading',
        'たべる',
        '--source',
        'https://example.com',
        '--field',
        'notes=hi=there',
        '--allow-duplicate',
        '--no-lookup',
      ]);
      expect(mine.method, 'POST');
      expect(mine.path, '/api/admin/anki/mine');
      expect(mine.body, <String, Object?>{
        'word': '食べる',
        'reading': 'たべる',
        'sentence': 'ご飯を食べる。',
        'source': 'https://example.com',
        'fields': <String, String>{'notes': 'hi=there'},
        'allowDuplicate': true,
        'lookup': false,
      });
      expect(
        _build('anki', 'mine', <String>['-w', '猫']).body,
        <String, Object?>{'word': '猫'},
      );
      expect(
        () => _build('anki', 'mine', <String>['-w', '猫', '--field', 'bad']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('duplicate', () {
      final CtlRequestSpec dup = _build('anki', 'duplicate', <String>[
        '猫',
        '--reading',
        'ねこ',
      ]);
      expect(dup.method, 'GET');
      expect(dup.path, '/api/admin/anki/duplicate');
      expect(dup.query, <String, String>{'expression': '猫', 'reading': 'ねこ'});
      expect(
        () => _build('anki', 'duplicate', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('mine 渲染区分成功 / 重复', () {
      final String Function(Object?) render = _spec('anki', 'mine').render!;
      expect(
        render(<String, Object?>{
          'result': 'success',
          'expression': '猫',
          'noteId': 42,
          'glossaryFilled': true,
        }),
        contains('note 42'),
      );
      expect(
        render(<String, Object?>{'result': 'duplicate', 'expression': '猫'}),
        contains('已有'),
      );
    });
  });
}
