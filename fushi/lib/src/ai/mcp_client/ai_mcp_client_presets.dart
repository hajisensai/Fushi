import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';

/// 内置 MCP server 预设（spec `docs/specs/2026-11-05-ai-mcp-client-design.md` §3、§9 D4）。
///
/// 预设只是「一键填好表单」：默认不加、不开，用户点了才出现在清单里。
class AiMcpServerPreset {
  const AiMcpServerPreset({
    required this.id,
    required this.name,
    required this.url,
    required this.homepage,
  });

  /// 稳定身份（进 [McpServerConfig.presetId]），也是首选 server id。
  final String id;
  final String name;
  final String url;

  /// 介绍页（设置页里给用户看）。
  final String homepage;

  /// 生成一条配置；id 与 [taken] 撞了就加后缀。
  McpServerConfig toConfig(Iterable<String> taken) => McpServerConfig(
    id: mcpServerIdFor(id, taken),
    name: name,
    presetId: id,
    url: url,
  );
}

/// MangaBaka：开放的漫画 / 轻小说数据库。匿名、18 个工具全部只读（2026-11-06 实测
/// `https://api.mangabaka.org/mcp`；只说 MCP 2026-07-28 无状态协议）。
const AiMcpServerPreset kMangaBakaMcpPreset = AiMcpServerPreset(
  id: 'mangabaka',
  name: 'MangaBaka',
  url: 'https://api.mangabaka.org/mcp',
  homepage: 'https://mangabaka.org/developers/mcp',
);

const List<AiMcpServerPreset> kAiMcpServerPresets = <AiMcpServerPreset>[
  kMangaBakaMcpPreset,
];
