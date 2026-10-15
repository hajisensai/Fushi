// 合集 AI 定序的纯逻辑：「规则判不出」判据（视频 SP / OVA、书汉字卷号 / 上下卷 /
// 卷号冲突）、规则序、回复校验（完整排列 / 越界 / 重复 / 缺失 / 锚点不可动 / 坏 JSON）、
// 请求函数没有歧义时一个请求都不发。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_collection_order_assistant.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

class _Settings implements AiSettingsSource {
  _Settings(this.aiFeatureAssignments);

  @override
  final AiFeatureAssignments aiFeatureAssignments;

  @override
  List<AiProviderConfig> get aiProviders => <AiProviderConfig>[_provider()];

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];
}

/// 回固定 [reply]，把每次请求的 user 文本记进 [prompts]。
AiChatClient _client(String reply, List<String> prompts) => AiChatClient(
  client: MockClient((http.Request request) async {
    final Map<String, Object?> body =
        jsonDecode(request.body) as Map<String, Object?>;
    for (final Object? m in body['messages'] as List<Object?>) {
      final Map<String, Object?> message = m as Map<String, Object?>;
      if (message['role'] == 'user') prompts.add(message['content'] as String);
    }
    return http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': reply},
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }),
);

AiCollectionOrderMember _video(String file) =>
    AiCollectionOrderMember.video(title: file, fileName: file);

AiCollectionOrderMember _book(String title) =>
    AiCollectionOrderMember.book(title: title);

void main() {
  group('collectionOrderAmbiguousIndices', () {
    test('视频：有集号与无集号并存时，无集号的 SP / OVA 判不出', () {
      final List<AiCollectionOrderMember> members = <AiCollectionOrderMember>[
        _video('[Grp] Show - 01 [1080p].mkv'),
        _video('[Grp] Show - 02 [1080p].mkv'),
        _video('[Grp] Show - OVA [1080p].mkv'),
        _video('[Grp] Show - SP [1080p].mkv'),
      ];
      expect(members[0].episode, 1);
      expect(members[2].episode, isNull);
      expect(
        collectionOrderAmbiguousIndices(members, AiCollectionOrderKind.video),
        <int>{2, 3},
      );
    });

    test('视频：全有集号 / 全无集号都不算歧义（不发请求）', () {
      expect(
        collectionOrderAmbiguousIndices(<AiCollectionOrderMember>[
          _video('Show - 01.mkv'),
          _video('Show - 02.mkv'),
        ], AiCollectionOrderKind.video),
        isEmpty,
      );
      expect(
        collectionOrderAmbiguousIndices(<AiCollectionOrderMember>[
          _video('Movie A.mkv'),
          _video('Movie B.mkv'),
        ], AiCollectionOrderKind.video),
        isEmpty,
      );
    });

    test('书：卷号齐全、只有第 1 卷无编号时规则排得出', () {
      expect(
        collectionOrderAmbiguousIndices(<AiCollectionOrderMember>[
          _book('安達としまむら'),
          _book('安達としまむら2'),
          _book('安達としまむら3'),
        ], AiCollectionOrderKind.book),
        isEmpty,
      );
    });

    test('书：上 / 下卷、汉字卷号、外传、卷号冲突、多本无卷号都判不出', () {
      expect(
        collectionOrderAmbiguousIndices(<AiCollectionOrderMember>[
          _book('物語 1'),
          _book('物語 上巻'),
          _book('物語 下巻'),
        ], AiCollectionOrderKind.book),
        <int>{1, 2},
      );
      expect(
        collectionOrderAmbiguousIndices(<AiCollectionOrderMember>[
          _book('物語 1'),
          _book('物語 第三巻'),
          _book('物語外伝'),
        ], AiCollectionOrderKind.book),
        <int>{1, 2},
      );
      expect(
        collectionOrderAmbiguousIndices(<AiCollectionOrderMember>[
          _book('物語 1'),
          _book('物語 2'),
          _book('別の物語 2'),
        ], AiCollectionOrderKind.book),
        <int>{1, 2},
        reason: '两本不同书解析出同一卷号',
      );
    });

    test('成员不足两个不算歧义', () {
      expect(
        collectionOrderAmbiguousIndices(<AiCollectionOrderMember>[
          _video('Show - SP.mkv'),
        ], AiCollectionOrderKind.video),
        isEmpty,
      );
    });
  });

  test('ruleOrderCollectionMembers：视频季→集→名称，无集号在本季殿后；书按卷号', () {
    final List<AiCollectionOrderMember> videos = <AiCollectionOrderMember>[
      _video('Show - SP.mkv'),
      _video('Show S02E01.mkv'),
      _video('Show - 02.mkv'),
      _video('Show - 01.mkv'),
    ];
    expect(
      ruleOrderCollectionMembers(videos, AiCollectionOrderKind.video),
      // 与 VideoFolderGroupCoordinator 同口径：无季号按第 1 季，SP 落在第 1 季末尾。
      <int>[3, 2, 0, 1],
    );
    final List<AiCollectionOrderMember> books = <AiCollectionOrderMember>[
      _book('物語 10'),
      _book('物語 2'),
      _book('物語'),
    ];
    expect(ruleOrderCollectionMembers(books, AiCollectionOrderKind.book), <int>[
      2,
      1,
      0,
    ]);
  });

  group('parseAiCollectionOrder', () {
    // 规则序：0=E1 1=E2 2=E3 3=SP(判不出) 4=OVA(判不出)
    const Set<int> floating = <int>{3, 4};

    test('模型把 SP 插到第 1 集后、OVA 放最后 → 完整排列', () {
      expect(
        parseAiCollectionOrder(
          '{"order": [0, 3, 1, 2, 4]}',
          count: 5,
          floating: floating,
        ),
        <int>[0, 3, 1, 2, 4],
      );
    });

    test('越界 / 重复 / 字符串下标容忍；结果恒为完整排列', () {
      final List<int>? order = parseAiCollectionOrder(
        '```json\n{"order": ["0", 9, 3, 3, -1, 1.0, 2, 4]}\n```',
        count: 5,
        floating: floating,
      );
      expect(order, <int>[0, 3, 1, 2, 4]);
    });

    test('锚点被模型打乱也不动：只取判不出成员的相对位置', () {
      expect(
        parseAiCollectionOrder(
          '{"order": [2, 1, 4, 0, 3]}',
          count: 5,
          floating: floating,
        ),
        // 2 在最前（rank 2），4 的槽位 = rank 2 之后；0 不抬高 maxRank，3 同样在
        // rank 2 之后——锚点保持 0,1,2 的规则序。
        <int>[0, 1, 2, 4, 3],
      );
    });

    test('缺失补齐：漏掉的判不出成员留在规则位置，漏掉的锚点照常在位', () {
      expect(
        parseAiCollectionOrder(
          '{"order": [0, 4]}',
          count: 5,
          floating: floating,
        ),
        <int>[0, 4, 1, 2, 3],
      );
    });

    test('坏 JSON / 没有 order / 判不出成员一个都没给 → null（不改）', () {
      expect(
        parseAiCollectionOrder('nope', count: 5, floating: floating),
        isNull,
      );
      expect(
        parseAiCollectionOrder('{"x": 1}', count: 5, floating: floating),
        isNull,
      );
      expect(
        parseAiCollectionOrder(
          '{"order": [0, 1, 2]}',
          count: 5,
          floating: floating,
        ),
        isNull,
      );
    });
  });

  group('requestAiCollectionOrder', () {
    test('没有歧义：不发请求，返回恒等', () async {
      final List<String> prompts = <String>[];
      final AiChatClient client = _client('{"order": [1, 0]}', prompts);
      addTearDown(client.close);
      final AiCollectionOrderProposal proposal = await requestAiCollectionOrder(
        client: client,
        provider: _provider(),
        kind: AiCollectionOrderKind.video,
        collectionName: 'Show',
        members: <AiCollectionOrderMember>[
          _video('Show - 01.mkv'),
          _video('Show - 02.mkv'),
        ],
      );
      expect(proposal.status, AiCollectionOrderStatus.noAmbiguity);
      expect(proposal.order, <int>[0, 1]);
      expect(prompts, isEmpty);
    });

    test('有歧义：提示词含全部成员与 needs_placement，采纳校验后的排列', () async {
      final List<String> prompts = <String>[];
      final AiChatClient client = _client('{"order": [0, 2, 1]}', prompts);
      addTearDown(client.close);
      final AiCollectionOrderProposal proposal = await requestAiCollectionOrder(
        client: client,
        provider: _provider(),
        kind: AiCollectionOrderKind.video,
        collectionName: 'Show',
        members: <AiCollectionOrderMember>[
          _video('Show - 01.mkv'),
          _video('Show - 02.mkv'),
          AiCollectionOrderMember.video(
            title: 'Show - SP',
            fileName: 'Show - SP.mkv',
            metadata: const <String, Object?>{'air_date': '2020-01-08'},
          ),
        ],
      );
      expect(proposal.status, AiCollectionOrderStatus.proposed);
      expect(proposal.order, <int>[0, 2, 1]);
      expect(proposal.changed, isTrue);
      expect(proposal.ambiguous, <int>{2});
      expect(prompts, hasLength(1));
      expect(prompts.single, contains('"needs_placement":true'));
      expect(prompts.single, contains('2020-01-08'));
      expect(prompts.single, contains('"index":0'));
    });

    test('回复没过校验 → invalidReply、恒等', () async {
      final AiChatClient client = _client(
        'I think the order is fine',
        <String>[],
      );
      addTearDown(client.close);
      final AiCollectionOrderProposal proposal = await requestAiCollectionOrder(
        client: client,
        provider: _provider(),
        kind: AiCollectionOrderKind.video,
        collectionName: 'Show',
        members: <AiCollectionOrderMember>[
          _video('Show - 01.mkv'),
          _video('Show - SP.mkv'),
        ],
      );
      expect(proposal.status, AiCollectionOrderStatus.invalidReply);
      expect(proposal.order, <int>[0, 1]);
    });
  });

  test('resolveCollectionOrderAiProvider：未指派 = null；指派 / 默认 = 那一家', () {
    expect(
      resolveCollectionOrderAiProvider(_Settings(const AiFeatureAssignments())),
      isNull,
    );
    expect(
      resolveCollectionOrderAiProvider(
        _Settings(
          const AiFeatureAssignments().withAssignment(
            AiFeature.collectionOrder,
            'p1',
          ),
        ),
      )?.id,
      'p1',
    );
    expect(
      resolveCollectionOrderAiProvider(
        _Settings(
          const AiFeatureAssignments(
            defaultProviderId: 'p1',
          ).withAssignment(AiFeature.collectionOrder, kAiFeatureDisabled),
        ),
      ),
      isNull,
      reason: '显式关掉压过默认',
    );
  });
}
