import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:test/test.dart';

/// 提供商的 tool calling 能力位：预设给默认值，用户三态覆盖，覆盖值往返持久化，
/// 旧数据缺字段 = 跟随预设。
void main() {
  AiProviderConfig fromPreset(String presetId) => AiProviderConfig.fromPreset(
    aiProviderPresetById(presetId)!,
    id: 'p-$presetId',
  );

  test('预设：主流云端开，本地与拿不准的兼容端点关', () {
    for (final String id in <String>[
      'openai',
      'anthropic',
      'gemini',
      'deepseek',
    ]) {
      expect(aiProviderPresetById(id)!.supportsTools, isTrue, reason: id);
      expect(fromPreset(id).supportsToolCalling, isTrue, reason: id);
    }
    for (final String id in <String>['ollama', 'lmstudio', kAiCustomPresetId]) {
      expect(aiProviderPresetById(id)!.supportsTools, isFalse, reason: id);
      // 自定义预设没有默认地址，fromPreset 建不出来；它的配置判据见下面的往返用例。
      if (id != kAiCustomPresetId) {
        expect(fromPreset(id).supportsToolCalling, isFalse, reason: id);
      }
    }
  });

  test('覆盖优先于预设', () {
    final AiProviderConfig local = fromPreset('ollama');
    expect(
      local
          .copyWith(toolCallingOverride: AiToolCallingOverride.forceOn)
          .supportsToolCalling,
      isTrue,
    );
    final AiProviderConfig cloud = fromPreset('openai');
    expect(
      cloud
          .copyWith(toolCallingOverride: AiToolCallingOverride.forceOff)
          .supportsToolCalling,
      isFalse,
    );
  });

  test('presetId 认不出时按不支持', () {
    final AiProviderConfig unknown = AiProviderConfig(
      id: 'x',
      presetId: 'from-a-newer-version',
      name: 'x',
      baseUrl: Uri.parse('https://example.com/v1'),
    );
    expect(unknown.supportsToolCalling, isFalse);
  });

  test('往返：覆盖值落盘并读回；跟随预设不落字段', () {
    for (final AiToolCallingOverride o in AiToolCallingOverride.values) {
      final AiProviderConfig config = fromPreset(
        'openai',
      ).copyWith(toolCallingOverride: o);
      final Map<String, Object?> json = config.toJson();
      expect(
        json.containsKey('toolCalling'),
        o != AiToolCallingOverride.followPreset,
      );
      final List<AiProviderConfig> back = decodeAiProviderConfigs(
        encodeAiProviderConfigs(<AiProviderConfig>[config]),
      );
      expect(back.single.toolCallingOverride, o);
    }
  });

  test('旧数据缺字段 / 未知值 = 跟随预设', () {
    final Map<String, Object?> legacy = fromPreset('anthropic').toJson()
      ..remove('toolCalling');
    final AiProviderConfig old = AiProviderConfig.fromJson(legacy);
    expect(old.toolCallingOverride, AiToolCallingOverride.followPreset);
    expect(old.supportsToolCalling, isTrue);

    final AiProviderConfig weird = AiProviderConfig.fromJson(<String, Object?>{
      ...legacy,
      'toolCalling': 'sometimes',
    });
    expect(weird.toolCallingOverride, AiToolCallingOverride.followPreset);
  });

  test('copyWith 不传覆盖时保留原值', () {
    final AiProviderConfig on = fromPreset(
      'ollama',
    ).copyWith(toolCallingOverride: AiToolCallingOverride.forceOn);
    expect(
      on.copyWith(model: 'x').toolCallingOverride,
      AiToolCallingOverride.forceOn,
    );
  });

  test('「支持图片输入」：默认关、关着不落盘、往返保留、copyWith 保留', () {
    final AiProviderConfig base = fromPreset('openai');
    expect(base.acceptsImages, isFalse);
    expect(base.toJson().containsKey('images'), isFalse);

    final AiProviderConfig on = base.copyWith(acceptsImages: true);
    final List<AiProviderConfig> back = decodeAiProviderConfigs(
      encodeAiProviderConfigs(<AiProviderConfig>[on]),
    );
    expect(back.single.acceptsImages, isTrue);
    expect(on.copyWith(model: 'x').acceptsImages, isTrue);
  });
}
