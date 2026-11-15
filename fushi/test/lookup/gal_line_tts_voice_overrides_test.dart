// 台词 TTS 按语言 / 按游戏指定声音（反馈 ExQTCejX15：同时玩日语和中文游戏，
// 一个全局声音不够用）。咬住：裁决顺序（规则 > 游戏 > 语言 > 全局）、语言键归一
// 与回落、JSON 往返与坏条目丢弃、播放器每次裁决现取上下文（含「等」分支的预合成
// 也用覆盖后的声音）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/src/lookup/gal_line_tts.dart';
import 'package:fushi/src/lookup/gal_line_tts_player.dart';
import 'package:fushi/src/lookup/gal_line_tts_voice_overrides_page.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

TexthookerLineEntry _line(
  String id,
  String text, {
  TexthookerLineAudioStatus status = TexthookerLineAudioStatus.pending,
}) => TexthookerLineEntry(
  id: id,
  text: text,
  source: TexthookerLineSource.engineHook,
  receivedAt: DateTime(2026, 11, 11),
  audioStatus: status,
);

const GalLineTtsSettings _base = GalLineTtsSettings(
  autoPlayEnabled: true,
  autoPlay: GalLineTtsAutoPlay.all,
  presetId: 'global',
);

String? _spokenVoice(
  GalLineTtsSettings settings,
  GalLineTtsVoiceContext context, {
  String text = 'おはよう',
}) {
  final GalLineTtsDecision decision = decideGalLineTts(
    settings: settings,
    rawText: text,
    evidence: GalLineVoiceEvidence.unvoiced,
    manual: false,
    voiceContext: context,
  );
  return (decision as GalLineTtsSpeak).presetId;
}

void main() {
  group('GalLineTtsSettings.voiceFor', () {
    final GalLineTtsSettings settings = _base
        .withLanguageVoice('ja', 'ja-voice')
        .withLanguageVoice('zh-Hans', 'zh-voice')
        .withGameVoice('game-1', 'game-voice');

    test('按游戏压过按语言', () {
      expect(
        settings.voiceFor(
          const GalLineTtsVoiceContext(gameId: 'game-1', language: 'ja'),
        ),
        'game-voice',
      );
    });

    test('游戏没指定时按语言', () {
      expect(
        settings.voiceFor(
          const GalLineTtsVoiceContext(gameId: 'game-2', language: 'ja-JP'),
        ),
        'ja-voice',
      );
      expect(
        settings.voiceFor(const GalLineTtsVoiceContext(language: 'zh-Hans')),
        'zh-voice',
      );
    });

    test('语言也没指定时回落全局默认，全局也没设 = 跟随朗读声音', () {
      expect(
        settings.voiceFor(const GalLineTtsVoiceContext(language: 'ko')),
        'global',
      );
      expect(settings.voiceFor(const GalLineTtsVoiceContext()), 'global');
      expect(
        settings
            .copyWith(clearPresetId: true)
            .voiceFor(const GalLineTtsVoiceContext(language: 'en')),
        isNull,
      );
    });

    test('清掉覆盖就回落下一层', () {
      final GalLineTtsSettings cleared = settings
          .withGameVoice('game-1', null)
          .withLanguageVoice('ja-JP', null);
      expect(cleared.gameVoices, isEmpty);
      expect(cleared.languageVoices.keys, <String>['zh-Hans']);
      expect(
        cleared.voiceFor(
          const GalLineTtsVoiceContext(gameId: 'game-1', language: 'ja'),
        ),
        'global',
      );
    });
  });

  group('galLineTtsLanguageVoiceFor', () {
    test('同键 > 主语言条目 > 同主语言唯一条目，多个时不猜', () {
      expect(
        galLineTtsLanguageVoiceFor(<String, String>{
          'zh': 'zh',
          'zh-Hant': 'hant',
        }, 'zh-Hant-TW'),
        'hant',
      );
      expect(
        galLineTtsLanguageVoiceFor(<String, String>{
          'zh': 'zh',
          'zh-Hant': 'hant',
        }, 'zh-Hans'),
        'zh',
      );
      expect(
        galLineTtsLanguageVoiceFor(<String, String>{
          'zh-Hans': 'hans',
        }, 'zh-CN'),
        'hans',
      );
      expect(
        galLineTtsLanguageVoiceFor(<String, String>{
          'zh-Hans': 'hans',
          'zh-Hant': 'hant',
        }, 'zh'),
        isNull,
      );
      expect(
        galLineTtsLanguageVoiceFor(<String, String>{'ja': 'ja'}, null),
        isNull,
      );
      expect(
        galLineTtsLanguageVoiceFor(<String, String>{'ja': 'ja'}, 'und'),
        isNull,
      );
    });

    test('写入时语言键先归一，认不出的标签不写', () {
      final GalLineTtsSettings s = _base
          .withLanguageVoice('ja-JP', 'a')
          .withLanguageVoice('!!', 'b');
      expect(s.languageVoices, <String, String>{'ja': 'a'});
    });
  });

  group('decideGalLineTts 的声音分层', () {
    const GalLineTtsVoiceContext jaGame = GalLineTtsVoiceContext(
      gameId: 'g',
      language: 'ja',
    );
    final GalLineTtsSettings settings = _base.withLanguageVoice('ja', 'ja-v');

    test('无规则时用按语言的声音', () {
      expect(_spokenVoice(settings, jaGame), 'ja-v');
    });

    test('规则 read / 手动越过 skip 都用分层后的默认声音', () {
      final GalLineTtsSettings withRead = settings.copyWith(
        rules: const <GalLineTtsRule>[
          GalLineTtsRule(
            match: GalLineTtsRuleMatch.contains,
            pattern: 'おは',
            action: GalLineTtsRuleAction.read,
          ),
        ],
      );
      expect(_spokenVoice(withRead, jaGame), 'ja-v');
      final GalLineTtsSettings withSkip = settings.copyWith(
        rules: const <GalLineTtsRule>[
          GalLineTtsRule(
            match: GalLineTtsRuleMatch.contains,
            pattern: 'おは',
            action: GalLineTtsRuleAction.skip,
          ),
        ],
      );
      final GalLineTtsDecision manual = decideGalLineTts(
        settings: withSkip,
        rawText: 'おはよう',
        evidence: GalLineVoiceEvidence.unvoiced,
        manual: true,
        voiceContext: jaGame,
      );
      expect((manual as GalLineTtsSpeak).presetId, 'ja-v');
    });

    test('规则指定的声音压过按游戏 / 按语言；规则没选声音时回落分层默认', () {
      final GalLineTtsSettings withVoice = settings
          .withGameVoice('g', 'game-v')
          .copyWith(
            rules: const <GalLineTtsRule>[
              GalLineTtsRule(
                match: GalLineTtsRuleMatch.contains,
                pattern: 'おは',
                action: GalLineTtsRuleAction.voice,
                presetId: 'rule-v',
              ),
            ],
          );
      expect(_spokenVoice(withVoice, jaGame), 'rule-v');
      final GalLineTtsSettings noRuleVoice = withVoice.copyWith(
        rules: const <GalLineTtsRule>[
          GalLineTtsRule(
            match: GalLineTtsRuleMatch.contains,
            pattern: 'おは',
            action: GalLineTtsRuleAction.voice,
          ),
        ],
      );
      expect(_spokenVoice(noRuleVoice, jaGame), 'game-v');
    });

    test('不传上下文 = 只用全局默认（规则页试算框）', () {
      final GalLineTtsDecision decision = decideGalLineTts(
        settings: settings,
        rawText: 'おはよう',
        evidence: GalLineVoiceEvidence.unvoiced,
        manual: false,
      );
      expect((decision as GalLineTtsSpeak).presetId, 'global');
    });
  });

  test('JSON 往返保留覆盖表，坏条目丢弃，旧设置没有这两个字段 = 空表', () {
    final GalLineTtsSettings settings = _base
        .withLanguageVoice('zh-Hans', 'zh-v')
        .withGameVoice('game-1', 'g-v');
    final GalLineTtsSettings decoded = GalLineTtsSettings.decode(
      settings.encode(),
    );
    expect(decoded, settings);
    expect(decoded.hashCode, settings.hashCode);

    final GalLineTtsSettings legacy = GalLineTtsSettings.decode(
      '{"presetId":"p"}',
    );
    expect(legacy.languageVoices, isEmpty);
    expect(legacy.gameVoices, isEmpty);

    final GalLineTtsSettings partial = GalLineTtsSettings.decode(
      '{"languageVoices":{"ja-JP":"ja","zh":5,"!!":"x","ko":""},'
      '"gameVoices":{"g":"v","h":null,"":"z"}}',
    );
    expect(partial.languageVoices, <String, String>{'ja': 'ja'});
    expect(partial.gameVoices, <String, String>{'g': 'v'});
    expect(
      GalLineTtsSettings.decode('{"languageVoices":[1],"gameVoices":"x"}'),
      const GalLineTtsSettings(),
    );
  });

  test('语言条目按常用语言表排序，其余按键名', () {
    expect(
      galLineTtsSortedLanguageKeys(<String>['vi', 'zh-Hans', 'ja', 'de']),
      <String>['ja', 'zh-Hans', 'de', 'vi'],
    );
  });

  group('GalLineTtsPlayer 按上下文选声音', () {
    late List<({String text, String? presetId})> synthesized;
    late GalLineTtsVoiceContext context;
    late Map<String, Completer<bool>> playbacks;

    GalLineTtsPlayer build(GalLineTtsSettings settings) => GalLineTtsPlayer(
      settings: () => settings,
      voiceContext: () => context,
      synthesize:
          (
            String text, {
            required String? presetId,
            required TtsCancelToken cancel,
          }) async {
            synthesized.add((text: text, presetId: presetId));
            return '/tts/$text';
          },
      playToEnd: (String path, double volume, double speed) =>
          (playbacks[path] = Completer<bool>()).future,
      stopPlayback: () async {
        for (final Completer<bool> c in playbacks.values) {
          if (!c.isCompleted) c.complete(false);
        }
      },
      maxInputLength: (_) => 140,
    );

    setUp(() {
      synthesized = <({String text, String? presetId})>[];
      playbacks = <String, Completer<bool>>{};
      context = const GalLineTtsVoiceContext(language: 'ja');
    });

    test('每次裁决现取上下文：换到中文游戏后下一句用中文声音', () async {
      final GalLineTtsPlayer player = build(
        _base
            .withLanguageVoice('ja', 'ja-v')
            .withLanguageVoice('zh-Hans', 'zh-v'),
      );
      player.onLatestLine(_line('1', 'おはよう'));
      await pumpEventQueue();
      context = const GalLineTtsVoiceContext(language: 'zh-Hans');
      player.onLatestLine(_line('2', '早上好'));
      await pumpEventQueue();
      expect(synthesized, <({String text, String? presetId})>[
        (text: 'おはよう', presetId: 'ja-v'),
        (text: '早上好', presetId: 'zh-v'),
      ]);
      player.dispose();
    });

    test('等配对证据时的预合成也用覆盖后的声音（落定后直接复用，不重合成）', () async {
      final GalLineTtsPlayer player = build(
        _base
            .copyWith(autoPlay: GalLineTtsAutoPlay.unvoicedOnly)
            .withGameVoice('g', 'game-v'),
      );
      context = const GalLineTtsVoiceContext(gameId: 'g', language: 'ja');
      player.onLatestLine(_line('1', 'おはよう'));
      await pumpEventQueue();
      expect(synthesized, <({String text, String? presetId})>[
        (text: 'おはよう', presetId: 'game-v'),
      ]);
      player.onLatestLine(
        _line('1', 'おはよう', status: TexthookerLineAudioStatus.missing),
      );
      await pumpEventQueue();
      expect(synthesized, hasLength(1));
      expect(playbacks.keys, <String>['/tts/おはよう']);
      player.dispose();
    });
  });
}
