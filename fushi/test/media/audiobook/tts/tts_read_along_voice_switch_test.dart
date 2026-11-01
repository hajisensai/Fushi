import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_read_along.dart';
import 'package:fushi/src/media/audiobook/tts/tts_read_along_voices.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_quick_switch.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

/// 播放中换声音（用户反馈「播放的时候无法切换声音」）：朗读会话在开始时捕获了
/// 声音与调度器，之后改「使用中」的声音对正在进行的朗读毫无作用。
/// [TtsReadAlong.switchVoice] 换掉调度器：旧声音的在途 / 排队合成取消，从当前句
/// 起只向新声音请求，旧声音已合成的缓存留在磁盘上。

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

/// 一次合成请求的记录。
class _Call {
  _Call(this.voice, this.text, this.token);
  final String voice;
  final String text;
  final TtsCancelToken token;
  bool cancelled = false;
}

/// 假引擎：[hang] 为真时请求一直挂着直到被取消（模拟慢服务的在途请求）。
class _FakeProvider extends TtsProvider {
  _FakeProvider(this.voice, this.owner);

  final String voice;
  final _FakeDescriptor owner;
  bool hang = false;
  bool disposed = false;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    maxConcurrency: 2,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    final _Call call = _Call(voice, text, cancel);
    owner.record(call);
    if (hang) {
      final Completer<void> cancelled = Completer<void>();
      cancel.onCancel(() {
        call.cancelled = true;
        cancelled.complete();
      });
      await cancelled.future;
      throw const TtsFailure(TtsFailureCode.cancelled);
    }
    await File(outputPath).writeAsBytes(_wav());
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

class _FakeDescriptor extends TtsProviderDescriptor {
  _FakeDescriptor({this.maxInputLength = 300, this.available = true});

  final int maxInputLength;
  final bool available;
  final List<_Call> log = <_Call>[];
  final List<_FakeProvider> created = <_FakeProvider>[];
  final List<(bool Function(List<_Call>), Completer<void>)> _waiters =
      <(bool Function(List<_Call>), Completer<void>)>[];

  void record(_Call call) {
    log.add(call);
    for (final (bool Function(List<_Call>), Completer<void>) w
        in List<(bool Function(List<_Call>), Completer<void>)>.of(_waiters)) {
      if (w.$1(log)) {
        _waiters.remove(w);
        w.$2.complete();
      }
    }
  }

  /// 等到请求记录满足 [condition]（按请求真正到达引擎来等，不靠时序假设）。
  Future<void> until(bool Function(List<_Call> log) condition) {
    if (condition(log)) return Future<void>.value();
    final Completer<void> done = Completer<void>();
    _waiters.add((condition, done));
    return done.future.timeout(const Duration(seconds: 20));
  }

  /// 新建的引擎实例是否挂起请求。
  bool hangNext = false;

  @override
  String get id => 'fake';

  @override
  bool get isAvailable => available;

  @override
  TtsCapabilities get capabilities => TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    maxConcurrency: 2,
    maxInputLength: maxInputLength,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(key: 'voice', kind: TtsParamKind.voice, required: true),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) {
    final _FakeProvider provider = _FakeProvider(preset.param('voice'), this)
      ..hang = hangNext;
    created.add(provider);
    return provider;
  }
}

TtsVoicePreset _preset(String id, String voice) => TtsVoicePreset(
  id: id,
  providerId: 'fake',
  name: 'Voice $voice',
  params: <String, String>{'voice': voice},
);

TtsBookPlan _plan(int count, {int length = 4}) => TtsBookPlan(<TtsPlanSentence>[
  for (int i = 0; i < count; i++)
    TtsPlanSentence(
      section: 0,
      href: 'c.xhtml',
      text: '句$i',
      spokenText: '${'あ' * (length - 1)}$i',
      matchStart: i * 10,
      matchEnd: i * 10 + 10,
      studyStart: i * 10,
      studyEnd: i * 10 + 10,
    ),
]);

/// 请求对应的句子下标（测试分句的朗读文本以下标结尾）。
List<int> _indices(List<_Call> calls) => <int>[
  for (final _Call c in calls) int.parse(c.text.substring(c.text.length - 1)),
];

void main() {
  late Directory root;
  late TtsAudioCache cache;
  late TtsPresetStore store;
  final List<TtsReadAlong> live = <TtsReadAlong>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tts_voice_switch_test');
    cache = TtsAudioCache(root: root);
    store = TtsPresetStore(_MemoryPrefs());
  });

  tearDown(() async {
    // 调度器 dispose 等在途合成（含预取）全部收尾才返回，之后不会再有写盘。
    for (final TtsReadAlong r in live) {
      await r.debugScheduler.dispose();
    }
    live.clear();
    await root.delete(recursive: true);
  });

  group('TtsReadAlong.switchVoice', () {
    test('cancels the old voice\'s pending synthesis and synthesizes from the '
        'current sentence with the new voice', () async {
      final _FakeDescriptor descriptor = _FakeDescriptor();
      final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
        plan: _plan(8),
        preset: _preset('a', 'A'),
        descriptor: descriptor,
        cache: cache,
        host: const TtsHost(),
        store: store,
      );
      live.add(readAlong);

      // 旧声音先合成好开头两句（之后要验证它的缓存没被删）。
      readAlong.debugScheduler.setLookahead(1);
      await readAlong.debugScheduler.ensure(0);
      await readAlong.debugScheduler.ensure(1);
      final String oldKey0 = readAlong.debugScheduler.keyOf(0);
      expect(cache.audioPathFor(oldKey0), isNotEmpty);
      expect(File(cache.audioPathFor(oldKey0)).existsSync(), isTrue);

      // 旧声音之后的请求都挂着：播放推进到第 4 句，4、5 句在途。
      final _FakeProvider oldProvider = descriptor.created.single;
      oldProvider.hang = true;
      descriptor.log.clear();
      readAlong.debugScheduler.setCursor(4);
      // 预取窗口 4..5、并发 2：两句都到达旧引擎后才算「在途」。
      await descriptor.until(
        (List<_Call> log) => _indices(log).toSet().containsAll(<int>{4, 5}),
      );
      final List<_Call> oldInFlight = List<_Call>.of(descriptor.log);
      expect(oldInFlight.map((_Call c) => c.voice).toSet(), <String>{'A'});
      expect(oldInFlight, isNotEmpty);
      expect(_indices(oldInFlight), contains(4));

      descriptor.log.clear();
      final TtsVoiceSwitchOutcome outcome = await readAlong.switchVoice(
        _preset('b', 'B'),
        descriptor,
      );
      // 新调度器从当前句起合成：等第 4 句的请求真正到达新引擎。
      await descriptor.until(
        (List<_Call> log) =>
            log.any((_Call c) => c.voice == 'B' && c.text.endsWith('4')),
      );

      expect(outcome, TtsVoiceSwitchOutcome.switched);
      expect(readAlong.preset.id, 'b');
      // 旧声音的在途合成全部取消，旧引擎实例被释放。
      expect(oldInFlight.every((_Call c) => c.cancelled), isTrue);
      expect(oldProvider.disposed, isTrue);
      // 之后的请求只发给新声音，且从当前句（第 4 句）开始。
      expect(descriptor.log, isNotEmpty);
      expect(descriptor.log.every((_Call c) => c.voice == 'B'), isTrue);
      // 并发 2 的新调度器同时发出第 4、5 句，到达假引擎的先后不定。
      expect(_indices(descriptor.log), contains(4));
      expect(_indices(descriptor.log).every((int i) => i >= 4), isTrue);
      // 缓存键随声音变；旧声音已合成的音频仍在磁盘上（换回来可复用）。
      expect(readAlong.debugScheduler.keyOf(0), isNot(oldKey0));
      expect(File(cache.audioPathFor(oldKey0)).existsSync(), isTrue);
      final TtsCachedAudio ready = await readAlong.debugScheduler.ensure(4);
      expect(File(ready.path).existsSync(), isTrue);
    });

    test('switching back reuses the old voice\'s cached audio', () async {
      final _FakeDescriptor descriptor = _FakeDescriptor();
      final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
        plan: _plan(3),
        preset: _preset('a', 'A'),
        descriptor: descriptor,
        cache: cache,
        host: const TtsHost(),
        store: store,
      );
      live.add(readAlong);
      await readAlong.debugScheduler.ensure(0);
      await readAlong.switchVoice(_preset('b', 'B'), descriptor);
      await readAlong.debugScheduler.ensure(0);
      descriptor.log.clear();

      await readAlong.switchVoice(_preset('a', 'A'), descriptor);
      await readAlong.debugScheduler.ensure(0);
      expect(
        descriptor.log.where((_Call c) => c.text.endsWith('0')),
        isEmpty,
        reason: 'sentence 0 in voice A is served from the cache',
      );
    });

    test('the same preset is a no-op', () async {
      final _FakeDescriptor descriptor = _FakeDescriptor();
      final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
        plan: _plan(3),
        preset: _preset('a', 'A'),
        descriptor: descriptor,
        cache: cache,
        host: const TtsHost(),
        store: store,
      );
      live.add(readAlong);
      final Object scheduler = readAlong.debugScheduler;
      expect(
        await readAlong.switchVoice(_preset('a', 'A'), descriptor),
        TtsVoiceSwitchOutcome.unchanged,
      );
      expect(identical(readAlong.debugScheduler, scheduler), isTrue);
      expect(descriptor.created, hasLength(1));
    });

    test('a voice whose input limit cannot fit the current sentences asks '
        'for a restart and leaves the session untouched', () async {
      final _FakeDescriptor descriptor = _FakeDescriptor();
      final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
        plan: _plan(3, length: 250),
        preset: _preset('a', 'A'),
        descriptor: descriptor,
        cache: cache,
        host: const TtsHost(),
        store: store,
      );
      live.add(readAlong);
      final Object scheduler = readAlong.debugScheduler;
      // 谷歌翻译这类单次上限 180 的引擎接不住按 300 分的句子。
      final _FakeDescriptor shortLimit = _FakeDescriptor(maxInputLength: 180);
      expect(
        await readAlong.switchVoice(_preset('g', 'G'), shortLimit),
        TtsVoiceSwitchOutcome.needsRestart,
      );
      expect(readAlong.preset.id, 'a');
      expect(identical(readAlong.debugScheduler, scheduler), isTrue);
      expect(shortLimit.created, isEmpty);
      expect(readAlong.currentSentence?.matchStart, 0);
    });

    test('an incomplete voice is rejected', () async {
      final _FakeDescriptor descriptor = _FakeDescriptor();
      final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
        plan: _plan(3),
        preset: _preset('a', 'A'),
        descriptor: descriptor,
        cache: cache,
        host: const TtsHost(),
        store: store,
      );
      live.add(readAlong);
      await expectLater(
        readAlong.switchVoice(
          const TtsVoicePreset(id: 'x', providerId: 'fake', name: ''),
          descriptor,
        ),
        throwsA(isA<TtsStartException>()),
      );
      expect(readAlong.preset.id, 'a');
    });
  });

  group('ttsVoiceSwitchEntries', () {
    test('marks the active voice and blocks unusable ones', () {
      final _FakeDescriptor ok = _FakeDescriptor();
      final List<TtsVoiceSwitchEntry> entries = ttsVoiceSwitchEntries(
        presets: <TtsVoicePreset>[
          _preset('a', 'A'),
          _preset('b', 'B'),
          const TtsVoicePreset(id: 'c', providerId: 'fake', name: 'C'),
          const TtsVoicePreset(id: 'd', providerId: 'gone', name: 'D'),
          const TtsVoicePreset(
            id: 'e',
            providerId: 'off',
            name: 'E',
            params: <String, String>{'voice': 'x'},
          ),
        ],
        activePresetId: 'b',
        descriptorOf: (String id) => switch (id) {
          'fake' => ok,
          'off' => _FakeDescriptor(available: false),
          _ => null,
        },
      );
      expect(entries.map((TtsVoiceSwitchEntry e) => e.preset.id), <String>[
        'a',
        'b',
        'c',
        'd',
        'e',
      ]);
      expect(
        entries.where((TtsVoiceSwitchEntry e) => e.active).single.preset.id,
        'b',
      );
      expect(entries[0].selectable, isTrue);
      expect(entries[1].selectable, isTrue);
      expect(entries[2].block, TtsVoiceSwitchBlock.incomplete);
      expect(entries[3].block, TtsVoiceSwitchBlock.unavailable);
      expect(entries[4].block, TtsVoiceSwitchBlock.unavailable);
      expect(entries[0].label, 'Voice A');
    });

    test('choice values compare by preset id; manage is distinct', () {
      expect(
        const TtsVoiceQuickSwitchChoice.preset('a'),
        const TtsVoiceQuickSwitchChoice.preset('a'),
      );
      expect(const TtsVoiceQuickSwitchChoice.manage().isManage, isTrue);
      expect(
        const TtsVoiceQuickSwitchChoice.manage(),
        isNot(const TtsVoiceQuickSwitchChoice.preset('a')),
      );
    });
  });

  group('multi-voice read-along', () {
    test('character lines use the cast voice; switching the default voice '
        'keeps character lines on their voice (served from cache)', () async {
      final _FakeDescriptor descriptor = _FakeDescriptor();
      // 句 1、3 是 alice 的台词（选角表按句首坐标 i*10 记），alice 配声音 C。
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          for (final int i in <int>[1, 3])
            ttsLineKey(0, i * 10): const TtsCastLine(
              speaker: 'alice',
              source: TtsCastSource.user,
            ),
        },
        voices: <String, String>{'alice': 'c'},
      );
      final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
        plan: _plan(6),
        preset: _preset('a', 'A'),
        descriptor: descriptor,
        cache: cache,
        host: const TtsHost(),
        store: store,
        cast: cast,
        slotVoices: <String, TtsResolvedVoice>{
          'alice': (preset: _preset('c', 'C'), descriptor: descriptor),
        },
      );
      live.add(readAlong);
      expect(readAlong.isMultiVoice, isTrue);
      expect(readAlong.voiceAt(1).preset.id, 'c');
      expect(readAlong.voiceAt(2).preset.id, 'a');

      readAlong.debugScheduler
        ..setLookahead(5)
        ..setCursor(0);
      await descriptor.until((List<_Call> log) => log.length == 6);
      final Map<int, String> voiceBySentence = <int, String>{
        for (final _Call c in descriptor.log)
          int.parse(c.text.substring(c.text.length - 1)): c.voice,
      };
      expect(voiceBySentence, <int, String>{
        0: 'A',
        1: 'C',
        2: 'A',
        3: 'C',
        4: 'A',
        5: 'A',
      });
      // 六句全部落盘（发布进缓存）后再换声音，角色台词才谈得上「命中缓存」。
      // 请求记录在合成开始时就有了，所以这里按调度器的就绪事件等，不按请求等。
      bool allReady() => <int>[
        for (int i = 0; i < 6; i++) i,
      ].every((int i) => readAlong.debugScheduler.readyAudio(i) != null);
      if (!allReady()) {
        await readAlong.debugScheduler.events
            .firstWhere((_) => allReady())
            .timeout(const Duration(seconds: 20));
      }

      expect(
        await readAlong.switchVoice(_preset('b', 'B'), descriptor),
        TtsVoiceSwitchOutcome.switched,
      );
      await descriptor.until(
        (List<_Call> log) => log.where((_Call c) => c.voice == 'B').length == 4,
      );
      // alice 的两句仍用 C、命中缓存，没有再请求；默认声音的四句换成 B。
      expect(
        _indices(descriptor.log.where((_Call c) => c.voice == 'B').toList())
          ..sort(),
        <int>[0, 2, 4, 5],
      );
      expect(descriptor.log.where((_Call c) => c.voice == 'C'), hasLength(2));
      expect(readAlong.voiceAt(1).preset.id, 'c');
      expect(readAlong.voiceAt(0).preset.id, 'b');
    });
  });
}
