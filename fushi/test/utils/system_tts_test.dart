import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/utils/misc/desktop_tts.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// BUG-3669：系统语音不再写死日语、失败不再静默。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveSystemTtsLanguageTag：判据顺序', () {
    test('1. 词典声明的词头语言优先于一切', () {
      expect(
        resolveSystemTtsLanguageTag(
          text: 'たべる',
          dictionaryLanguage: 'en',
          installedDictionaryLanguages: <String?>['ja'],
        ),
        'en',
      );
    });

    test('2. 没有词典语言时，假名 = ja、谚文 = ko（结构性证据）', () {
      expect(
        resolveSystemTtsLanguageTag(
          text: '食べる たべる',
          installedDictionaryLanguages: <String?>['en', 'zh'],
        ),
        'ja',
      );
      expect(resolveSystemTtsLanguageTag(text: '먹다'), 'ko');
    });

    test('3. 文字看不出（拉丁 / 纯汉字）时，已装词典只有一种语言就用它', () {
      // 反馈 -5lhI1miwl：只装了英语词典的用户查英语词，不能按日语念。
      expect(
        resolveSystemTtsLanguageTag(
          text: 'apple',
          installedDictionaryLanguages: <String?>['en', null, 'en-US', ''],
        ),
        'en',
      );
    });

    test('4. 已装词典有多种语言 / 都没声明 → null（引擎默认），不回落日语', () {
      expect(
        resolveSystemTtsLanguageTag(
          text: '学生',
          installedDictionaryLanguages: <String?>['ja', 'zh-Hans'],
        ),
        isNull,
      );
      expect(resolveSystemTtsLanguageTag(text: 'apple'), isNull);
      expect(
        resolveSystemTtsLanguageTag(
          text: 'apple',
          installedDictionaryLanguages: <String?>[null, ''],
        ),
        isNull,
      );
    });

    test('标签归一：下划线换成连字符，空白当作没有', () {
      expect(
        resolveSystemTtsLanguageTag(text: 'x', dictionaryLanguage: ' pt_BR '),
        'pt-BR',
      );
      expect(
        resolveSystemTtsLanguageTag(text: 'apple', dictionaryLanguage: '  '),
        isNull,
      );
    });
  });

  group('原生通道：locale 透传与失败映射', () {
    const MethodChannel channel = MethodChannel('fushi.test/system_tts');
    late List<MethodCall> calls;

    void answer(Object? Function(MethodCall call) handler) {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return handler(call);
          });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('languageTag 原样交给原生（不再是写死的 ja-JP），成功返回路径', () async {
      answer((MethodCall call) => '/out/a.wav');
      final String path = await TtsChannel.nativeTtsToFile(
        channel,
        text: 'apple',
        outputPath: '/out/a.wav',
        languageTag: 'en',
      );
      expect(path, '/out/a.wav');
      expect(calls.single.method, 'ttsToFile');
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['languageTag'], 'en');
      expect(args.containsKey('locale'), isFalse);
    });

    test('引擎包名与声音 id 原样交给原生；没选就不带这两个键', () async {
      answer((MethodCall call) => '/out/a.wav');
      await TtsChannel.nativeTtsToFile(
        channel,
        text: '学生',
        outputPath: '/out/a.wav',
        languageTag: 'ja',
        engine: 'com.iflytek.speechcloud',
        voice: 'ja-jp-x-htm-local',
      );
      await TtsChannel.nativeTtsToFile(
        channel,
        text: '学生',
        outputPath: '/out/a.wav',
        languageTag: 'ja',
        engine: '',
      );
      final Map<Object?, Object?> chosen =
          calls.first.arguments as Map<Object?, Object?>;
      expect(chosen['engine'], 'com.iflytek.speechcloud');
      expect(chosen['voice'], 'ja-jp-x-htm-local');
      final Map<Object?, Object?> auto =
          calls.last.arguments as Map<Object?, Object?>;
      expect(auto.containsKey('engine'), isFalse);
      expect(auto.containsKey('voice'), isFalse);
    });

    test('不指定语言时传 null（原生用引擎默认语言）', () async {
      answer((MethodCall call) => '/out/a.wav');
      await TtsChannel.nativeTtsToFile(
        channel,
        text: '学生',
        outputPath: '/out/a.wav',
        languageTag: null,
      );
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['languageTag'], isNull);
    });

    final Map<String, SystemTtsFailureReason> codes =
        <String, SystemTtsFailureReason>{
          'LANGUAGE_MISSING_DATA': SystemTtsFailureReason.languageMissingData,
          'LANGUAGE_NOT_SUPPORTED': SystemTtsFailureReason.languageNotSupported,
          'ENGINE_UNAVAILABLE': SystemTtsFailureReason.engineUnavailable,
          'VOICE_UNAVAILABLE': SystemTtsFailureReason.voiceUnavailable,
          'SYNTHESIS_FAILED': SystemTtsFailureReason.synthesisFailed,
          'SOMETHING_NEW': SystemTtsFailureReason.synthesisFailed,
        };
    for (final MapEntry<String, SystemTtsFailureReason> e in codes.entries) {
      test('原生错误码 ${e.key} → ${e.value.name}（抛出，不返回 null）', () async {
        answer((MethodCall call) => throw PlatformException(code: e.key));
        await expectLater(
          TtsChannel.nativeTtsToFile(
            channel,
            text: 'apple',
            outputPath: '/out/a.wav',
            languageTag: 'en',
          ),
          throwsA(
            isA<SystemTtsFailure>()
                .having((SystemTtsFailure f) => f.reason, 'reason', e.value)
                .having((SystemTtsFailure f) => f.languageTag, 'lang', 'en'),
          ),
        );
      });
    }

    test('原生回 null / 空串也算失败（以前这就是静默无音频）', () async {
      answer((MethodCall call) => null);
      await expectLater(
        TtsChannel.nativeTtsToFile(
          channel,
          text: 'apple',
          outputPath: '/out/a.wav',
          languageTag: 'en',
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.synthesisFailed,
          ),
        ),
      );
    });

    test('通道没挂原生 handler → 没有引擎', () async {
      // 不装 mock handler：invokeMethod 抛 MissingPluginException。
      await expectLater(
        TtsChannel.nativeTtsToFile(
          channel,
          text: 'apple',
          outputPath: '/out/a.wav',
          languageTag: 'en',
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.engineUnavailable,
          ),
        ),
      );
    });
  });

  group('失败文案', () {
    test('不支持 / 缺数据的提示带上语言名，并说清怎么办', () {
      final String unsupported = systemTtsFailureText(
        SystemTtsFailure(
          SystemTtsFailureReason.languageNotSupported,
          languageTag: 'en',
        ),
      );
      expect(
        unsupported,
        t.tts_system_language_unsupported(language: 'English (en)'),
      );
      final String missing = systemTtsFailureText(
        SystemTtsFailure(
          SystemTtsFailureReason.languageMissingData,
          languageTag: 'ko',
        ),
      );
      expect(missing, contains('ko'));
      expect(
        systemTtsFailureText(
          SystemTtsFailure(SystemTtsFailureReason.languageNotSupported),
        ),
        t.tts_system_language_unsupported(
          language: t.tts_system_language_default,
        ),
      );
    });

    test('朗读声音体系的 ttsFailureText 对系统语音失败给具体原因而不是笼统「不支持」', () {
      final SystemTtsFailure failure = SystemTtsFailure(
        SystemTtsFailureReason.languageMissingData,
        languageTag: 'en',
      );
      expect(failure, isA<TtsFailure>());
      expect(ttsFailureText(failure), systemTtsFailureText(failure));
      expect(
        ttsFailureText(failure),
        isNot(t.audiobook_tts_failure_unsupported),
      );
    });
  });

  group('制卡兜底的上报：记日志 + 提示，自动路径同一原因只提示一次', () {
    late List<String> logged;
    late List<String> notified;
    late WordAudioFailureReporter reporter;

    setUp(() {
      logged = <String>[];
      notified = <String>[];
      reporter = WordAudioFailureReporter(
        log: (String tag, Object error, StackTrace stack) => logged.add(tag),
        notify: notified.add,
      );
    });

    WordAudioUnavailable systemFailure(
      SystemTtsFailureReason reason,
      String? lang,
    ) {
      final SystemTtsFailure f = SystemTtsFailure(reason, languageTag: lang);
      return WordAudioUnavailable(systemTtsFailureText(f), cause: f);
    }

    test('自动触发：同一原因 + 语言只提示一次，但每次都记日志', () {
      for (int i = 0; i < 5; i++) {
        reporter.report(
          systemFailure(SystemTtsFailureReason.languageMissingData, 'en'),
          StackTrace.current,
          manual: false,
        );
      }
      expect(logged, hasLength(5));
      expect(notified, hasLength(1));
      expect(
        notified.single,
        contains(t.tts_system_language_missing_data(language: 'English (en)')),
      );
    });

    test('自动触发：换了原因或语言会再提示一次', () {
      reporter.report(
        systemFailure(SystemTtsFailureReason.languageMissingData, 'en'),
        StackTrace.current,
        manual: false,
      );
      reporter.report(
        systemFailure(SystemTtsFailureReason.languageMissingData, 'ko'),
        StackTrace.current,
        manual: false,
      );
      reporter.report(
        systemFailure(SystemTtsFailureReason.engineUnavailable, 'ko'),
        StackTrace.current,
        manual: false,
      );
      expect(notified, hasLength(3));
    });

    test('手动触发：每次都提示', () {
      for (int i = 0; i < 3; i++) {
        reporter.report(
          systemFailure(SystemTtsFailureReason.languageMissingData, 'en'),
          StackTrace.current,
          manual: true,
        );
      }
      expect(notified, hasLength(3));
    });

    test('自动触发的非系统语音原因（在线声音失败）维持只记日志', () {
      reporter.report(
        const WordAudioUnavailable(
          'x',
          cause: TtsFailure(TtsFailureCode.network),
        ),
        StackTrace.current,
        manual: false,
      );
      expect(logged, hasLength(1));
      expect(notified, isEmpty);
    });
  });

  group('桌面引擎：按语言选声音', () {
    test('语言码只放行 2–3 个字母（要拼进 PowerShell）', () {
      expect(desktopTtsLanguageCode('en-US'), 'en');
      expect(desktopTtsLanguageCode('zh_Hans'), 'zh');
      expect(desktopTtsLanguageCode("en'; rm -rf"), isNull);
      expect(desktopTtsLanguageCode(null), isNull);
    });

    test('Windows：点名声音按 id 拆成引擎 + 键；没点名才带语言；不认识的 id = 声音不在', () {
      final Map<String, Object?> byVoice = windowsSpeakRequest(
        text: 'テスト',
        outputPath: r'C:\o.wav',
        languageTag: 'ja',
        voice: 'onecore:MSTTS_V110_jaJP_HarukaM',
      )!;
      expect(byVoice['voiceKind'], 'onecore');
      expect(byVoice['voiceKey'], 'MSTTS_V110_jaJP_HarukaM');
      expect(byVoice.containsKey('lang'), isFalse);
      expect(utf8.decode(base64Decode(byVoice['text']! as String)), 'テスト');
      final Map<String, Object?> sapi = windowsSpeakRequest(
        text: 'a',
        outputPath: r'C:\o.wav',
        languageTag: null,
        voice: 'sapi:Microsoft Haruka Desktop',
      )!;
      expect(sapi['voiceKind'], 'sapi');
      expect(sapi['voiceKey'], 'Microsoft Haruka Desktop');
      final Map<String, Object?> byLang = windowsSpeakRequest(
        text: 'a',
        outputPath: r'C:\o.wav',
        languageTag: 'en-US',
        voice: null,
      )!;
      expect(byLang['lang'], 'en');
      expect(byLang.containsKey('voiceKind'), isFalse);
      expect(
        windowsSpeakRequest(
          text: 'a',
          outputPath: r'C:\o.wav',
          languageTag: null,
          voice: 'ja-jp-x-htm-local',
        ),
        isNull,
      );
    });

    test('macOS：say 直接出 16-bit WAV，点名声音时带 -v，正文在 -- 之后', () {
      expect(
        sayMacOSArguments(outputPath: '/o.wav', text: '-x', voice: 'Kyoko'),
        <String>[
          '-v',
          'Kyoko',
          '--file-format=WAVE',
          '--data-format=LEI16@22050',
          '-o',
          '/o.wav',
          '--',
          '-x',
        ],
      );
      expect(
        sayMacOSArguments(outputPath: '/o.wav', text: 'a'),
        isNot(contains('-v')),
      );
    });

    test('macOS：从 say -v ? 里挑该语言的第一个声音（名字可带空格）', () {
      const String list =
          'Alex                en_US    # Most people recognize me by my voice.\n'
          'Good News           en_US    # We cannot control the weather.\n'
          'Kyoko               ja_JP    # こんにちは、私の名前はKyokoです。\n'
          'Yuna                ko_KR    # 안녕하세요\n';
      expect(pickMacOSVoice(list, 'ja'), 'Kyoko');
      expect(pickMacOSVoice(list, 'en'), 'Alex');
      expect(pickMacOSVoice(list, 'fr'), isNull);
      // macOS 27 的多变体声音：名字带本地化括号，取整段名字（say -v 认它）。
      expect(
        pickMacOSVoice(
          'Eddy (日语（日本）)       ja_JP    # こんにちは! 私の名前はEddyです。\n',
          'ja',
        ),
        'Eddy (日语（日本）)',
      );
    });

    test('Linux：只有日语引擎，别的语言直接报不支持（不拿日语声音念英语）', () async {
      final Directory dir = Directory.systemTemp.createTempSync('fushi_tts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      bool started = false;
      await expectLater(
        synthesizeLinuxTtsForLanguage(
          text: 'apple',
          outputPath: '${dir.path}/a.wav',
          languageTag: 'en',
          openJTalk: null,
          startProcess: (String exe, List<String> args) {
            started = true;
            throw const ProcessException('x', <String>[]);
          },
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.languageNotSupported,
          ),
        ),
      );
      expect(started, isFalse);
    });

    test('Linux：没有任何引擎能出音频时报「没有引擎」而不是返回 null', () async {
      final Directory dir = Directory.systemTemp.createTempSync('fushi_tts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        synthesizeLinuxTtsForLanguage(
          text: 'たべる',
          outputPath: '${dir.path}/a.wav',
          languageTag: 'ja',
          openJTalk: null,
          startProcess: (String exe, List<String> args) =>
              throw ProcessException(exe, args),
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.engineUnavailable,
          ),
        ),
      );
    });
  });
}
