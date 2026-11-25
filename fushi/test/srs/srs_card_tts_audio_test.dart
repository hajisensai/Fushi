// 复习朗读键的合成与落盘缓存（拍板台 YmWT1x57XV：「保持下来下次背还能用上」）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_card_tts_audio.dart';
import 'package:fushi/src/srs/srs_review_tts.dart';
import 'package:fushi_engine/srs/srs_card_tts.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

const TtsVoicePreset _fushi = TtsVoicePreset(
  id: 'p1',
  providerId: 'edge',
  name: 'Fushi Nanami',
  revision: 2,
);

SrsTtsPlan _plan(
  SrsTtsSound sound, {
  MiningTtsFallbackVoice configured = const MiningTtsFallbackVoice.system(),
  double defaultTempo = 1.0,
}) => srsTtsPlanOf(
  sound,
  configured: configured,
  presets: const <TtsVoicePreset>[_fushi],
  identityOf: (TtsVoicePreset preset) => <String, Object?>{
    'provider': preset.providerId,
    'voice': preset.name,
    'revision': preset.revision,
  },
  defaultTempo: defaultTempo,
  detectLanguage: (String text) => 'ja-JP',
  platform: 'windows',
);

void main() {
  group('srsTtsCacheKey', () {
    test('同文字同声音同语言同倍速 = 同一个键；任一项变了就换键', () {
      String key({
        String text = '偶然',
        Map<String, Object?> voice = const <String, Object?>{'system': 'win'},
        String? lang = 'ja-JP',
        double tempo = 1.0,
      }) => srsTtsCacheKey(
        text: text,
        voiceIdentity: voice,
        languageTag: lang,
        tempo: tempo,
      );
      expect(key(), key());
      expect(key(), hasLength(40));
      expect(
        key(voice: const <String, Object?>{'a': 1, 'b': 2}),
        key(voice: const <String, Object?>{'b': 2, 'a': 1}),
        reason: '身份按键名排序后序列化，顺序无关',
      );
      expect(key(text: '必然'), isNot(key()));
      expect(
        key(voice: const <String, Object?>{'system': 'mac'}),
        isNot(key()),
      );
      expect(key(lang: 'zh-CN'), isNot(key()));
      expect(key(tempo: 1.2), isNot(key()));
    });
  });

  group('srsTtsPlanOf', () {
    test('没点名声音：用 TTS 兜底声音；「不使用」按系统语音念', () {
      final SrsTtsPlan none = _plan(
        const SrsTtsSound(text: 'あ'),
        configured: const MiningTtsFallbackVoice.none(),
      );
      expect(none.choice, const MiningTtsFallbackVoice.system());
      expect(none.voiceIdentity, <String, Object?>{'system': 'windows'});
      final SrsTtsPlan preset = _plan(
        const SrsTtsSound(text: 'あ'),
        configured: const MiningTtsFallbackVoice.preset('p1'),
      );
      expect(preset.choice, const MiningTtsFallbackVoice.preset('p1'));
      expect(preset.voiceIdentity['preset'], <String, Object?>{
        'provider': 'edge',
        'voice': 'Fushi Nanami',
        'revision': 2,
      });
    });

    test('voices= 按预设 id 或名字点名（不分大小写，下划线等同空格）', () {
      expect(
        _plan(
          const SrsTtsSound(text: 'あ', voices: <String>['Bob', 'fushi_nanami']),
        ).choice,
        const MiningTtsFallbackVoice.preset('p1'),
      );
      expect(
        _plan(const SrsTtsSound(text: 'あ', voices: <String>['p1'])).choice,
        const MiningTtsFallbackVoice.preset('p1'),
      );
      expect(
        _plan(const SrsTtsSound(text: 'あ', voices: <String>['Bob'])).choice,
        const MiningTtsFallbackVoice.system(),
        reason: '点名的声音对不上：回到默认声音',
      );
    });

    test('lang= 换成 BCP-47；没给按文字判；speed= 优先并夹到范围内', () {
      expect(
        _plan(const SrsTtsSound(text: 'a', lang: 'en_US')).languageTag,
        'en-US',
      );
      expect(_plan(const SrsTtsSound(text: 'a')).languageTag, 'ja-JP');
      expect(_plan(const SrsTtsSound(text: 'a'), defaultTempo: 1.3).tempo, 1.3);
      expect(
        _plan(
          const SrsTtsSound(text: 'a', speed: 1.5),
          defaultTempo: 1.3,
        ).tempo,
        1.5,
      );
      expect(
        _plan(const SrsTtsSound(text: 'a', speed: 99)).tempo,
        kTtsFallbackSpeedMax,
      );
      expect(srsTtsLanguageTagOf('not a lang!'), isNull);
    });
  });

  group('SrsCardTtsAudio', () {
    late Directory tmp;
    late SrsMediaStore store;
    late int calls;
    late Completer<void>? gate;

    SrsCardTtsAudio audio({bool produce = true}) => SrsCardTtsAudio(
      plan: _plan,
      synthesize: (SrsTtsPlan plan, Directory out) async {
        calls++;
        await gate?.future;
        if (!produce) return null;
        await out.create(recursive: true);
        final File f = File(p.join(out.path, 'tts_term_audio.wav'));
        await f.writeAsString('RIFF ${plan.text}');
        return f;
      },
      scratch: () async => Directory(p.join(tmp.path, 'scratch')),
    );

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('srs_tts_audio_');
      store = SrsMediaStore(Directory(p.join(tmp.path, 'media')));
      calls = 0;
      gate = null;
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('合成一次落进媒体库，之后直接命中缓存（新实例 = 下次复习也命中）', () async {
      const SrsTtsSound sound = SrsTtsSound(text: '偶然', lang: 'ja_JP');
      final File first = (await audio().fileFor(sound, store))!;
      expect(calls, 1);
      expect(p.dirname(first.path), store.root.path);
      expect(
        p.basename(first.path),
        '$kSrsTtsCachePrefix${_plan(sound).key}.wav',
      );
      expect(await first.readAsString(), 'RIFF 偶然');
      expect(
        await Directory(p.join(tmp.path, 'scratch')).list().toList(),
        isEmpty,
        reason: '临时目录用完删掉',
      );

      final File again = (await audio().fileFor(sound, store))!;
      expect(calls, 1, reason: '换了实例（重启 app）仍命中落盘缓存，不再合成');
      expect(again.path, first.path);
    });

    test('同一段同时要两次只合成一次', () async {
      final SrsCardTtsAudio a = audio();
      gate = Completer<void>();
      const SrsTtsSound sound = SrsTtsSound(text: '散歩');
      final Future<File?> x = a.fileFor(sound, store);
      final Future<File?> y = a.fileFor(sound, store);
      await Future<void>.delayed(Duration.zero);
      gate!.complete();
      final List<File?> both = await Future.wait(<Future<File?>>[x, y]);
      expect(calls, 1);
      expect(both[0]!.path, both[1]!.path);
      expect(a.inFlightCount, 0);
    });

    test('合成不出声（返回 null）不落盘', () async {
      expect(
        await audio(
          produce: false,
        ).fileFor(const SrsTtsSound(text: 'x'), store),
        isNull,
      );
      expect(await store.root.exists(), isFalse);
    });

    test('srsResolveTtsSound：不是朗读键交还调用方；失败带原因上报', () async {
      final SrsTtsResolution plain = await srsResolveTtsSound(
        audio(),
        store,
        'a.mp3',
        manual: true,
      );
      expect(plain.isTts, isFalse);

      final List<String> notified = <String>[];
      final WordAudioFailureReporter saved = WordAudioFailureReporter.instance;
      WordAudioFailureReporter.instance = WordAudioFailureReporter(
        log: (String tag, Object error, StackTrace stack) {},
        notify: notified.add,
      );
      addTearDown(() => WordAudioFailureReporter.instance = saved);
      final SrsCardTtsAudio failing = SrsCardTtsAudio(
        plan: _plan,
        synthesize: (SrsTtsPlan plan, Directory out) async =>
            throw const WordAudioUnavailable('service down'),
        scratch: () async => Directory(p.join(tmp.path, 'scratch')),
      );
      final SrsTtsResolution failed = await srsResolveTtsSound(
        failing,
        store,
        const SrsTtsSound(text: 'x').name,
        manual: true,
      );
      expect(failed.isTts, isTrue);
      expect(failed.file, isNull);
      expect(notified.single, contains('service down'));

      final SrsTtsResolution ok = await srsResolveTtsSound(
        audio(),
        store,
        const SrsTtsSound(text: 'y').name,
        manual: false,
      );
      expect(await ok.file!.readAsString(), 'RIFF y');
    });
  });

  group('SrsReviewTts', () {
    test('默认：认 {{tts}}、选中可朗读、不填字段、自动播放也念', () {
      const SrsReviewTts d = SrsReviewTts();
      expect(SrsReviewTts.decode(''), d);
      expect(SrsReviewTts.decode('not json'), d);
      expect(d.renderOptions, const SrsCardTtsOptions());
    });

    test('编码往返；只有开着「填字段」时渲染选项才带字段', () {
      const SrsReviewTts v = SrsReviewTts(
        templateTags: false,
        speakSelection: false,
        fillMissing: true,
        fillFields: <String>{'TermAudio', 'SentenceAudio'},
        autoplay: false,
      );
      expect(SrsReviewTts.decode(v.encode()), v);
      expect(
        v.renderOptions,
        const SrsCardTtsOptions(
          templateTags: false,
          fillAudioFields: <String>{'TermAudio', 'SentenceAudio'},
        ),
      );
      expect(
        v.copyWith(fillMissing: false).renderOptions.fillAudioFields,
        isEmpty,
      );
    });
  });

  test('卡面上的朗读键画成喇叭，无障碍标签是要念的文字', () {
    final String name = const SrsTtsSound(text: '偶然 & <b>').name;
    final String html = srsLocalizeCardHtml(
      'A[sound:$name]B',
      urlPrefix: 'https://srs.local/media/',
    );
    expect(html, contains('fushi-srs-tts'));
    expect(html, contains('data-sound="$name"'));
    expect(html, contains('aria-label="偶然 &amp; &lt;b&gt;"'));
    expect(srsCardReferencedMedia('[sound:$name]'), isEmpty);
  });
}
