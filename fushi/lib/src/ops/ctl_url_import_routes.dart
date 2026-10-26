import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_context.dart';

/// URL 视频导入（YouTube 等）的控制通道路由（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §2.2 / §8 P2）。每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑。
List<CtlRoute> buildUrlImportCtlRoutes(OpContext context) => <CtlRoute>[];
