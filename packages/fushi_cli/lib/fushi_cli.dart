/// Fushi 桌面客户端命令行与本机控制通道。
///
/// - app 侧：[CtlServer] + [CtlDesktopHandler]（`fushi/lib/src/platform/desktop/desktop_ctl_host.dart` 接线）。
/// - CLI 侧：[runFushiCli]（`bin/fushi_cli.dart`）。
/// - 外部 AI：[McpServer] / [McpHttpEndpoint]（挂在控制通道 `/mcp`）与
///   `fushi_cli mcp`（[McpStdioBridge]，stdio ↔ `/mcp`）。
/// - 两侧共用：[CtlEndpoint] 发现文件与 [resolveCtlStateDir] 路径约定。
library;

export 'src/ctl_cli.dart';
export 'src/ctl_client.dart';
export 'src/ctl_endpoint.dart';
export 'src/ctl_launcher.dart';
export 'src/ctl_paths.dart';
export 'src/ctl_protocol.dart';
export 'src/ctl_routes.dart';
export 'src/ctl_command_registry.dart';
export 'src/ctl_commands.dart';
export 'src/ctl_server.dart';
export 'src/mcp/mcp_http.dart';
export 'src/mcp/mcp_server.dart';
export 'src/mcp/mcp_stdio_bridge.dart';
export 'src/ops/fushi_op.dart';
export 'src/ops/op_catalog.dart';
export 'src/ops/op_routes.dart';
