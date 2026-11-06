import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/preferences_repository.dart';

/// 外部 AI 访问（MCP）的鉴权：设置开关 + 配对令牌（只存 SHA-256）。

/// 令牌摘要（hex）。
String hashAiMcpToken(String token) =>
    sha256.convert(utf8.encode(token)).toString();

/// 按开关、已存摘要与请求带的令牌判定。纯函数，测试直接调。
McpAccess evaluateAiMcpAccess({
  required bool enabled,
  required String storedSha256,
  required String? presentedToken,
}) {
  if (!enabled) return McpAccess.disabled;
  if (storedSha256.isEmpty) return McpAccess.notPaired;
  if (presentedToken == null || presentedToken.isEmpty) {
    return McpAccess.unauthorized;
  }
  return _constantTimeEquals(hashAiMcpToken(presentedToken), storedSha256)
      ? McpAccess.allowed
      : McpAccess.unauthorized;
}

bool _constantTimeEquals(String a, String b) {
  final List<int> x = utf8.encode(a);
  final List<int> y = utf8.encode(b);
  int diff = x.length ^ y.length;
  for (int i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// 生成新的配对令牌并落摘要（旧令牌随即作废）。返回明文令牌——只给用户看这一次。
Future<String> issueAiMcpToken(PreferencesRepository prefs) async {
  final String token = generateCtlToken();
  await prefs.setAiMcpTokenSha256(hashAiMcpToken(token));
  return token;
}

/// 本机 `fushi_cli` 的路径：Windows 安装包把 `fushi_cli.exe` 放在 `fushi.exe` 旁边；
/// 找不到（macOS / Linux / 开发构建）时回 `fushi_cli`，由用户按接入文档换成实际路径。
String aiMcpCliCommand({String? appExecutable}) {
  final String exe = appExecutable ?? Platform.resolvedExecutable;
  final String name = Platform.isWindows ? 'fushi_cli.exe' : 'fushi_cli';
  final String sibling = p.join(p.dirname(exe), name);
  return File(sibling).existsSync() ? sibling : 'fushi_cli';
}

/// 给 MCP 客户端的配置片段（Claude Desktop 的 `claude_desktop_config.json` 形状，
/// 其它客户端同一组 command / args / env）。
String aiMcpClientConfig({required String token, required String command}) =>
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'mcpServers': <String, Object?>{
        'fushi': <String, Object?>{
          'command': command,
          'args': <String>['mcp'],
          'env': <String, String>{kMcpTokenEnv: token},
        },
      },
    });
