// 「功能 → 提供商」映射的默认提供商语义：显式指派 > 显式关掉 > 默认。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';

AiProviderConfig _provider(String id, {String apiKey = 'k'}) =>
    AiProviderConfig.fromPreset(
      kAiProviderPresets.firstWhere(
        (AiProviderPreset preset) => preset.id == 'openai',
      ),
      id: id,
    ).copyWith(apiKey: apiKey, model: 'gpt-test');

void main() {
  final List<AiProviderConfig> providers = <AiProviderConfig>[
    _provider('ai-a'),
    _provider('ai-b'),
    _provider('ai-broken', apiKey: ''),
  ];

  test('素材自检：前两家可用、broken 不可用', () {
    expect(providers[0].isUsable, isTrue);
    expect(providers[1].isUsable, isTrue);
    expect(providers[2].isUsable, isFalse);
  });

  test('没指派的功能跟随默认提供商', () {
    const AiFeatureAssignments assignments = AiFeatureAssignments(
      defaultProviderId: 'ai-a',
    );
    for (final AiFeature feature in AiFeature.values) {
      expect(assignments.resolve(feature, providers)?.id, 'ai-a');
    }
  });

  test('显式指派压过默认；显式关掉 = 不用 AI', () {
    final AiFeatureAssignments assignments =
        const AiFeatureAssignments(defaultProviderId: 'ai-a')
            .withAssignment(AiFeature.dictStyle, 'ai-b')
            .withAssignment(AiFeature.videoIdentify, kAiFeatureDisabled);
    expect(assignments.resolve(AiFeature.dictStyle, providers)?.id, 'ai-b');
    expect(assignments.resolve(AiFeature.videoIdentify, providers), isNull);
    expect(assignments.resolve(AiFeature.customTheme, providers)?.id, 'ai-a');
  });

  test('显式指派的那家失效时不静默回退到默认', () {
    final AiFeatureAssignments assignments = const AiFeatureAssignments(
      defaultProviderId: 'ai-a',
    ).withAssignment(AiFeature.dictStyle, 'ai-broken');
    expect(assignments.resolve(AiFeature.dictStyle, providers), isNull);
  });

  test('没有默认也没有指派 → null（与旧行为一致）', () {
    expect(
      const AiFeatureAssignments().resolve(AiFeature.dictStyle, providers),
      isNull,
    );
  });

  test('删掉提供商同时清掉默认与指向它的指派', () {
    final AiFeatureAssignments assignments = const AiFeatureAssignments(
      defaultProviderId: 'ai-a',
    ).withAssignment(AiFeature.dictStyle, 'ai-a').withoutProvider('ai-a');
    expect(assignments.defaultProviderId, isNull);
    expect(assignments.providerIdFor(AiFeature.dictStyle), isNull);
  });

  test('JSON 往返保留默认、指派与关掉；旧 JSON（无默认键）照读', () {
    final AiFeatureAssignments original =
        const AiFeatureAssignments(defaultProviderId: 'ai-a')
            .withAssignment(AiFeature.dictStyle, 'ai-b')
            .withAssignment(AiFeature.videoIdentify, kAiFeatureDisabled);
    final AiFeatureAssignments decoded = AiFeatureAssignments.fromJson(
      original.toJson(),
    );
    expect(decoded.defaultProviderId, 'ai-a');
    expect(decoded.providerIdFor(AiFeature.dictStyle), 'ai-b');
    expect(decoded.providerIdFor(AiFeature.videoIdentify), kAiFeatureDisabled);

    final AiFeatureAssignments legacy = AiFeatureAssignments.fromJson(
      '{"dictStyle": "ai-b"}',
    );
    expect(legacy.defaultProviderId, isNull);
    expect(legacy.resolve(AiFeature.dictStyle, providers)?.id, 'ai-b');
  });

  test('withDefault(null / 空串) 清掉默认', () {
    const AiFeatureAssignments assignments = AiFeatureAssignments(
      defaultProviderId: 'ai-a',
    );
    expect(assignments.withDefault(null).defaultProviderId, isNull);
    expect(assignments.withDefault('  ').defaultProviderId, isNull);
  });
}
