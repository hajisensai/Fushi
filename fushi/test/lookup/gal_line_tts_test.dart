import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/src/lookup/gal_line_tts.dart';
import 'package:fushi/src/lookup/gal_line_tts_player.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

TexthookerLineEntry _line(
  String id,
  String text, {
  TexthookerLineAudioStatus status = TexthookerLineAudioStatus.pending,
  String? fallbackReason,
}) => TexthookerLineEntry(
  id: id,
  text: text,
  source: TexthookerLineSource.engineHook,
  receivedAt: DateTime(2026, 10, 30),
  audioStatus: status,
  fallbackReason: fallbackReason,
);

const GalLineTtsSettings _auto = GalLineTtsSettings(autoPlayEnabled: true);

void main() {
  group('splitGalLineSpeaker', () {
    test('内置格式：【名】/ 名「」/ 名换行 / 名：', () {
      expect(splitGalLineSpeaker('【ヒロ】いいから食べろ'), (
        speaker: 'ヒロ',
        body: 'いいから食べろ',
      ));
      expect(splitGalLineSpeaker('悠真「おはよう」'), (speaker: '悠真', body: '「おはよう」'));
      expect(splitGalLineSpeaker('二階堂ヒロ\nいいから、さっさと食べるんだ。'), (
        speaker: '二階堂ヒロ',
        body: 'いいから、さっさと食べるんだ。',
      ));
      expect(splitGalLineSpeaker('ヒロ：うん'), (speaker: 'ヒロ', body: 'うん'));
    });

    test('旁白（没有人名牌）原样返回', () {
      expect(splitGalLineSpeaker('窓の外では雨が降っていた。'), (
        speaker: null,
        body: '窓の外では雨が降っていた。',
      ));
      // 句中的引号不是人名牌（人名不能含句读）。
      expect(splitGalLineSpeaker('彼は、「待って」と言った。').speaker, isNull);
    });

    test('自定义正则只用它，不回落内置格式', () {
      const String pattern = r'^#(?<name>\S+) (?<text>.*)$';
      expect(splitGalLineSpeaker('#ヒロ 行くぞ', customPattern: pattern), (
        speaker: 'ヒロ',
        body: '行くぞ',
      ));
      expect(
        splitGalLineSpeaker('【ヒロ】行くぞ', customPattern: pattern).speaker,
        isNull,
      );
      // 缺 name 组的正则视为无效。
      expect(compileGalSpeakerPattern(r'^(\S+) (.*)$'), isNull);
    });
  });

  group('decideGalLineTts', () {
    test('自动朗读关闭时不读，手动照读', () {
      const GalLineTtsSettings off = GalLineTtsSettings();
      expect(
        decideGalLineTts(
          settings: off,
          rawText: '雨。',
          evidence: GalLineVoiceEvidence.unvoiced,
          manual: false,
        ),
        isA<GalLineTtsSkip>(),
      );
      expect(
        decideGalLineTts(
          settings: off,
          rawText: '雨。',
          evidence: GalLineVoiceEvidence.voiced,
          manual: true,
        ),
        isA<GalLineTtsSpeak>(),
      );
    });

    test('仅无原声：配上原声不读、还在配就等、确定没配音才读', () {
      GalLineTtsDecision at(GalLineVoiceEvidence e) => decideGalLineTts(
        settings: _auto,
        rawText: 'ヒロ「行くぞ」',
        evidence: e,
        manual: false,
      );
      expect(at(GalLineVoiceEvidence.voiced), isA<GalLineTtsSkip>());
      expect(at(GalLineVoiceEvidence.pending), isA<GalLineTtsWait>());
      final GalLineTtsDecision speak = at(GalLineVoiceEvidence.unvoiced);
      expect(speak, isA<GalLineTtsSpeak>());
      // 默认去掉人名，只读台词。
      expect((speak as GalLineTtsSpeak).text, '「行くぞ」');
    });

    test('全部句子：有原声也读，不等配对', () {
      final GalLineTtsSettings all = _auto.copyWith(
        autoPlay: GalLineTtsAutoPlay.all,
      );
      expect(
        decideGalLineTts(
          settings: all,
          rawText: 'ヒロ「行くぞ」',
          evidence: GalLineVoiceEvidence.pending,
          manual: false,
        ),
        isA<GalLineTtsSpeak>(),
      );
    });

    test('教程情形一：跳括号 + 主角照读 + 去括号', () {
      List<GalLineTtsRule> rules = <GalLineTtsRule>[
        galLineTtsRuleFromPreset(GalLineTtsRulePreset.skipBracketed),
      ];
      rules = insertGalLineTtsRule(
        rules,
        galLineTtsRuleFromPreset(
          GalLineTtsRulePreset.readProtagonist,
          names: '悠真',
        ),
      );
      // 照读规则插到跳过规则前面。
      expect(rules.first.action, GalLineTtsRuleAction.read);
      final GalLineTtsSettings settings = _auto.copyWith(
        rules: rules,
        textFixes: const <GalLineTtsTextFix>[kGalLineTtsStripBracketsFix],
      );
      GalLineTtsDecision decide(String raw) => decideGalLineTts(
        settings: settings,
        rawText: raw,
        // 抓不到语音的引擎：每句都是「无原声」，全靠规则。
        evidence: GalLineVoiceEvidence.unvoiced,
        manual: false,
      );
      expect(decide('ヒロ「行くぞ」'), isA<GalLineTtsSkip>());
      expect(decide('「行くぞ」'), isA<GalLineTtsSkip>());
      final GalLineTtsDecision hero = decide('悠真「わかった」');
      expect(hero, isA<GalLineTtsSpeak>());
      expect((hero as GalLineTtsSpeak).text, 'わかった');
      expect(decide('窓の外では雨が降っていた。'), isA<GalLineTtsSpeak>());
    });

    test('照读规则压过配对证据（主角句被误配上原声也照读）', () {
      final GalLineTtsSettings settings = _auto.copyWith(
        rules: <GalLineTtsRule>[
          galLineTtsRuleFromPreset(
            GalLineTtsRulePreset.readProtagonist,
            names: '悠真',
          ),
        ],
      );
      expect(
        decideGalLineTts(
          settings: settings,
          rawText: '悠真「わかった」',
          evidence: GalLineVoiceEvidence.voiced,
          manual: false,
        ),
        isA<GalLineTtsSpeak>(),
      );
    });

    test('教程情形二：配音角色名单按人名跳过；指定声音', () {
      final GalLineTtsSettings settings = _auto.copyWith(
        rules: const <GalLineTtsRule>[
          GalLineTtsRule(
            match: GalLineTtsRuleMatch.speakerIs,
            pattern: '二階堂ヒロ, 桜羽エマ',
            action: GalLineTtsRuleAction.skip,
          ),
          GalLineTtsRule(
            match: GalLineTtsRuleMatch.speakerIs,
            pattern: 'ナレーター',
            action: GalLineTtsRuleAction.voice,
            presetId: 'narrator',
          ),
        ],
      );
      GalLineTtsDecision decide(String raw) => decideGalLineTts(
        settings: settings,
        rawText: raw,
        evidence: GalLineVoiceEvidence.unvoiced,
        manual: false,
      );
      expect(decide('二階堂ヒロ\nいいから食べろ。'), isA<GalLineTtsSkip>());
      final GalLineTtsDecision narrator = decide('ナレーター\n夜が明けた。');
      expect((narrator as GalLineTtsSpeak).presetId, 'narrator');
      expect(narrator.text, '夜が明けた。');
    });

    test('只剩标点的行不读', () {
      expect(
        decideGalLineTts(
          settings: _auto,
          rawText: '……',
          evidence: GalLineVoiceEvidence.unvoiced,
          manual: true,
        ),
        isA<GalLineTtsSkip>(),
      );
    });
  });

  test('配对状态 → 证据', () {
    expect(
      galLineVoiceEvidenceOf(
        _line('a', 'x', status: TexthookerLineAudioStatus.matched),
      ),
      GalLineVoiceEvidence.voiced,
    );
    expect(
      galLineVoiceEvidenceOf(
        _line(
          'a',
          'x',
          status: TexthookerLineAudioStatus.fallback,
          fallbackReason: kGalLineNoVoiceReason,
        ),
      ),
      GalLineVoiceEvidence.unvoiced,
    );
    expect(
      galLineVoiceEvidenceOf(
        _line('a', 'x', status: TexthookerLineAudioStatus.unavailable),
      ),
      GalLineVoiceEvidence.unvoiced,
    );
    expect(
      galLineVoiceEvidenceOf(_line('a', 'x')),
      GalLineVoiceEvidence.pending,
    );
  });

  test('设置 JSON 往返，坏规则丢弃', () {
    final GalLineTtsSettings settings = _auto.copyWith(
      presetId: 'p1',
      speakerPattern: r'^(?<name>\S+):',
      rules: <GalLineTtsRule>[
        galLineTtsRuleFromPreset(GalLineTtsRulePreset.skipBracketed),
      ],
      textFixes: const <GalLineTtsTextFix>[kGalLineTtsStripBracketsFix],
      volume: 0.5,
    );
    expect(GalLineTtsSettings.decode(settings.encode()), settings);
    final GalLineTtsSettings partial = GalLineTtsSettings.decode(
      '{"autoPlayEnabled":true,"rules":[{"match":"nope"},'
      '{"match":"contains","pattern":"x","action":"skip"}]}',
    );
    expect(partial.rules, hasLength(1));
    expect(GalLineTtsSettings.decode('not json'), const GalLineTtsSettings());
  });

  test('语音修正支持捕获组引用', () {
    const GalLineTtsTextFix fix = GalLineTtsTextFix(
      // Dart 正则的 \w 只认 ASCII，日文名要用字符类。
      pattern: r'(?<w>[^\sさ]+)さん',
      replacement: r'${w}くん',
    );
    expect(fix.apply('ヒロさん'), 'ヒロくん');
  });

  test('按引擎上限切句', () {
    expect(splitGalLineTtsText('あいう。えお。', maxLength: 4), <String>[
      'あいう。',
      'えお。',
    ]);
    expect(splitGalLineTtsText('あいうえおか', maxLength: 4), <String>['あいうえ', 'おか']);
    expect(splitGalLineTtsText('短い', maxLength: 140), <String>['短い']);
  });

  group('GalLineTtsPlayer', () {
    late GalLineTtsSettings settings;
    late List<String> synthesized;
    late List<String> played;
    late List<double> volumes;
    late int stops;
    late Map<String, Completer<bool>> playbacks;

    GalLineTtsPlayer build() => GalLineTtsPlayer(
      settings: () => settings,
      synthesize:
          (
            String text, {
            required String? presetId,
            required TtsCancelToken cancel,
          }) async {
            synthesized.add(text);
            return '/tts/$text';
          },
      playToEnd: (String path, double volume) {
        played.add(path);
        volumes.add(volume);
        return (playbacks[path] = Completer<bool>()).future;
      },
      stopPlayback: () async {
        stops++;
        for (final Completer<bool> c in playbacks.values) {
          if (!c.isCompleted) c.complete(false);
        }
      },
      maxInputLength: (_) => 140,
    );

    setUp(() {
      settings = _auto;
      synthesized = <String>[];
      played = <String>[];
      volumes = <double>[];
      stops = 0;
      playbacks = <String, Completer<bool>>{};
    });

    test('还在配对时只预合成不播，判定无配音后才播', () async {
      final GalLineTtsPlayer player = build();
      player.onLatestLine(_line('1', '雨が降っていた。'));
      await pumpEventQueue();
      expect(synthesized, <String>['雨が降っていた。']);
      expect(played, isEmpty);
      player.onLatestLine(
        _line('1', '雨が降っていた。', status: TexthookerLineAudioStatus.missing),
      );
      await pumpEventQueue();
      // 预合成复用，不重复合成。
      expect(synthesized, hasLength(1));
      expect(played, <String>['/tts/雨が降っていた。']);
      expect(player.speaking.value, isTrue);
      playbacks.values.single.complete(true);
      await pumpEventQueue();
      expect(player.speaking.value, isFalse);
      // 同一行后续的状态更新不会再读一次。
      player.onLatestLine(
        _line('1', '雨が降っていた。', status: TexthookerLineAudioStatus.missing),
      );
      await pumpEventQueue();
      expect(played, hasLength(1));
      player.dispose();
    });

    test('朗读音量取设置里的 volume', () async {
      settings = _auto.copyWith(volume: 0.4);
      final GalLineTtsPlayer player = build();
      player.onLatestLine(
        _line('1', '雨が降っていた。', status: TexthookerLineAudioStatus.missing),
      );
      await pumpEventQueue();
      expect(played, <String>['/tts/雨が降っていた。']);
      expect(volumes, <double>[0.4]);
      player.dispose();
    });

    test('配上原声的句子不播', () async {
      final GalLineTtsPlayer player = build();
      player.onLatestLine(_line('1', 'ヒロ「行くぞ」'));
      player.onLatestLine(
        _line('1', 'ヒロ「行くぞ」', status: TexthookerLineAudioStatus.matched),
      );
      await pumpEventQueue();
      expect(played, isEmpty);
      expect(player.speaking.value, isFalse);
      player.dispose();
    });

    test('新台词到达立刻打断上一句', () async {
      settings = _auto.copyWith(autoPlay: GalLineTtsAutoPlay.all);
      final GalLineTtsPlayer player = build();
      player.onLatestLine(_line('1', '一つ目。'));
      await pumpEventQueue();
      expect(played, <String>['/tts/一つ目。']);
      player.onLatestLine(_line('2', '二つ目。'));
      await pumpEventQueue();
      expect(stops, 1);
      expect(played, <String>['/tts/一つ目。', '/tts/二つ目。']);
      expect(player.currentLineId, '2');
      player.dispose();
    });

    test('读到一半配上了原声 → 让给原声；手动朗读的不让', () async {
      settings = _auto.copyWith(autoPlay: GalLineTtsAutoPlay.unvoicedOnly);
      final GalLineTtsPlayer player = build();
      player.onLatestLine(
        _line('1', '雨。', status: TexthookerLineAudioStatus.unavailable),
      );
      await pumpEventQueue();
      expect(player.speaking.value, isTrue);
      player.onLatestLine(
        _line('1', '雨。', status: TexthookerLineAudioStatus.matched),
      );
      await pumpEventQueue();
      expect(stops, 1);
      expect(player.speaking.value, isFalse);

      player.toggleManual(
        _line('1', '雨。', status: TexthookerLineAudioStatus.matched),
      );
      await pumpEventQueue();
      expect(player.speaking.value, isTrue);
      player.onLatestLine(
        _line('1', '雨。', status: TexthookerLineAudioStatus.matched),
      );
      await pumpEventQueue();
      expect(player.speaking.value, isTrue);
      // 再点一次 = 停。
      player.toggleManual(null);
      expect(player.speaking.value, isFalse);
      player.dispose();
    });

    test('等配对时手动点朗读：复用预合成但按手动处理，配上原声也不停', () async {
      settings = _auto.copyWith(autoPlay: GalLineTtsAutoPlay.unvoicedOnly);
      final GalLineTtsPlayer player = build();
      // 自动朗读在等配对证据：只预合成，不播。
      player.onLatestLine(_line('1', '雨。'));
      await pumpEventQueue();
      expect(synthesized, <String>['雨。']);
      expect(played, isEmpty);
      expect(player.speaking.value, isFalse);

      // 用户点「朗读」：复用预合成（不重合成）并开播。
      player.toggleManual(_line('1', '雨。'));
      await pumpEventQueue();
      expect(synthesized, hasLength(1));
      expect(played, <String>['/tts/雨。']);
      expect(player.speaking.value, isTrue);

      // 游戏原声随后配上：手动朗读不让给原声。
      player.onLatestLine(
        _line('1', '雨。', status: TexthookerLineAudioStatus.matched),
      );
      await pumpEventQueue();
      expect(stops, 0);
      expect(player.speaking.value, isTrue);
      expect(player.currentLineId, '1');
      player.dispose();
    });

    test('没有可用声音时报错且不播', () async {
      final GalLineTtsPlayer player = GalLineTtsPlayer(
        settings: () => _auto.copyWith(autoPlay: GalLineTtsAutoPlay.all),
        synthesize:
            (
              String text, {
              required String? presetId,
              required TtsCancelToken cancel,
            }) async => throw const GalLineTtsUnavailable('no_voice'),
        playToEnd: (String path, double volume) async => true,
        stopPlayback: () async {},
        maxInputLength: (_) => 140,
      );
      player.onLatestLine(_line('1', '雨。'));
      await pumpEventQueue();
      expect(player.lastError.value, isA<GalLineTtsUnavailable>());
      expect(player.speaking.value, isFalse);
      player.dispose();
    });
  });
}
