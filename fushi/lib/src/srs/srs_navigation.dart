/// 复习模块里压页面的唯一入口。
///
/// 复习页面可能跑在子 provider 作用域里：远程复习的 `SrsRemoteCollectionScope`（`srsStoreProvider` 换成转发到
/// 主机的库）、浏览器扩展所选的非激活配置（[srsPushNoteEditor] 的 overrides）。路由建在导航器的 overlay 里，
/// 不在调用方的子树下——裸 `Navigator.push(adaptivePageRoute(...))` 压出的页面会落回根作用域，读写的是
/// App 激活配置的本机库，而不是调用方那份。所以复习模块可达的页面一律经 [srsPushPage] / [srsPageRoute] 压页，
/// 守卫 `fushi/test/srs/srs_navigation_scope_guard_test.dart` 钉住。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/utils.dart';

/// 从 [from] 所在的 provider 作用域再压页面 / 抽屉时，把同一个作用域带过去：路由建在导航器的
/// overlay 里，不在 [from] 的子树下，不带的话会落回根作用域（App 激活配置的复习）。
/// [from] 就在根作用域里时这层包装是透明的。
Widget srsInheritProviderScope(BuildContext from, Widget child) =>
    UncontrolledProviderScope(
      container: ProviderScope.containerOf(from, listen: false),
      child: child,
    );

/// 沿用 [from] 所在 provider 作用域的页面路由。作用域容器在建路由时就取好：之后 [from] 卸载（下面那页被
/// 替换掉）也不影响这页的重建。
Route<T> srsPageRoute<T>(
  BuildContext from,
  WidgetBuilder builder, {
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  final ProviderContainer container = ProviderScope.containerOf(
    from,
    listen: false,
  );
  return adaptivePageRoute<T>(
    context: from,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
    builder: (BuildContext context) => UncontrolledProviderScope(
      container: container,
      child: builder(context),
    ),
  );
}

/// 在 [context] 的导航器上压一页，页面沿用 [context] 所在的 provider 作用域（见库注释）。
Future<T?> srsPushPage<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) => Navigator.of(context).push<T>(
  srsPageRoute<T>(
    context,
    builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  ),
);
