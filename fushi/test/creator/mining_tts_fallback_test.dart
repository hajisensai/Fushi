import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/creator/mining_tts_fallback_picker.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiChoiceOption;
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

/// 制卡单词音频 TTS 兜底：系统语音默认行为不变；选了朗读声音预设时走 provider 与
/// 共用缓存、扩展名随真实格式、失败带原因且不回退系统语音；「不使用」跳过 TTS。

Uint8List _wav() {
  const int dataBytes = 3200;
  final ByteData b = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

/// 三帧 MPEG-1 Layer III 128 kbps 44.1 kHz（每帧 417 字节）。
Uint8List _mp3() {
  const int frame = 417;
  final Uint8List bytes = Uint8List(frame * 3);
  for (int i = 0; i < 3; i++) {
    bytes[i * frame] = 0xFF;
    bytes[i * frame + 1] = 0xFB;
    bytes[i * frame + 2] = 0x90;
    bytes[i * frame + 3] = 0x00;
  }
  return bytes;
}

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

class _FakeProvider extends TtsProvider {
  _FakeProvider(this.owner);

  final _FakeDescriptor owner;

  @override
  TtsCapabilities get capabilities => owner.capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    owner.texts.add(text);
    final TtsFailure? failure = owner.failure;
    if (failure != null) throw failure;
    await File(outputPath).writeAsBytes(owner.mp3 ? _mp3() : _wav());
    return TtsResult(
      format: owner.mp3 ? TtsAudioFormat.mp3 : TtsAudioFormat.wav,
    );
  }

  @override
  Future<void> dispose() async => owner.disposed++;
}

class _FakeDescriptor extends TtsProviderDescriptor {
  _FakeDescriptor({
    this.providerId = 'fake',
    this.online = false,
    this.mp3 = false,
    this.requiresEndpoint = false,
  });

  final String providerId;
  final bool online;
  final bool mp3;
  final bool requiresEndpoint;
  TtsFailure? failure;

  /// 非空时 [create] 直接抛它（模拟引擎构造期失败）。
  Object? createError;
  final List<String> texts = <String>[];
  int disposed = 0;

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: online,
    needsCredential: false,
    maxConcurrency: 1,
    maxInputLength: 200,
  );

  @override
  List<TtsParamSpec> get params => <TtsParamSpec>[
    if (requiresEndpoint)
      const TtsParamSpec(
        key: 'endpoint',
        kind: TtsParamKind.url,
        required: true,
      ),
    const TtsParamSpec(key: 'voice', kind: TtsParamKind.text),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) {
    final Object? error = createError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    return _FakeProvider(this);
  }
}

class _FakeSource implements MiningTtsVoiceSource {
  _FakeSource(this.presets, this.descriptors, this._cache);

  final List<TtsVoicePreset> presets;
  final Map<String, TtsProviderDescriptor> descriptors;
  final TtsAudioCache _cache;

  @override
  TtsVoicePreset? presetById(String id) =>
      presets.where((TtsVoicePreset p) => p.id == id).firstOrNull;

  @override
  TtsProviderDescriptor? descriptorOf(String providerId) =>
      descriptors[providerId];

  @override
  TtsHost get host => const TtsHost();

  @override
  Future<TtsAudioCache> cache() async => _cache;
}

void main() {
  late Directory tmp;
  late Directory outDir;
  late TtsAudioCache cache;
  late List<String> systemCalls;
  late List<String?> systemLanguages;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mining_tts_fallback_');
    outDir = Directory('${tmp.path}/out');
    cache = TtsAudioCache(root: Directory('${tmp.path}/cache'));
    systemCalls = <String>[];
    systemLanguages = <String?>[];
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> fakeSystemTts(
    String text,
    String outputPath,
    String? languageTag,
  ) async {
    systemCalls.add('$text|$outputPath');
    systemLanguages.add(languageTag);
    await File(outputPath).parent.create(recursive: true);
    await File(outputPath).writeAsBytes(_wav());
    return outputPath;
  }

  const TtsVoicePreset preset = TtsVoicePreset(
    id: 'p1',
    providerId: 'fake',
    name: 'Nanami',
    params: <String, String>{'voice': 'ja-JP-NanamiNeural'},
  );

  Future<File?> run(
    MiningTtsFallbackVoice choice, {
    required _FakeDescriptor descriptor,
    String text = 'たべる',
    List<TtsVoicePreset> presets = const <TtsVoicePreset>[preset],
    void Function()? onVoices,
  }) => synthesizeMiningTtsFallback(
    text: text,
    choice: choice,
    outputDir: outDir,
    systemTts: fakeSystemTts,
    voices: () {
      onVoices?.call();
      return _FakeSource(presets, <String, TtsProviderDescriptor>{
        descriptor.id: descriptor,
      }, cache);
    },
  );

  group('偏好', () {
    test('未写过 / 不认识的值 = 系统语音（升级前行为）', () {
      final _MemoryPrefs prefs = _MemoryPrefs();
      expect(
        miningTtsFallbackVoiceOf(prefs),
        const MiningTtsFallbackVoice.system(),
      );
      prefs.values[kMiningTtsFallbackVoicePref] = 'garbage';
      expect(
        miningTtsFallbackVoiceOf(prefs),
        const MiningTtsFallbackVoice.system(),
      );
      prefs.values[kMiningTtsFallbackVoicePref] = 'preset:';
      expect(
        miningTtsFallbackVoiceOf(prefs),
        const MiningTtsFallbackVoice.system(),
      );
    });

    test('查词兜底只认显式选过的声音（没碰过设置 / 选了不使用 = 不兜底）', () {
      final _MemoryPrefs prefs = _MemoryPrefs();
      expect(lookupTtsFallbackVoiceOf(prefs), isNull);
      prefs.values[kMiningTtsFallbackVoicePref] = 'none';
      expect(lookupTtsFallbackVoiceOf(prefs), isNull);
      prefs.values[kMiningTtsFallbackVoicePref] = 'system';
      expect(
        lookupTtsFallbackVoiceOf(prefs),
        const MiningTtsFallbackVoice.system(),
      );
      prefs.values[kMiningTtsFallbackVoicePref] = 'preset:sovits';
      expect(
        lookupTtsFallbackVoiceOf(prefs),
        const MiningTtsFallbackVoice.preset('sovits'),
      );
    });

    test('三种选择往返', () async {
      final _MemoryPrefs prefs = _MemoryPrefs();
      for (final MiningTtsFallbackVoice v in <MiningTtsFallbackVoice>[
        const MiningTtsFallbackVoice.none(),
        const MiningTtsFallbackVoice.preset('abc:1'),
        const MiningTtsFallbackVoice.system(),
      ]) {
        await setMiningTtsFallbackVoice(prefs, v);
        expect(miningTtsFallbackVoiceOf(prefs), v);
      }
    });
  });

  group('TTS 兜底倍速', () {
    test('偏好：默认 1.0、坏值回落、越界夹回范围', () async {
      final _MemoryPrefs prefs = _MemoryPrefs();
      expect(ttsFallbackSpeedOf(prefs), 1.0);
      prefs.values[kTtsFallbackSpeedPref] = 'fast';
      expect(ttsFallbackSpeedOf(prefs), 1.0);
      await setTtsFallbackSpeed(prefs, 1.5);
      expect(ttsFallbackSpeedOf(prefs), 1.5);
      await setTtsFallbackSpeed(prefs, 10);
      expect(ttsFallbackSpeedOf(prefs), kTtsFallbackSpeedMax);
    });

    test('制卡单词音频的 TTS 兜底一律按兜底倍速，不受有声书「句子音频跟随播放倍速」开关影响', () {
      // 倍速是 TTS 声音本身的属性（所有者拍板）。生效点在 LocalAudioEnhancement
      // 的兜底合成调用里，它要 AppModel + 平台目录，单测起不来，所以咬源码：
      // tempo 直接取 ttsFallbackSpeedOf，整个文件不再读那个有声书开关。
      final String src = File(
        'lib/src/creator/enhancements/local_audio_enhancement.dart',
      ).readAsStringSync();
      expect(src, contains('tempo: ttsFallbackSpeedOf(appModel.prefsRepo),'));
      expect(src, isNot(contains('miningAudioFollowPlaybackSpeed')));
    });

    Future<File?> runAt(
      MiningTtsFallbackVoice choice,
      double? tempo,
      List<String> retempoCalls, {
      bool fail = false,
    }) => synthesizeMiningTtsFallback(
      text: 'たべる',
      choice: choice,
      outputDir: outDir,
      systemTts: fakeSystemTts,
      voices: () => _FakeSource(
        const <TtsVoicePreset>[preset],
        <String, TtsProviderDescriptor>{'fake': _FakeDescriptor()},
        cache,
      ),
      tempo: tempo,
      retempo:
          ({
            required String inputPath,
            required String outputPath,
            required double tempo,
          }) async {
            retempoCalls.add('${p.basename(inputPath)}>$tempo');
            if (fail) return null;
            await File(outputPath).writeAsBytes(<int>[1, 2, 3]);
            return outputPath;
          },
    );

    test('1.0 / null 不变速，原样返回合成产物', () async {
      final List<String> calls = <String>[];
      final File? a = await runAt(
        const MiningTtsFallbackVoice.system(),
        null,
        calls,
      );
      final File? b = await runAt(
        const MiningTtsFallbackVoice.system(),
        1.0,
        calls,
      );
      expect(a!.path, endsWith(kSystemTtsTermAudioFileName));
      expect(b!.path, endsWith(kSystemTtsTermAudioFileName));
      expect(calls, isEmpty);
    });

    test('非 1× 时变速产物另存为 _x<倍速> 文件', () async {
      final List<String> calls = <String>[];
      final File? file = await runAt(
        const MiningTtsFallbackVoice.system(),
        1.5,
        calls,
      );
      expect(calls, <String>['$kSystemTtsTermAudioFileName>1.5']);
      expect(p.basename(file!.path), startsWith('tts_term_audio_x1.50.'));
    });

    test('预设产物已变速过就复用，系统语音每次重做', () async {
      final List<String> presetCalls = <String>[];
      const MiningTtsFallbackVoice presetChoice = MiningTtsFallbackVoice.preset(
        'p1',
      );
      final File? first = await runAt(presetChoice, 1.25, presetCalls);
      final File? second = await runAt(presetChoice, 1.25, presetCalls);
      expect(presetCalls, hasLength(1));
      expect(second!.path, first!.path);

      final List<String> systemRetempo = <String>[];
      await runAt(const MiningTtsFallbackVoice.system(), 1.25, systemRetempo);
      await runAt(const MiningTtsFallbackVoice.system(), 1.25, systemRetempo);
      expect(systemRetempo, hasLength(2));
    });

    test('变速失败退回原速产物（发音照常可用）', () async {
      final List<String> calls = <String>[];
      final File? file = await runAt(
        const MiningTtsFallbackVoice.system(),
        2.0,
        calls,
        fail: true,
      );
      expect(calls, hasLength(1));
      expect(file!.path, endsWith(kSystemTtsTermAudioFileName));
    });
  });

  group('兜底合成', () {
    test('系统语音（默认）：仍走 ttsToFile + 固定文件名，不碰朗读声音体系', () async {
      final _FakeDescriptor d = _FakeDescriptor();
      bool touched = false;
      final File? file = await run(
        const MiningTtsFallbackVoice.system(),
        descriptor: d,
        onVoices: () => touched = true,
      );
      expect(file, isNotNull);
      expect(file!.path, endsWith(kSystemTtsTermAudioFileName));
      expect(systemCalls, hasLength(1));
      expect(systemCalls.single, startsWith('たべる|'));
      expect(touched, isFalse);
      expect(d.texts, isEmpty);
    });

    test('BUG-3669 系统语音：languageTag 原样交给系统语音（不写死 ja-JP）', () async {
      await synthesizeMiningTtsFallback(
        text: 'apple',
        choice: const MiningTtsFallbackVoice.system(),
        outputDir: outDir,
        systemTts: fakeSystemTts,
        voices: () => throw StateError('不该取朗读声音'),
        languageTag: 'en',
      );
      expect(systemLanguages, <String?>['en']);
    });

    test('BUG-3669 系统语音合成失败：抛带原因的 WordAudioUnavailable，不再静默 null', () async {
      await expectLater(
        synthesizeMiningTtsFallback(
          text: 'apple',
          choice: const MiningTtsFallbackVoice.system(),
          outputDir: outDir,
          systemTts: (String text, String out, String? lang) async =>
              throw SystemTtsFailure(
                SystemTtsFailureReason.languageMissingData,
                languageTag: lang,
              ),
          voices: () => throw StateError('不该取朗读声音'),
          languageTag: 'en',
        ),
        throwsA(
          isA<WordAudioUnavailable>()
              .having(
                (WordAudioUnavailable e) => e.reason,
                'reason',
                t.tts_system_language_missing_data(language: 'English (en)'),
              )
              .having(
                (WordAudioUnavailable e) => e.cause,
                'cause',
                isA<SystemTtsFailure>(),
              ),
        ),
      );
    });

    test('BUG-3669 系统语音说成功却没写出文件：同样按合成失败上报', () async {
      await expectLater(
        synthesizeMiningTtsFallback(
          text: 'apple',
          choice: const MiningTtsFallbackVoice.system(),
          outputDir: outDir,
          systemTts: (String text, String out, String? lang) async => out,
          voices: () => throw StateError('不该取朗读声音'),
        ),
        throwsA(isA<WordAudioUnavailable>()),
      );
    });

    test('不使用 TTS 兜底：直接跳过，系统与预设都不调用', () async {
      final _FakeDescriptor d = _FakeDescriptor();
      bool touched = false;
      final File? file = await run(
        const MiningTtsFallbackVoice.none(),
        descriptor: d,
        onVoices: () => touched = true,
      );
      expect(file, isNull);
      expect(systemCalls, isEmpty);
      expect(touched, isFalse);
      expect(d.texts, isEmpty);
    });

    test('选预设：经 provider 合成，扩展名随格式（wav），同词同音色只合成一次', () async {
      final _FakeDescriptor d = _FakeDescriptor();
      final File? first = await run(
        const MiningTtsFallbackVoice.preset('p1'),
        descriptor: d,
      );
      final File? again = await run(
        const MiningTtsFallbackVoice.preset('p1'),
        descriptor: d,
      );
      expect(first, isNotNull);
      expect(first!.path, endsWith('.wav'));
      expect(first.path, isNot(endsWith(kSystemTtsTermAudioFileName)));
      expect(first.readAsBytesSync(), _wav());
      expect(again!.path, first.path);
      expect(d.texts, <String>['たべる'], reason: '第二次应命中缓存');
      expect(d.disposed, 2);
      expect(systemCalls, isEmpty);
    });

    test('选预设：mp3 产物落 .mp3；不同词互不覆盖', () async {
      final _FakeDescriptor d = _FakeDescriptor(mp3: true);
      final File? a = await run(
        const MiningTtsFallbackVoice.preset('p1'),
        descriptor: d,
        text: 'たべる',
      );
      final File? b = await run(
        const MiningTtsFallbackVoice.preset('p1'),
        descriptor: d,
        text: 'のむ',
      );
      expect(a!.path, endsWith('.mp3'));
      expect(b!.path, endsWith('.mp3'));
      expect(a.path, isNot(b.path));
      expect(a.existsSync() && b.existsSync(), isTrue);
    });

    test('选预设而服务失败：抛带原因的 WordAudioUnavailable，不回退系统语音', () async {
      final _FakeDescriptor d = _FakeDescriptor()
        ..failure = const TtsFailure(TtsFailureCode.network, 'connect');
      await expectLater(
        run(const MiningTtsFallbackVoice.preset('p1'), descriptor: d),
        throwsA(
          isA<WordAudioUnavailable>()
              .having(
                (WordAudioUnavailable e) => e.reason,
                'reason',
                t.audiobook_tts_failure_network,
              )
              .having(
                (WordAudioUnavailable e) => e.cause,
                'cause',
                isA<TtsFailure>(),
              ),
        ),
      );
      expect(systemCalls, isEmpty);
      expect(d.disposed, 1);
    });

    test('引擎构造期抛 TtsFailure：同样归一成带原因的 WordAudioUnavailable', () async {
      final _FakeDescriptor d = _FakeDescriptor()
        ..createError = const TtsFailure(TtsFailureCode.network, 'connect');
      await expectLater(
        run(const MiningTtsFallbackVoice.preset('p1'), descriptor: d),
        throwsA(
          isA<WordAudioUnavailable>()
              .having(
                (WordAudioUnavailable e) => e.reason,
                'reason',
                t.audiobook_tts_failure_network,
              )
              .having(
                (WordAudioUnavailable e) => e.cause,
                'cause',
                isA<TtsFailure>(),
              ),
        ),
      );
      expect(systemCalls, isEmpty);
      expect(d.texts, isEmpty);
      expect(d.disposed, 0, reason: '没构造出来的 provider 不该被 dispose');
    });

    test('引擎构造期抛任意异常：不漏出裸异常，原因是「响应异常」', () async {
      final _FakeDescriptor d = _FakeDescriptor()
        ..createError = StateError('runtime missing');
      await expectLater(
        run(const MiningTtsFallbackVoice.preset('p1'), descriptor: d),
        throwsA(
          isA<WordAudioUnavailable>()
              .having(
                (WordAudioUnavailable e) => e.reason,
                'reason',
                t.audiobook_tts_failure_bad_response,
              )
              .having(
                (WordAudioUnavailable e) => e.cause,
                'cause',
                isA<StateError>(),
              ),
        ),
      );
      expect(systemCalls, isEmpty);
    });

    test('选中的声音已删除：原因是「已被删除」', () async {
      final _FakeDescriptor d = _FakeDescriptor();
      await expectLater(
        run(const MiningTtsFallbackVoice.preset('gone'), descriptor: d),
        throwsA(
          isA<WordAudioUnavailable>().having(
            (WordAudioUnavailable e) => e.reason,
            'reason',
            t.models_tts_fallback_voice_missing,
          ),
        ),
      );
      expect(systemCalls, isEmpty);
    });

    test('预设缺必填参数（凭据 / 地址）：原因是「未配置」，不发请求', () async {
      final _FakeDescriptor d = _FakeDescriptor(requiresEndpoint: true);
      await expectLater(
        run(const MiningTtsFallbackVoice.preset('p1'), descriptor: d),
        throwsA(
          isA<WordAudioUnavailable>().having(
            (WordAudioUnavailable e) => e.reason,
            'reason',
            t.audiobook_tts_failure_not_configured,
          ),
        ),
      );
      expect(d.texts, isEmpty);
    });

    test('手动触发的提示 = audio_unavailable + 原因', () {
      expect(
        wordAudioUnavailableMessage(const WordAudioUnavailable('X')),
        '${t.audio_unavailable} X',
      );
    });
  });

  group('选择器选项与摘要', () {
    final _FakeDescriptor online = _FakeDescriptor(
      providerId: 'online',
      online: true,
    );
    final _FakeDescriptor local = _FakeDescriptor(
      providerId: 'local',
      requiresEndpoint: true,
    );
    const List<TtsVoicePreset> presets = <TtsVoicePreset>[
      TtsVoicePreset(id: 'a', providerId: 'online', name: 'Cloud'),
      TtsVoicePreset(id: 'b', providerId: 'local', name: 'Home'),
      TtsVoicePreset(id: 'c', providerId: 'missing', name: 'Old'),
    ];
    TtsProviderDescriptor? descriptorOf(String id) =>
        <String, TtsProviderDescriptor>{'online': online, 'local': local}[id];

    test('系统 / 不使用 / 全部预设 / 管理声音；不可用与未配置完整的灰掉', () {
      final List<FushiChoiceOption<String>> options =
          miningTtsFallbackChoiceOptions(
            presets: presets,
            descriptorOf: descriptorOf,
            systemEngineName: 'Windows SAPI',
          );
      expect(
        options.map((FushiChoiceOption<String> o) => o.value).toList(),
        <String>[
          'system',
          'none',
          'preset:a',
          'preset:b',
          'preset:c',
          kMiningTtsFallbackManageValue,
        ],
      );
      expect(options[0].subtitle, 'Windows SAPI');
      expect(options[2].enabled, isTrue);
      expect(
        options[2].subtitle,
        contains(t.models_tts_fallback_online_notice),
      );
      expect(options[3].enabled, isFalse, reason: '缺必填地址');
      expect(options[4].enabled, isFalse, reason: '引擎不在注册表');
    });

    test('摘要：在线声音另起一行提示词条会发给该服务；本机声音不提示', () {
      String summary(MiningTtsFallbackVoice v) => miningTtsFallbackSummary(
        choice: v,
        presets: presets,
        descriptorOf: descriptorOf,
        systemEngineName: null,
      );
      expect(
        summary(const MiningTtsFallbackVoice.preset('a')),
        contains('\n${t.models_tts_fallback_online_notice}'),
      );
      expect(
        summary(const MiningTtsFallbackVoice.preset('b')),
        isNot(contains(t.models_tts_fallback_online_notice)),
      );
      expect(
        summary(const MiningTtsFallbackVoice.preset('zzz')),
        t.models_tts_fallback_voice_missing,
      );
      expect(
        summary(const MiningTtsFallbackVoice.none()),
        t.models_tts_fallback_off,
      );
      expect(
        summary(const MiningTtsFallbackVoice.system()),
        contains(t.models_tts_unavailable),
      );
    });
  });
}
