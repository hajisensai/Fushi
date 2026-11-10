// AI 助手接入的外部 MCP server（spec docs/specs/2026-11-05-ai-mcp-client-design.md）：
// - 偏好 `ai_mcp_client_servers` 存取、坏数据不崩；
// - 键登记为凭据键、日志脱敏键、设备本地键（请求头 / 环境变量里可能有 token）；
// - 编辑页多行文本 ↔ 字段的解析；
// - 平台判据。没有内置预设：清单默认为空，server 全由用户自己添加。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/mcp_client/ai_mcp_client_form.dart';
import 'package:fushi/src/ai/mcp_client/ai_mcp_client_runtime.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';

void main() {
  group('preference', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() => db.close());

    test('empty by default; round-trips through the database', () async {
      expect(prefs.aiMcpClientServers, isEmpty);
      await prefs.setAiMcpClientServers(<McpServerConfig>[
        const McpServerConfig(
          id: 'public',
          name: 'Public',
          url: 'https://public.example/mcp',
        ),
        const McpServerConfig(
          id: 'private',
          name: 'Private',
          url: 'https://example.com/mcp',
          headers: <String, String>{'Authorization': 'Bearer t0ken'},
        ),
      ]);
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      final List<McpServerConfig> servers = reloaded.aiMcpClientServers;
      expect(servers.map((McpServerConfig s) => s.id), <String>[
        'public',
        'private',
      ]);
      expect(servers.first.headers, isEmpty);
      expect(servers.last.headers['Authorization'], 'Bearer t0ken');
    });

    test(
      'a corrupt value reads as an empty list instead of throwing',
      () async {
        await prefs.setPref('ai_mcp_client_servers', '{not json');
        expect(prefs.aiMcpClientServers, isEmpty);
      },
    );
  });

  test('the key is known, a credential, redacted and device-local', () {
    const String key = 'ai_mcp_client_servers';
    expect(kKnownPreferenceKeys, contains(key));
    expect(kCredentialPreferenceKeys, contains(key));
    expect(PrefRedactionPolicy.sensitiveKeys, contains(key));
    expect(SyncRepository.deviceLocalPrefKeys, contains(key));
  });

  group('form parsing', () {
    test('headers: Key: Value per line, colons in values kept', () {
      expect(
        parseMcpHeaderLines(
          'Authorization: Bearer a:b\n\nbad line\n : no key\nX-Id:  7 ',
        ),
        <String, String>{'Authorization': 'Bearer a:b', 'X-Id': '7'},
      );
      const Map<String, String> headers = <String, String>{
        'A': '1',
        'B': 'two words',
      };
      expect(parseMcpHeaderLines(formatMcpHeaderLines(headers)), headers);
    });

    test('env: KEY=value per line, = in values kept', () {
      expect(
        parseMcpEnvLines('API_KEY=abc=def\r\nEMPTY=\nnope'),
        <String, String>{'API_KEY': 'abc=def', 'EMPTY': ''},
      );
      const Map<String, String> env = <String, String>{'A': '1'};
      expect(parseMcpEnvLines(formatMcpEnvLines(env)), env);
    });

    test('args: one per line, blank lines dropped, inner spaces kept', () {
      expect(
        parseMcpArgLines('-y\n\n  @scope/server  \n/path with space'),
        <String>['-y', '@scope/server', '/path with space'],
      );
    });
  });

  test('web servers are supported everywhere', () {
    expect(
      aiMcpServerSupported(
        const McpServerConfig(id: 'a', name: 'A', url: 'https://a/mcp'),
      ),
      isTrue,
    );
  });
}
