import 'package:fushi_engine/ai/ai_model_pricing.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:test/test.dart';

void main() {
  test('按每百万 token 单价算费用；缓存单价没填按输入单价', () {
    const AiModelPricing pricing = AiModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 10,
      cacheReadPerMillion: 0.5,
    );
    expect(
      pricing.costOf(
        inputTokens: 1000000,
        outputTokens: 500000,
        cacheReadTokens: 2000000,
        cacheWriteTokens: 1000000,
      ),
      closeTo(2 + 5 + 1 + 2, 1e-9),
    );
  });

  test('输入 / 输出单价没填齐时不算费用', () {
    expect(
      const AiModelPricing(inputPerMillion: 2).costOf(inputTokens: 100),
      isNull,
    );
    expect(const AiModelPricing().isSet, isFalse);
  });

  test('币种规整成大写三字母，认不出回落 USD', () {
    expect(const AiModelPricing(currency: ' cny ').currency, 'CNY');
    expect(const AiModelPricing(currency: 'yuan').currency, 'USD');
  });

  test('用户输入的单价：空 / 非数字 / 负数 = 没填', () {
    expect(parseAiPrice('3.5'), 3.5);
    expect(parseAiPrice(''), isNull);
    expect(parseAiPrice('abc'), isNull);
    expect(parseAiPrice('-1'), isNull);
  });

  test('提供商配置带单价往返；没填单价不落盘', () {
    final AiProviderConfig config = AiProviderConfig(
      id: 'p1',
      presetId: kAiCustomPresetId,
      name: 'x',
      baseUrl: Uri.parse('https://api.example.com'),
      model: 'm',
      pricing: const AiModelPricing(
        inputPerMillion: 3,
        outputPerMillion: 15,
        currency: 'CNY',
      ),
    );
    final AiProviderConfig restored = AiProviderConfig.fromJson(
      config.toJson(),
    );
    expect(restored.pricing.inputPerMillion, 3);
    expect(restored.pricing.outputPerMillion, 15);
    expect(restored.pricing.cacheReadPerMillion, isNull);
    expect(restored.pricing.currency, 'CNY');

    expect(
      config.copyWith(pricing: const AiModelPricing()).toJson(),
      isNot(contains('pricing')),
    );
  });
}
