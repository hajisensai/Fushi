import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/providers/unsloth_studio_tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 cAteTpUDap ②：有声书制作台的声音选择弹窗没有「添加声音」入口，只有一个
/// 声音时选择行点了没反应。制作侧各声音选择弹窗统一走 [showTtsVoicePickDialog]
/// （末尾固定一项「添加声音」），添加流程与朗读声音页共用 [runTtsVoiceAddFlow]。

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

/// 开一个按钮，点了弹 [showTtsVoicePickDialog]，结果写进 [result]。
Future<void> _pumpPicker(
  WidgetTester tester, {
  required List<FushiChoiceOption<String>> options,
  required Future<String?> Function() onAdd,
  required void Function(String? picked) onResult,
}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async => onResult(
                await showTtsVoicePickDialog(
                  context: context,
                  title: 'Voice',
                  options: options,
                  onAdd: onAdd,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  const List<FushiChoiceOption<String>> oneVoice = <FushiChoiceOption<String>>[
    FushiChoiceOption<String>(value: 'only', label: 'Only voice'),
  ];

  testWidgets('只有一个声音时弹窗末尾也有「添加声音」，选它回填新声音', (WidgetTester tester) async {
    int adds = 0;
    String? result = 'unset';
    await _pumpPicker(
      tester,
      options: oneVoice,
      onAdd: () async {
        adds++;
        return 'fresh';
      },
      onResult: (String? picked) => result = picked,
    );
    expect(find.text('Only voice'), findsOneWidget);
    expect(find.text(t.audiobook_tts_voice_add), findsOneWidget);

    await tester.tap(find.text(t.audiobook_tts_voice_add));
    await tester.pumpAndSettle();
    expect(adds, 1);
    expect(result, 'fresh');
  });

  testWidgets('选已有声音原样返回，不跑添加流程', (WidgetTester tester) async {
    int adds = 0;
    String? result = 'unset';
    await _pumpPicker(
      tester,
      options: oneVoice,
      onAdd: () async {
        adds++;
        return 'fresh';
      },
      onResult: (String? picked) => result = picked,
    );
    await tester.tap(find.text('Only voice'));
    await tester.pumpAndSettle();
    expect(adds, 0);
    expect(result, 'only');
  });

  testWidgets('添加流程取消时返回 null（不把哨兵值当声音 id 交出去）', (WidgetTester tester) async {
    String? result = 'unset';
    await _pumpPicker(
      tester,
      options: oneVoice,
      onAdd: () async => null,
      onResult: (String? picked) => result = picked,
    );
    await tester.tap(find.text(t.audiobook_tts_voice_add));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(result, isNot(kTtsVoicePickAddValue));
  });

  group('addTtsPresetFor', () {
    test('空清单：新声音落盘并成为使用中', () async {
      final TtsPresetStore store = TtsPresetStore(_MemoryPrefs());
      const UnslothStudioTtsDescriptor descriptor =
          UnslothStudioTtsDescriptor();
      final String id = await addTtsPresetFor(store, descriptor);
      final List<TtsVoicePreset> presets = store.loadPresets();
      expect(presets.map((TtsVoicePreset p) => p.id), <String>[id]);
      expect(presets.single.providerId, descriptor.id);
      expect(store.activePreset()?.id, id);
    });

    test('已有使用中的声音：追加到末尾，使用中不变', () async {
      final TtsPresetStore store = TtsPresetStore(_MemoryPrefs());
      const TtsVoicePreset existing = TtsVoicePreset(
        id: 'a',
        providerId: 'edge',
        name: 'A',
        params: <String, String>{},
      );
      await store.savePresets(const <TtsVoicePreset>[existing]);
      await store.setActivePresetId('a');
      final String id = await addTtsPresetFor(
        store,
        const UnslothStudioTtsDescriptor(),
      );
      expect(store.loadPresets().map((TtsVoicePreset p) => p.id), <String>[
        'a',
        id,
      ]);
      expect(store.activePreset()?.id, 'a');
    });
  });
}
