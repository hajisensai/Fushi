import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_context.dart';

/// 碟片：DVD / BD 菜单、光驱交接的控制通道路由（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §2.2 / §8 P2）。每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑。
List<CtlRoute> buildDiscCtlRoutes(OpContext context) => <CtlRoute>[];
