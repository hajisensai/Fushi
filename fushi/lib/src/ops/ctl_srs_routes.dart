import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_context.dart';

/// 复习（SRS）：牌组 / 笔记查询、统计、sync v2 冲突、重复笔记合并；以及云同步中途冲突的非交互裁决的控制通道路由（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §2.2 / §8 P2）。每条路由调用 UI 按钮背后的同一个方法，不另写业务逻辑。
List<CtlRoute> buildSrsCtlRoutes(OpContext context) => <CtlRoute>[];
