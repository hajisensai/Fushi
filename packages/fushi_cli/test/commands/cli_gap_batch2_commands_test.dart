import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

/// 拍板台 PGpPujl99g 第二批补进 CLI 的命令（音乐以外）：game hook-codes*、
/// srs import-mined、leaderboard、anime、config backdrop-image。
CtlRequestSpec _build(String group, String command, List<String> args) {
  final CtlCommandSpec spec = kCtlCommandGroups
      .singleWhere((CtlCommandGroup g) => g.name == group)
      .find(command)!;
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('game hook-codes：列出 / 导出（--overwrite）/ 导入', () {
    expect(
      _build('game', 'hook-codes', <String>[]).path,
      '/api/admin/game/hook-codes',
    );
    final CtlRequestSpec export = _build('game', 'hook-codes-export', <String>[
      'out.tsv',
      '--overwrite',
    ]);
    expect(export.path, '/api/admin/game/hook-codes/export');
    expect(export.body!['overwrite'], isTrue);
    expect('${export.body!['path']}', endsWith('out.tsv'));
    expect(
      _build('game', 'hook-codes-import', <String>['in.tsv']).path,
      '/api/admin/game/hook-codes/import',
    );
  });

  test('srs import-mined 要 --yes', () {
    expect(() => _build('srs', 'import-mined', <String>[]), _usageError());
    final CtlRequestSpec r = _build('srs', 'import-mined', <String>['--yes']);
    expect(r.path, '/api/admin/srs/import-mined');
    expect(r.body, <String, Object?>{'confirm': true});
  });

  test('leaderboard：status；recovery-import 从环境变量读恢复码、不收命令行明文', () {
    expect(
      _build('leaderboard', 'status', <String>[]).path,
      '/api/admin/leaderboard',
    );
    expect(
      () => _build('leaderboard', 'recovery-import', <String>[
        '--from-env',
        'FUSHI_TEST_SURELY_UNSET_VAR',
      ]),
      _usageError(),
    );
    expect(
      () => ArgParser()
        ..addOption('from-env')
        ..parse(<String>['--code', 'x']),
      throwsA(isA<ArgParserException>()),
    );
  });

  test('anime：plans / import-now', () {
    expect(
      _build('anime', 'plans', <String>[]).path,
      '/api/admin/anime-downloads',
    );
    final CtlRequestSpec r = _build('anime', 'import-now', <String>['p 1']);
    expect(r.method, 'POST');
    expect(r.path, '/api/admin/anime-downloads/p%201/import-now');
  });

  test('config backdrop-image：--portrait / --module', () {
    final CtlRequestSpec r = _build('config', 'backdrop-image', <String>[
      'bg.png',
      '--portrait',
      '--module',
      'music',
    ]);
    expect(r.path, '/api/admin/appearance/page-backdrop/image');
    expect(r.body!['portrait'], isTrue);
    expect(r.body!['module'], 'music');
    expect('${r.body!['path']}', endsWith('bg.png'));
  });
}
