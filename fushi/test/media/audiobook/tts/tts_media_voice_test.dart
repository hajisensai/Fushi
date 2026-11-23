import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_quick_switch.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}

TtsVoicePreset _edge(String id) => TtsVoicePreset(
  id: id,
  providerId: EdgeTtsDescriptor.providerId,
  name: id,
  params: const <String, String>{
    EdgeTtsDescriptor.voiceKey: EdgeTtsDescriptor.defaultVoice,
  },
);

const String _series = 'collection:1';

/// 化物語：日文版与台版在同一个合集里。
const TtsMediaVoiceScope _jp1 = TtsMediaVoiceScope(
  bookKey: 'bake-jp-1',
  seriesKey: _series,
  language: 'ja',
);
const TtsMediaVoiceScope _jp2 = TtsMediaVoiceScope(
  bookKey: 'bake-jp-2',
  seriesKey: _series,
  language: 'ja',
);
const TtsMediaVoiceScope _zh1 = TtsMediaVoiceScope(
  bookKey: 'bake-zh-1',
  seriesKey: _series,
  language: 'zh-Hant',
);
const TtsMediaVoiceScope _zh4 = TtsMediaVoiceScope(
  bookKey: 'bake-zh-4',
  seriesKey: _series,
  language: 'zh-TW',
);
const TtsMediaVoiceScope _threeBody = TtsMediaVoiceScope(
  bookKey: 'three-body',
  language: 'zh',
);

void main() {
  // TtsServices 是进程级单例：本文件只建这一份。
  final _MemoryPrefs prefs = _MemoryPrefs();
  final TtsServices services = TtsServices.of(prefs);

  setUp(() async {
    prefs.values.clear();
    await services.store.savePresets(<TtsVoicePreset>[
      _edge('unsloth-jp'),
      _edge('unsloth-tw'),
      const TtsVoicePreset(id: 'gone-engine', providerId: 'gone', name: 'X'),
    ]);
    await services.store.setActivePresetId('unsloth-jp');
  });

  String? voiceId(TtsMediaVoiceScope scope) =>
      services.voiceForMedia(scope)?.preset.id;

  test('PR scenario: series + language voice, default untouched', () async {
    // 1. 日文第 1 卷：默认声音。
    expect(voiceId(_jp1), 'unsloth-jp');
    expect(services.voiceForMedia(_jp1)!.source, TtsVoiceSource.defaultVoice);
    // 2. 中文第 1 卷：换成台湾声音（记到系列 + 中文）。
    await applyTtsVoiceQuickSwitchChoice(
      services,
      const TtsVoiceQuickSwitchChoice.preset('unsloth-tw'),
      scope: _zh1,
    );
    expect(voiceId(_zh1), 'unsloth-tw');
    // 3 / 7. 同系列的其它中文卷（含以后导入的）直接用它。
    expect(voiceId(_zh4), 'unsloth-tw');
    expect(services.voiceForMedia(_zh4)!.source, TtsVoiceSource.series);
    // 4. 回到日文卷：不受影响。
    expect(voiceId(_jp2), 'unsloth-jp');
    // 全局默认没变。
    expect(services.store.activePresetId, 'unsloth-jp');
    // 6. 不属系列的书只记这本。
    await applyTtsVoiceQuickSwitchChoice(
      services,
      const TtsVoiceQuickSwitchChoice.preset('unsloth-tw'),
      scope: _threeBody,
    );
    expect(voiceId(_threeBody), 'unsloth-tw');
    expect(
      voiceId(const TtsMediaVoiceScope(bookKey: 'other-zh', language: 'zh')),
      'unsloth-jp',
    );
  });

  test('use default clears the media voice', () async {
    await applyTtsVoiceQuickSwitchChoice(
      services,
      const TtsVoiceQuickSwitchChoice.preset('unsloth-tw'),
      scope: _zh1,
    );
    await applyTtsVoiceQuickSwitchChoice(
      services,
      const TtsVoiceQuickSwitchChoice.useDefault(),
      scope: _zh4,
    );
    expect(voiceId(_zh1), 'unsloth-jp');
    expect(services.store.loadMediaVoices().isEmpty, isTrue);
  });

  test(
    'without a scope a pick sets the global default (old behaviour)',
    () async {
      await applyTtsVoiceQuickSwitchChoice(
        services,
        const TtsVoiceQuickSwitchChoice.preset('unsloth-tw'),
      );
      expect(services.store.activePresetId, 'unsloth-tw');
      expect(services.store.loadMediaVoices().isEmpty, isTrue);
    },
  );

  test(
    'a deleted or unavailable media voice falls back instead of failing',
    () async {
      await services.store.saveMediaVoices(
        TtsMediaVoices(
          books: <String, String>{'three-body': 'deleted'},
          series: <String, Map<String, String>>{
            _series: <String, String>{'zh': 'gone-engine'},
          },
        ),
      );
      expect(voiceId(_threeBody), 'unsloth-jp');
      expect(voiceId(_zh1), 'unsloth-jp');
      expect(services.voiceForMedia(_zh1)!.source, TtsVoiceSource.defaultVoice);
    },
  );

  test('book voice is tried before the series voice', () async {
    await services.store.saveMediaVoices(
      TtsMediaVoices(
        books: <String, String>{'bake-zh-1': 'unsloth-jp'},
        series: <String, Map<String, String>>{
          _series: <String, String>{'zh': 'unsloth-tw'},
        },
      ),
    );
    expect(voiceId(_zh1), 'unsloth-jp');
    expect(services.voiceForMedia(_zh1)!.source, TtsVoiceSource.book);
    expect(voiceId(_zh4), 'unsloth-tw');
  });

  group('ttsVoiceScopeMessage', () {
    test('names the series language, or the book', () {
      expect(
        ttsVoiceScopeMessage(_jp1),
        t.audiobook_tts_voice_scope_series_language(
          language: contentLanguageLabelOf('ja'),
        ),
      );
      expect(
        ttsVoiceScopeMessage(
          const TtsMediaVoiceScope(bookKey: 'b', seriesKey: _series),
        ),
        t.audiobook_tts_voice_scope_series,
      );
      expect(
        ttsVoiceScopeMessage(_threeBody),
        t.audiobook_tts_voice_scope_book,
      );
    });
  });
}
