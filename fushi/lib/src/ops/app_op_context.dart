import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_context.dart';

/// 进程级的操作上下文：app 根组件在 initState 里登记（五个平台都登记），AI 助手
/// 与桌面控制通道共用这一份——它持有根组件的 `WidgetRef`，生命周期等于 app，
/// 不会像某个页面的 ref 那样随页面关闭失效（AI 会话关了浮层仍可能在跑长任务）。
OpContext? get appOpContext => _appOpContext;
OpContext? _appOpContext;

/// 组装「全部按域路由 + 操作目录」的进程内调用器（生产实现是 `op_routes.dart` 的
/// `buildInProcessOpInvoker`）。
///
/// AI 助手（本机浮层、远端会话、`/mcp`）只经这个窄接口拿调用器，不直接 import
/// `op_routes.dart`：那张路由表依赖全部 `ctl_<域>_routes.dart`，而它们又依赖
/// `AppModel`，直接 import 会把整个操作目录拖进 app 的 import 大环。
typedef InProcessOpInvokerBuilder =
    OpInvoker Function(OpContext context, {Iterable<FushiOp> extra});

InProcessOpInvokerBuilder? _inProcessOpInvokerBuilder;

/// 登记进程级上下文与进程内调用器的组装函数（app 根组件调用，两者同时登记）。
void registerAppOpContext(
  OpContext context, {
  required InProcessOpInvokerBuilder buildInProcessInvoker,
}) {
  _appOpContext = context;
  _inProcessOpInvokerBuilder = buildInProcessInvoker;
}

/// 用登记的组装函数为 [context] 建进程内调用器；[extra] 是只在进程内有的操作。
///
/// 没登记就调用是装配错误（调用方都在 [appOpContext] 登记之后才可达），直接抛
/// [StateError]，不静默返回空目录。
OpInvoker buildAppInProcessOpInvoker(
  OpContext context, {
  Iterable<FushiOp> extra = const <FushiOp>[],
}) {
  final InProcessOpInvokerBuilder? build = _inProcessOpInvokerBuilder;
  if (build == null) {
    throw StateError(
      'buildAppInProcessOpInvoker called before registerAppOpContext',
    );
  }
  return build(context, extra: extra);
}
