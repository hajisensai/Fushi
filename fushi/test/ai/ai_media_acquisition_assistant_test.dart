import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart';

void main() {
  group('parseAiMediaAcquisitionIntent', () {
    test('取 queries，去空 / 去重（不分大小写）/ 压空白 / 限个数', () {
      final AiMediaAcquisitionIntent intent = parseAiMediaAcquisitionIntent(
        'ok {"queries": ["  無職転生  ", "", "Mushoku  Tensei", '
        '"mushoku tensei", 3, "A", "B"]}',
      );
      expect(intent.queries, <String>['無職転生', 'Mushoku Tensei', 'A']);
      expect(intent.queries.length, kAiMediaAcquisitionMaxQueries);
    });

    test('超长词截断', () {
      final String long = 'x' * 200;
      final AiMediaAcquisitionIntent intent = parseAiMediaAcquisitionIntent(
        '{"queries": ["$long"]}',
      );
      expect(intent.queries.single.length, kAiMediaAcquisitionMaxQueryLength);
    });

    test('坏 JSON / 缺字段 / 类型错 → empty', () {
      expect(parseAiMediaAcquisitionIntent('no json').isEmpty, isTrue);
      expect(parseAiMediaAcquisitionIntent('{"q": ["a"]}').isEmpty, isTrue);
      expect(parseAiMediaAcquisitionIntent('{"queries": "a"}').isEmpty, isTrue);
    });
  });

  group('parseAiMediaAcquisitionPicks', () {
    const Set<String> valid = <String>{'a', 'b', 'c', 'd', '7'};

    test('只留集合内的 id，去重，保持顺序，限个数', () {
      expect(
        parseAiMediaAcquisitionPicks(
          '{"picks": ["b", "zzz", "b", "a", 7, "c", "d"]}',
          validIds: valid,
        ),
        <String>['b', 'a', '7'],
      );
    });

    test('空 / 坏回复 → 无推荐', () {
      expect(
        parseAiMediaAcquisitionPicks('{"picks": []}', validIds: valid),
        isEmpty,
      );
      expect(parseAiMediaAcquisitionPicks('???', validIds: valid), isEmpty);
    });
  });

  test('提示词按域描述，且要求只回 JSON', () {
    for (final AiMediaAcquisitionDomain domain
        in AiMediaAcquisitionDomain.values) {
      expect(
        buildAiMediaAcquisitionIntentSystemPrompt(domain),
        contains('{"queries"'),
      );
      expect(
        buildAiMediaAcquisitionPickSystemPrompt(domain),
        contains('{"picks"'),
      );
    }
    expect(
      buildAiMediaAcquisitionPickUserPrompt(
        request: 'r',
        candidates: const <AiMediaAcquisitionCandidateFact>[
          AiMediaAcquisitionCandidateFact(id: 'x', title: 'T', source: 'S'),
        ],
      ),
      '{"request":"r","results":[{"id":"x","title":"T","source":"S"}]}',
    );
  });
}
