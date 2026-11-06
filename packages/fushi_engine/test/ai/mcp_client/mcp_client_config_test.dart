import 'dart:convert';

import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';
import 'package:test/test.dart';

void main() {
  group('McpServerConfig codec', () {
    test('round-trips every field; secrets are stored base64, not plain', () {
      const McpServerConfig config = McpServerConfig(
        id: 'my-server',
        name: 'My server',
        presetId: 'mangabaka',
        enabled: false,
        url: 'https://example.com/mcp',
        headers: <String, String>{'Authorization': 'Bearer secret-token'},
        disabledTools: <String>{'b_tool', 'a_tool'},
        confirmEveryCall: true,
      );
      final String raw = encodeMcpServerConfigs(<McpServerConfig>[config]);
      expect(raw, isNot(contains('secret-token')));
      final McpServerConfig back = decodeMcpServerConfigs(raw).single;
      expect(back.id, 'my-server');
      expect(back.name, 'My server');
      expect(back.presetId, 'mangabaka');
      expect(back.enabled, isFalse);
      expect(back.transport, McpTransportKind.http);
      expect(back.url, 'https://example.com/mcp');
      expect(back.headers, <String, String>{
        'Authorization': 'Bearer secret-token',
      });
      expect(back.disabledTools, <String>{'a_tool', 'b_tool'});
      expect(back.confirmEveryCall, isTrue);
    });

    test('stdio fields round-trip; env values are base64', () {
      const McpServerConfig config = McpServerConfig(
        id: 'local',
        name: 'Local',
        transport: McpTransportKind.stdio,
        command: 'npx',
        args: <String>['-y', 'some-mcp'],
        env: <String, String>{'API_KEY': 'k-123'},
      );
      final String raw = encodeMcpServerConfigs(<McpServerConfig>[config]);
      expect(raw, isNot(contains('k-123')));
      final McpServerConfig back = decodeMcpServerConfigs(raw).single;
      expect(back.transport, McpTransportKind.stdio);
      expect(back.command, 'npx');
      expect(back.args, <String>['-y', 'some-mcp']);
      expect(back.env, <String, String>{'API_KEY': 'k-123'});
    });

    test('a broken entry only drops itself; duplicate ids keep the first', () {
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{'id': 'ok', 'name': 'OK', 'url': 'https://a/mcp'},
        'not a map',
        <String, Object?>{'id': 'Bad Id!', 'name': 'bad'},
        <String, Object?>{'name': 'no id'},
        <String, Object?>{'id': 'ok', 'name': 'duplicate'},
        <String, Object?>{
          'id': 'half',
          'headersB64': <String, Object?>{
            'X': '%%%not base64',
            'Y': base64.encode(utf8.encode('fine')),
          },
        },
      ]);
      final List<McpServerConfig> configs = decodeMcpServerConfigs(raw);
      expect(configs.map((McpServerConfig c) => c.id), <String>['ok', 'half']);
      expect(configs.first.name, 'OK');
      expect(configs.last.headers, <String, String>{'Y': 'fine'});
    });

    test('a non-list payload is a FormatException', () {
      expect(() => decodeMcpServerConfigs('{}'), throwsFormatException);
    });

    test(
      'connection fingerprint ignores on/off, tool switches and confirm policy',
      () {
        const McpServerConfig base = McpServerConfig(
          id: 'a',
          name: 'A',
          url: 'https://a/mcp',
        );
        expect(
          base
              .copyWith(
                enabled: false,
                disabledTools: <String>{'x'},
                confirmEveryCall: true,
              )
              .connectionFingerprint,
          base.connectionFingerprint,
        );
        expect(
          base.copyWith(url: 'https://b/mcp').connectionFingerprint,
          isNot(base.connectionFingerprint),
        );
      },
    );

    test(
      'isComplete needs a URL with a scheme (http) or a command (stdio)',
      () {
        expect(const McpServerConfig(id: 'a', name: 'A').isComplete, isFalse);
        expect(
          const McpServerConfig(
            id: 'a',
            name: 'A',
            url: 'example.com',
          ).isComplete,
          isFalse,
        );
        expect(
          const McpServerConfig(
            id: 'a',
            name: 'A',
            url: 'https://example.com/mcp',
          ).isComplete,
          isTrue,
        );
        expect(
          const McpServerConfig(
            id: 'a',
            name: 'A',
            transport: McpTransportKind.stdio,
            command: 'uvx',
          ).isComplete,
          isTrue,
        );
      },
    );
  });

  group('server ids', () {
    test('slug from the name, de-duplicated', () {
      expect(mcpServerIdFor('MangaBaka', const <String>[]), 'mangabaka');
      expect(
        mcpServerIdFor('MangaBaka', const <String>['mangabaka']),
        'mangabaka-2',
      );
      expect(
        mcpServerIdFor('My  Cool__Server!', const <String>[]),
        'my-cool-server',
      );
      expect(mcpServerIdFor('漫画', const <String>[]), 'server');
      expect(
        isValidMcpServerId(mcpServerIdFor('x' * 80, const <String>[])),
        isTrue,
      );
    });

    test(
      'valid ids never contain characters that break tool-name round trips',
      () {
        expect(isValidMcpServerId('mangabaka'), isTrue);
        expect(isValidMcpServerId('a-b'), isTrue);
        expect(isValidMcpServerId('a_b'), isFalse);
        expect(isValidMcpServerId('a.b'), isFalse);
        expect(isValidMcpServerId('-a'), isFalse);
        expect(isValidMcpServerId(''), isFalse);
      },
    );
  });

  group('importMcpServersFromJson', () {
    test('reads the common mcpServers shape (url and command entries)', () {
      final List<McpServerConfig> imported = importMcpServersFromJson(
        jsonEncode(<String, Object?>{
          'mcpServers': <String, Object?>{
            'mangabaka': <String, Object?>{
              'url': 'https://api.mangabaka.org/mcp',
            },
            'files': <String, Object?>{
              'command': 'npx',
              'args': <String>[
                '-y',
                '@modelcontextprotocol/server-filesystem',
                '/tmp',
              ],
              'env': <String, Object?>{'DEBUG': '1'},
            },
            'junk': <String, Object?>{'nothing': true},
          },
        }),
        taken: const <String>['mangabaka'],
      );
      expect(imported, hasLength(2));
      expect(imported[0].id, 'mangabaka-2');
      expect(imported[0].transport, McpTransportKind.http);
      expect(imported[0].url, 'https://api.mangabaka.org/mcp');
      expect(imported[1].id, 'files');
      expect(imported[1].transport, McpTransportKind.stdio);
      expect(imported[1].args, hasLength(3));
      expect(imported[1].env, <String, String>{'DEBUG': '1'});
    });

    test('also accepts VS Code "servers" and a bare map', () {
      expect(
        importMcpServersFromJson(
          '{"servers":{"a":{"url":"https://a/mcp"}}}',
        ).single.url,
        'https://a/mcp',
      );
      expect(
        importMcpServersFromJson('{"b":{"url":"https://b/mcp"}}').single.id,
        'b',
      );
    });

    test('rejects non-object JSON', () {
      expect(() => importMcpServersFromJson('[]'), throwsFormatException);
    });
  });
}
