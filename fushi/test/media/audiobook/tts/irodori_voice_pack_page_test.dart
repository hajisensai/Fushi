import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_voice_pack_page.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 声音包在 app 侧的装配：制作侧声音清单 = 预设 + 声音包；声音包描述符只给制作侧
/// 查、不进「添加声音」的注册表；管理页能列出 / 删除声音包。

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

const IrodoriVoicePack _miyagi = IrodoriVoicePack(
  id: 'pmiyagi',
  character: 'Miyagi',
  adapterDir: '/lora/miyagi',
  groups: <IrodoriRefGroup>[
    IrodoriRefGroup(name: 'spoken', files: <String>['/r/a.wav']),
    IrodoriRefGroup(name: 'inner', files: <String>['/r/b.wav']),
  ],
);

const TtsVoicePreset _edge = TtsVoicePreset(
  id: 'edge1',
  providerId: EdgeTtsDescriptor.providerId,
  name: 'Nanami',
  params: <String, String>{
    EdgeTtsDescriptor.voiceKey: EdgeTtsDescriptor.defaultVoice,
  },
);

void main() {
  test('制作侧声音 = 预设在前、每个声音包每组一份；不完整的包不列', () {
    final List<TtsVoicePreset> all = ttsProductionPresetsFrom(
      presets: const <TtsVoicePreset>[_edge],
      packs: const <IrodoriVoicePack>[
        _miyagi,
        IrodoriVoicePack(
          id: 'pempty',
          character: 'X',
          groups: <IrodoriRefGroup>[],
        ),
      ],
    );
    expect(all.map((TtsVoicePreset e) => e.id), <String>[
      'edge1',
      'pack:pmiyagi/spoken',
      'pack:pmiyagi/inner',
    ]);
    expect(
      ttsProviderLabel(all[1].providerId),
      t.audiobook_tts_provider_irodori_pack,
    );
  });

  test('声音包描述符只经 productionDescriptor 可查，不进「添加声音」注册表', () {
    final TtsServices services = TtsServices.of(_MemoryPrefs());
    expect(
      services.productionDescriptor(kIrodoriPackProviderId),
      same(services.voicePacks),
    );
    expect(services.registry[kIrodoriPackProviderId], isNull);
    expect(
      services.registry.available.map((TtsProviderDescriptor d) => d.id),
      isNot(contains(kIrodoriPackProviderId)),
    );
    expect(
      services.productionDescriptor(EdgeTtsDescriptor.providerId),
      same(services.registry[EdgeTtsDescriptor.providerId]),
    );
  });

  test('worker 状态与声音包摘要文案', () {
    final IrodoriBatchWorker worker = IrodoriBatchWorker(
      launch: () async => null,
    );
    expect(
      irodoriBatchWorkerStatus(worker),
      t.audiobook_tts_voice_pack_worker_stopped,
    );
    worker.phase = IrodoriBatchPhase.ready;
    worker.device = 'cuda';
    expect(
      irodoriBatchWorkerStatus(worker),
      t.audiobook_tts_voice_pack_worker_ready(device: 'cuda'),
    );
    expect(
      irodoriVoicePackSummary(_miyagi, const <String>[]),
      t.audiobook_tts_voice_pack_summary_lora(count: 2),
    );
    expect(
      irodoriVoicePackSummary(_miyagi, const <String>['/r/a.wav']),
      t.audiobook_tts_voice_pack_missing_files(count: 1),
    );
    expect(
      irodoriVoicePackSummary(
        const IrodoriVoicePack(
          id: 'x',
          character: 'X',
          groups: <IrodoriRefGroup>[],
        ),
        const <String>[],
      ),
      t.audiobook_tts_voice_pack_incomplete,
    );
  });

  testWidgets('管理页列出声音包，删除后清单里也没了', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory dir = Directory.systemTemp.createTempSync('voice_pack_ui_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final IrodoriVoicePackStore store = IrodoriVoicePackStore(
      File(p.join(dir.path, 'packs.json')),
    )..save(const <IrodoriVoicePack>[_miyagi]);
    final TtsServices services = TtsServices.of(_MemoryPrefs());

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: IrodoriVoicePackPage(services: services, store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('voice-pack-pmiyagi')),
      findsOneWidget,
    );
    expect(find.text('Miyagi'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('voice-pack-add')),
      findsOneWidget,
    );
    // 没装 v4-Large：worker 行提示先下载模型，不给启动按钮。
    expect(find.text(t.audiobook_tts_voice_pack_needs_large), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('voice-pack-worker-start-stop')),
      findsNothing,
    );

    // 点进编辑页：两组参考音频都在，组名即选角里的声音名。
    await tester.tap(find.text('Miyagi'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('voice-pack-group-0')),
      findsOneWidget,
    );
    expect(find.text('spoken'), findsOneWidget);
    expect(find.text('inner'), findsOneWidget);
    expect(
      find.text(t.audiobook_tts_voice_pack_group_files(count: 1)),
      findsNWidgets(2),
    );
  });
}
