import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_toolbox.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_transport.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

import 'package:fushi/src/utils/misc/platform_utils.dart';

/// AI 助手接入外部 MCP server 的 app 侧装配（spec
/// `docs/specs/2026-11-05-ai-mcp-client-design.md` §4、§6）。
///
/// - HTTP 一律经 [createAppHttpIoClient]：走应用代理与连接超时，loopback 自动直连
///   （守卫 `outbound_http_discipline_guard_test.dart`）。
/// - 本地程序（stdio）只在桌面提供：手机上不能拉起任意程序。

/// 发给 server 的客户端名（`clientInfo.name`）。
const String kAiMcpClientName = 'Fushi';

/// 本平台能不能连这个 server。
bool aiMcpServerSupported(McpServerConfig config) => switch (config.transport) {
  McpTransportKind.http => true,
  McpTransportKind.stdio => isDesktopPlatform,
};

/// 按配置建传输。
Future<McpClientTransport> connectAiMcpServer(McpServerConfig config) async {
  switch (config.transport) {
    case McpTransportKind.http:
      return McpHttpTransport(
        endpoint: Uri.parse(config.url.trim()),
        client: createAppHttpIoClient(),
        headers: config.headers,
      );
    case McpTransportKind.stdio:
      if (!isDesktopPlatform) {
        throw const McpClientException(
          'connect_failed',
          'Local MCP programs are only available on desktop.',
        );
      }
      return McpStdioTransport.start(
        command: config.command.trim(),
        args: config.args,
        env: config.env,
      );
  }
}

/// AI 助手用的 MCP 工具箱：每轮对话前 `prepare()` 现读 [servers]。
McpClientToolbox buildAiMcpClientToolbox(
  List<McpServerConfig> Function() servers, {
  String clientVersion = '',
}) => McpClientToolbox(
  servers: servers,
  connect: connectAiMcpServer,
  isSupported: aiMcpServerSupported,
  clientName: kAiMcpClientName,
  clientVersion: clientVersion,
);

/// 设置页「测试连接」。
Future<McpProbeResult> probeAiMcpServer(McpServerConfig config) =>
    probeMcpServer(config, connectAiMcpServer, clientName: kAiMcpClientName);
