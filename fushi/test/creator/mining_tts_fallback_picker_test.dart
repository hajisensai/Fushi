import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/creator/mining_tts_fallback_picker.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_models.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

/// 「制卡发音兜底」设置：只读的「引擎」行换成了可选声音的选择器——列出系统语音、
/// 不使用、全部朗读声音预设（在线的带「词条会发给该服务」提示，配置不完整的灰掉），
/// 选中即写偏好。

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}

void main() {
  test('语音合成子页的「制卡发音兜底」分区：声音选择器 + 用途说明', () {
    final SettingsDestination models = buildModelsDestination();
    final SettingsNavigationItem tts = models.sections
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsNavigationItem>()
        .firstWhere((SettingsNavigationItem i) => i.id == 'models.tts');
    final SettingsSection fallback = tts.child!().sections.firstWhere(
      (SettingsSection s) => s.id == 'models.section.tts',
    );
    expect(fallback.items.map((SettingsItem i) => i.id).toList(), <String>[
      'models.tts_fallback_voice',
      'models.tts_fallback_speed',
      'models.tts_usage',
    ]);
    expect(fallback.items.first, isA<SettingsActionItem>());
    expect(
      (fallback.items.first as SettingsActionItem).cli,
      isNotNull,
      reason: '控制通道要能读写这个偏好',
    );
  });

  testWidgets('选择器列出系统 / 不使用 / 全部声音；选在线声音写入偏好', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _MemoryPrefs prefs = _MemoryPrefs();
    final TtsServices services = TtsServices.of(prefs);
    await services.store.savePresets(const <TtsVoicePreset>[
      TtsVoicePreset(
        id: 'edge1',
        providerId: EdgeTtsDescriptor.providerId,
        name: 'Cloud Nanami',
        params: <String, String>{
          EdgeTtsDescriptor.voiceKey: EdgeTtsDescriptor.defaultVoice,
        },
      ),
      // GPT-SoVITS 缺参考音频等必填项：列出但不可选。
      TtsVoicePreset(
        id: 'sovits1',
        providerId: GptSovitsTtsDescriptor.providerId,
        name: 'Home Voice',
      ),
    ]);

    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    final Future<MiningTtsFallbackVoice?> result =
        showMiningTtsFallbackVoicePicker(
          host,
          services,
          current: miningTtsFallbackVoiceOf(prefs),
        );
    await tester.pumpAndSettle();

    expect(find.text(t.audiobook_tts_provider_system), findsOneWidget);
    expect(find.text(t.models_tts_fallback_off), findsOneWidget);
    expect(find.text('Cloud Nanami'), findsOneWidget);
    expect(find.text('Home Voice'), findsOneWidget);
    expect(find.text(t.audiobook_tts_voice_settings), findsOneWidget);
    expect(
      find.textContaining(t.models_tts_fallback_online_notice),
      findsOneWidget,
      reason: '只有在线声音那一行带提示',
    );
    expect(find.text(t.audiobook_tts_voice_incomplete_status), findsOneWidget);

    await tester.tap(find.text('Cloud Nanami'));
    await tester.pumpAndSettle();
    final MiningTtsFallbackVoice? picked = await result;
    expect(picked, const MiningTtsFallbackVoice.preset('edge1'));

    await setMiningTtsFallbackVoice(prefs, picked!);
    expect(prefs.values[kMiningTtsFallbackVoicePref], 'preset:edge1');
    expect(
      miningTtsFallbackSummary(
        choice: miningTtsFallbackVoiceOf(prefs),
        presets: services.store.loadPresets(),
        descriptorOf: (String id) => services.registry[id],
        systemEngineName: systemTtsEngineName(),
      ),
      contains(t.models_tts_fallback_online_notice),
    );
  });
}
