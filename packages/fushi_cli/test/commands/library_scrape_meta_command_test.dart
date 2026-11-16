import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/library_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `library scrape-meta get|set|clear <key>`：单本书 / 漫画 / 有声书 / 游戏的刮削资料与
/// 横版背景（v155），脚本造测试数据用。
CtlCommandSpec _spec() =>
    libraryCommandGroups
        .singleWhere((CtlCommandGroup g) => g.name == 'library')
        .find('scrape-meta') ??
    (throw StateError('library scrape-meta'));

CtlRequestSpec _build(List<String> args) {
  final CtlCommandSpec spec = _spec();
  final ArgParser parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false);
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('get / clear：路径与 --yes 门', () {
    final CtlRequestSpec get = _build(<String>['get', 'game:g1']);
    expect(get.method, 'GET');
    expect(
      get.path,
      '/api/admin/library/items/${Uri.encodeComponent('game:g1')}/scrape-meta',
    );
    expect(() => _build(<String>['clear', 'book:k']), _usageError());
    expect(_build(<String>['clear', 'book:k', '--yes']).method, 'DELETE');
  });

  test('set：字段映射、类型逗号拆分、本地背景转绝对路径、URL 原样', () {
    final CtlRequestSpec set = _build(<String>[
      'set',
      'book:猫',
      '--summary',
      '一句话简介',
      '--year',
      '2014',
      '--rating',
      '8.5',
      '--genres',
      '恋爱, 日常，校园',
      '--backdrop',
      'bg.jpg',
      '--logo',
      'https://x.test/logo.png',
    ]);
    expect(set.method, 'PUT');
    expect(set.body, <String, Object?>{
      'summary': '一句话简介',
      'year': 2014,
      'rating': 8.5,
      'genres': <String>['恋爱', '日常', '校园'],
      'backdropPath': p.normalize(p.absolute('bg.jpg')),
      'logoUrl': 'https://x.test/logo.png',
    });
    expect(
      _build(<String>['set', 'srt:u', '--date', '2020-01', '--replace']).body,
      <String, Object?>{'date': '2020-01', 'replace': true},
    );
  });

  test('拒绝：空 set、坏数字、视频键、未知动作', () {
    expect(() => _build(<String>['set', 'book:k']), _usageError());
    expect(
      () => _build(<String>['set', 'book:k', '--rating', 'abc']),
      _usageError(),
    );
    expect(() => _build(<String>['get', 'video:v']), _usageError());
    expect(() => _build(<String>['show', 'book:k']), _usageError());
  });

  test('render：资料逐项 + 图片路径；clear 报删除数', () {
    final String out = _spec().render!(<String, Object?>{
      'key': 'game:g1',
      'mediaType': 'game',
      'entryKey': 'g1',
      'meta': <String, Object?>{
        'source': 'manual',
        'rating': 8.5,
        'tags': <String>['恋爱', '日常'],
      },
      'images': <Object?>[
        <String, Object?>{'kind': 'backdrop', 'path': '/x/bg.jpg'},
      ],
    });
    expect(out, allOf(contains('8.5'), contains('恋爱 / 日常')));
    expect(out, contains('backdrop：/x/bg.jpg'));
    expect(
      _spec().render!(<String, Object?>{
        'key': 'book:k',
        'cleared': true,
        'files': 2,
      }),
      contains('2 个图片文件'),
    );
  });
}
