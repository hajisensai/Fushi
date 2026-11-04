import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> yaml(Map<String, Object?> search) => <String, Object?>{
    'preset': 'openai',
    'api_key': 'sk-x',
    'web_search': search,
  };

  test('web_search 段解析；没写 = null', () {
    final ServerAiConfig? c = ServerAiConfig.fromYaml(
      yaml(<String, Object?>{
        'kind': 'searxng',
        'endpoint': 'https://s.example.org',
      }),
    );
    expect(c!.webSearch!.kind, WebSearchKind.searxng);
    expect(c.webSearch!.isUsable, isTrue);
    expect(ServerAiSettings(() => c).aiWebSearch, c.webSearch);

    final ServerAiConfig? none = ServerAiConfig.fromYaml(<String, Object?>{
      'preset': 'openai',
    });
    expect(none!.webSearch, isNull);
    expect(ServerAiSettings(() => none).aiWebSearch, isNull);
    expect(ServerAiSettings(() => null).aiWebSearch, isNull);
  });

  test('未知 kind -> null；brave 读 api_key', () {
    expect(
      ServerAiConfig.fromYaml(
        yaml(<String, Object?>{'kind': 'bing'}),
      )!.webSearch,
      isNull,
    );
    final ServerAiConfig? c = ServerAiConfig.fromYaml(
      yaml(<String, Object?>{'kind': 'brave', 'api_key': 'tok'}),
    );
    expect(c!.webSearch!.apiKey, 'tok');
  });

  test('writeYaml 写出 web_search，admin JSON 不回显 key', () {
    final ServerAiConfig c = ServerAiConfig.fromYaml(
      yaml(<String, Object?>{'kind': 'brave', 'api_key': 'tok'}),
    )!;
    final StringBuffer b = StringBuffer();
    c.writeYaml(b, (String s) => '"$s"');
    expect(b.toString(), contains('  web_search:'));
    expect(b.toString(), contains('    kind: "brave"'));
    expect(b.toString(), contains('    api_key: "tok"'));

    final Map<String, Object?> admin = c.toAdminJson();
    final Map<String, Object?> search =
        admin['webSearch']! as Map<String, Object?>;
    expect(search['apiKeySet'], true);
    expect(search.containsKey('apiKey'), false);
    expect(admin.toString(), isNot(contains('tok')));
  });

  test('copyWith 默认保留；clearWebSearch 清掉', () {
    final ServerAiConfig c = ServerAiConfig.fromYaml(
      yaml(<String, Object?>{'kind': 'brave', 'api_key': 'tok'}),
    )!;
    expect(c.copyWith(webKnowledge: false).webSearch, isNotNull);
    expect(c.copyWith(clearWebSearch: true).webSearch, isNull);
  });
}
