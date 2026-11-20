import 'dart:convert';

import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:fushi_engine/ai/ai_video_franchise_assistant.dart';
import 'package:fushi_engine/ai/ai_video_identity_assistant.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 统一调用层与各助手的「纯浪费」防回归（度量见 docs/agent/ai-token-budget.md）：
/// - 助手型请求的用户提示是紧凑 JSON，不带缩进空白；
/// - 原生 tool calling 时 `ops.describe` 的结果不重复工具表里已有的描述与 schema；
/// - 不可重试的失败（上下文超长、4xx、空回复、输出被截断）只发一次请求，不把整份
///   上下文重发 [kAiChatMaxAttempts] 次。
/// 打印的 `TOKEN|` 行是度量文档引用的数字。
const WebKnowledgeSite _site = WebKnowledgeSite(
  id: 'wikipedia-ja',
  kind: WebKnowledgeSiteKind.mediaWiki,
  label: 'Wikipedia',
);

List<WebKnowledgePage> _pages() => <WebKnowledgePage>[
  for (int i = 0; i < kAiIdentityReferenceMaxPages; i++)
    WebKnowledgePage(
      site: _site,
      title: '葬送のフリーレン $i',
      url: Uri.parse('https://ja.wikipedia.org/wiki/page_$i'),
      text: '『葬送のフリーレン』は、山田鐘人原作、アベツカサ作画による日本の漫画。' * 80,
    ),
];

AiVideoIdentityQuery _identityQuery() => AiVideoIdentityQuery(
  localTitles: <String>['葬送のフリーレン', 'Sousou no Frieren'],
  season: 1,
  episodeCount: 28,
  year: 2023,
  sampleFileNames: <String>[
    for (int i = 1; i <= 5; i++) '[SubsPlease] Sousou no Frieren - $i.mkv',
  ],
  candidates: <AiVideoIdentityCandidate>[
    for (int i = 0; i < 6; i++)
      AiVideoIdentityCandidate(
        key: 'mal:${52991 + i}',
        titles: <String>['Sousou no Frieren $i', '葬送のフリーレン $i'],
        mediaKind: VideoMetadataMediaKind.tv,
        year: 2023 + i % 2,
        episodeCount: 28,
        synopsis:
            'During their decade-long quest to defeat the Demon King. ' * 8,
      ),
  ],
  locale: 'zh-CN',
);

String _indented(String compact) =>
    const JsonEncoder.withIndent('  ').convert(jsonDecode(compact));

void main() {
  group('助手型请求的提示是紧凑 JSON', () {
    test('视频身份消解 / 系列清单：无缩进空白，内容与缩进版逐项相等', () {
      final Map<String, String> prompts = <String, String>{
        'video identity (6 candidates + 3 refs)':
            buildAiVideoIdentityUserPrompt(
              _identityQuery(),
              references: _pages(),
            ),
        'video identity (6 candidates, no refs)':
            buildAiVideoIdentityUserPrompt(_identityQuery()),
        'franchise list (3 refs)': buildAiFranchiseListUserPrompt(
          franchise: '葬送のフリーレン',
          pages: _pages(),
        ),
      };
      for (final MapEntry<String, String> e in prompts.entries) {
        final String before = _indented(e.value);
        // ignore: avoid_print
        print(
          'TOKEN|${e.key}: indented=${before.length} compact=${e.value.length} '
          'saved=${before.length - e.value.length} '
          '(${((before.length - e.value.length) * 100 / before.length).toStringAsFixed(1)}%)',
        );
        expect(e.value, isNot(contains('\n ')), reason: e.key);
        expect(jsonDecode(e.value), jsonDecode(before), reason: e.key);
      }
    });

    test('整理库单次请求构成（200 条目 + 150 合集，打印）', () {
      final AiLibraryOrganizeRequest request = AiLibraryOrganizeRequest(
        domain: 'video',
        nameLanguage: 'zh-Hans',
        knownKeys: <String>[for (int i = 0; i < 60; i++) 'anidb:${1000 + i}'],
        collections: <AiOrganizeCollection>[
          for (int i = 0; i < kAiOrganizeMaxCollectionsPerRequest; i++)
            AiOrganizeCollection(
              id: 'C$i',
              name: '合集 $i',
              memberCount: 5,
              sampleTitles: <String>['作品 $i 第1話', '作品 $i 第2話'],
              userOwned: i.isEven,
              organizeKey: i < 60 ? 'anidb:${1000 + i}' : null,
            ),
        ],
        items: <AiOrganizeItem>[
          for (int i = 0; i < kAiOrganizeMaxItemsPerRequest; i++)
            AiOrganizeItem(
              title: '[SubsPlease] Sousou no Frieren - ${i + 1} (1080p)',
              folder: 'Sousou no Frieren',
              episode: i + 1,
            ),
        ],
      );
      final String system = buildAiLibraryOrganizeSystemPrompt('video');
      final String user = buildAiLibraryOrganizeUserPrompt(request);
      final int itemsAt = user.indexOf('items:\n');
      // ignore: avoid_print
      print(
        'TOKEN|library organize request: system=${system.length} '
        'user=${user.length} (context before items=$itemsAt, '
        'items=${user.length - itemsAt})',
      );
      expect(user, isNot(contains('\n ')));
    });
  });

  group('ops.describe 结果', () {
    const AgentToolSpec spec = AgentToolSpec(
      name: 'library.collection.add',
      description: 'Add items to a collection. Long description of the op.',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{'type': 'integer', 'description': 'id'},
          'keys': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
        },
        'required': <String>['id', 'keys'],
      },
      risk: AgentToolRisk.write,
      undoable: true,
    );

    test('原生 tool calling：不重复描述与 schema，保留工具表里没有的标记与调用名', () {
      final Map<String, Object?> native = agentDescribeResult(
        spec,
        native: true,
      );
      final Map<String, Object?> json = agentDescribeResult(
        spec,
        native: false,
      );
      // ignore: avoid_print
      print(
        'TOKEN|describe result (sample spec): json-protocol=${jsonEncode(json).length} '
        'native=${jsonEncode(native).length}',
      );
      expect(native.containsKey('parameters'), isFalse);
      expect(native.containsKey('description'), isFalse);
      expect(native['risk'], 'write');
      expect(native['undoable'], isTrue);
      expect(native['callAs'], 'library__collection__add');
    });

    test('降级协议：完整描述与 schema 照旧给（系统提示里只有一行签名）', () {
      final Map<String, Object?> json = agentDescribeResult(
        spec,
        native: false,
      );
      expect(json['parameters'], spec.parameters);
      expect(json['description'], spec.description);
      expect(json['callAs'], 'library__collection__add');
    });
  });

  group('不可重试的失败只发一次请求', () {
    AiProviderConfig provider() => AiProviderConfig(
      id: 'p',
      presetId: kAiCustomPresetId,
      name: 'p',
      baseUrl: Uri.parse('https://example.com/v1'),
      apiKey: 'k',
      model: 'm',
    );

    Future<int> count(http.Response Function() reply) async {
      int calls = 0;
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        client: MockClient((http.Request request) async {
          calls++;
          return reply();
        }),
      );
      addTearDown(client.close);
      try {
        await client.completeWithUsage(
          provider: provider(),
          messages: <AiChatMessage>[AiChatMessage.user('x' * 1000)],
        );
      } on AiChatFailure {
        // 期望之中：这里只数请求次数。
      }
      return calls;
    }

    test('上下文超长 / 400 / 空回复 / 输出被截断：各 1 次', () async {
      expect(
        await count(
          () => http.Response(
            '{"error":{"code":"context_length_exceeded"}}',
            400,
          ),
        ),
        1,
      );
      expect(await count(() => http.Response('{"error":"bad"}', 400)), 1);
      expect(
        await count(
          () => http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'finish_reason': 'stop',
                  'message': <String, Object?>{'content': ''},
                },
              ],
            }),
            200,
          ),
        ),
        1,
      );
      expect(
        await count(
          () => http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'finish_reason': 'length',
                  'message': <String, Object?>{'content': '{"half":'},
                },
              ],
            }),
            200,
          ),
        ),
        1,
      );
    });
  });
}
