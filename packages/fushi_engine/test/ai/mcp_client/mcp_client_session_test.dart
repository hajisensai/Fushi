import 'package:fushi_engine/ai/mcp_client/mcp_client_session.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_transport.dart';
import 'package:test/test.dart';

/// 记下每条请求与头部，按 method 回预设应答的假传输。
class _FakeTransport implements McpClientTransport {
  _FakeTransport(this.handler);

  final Map<String, Object?> Function(Map<String, Object?> message) handler;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final List<Map<String, String>> requestHeaders = <Map<String, String>>[];
  final List<Map<String, Object?>> notifications = <Map<String, Object?>>[];
  bool closed = false;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
    required Duration timeout,
  }) async {
    requests.add(message);
    requestHeaders.add(headers);
    return <String, Object?>{
      'jsonrpc': '2.0',
      'id': message['id'],
      ...handler(message),
    };
  }

  @override
  Future<void> notify(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
  }) async => notifications.add(message);

  @override
  Future<void> close() async => closed = true;
}

Map<String, Object?> _params(Map<String, Object?> message) =>
    Map<String, Object?>.from(message['params']! as Map);

/// MangaBaka 2026-11-06 实测的拒绝应答形状。
const Map<String, Object?> _mangabakaInitializeError = <String, Object?>{
  'error': <String, Object?>{
    'code': -32022,
    'message': 'Unsupported protocol version: 2025-06-18',
    'data': <String, Object?>{
      'supported': <String>['2026-07-28'],
      'requested': '2025-06-18',
    },
  },
};

const Map<String, Object?> _searchTool = <String, Object?>{
  'name': 'series_search',
  'title': 'Search MangaBaka series',
  'description': 'Search the MangaBaka catalog.',
  'inputSchema': <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'q': <String, Object?>{'type': 'string'},
    },
  },
  'outputSchema': <String, Object?>{'type': 'object'},
  'annotations': <String, Object?>{'readOnlyHint': true},
};

McpClientSession _session(_FakeTransport transport) =>
    McpClientSession(transport, clientName: 'Fushi', clientVersion: '1.0');

void main() {
  test(
    'legacy servers: initialize, then initialized notification and version header',
    () async {
      final _FakeTransport transport = _FakeTransport((Map<String, Object?> m) {
        switch (m['method']) {
          case 'initialize':
            return <String, Object?>{
              'result': <String, Object?>{
                'protocolVersion': '2025-03-26',
                'serverInfo': <String, Object?>{'name': 'old-server'},
                'capabilities': <String, Object?>{},
              },
            };
          case 'tools/list':
            return <String, Object?>{
              'result': <String, Object?>{
                'tools': <Object?>[_searchTool],
              },
            };
        }
        return <String, Object?>{
          'error': <String, Object?>{'code': -32601},
        };
      });
      final McpClientSession session = _session(transport);
      await session.open();
      expect(session.mode, McpProtocolMode.legacy);
      expect(session.protocolVersion, '2025-03-26');
      expect(session.serverName, 'old-server');
      expect(
        transport.notifications.single['method'],
        'notifications/initialized',
      );
      final Map<String, Object?> init = _params(transport.requests.first);
      expect(init['protocolVersion'], kMcpClientLegacyProtocolVersion);
      expect((init['clientInfo']! as Map)['name'], 'Fushi');

      final List<McpRemoteTool> tools = await session.listTools();
      expect(tools.single.name, 'series_search');
      expect(
        transport.requestHeaders.last['MCP-Protocol-Version'],
        '2025-03-26',
      );
      // 旧协议没有 `_meta` 信封。
      expect(_params(transport.requests.last).containsKey('_meta'), isFalse);
    },
  );

  test(
    'stateless servers (MangaBaka): envelope in _meta and method headers on every request',
    () async {
      final _FakeTransport transport = _FakeTransport((Map<String, Object?> m) {
        switch (m['method']) {
          case 'initialize':
            return _mangabakaInitializeError;
          case 'tools/list':
            return <String, Object?>{
              'result': <String, Object?>{
                'tools': <Object?>[_searchTool],
                '_meta': <String, Object?>{
                  'io.modelcontextprotocol/serverInfo': <String, Object?>{
                    'name': 'mangabaka',
                  },
                },
              },
            };
          case 'tools/call':
            return <String, Object?>{
              'result': <String, Object?>{
                'content': <Object?>[
                  <String, Object?>{
                    'type': 'text',
                    'text': '{"results":[{"id":6766}]}',
                  },
                ],
                'structuredContent': <String, Object?>{'results': <Object?>[]},
              },
            };
        }
        return <String, Object?>{
          'error': <String, Object?>{'code': -32601},
        };
      });
      final McpClientSession session = _session(transport);
      await session.open();
      expect(session.mode, McpProtocolMode.stateless);
      expect(session.protocolVersion, kMcpClientStatelessProtocolVersion);
      expect(transport.notifications, isEmpty);

      final List<McpRemoteTool> tools = await session.listTools();
      expect(tools.single.readOnly, isTrue);
      expect(session.serverName, 'mangabaka');
      final Map<String, Object?> meta = Map<String, Object?>.from(
        _params(transport.requests.last)['_meta']! as Map,
      );
      expect(meta['io.modelcontextprotocol/protocolVersion'], '2026-07-28');
      expect(
        meta['io.modelcontextprotocol/clientCapabilities'],
        isA<Map<Object?, Object?>>(),
      );
      expect(transport.requestHeaders.last, <String, String>{
        'MCP-Protocol-Version': '2026-07-28',
        'Mcp-Method': 'tools/list',
      });

      final McpCallOutcome outcome = await session.callTool(
        'series_search',
        <String, Object?>{'q': 'yotsuba'},
      );
      expect(outcome.isError, isFalse);
      // 有文本块时用文本，不用 structuredContent。
      expect(outcome.text, '{"results":[{"id":6766}]}');
      expect(transport.requestHeaders.last['Mcp-Method'], 'tools/call');
      expect(transport.requestHeaders.last['Mcp-Name'], 'series_search');
      expect(_params(transport.requests.last)['arguments'], <String, Object?>{
        'q': 'yotsuba',
      });
    },
  );

  test('initialize method-not-found also falls back to stateless', () async {
    final McpClientSession session = _session(
      _FakeTransport(
        (_) => <String, Object?>{
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Method not found',
          },
        },
      ),
    );
    await session.open();
    expect(session.mode, McpProtocolMode.stateless);
  });

  test(
    'a server that supports neither generation fails with unsupported_version',
    () async {
      final McpClientSession session = _session(
        _FakeTransport(
          (_) => <String, Object?>{
            'error': <String, Object?>{
              'code': -32022,
              'message': 'nope',
              'data': <String, Object?>{
                'supported': <String>['2099-01-01'],
              },
            },
          },
        ),
      );
      await expectLater(
        session.open(),
        throwsA(
          isA<McpClientException>()
              .having(
                (McpClientException e) => e.code,
                'code',
                'unsupported_version',
              )
              .having(
                (McpClientException e) => e.message,
                'message',
                contains('2099-01-01'),
              ),
        ),
      );
    },
  );

  test(
    'tools/list follows nextCursor; outputSchema is dropped; bad tools skipped',
    () async {
      final _FakeTransport transport = _FakeTransport((Map<String, Object?> m) {
        if (m['method'] == 'initialize') return _mangabakaInitializeError;
        final Object? cursor = _params(m)['cursor'];
        return <String, Object?>{
          'result': cursor == null
              ? <String, Object?>{
                  'tools': <Object?>[
                    _searchTool,
                    <String, Object?>{'description': 'no name'},
                  ],
                  'nextCursor': 'page2',
                }
              : <String, Object?>{
                  'tools': <Object?>[
                    <String, Object?>{
                      'name': 'writer',
                      'description': 'Writes.',
                    },
                  ],
                },
        };
      });
      final McpClientSession session = _session(transport);
      await session.open();
      final List<McpRemoteTool> tools = await session.listTools();
      expect(tools.map((McpRemoteTool t) => t.name), <String>[
        'series_search',
        'writer',
      ]);
      // 没有 annotations：非只读，且按 MCP 缺省视为 destructive。
      expect(tools.last.readOnly, isFalse);
      expect(tools.last.destructive, isTrue);
      expect(tools.last.inputSchema, <String, Object?>{'type': 'object'});
    },
  );

  test('tool errors come back as isError outcomes; RPC errors throw', () async {
    final McpClientSession session = _session(
      _FakeTransport((Map<String, Object?> m) {
        if (m['method'] == 'initialize') return _mangabakaInitializeError;
        if (_params(m)['name'] == 'bad_args') {
          return <String, Object?>{
            'result': <String, Object?>{
              'isError': true,
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'q is required'},
              ],
            },
          };
        }
        return <String, Object?>{
          'error': <String, Object?>{'code': -32602, 'message': 'Unknown tool'},
        };
      }),
    );
    await session.open();
    final McpCallOutcome outcome = await session.callTool(
      'bad_args',
      const <String, Object?>{},
    );
    expect(outcome.isError, isTrue);
    expect(outcome.text, 'q is required');
    await expectLater(
      session.callTool('missing', const <String, Object?>{}),
      throwsA(
        isA<McpClientException>().having(
          (McpClientException e) => e.code,
          'code',
          'rpc_error',
        ),
      ),
    );
  });

  test(
    'result text: non-text blocks become placeholders; structuredContent is the fallback',
    () {
      expect(
        mcpCallResultText(<String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'a'},
            <String, Object?>{
              'type': 'image',
              'data': 'xx',
              'mimeType': 'image/png',
            },
            <String, Object?>{
              'type': 'resource',
              'resource': <String, Object?>{'uri': 'x://y', 'text': 'b'},
            },
          ],
        }),
        'a\n[image content omitted]\nb',
      );
      expect(
        mcpCallResultText(<String, Object?>{
          'content': <Object?>[],
          'structuredContent': <String, Object?>{'n': 1},
        }),
        '{"n":1}',
      );
    },
  );

  test('calling before open is a protocol error', () async {
    final McpClientSession session = _session(
      _FakeTransport((_) => const <String, Object?>{}),
    );
    await expectLater(session.listTools(), throwsA(isA<McpClientException>()));
  });
}
