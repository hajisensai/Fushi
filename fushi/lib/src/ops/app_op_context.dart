import 'package:fushi/src/ops/op_context.dart';

/// 进程级的操作上下文：app 根组件在 initState 里登记（五个平台都登记），AI 助手
/// 与桌面控制通道共用这一份——它持有根组件的 `WidgetRef`，生命周期等于 app，
/// 不会像某个页面的 ref 那样随页面关闭失效（AI 会话关了浮层仍可能在跑长任务）。
OpContext? get appOpContext => _appOpContext;
OpContext? _appOpContext;

void registerAppOpContext(OpContext context) => _appOpContext = context;
