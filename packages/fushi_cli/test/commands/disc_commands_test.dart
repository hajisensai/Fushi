import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group() =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == 'disc');

CtlCommandSpec _spec(String command) => _group().find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('disc 组只注册一次、子命令齐全不重名', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'disc'),
      hasLength(1),
    );
    final List<String> names = <String>[
      for (final CtlCommandSpec s in _group().commands) s.name,
    ];
    expect(names.toSet(), hasLength(names.length));
    expect(names, <String>['ls', 'open', 'now', 'key', 'exit']);
  });

  test('ls：关键词拼成 search，不给就不带', () {
    final CtlRequestSpec ls = _build('ls', <String>['Disc', '2']);
    expect(ls.method, 'GET');
    expect(ls.path, '/api/admin/disc/discs');
    expect(ls.query, <String, String>{'search': 'Disc 2'});
    expect(_build('ls', <String>[]).query, isEmpty);
  });

  test('open：uid 进 body，缺 uid 是用法错误', () {
    final CtlRequestSpec open = _build('open', <String>['vid-1']);
    expect(open.method, 'POST');
    expect(open.path, '/api/admin/disc/open');
    expect(open.body, <String, Object?>{'uid': 'vid-1'});
    expect(() => _build('open', <String>[]), _usageError());
  });

  test('key：kebab 键名换成 wire 名，ok / enter 是 select 的别名', () {
    CtlRequestSpec key(String k) => _build('key', <String>[k]);
    expect(key('up').path, '/api/admin/disc/session/key');
    expect(key('up').method, 'POST');
    expect(key('UP').body, <String, Object?>{'key': 'up'});
    expect(key('top-menu').body, <String, Object?>{'key': 'topMenu'});
    expect(key('title-menu').body, <String, Object?>{'key': 'titleMenu'});
    expect(key('popup-menu').body, <String, Object?>{'key': 'popupMenu'});
    expect(key('ok').body, <String, Object?>{'key': 'select'});
    expect(key('enter').body, <String, Object?>{'key': 'select'});
    expect(() => key('jump'), _usageError());
    expect(() => _build('key', <String>[]), _usageError());
  });

  test('now / exit：会话状态与退出', () {
    final CtlRequestSpec now = _build('now', <String>[]);
    expect(now.method, 'GET');
    expect(now.path, '/api/admin/disc/session');
    final CtlRequestSpec exit = _build('exit', <String>[]);
    expect(exit.method, 'POST');
    expect(exit.path, '/api/admin/disc/session/exit');
  });

  test('render：列表、会话、没有会话', () {
    final String table = _spec('ls').render!(<String, Object?>{
      'discs': <Object?>[
        <String, Object?>{
          'uid': 'v1',
          'label': 'Disc 1',
          'format': 'uhdBluray',
          'title': 'Movie',
          'present': true,
        },
        <String, Object?>{
          'uid': 'v2',
          'label': 'DISC_2',
          'format': 'dvd',
          'title': 'Extras',
          'present': false,
        },
      ],
    });
    expect(table, contains('UHD BD'));
    expect(table, contains('DVD'));
    expect(table, contains('不在线'));
    expect(
      _spec('ls').render!(<String, Object?>{'discs': <Object?>[]}),
      contains('没有原盘'),
    );
    expect(
      _spec('now').render!(<String, Object?>{'active': false}),
      '没有打开的原盘会话',
    );
    expect(
      _spec('now').render!(<String, Object?>{
        'active': true,
        'title': 'Movie',
        'type': 'bluray',
        'menuActive': true,
        'discTitle': 0,
      }),
      'Movie · BD · 菜单 · 标题 0',
    );
  });
}
