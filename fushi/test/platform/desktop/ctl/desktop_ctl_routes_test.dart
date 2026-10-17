import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造路由表时不应访问 ref');
}

/// 五个域各自只测了自己的路由表；这里测合起来之后的整张表——两个域撞上同一个
/// method+path 时，服务端按注册顺序只认第一条，另一条静默变成死路由。
void main() {
  final List<CtlRoute> routes = buildDesktopCtlRoutes(
    DesktopCtlContext(ref: _UnusedRef(), focusMainWindow: () async {}),
  );

  test('整张路由表非空且都在 /api/admin/ 下', () {
    expect(routes.length, greaterThan(50));
    for (final CtlRoute route in routes) {
      expect(route.pattern, startsWith('/api/admin/'), reason: route.pattern);
    }
  });

  test('跨域 method+path 不重复', () {
    final Set<String> seen = <String>{};
    for (final CtlRoute route in routes) {
      final String id = '${route.method} ${route.pattern}';
      expect(seen.add(id), isTrue, reason: '重复路由：$id');
    }
  });

  test('不遮住内置的 status / open / lookup / quit', () {
    for (final String builtin in <String>[
      kCtlStatusPath,
      kCtlOpenPath,
      kCtlLookupPath,
      kCtlQuitPath,
    ]) {
      for (final CtlRoute route in routes) {
        expect(
          route.match(builtin),
          isNull,
          reason: '${route.pattern} 会吞掉内置路径 $builtin',
        );
      }
    }
  });

  test('CLI 命令组名不重复，也不和内置命令重名', () {
    final Set<String> names = <String>{
      'status',
      'start',
      'open',
      'lookup',
      'quit',
    };
    for (final CtlCommandGroup group in kCtlCommandGroups) {
      expect(names.add(group.name), isTrue, reason: '重名命令组：${group.name}');
    }
  });
}
