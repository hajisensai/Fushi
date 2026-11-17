// AppMangaRenderBackend.prepare：声音包句段整批交给批处理 worker（假 worker），
// 断言分组 / 缓存键 / 结果落缓存 / 失败映射 / 已缓存不再下发。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart'
    show buildTtsSilenceWav;
import 'package:fushi/src/media/manga/audio/manga_audio_render_backend.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack_provider.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

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

/// 声音包描述符，但视为已装好 v4-Large（不必在磁盘上摆 13 GB 模型）。
class _AvailablePacks extends IrodoriVoicePackTtsDescriptor {
  const _AvailablePacks(super.engine);

  @override
  bool get isAvailable => true;
}

/// prepare 不该碰 ffmpeg。
class _NoFfmpeg implements FfmpegBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('prepare 不应调用 ffmpeg：${invocation.memberName}');
}

/// 假批处理 worker：记下收到的任务，按 [respond] 回结果。
class _FakeBatchWorker extends IrodoriBatchWorker {
  _FakeBatchWorker() : super(launch: () async => null);

  final List<IrodoriBatchJob> jobs = <IrodoriBatchJob>[];
  final List<TtsCancelToken?> cancels = <TtsCancelToken?>[];
  late IrodoriBatchResult Function(IrodoriBatchJob job) respond = _allOk;

  @override
  Future<IrodoriBatchResult> run(
    IrodoriBatchJob job, {
    void Function(IrodoriBatchLineResult line)? onLine,
    TtsCancelToken? cancel,
  }) async {
    jobs.add(job);
    cancels.add(cancel);
    return respond(job);
  }
}

/// 每句写一个时长 = 100 ms + 文字长度 × 10 ms 的 wav（用时长区分是哪句的音频）。
int _msOf(String text) => 100 + text.length * 10;

IrodoriBatchLineResult _write(IrodoriBatchItem item) {
  File(item.outputPath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(
      buildTtsSilenceWav(ms: _msOf(item.text), sampleRate: 8000, channels: 1),
    );
  return IrodoriBatchLineResult(
    id: item.id,
    ok: true,
    outputPath: item.outputPath,
  );
}

/// `fail` 开头的句子单句失败，其余成功。
IrodoriBatchResult _allOk(IrodoriBatchJob job) => IrodoriBatchResult(
  lines: <String, IrodoriBatchLineResult>{
    for (final IrodoriBatchItem item in job.items)
      item.id: item.text.startsWith('fail')
          ? IrodoriBatchLineResult(
              id: item.id,
              ok: false,
              error: 'RuntimeError: boom',
            )
          : _write(item),
  },
);

const IrodoriVoicePack _miyagi = IrodoriVoicePack(
  id: 'pmiyagi',
  character: '宮城',
  adapterDir: '/lora/miyagi',
  groups: <IrodoriRefGroup>[
    IrodoriRefGroup(name: '说出口', files: <String>['/r/a.wav', '/r/b.wav']),
    IrodoriRefGroup(name: '内心', files: <String>['/r/c.wav']),
  ],
  sampling: IrodoriSampling(seed: 3),
);

const IrodoriVoicePack _narrator = IrodoriVoicePack(
  id: 'pnarr',
  character: '旁白',
  groups: <IrodoriRefGroup>[
    IrodoriRefGroup(name: 'base', files: <String>['/r/n.wav']),
  ],
  sampling: IrodoriSampling(seed: 3),
);

final TtsVoicePreset _spoken = irodoriVoicePackPreset(
  _miyagi,
  _miyagi.groups[0],
);
final TtsVoicePreset _inner = irodoriVoicePackPreset(
  _miyagi,
  _miyagi.groups[1],
);
final TtsVoicePreset _narr = irodoriVoicePackPreset(
  _narrator,
  _narrator.groups[0],
);
const TtsVoicePreset _edge = TtsVoicePreset(
  id: 'edge-1',
  providerId: 'edge',
  name: 'Edge',
);

MangaRenderItem _synth(String voice, List<String> segments, {int seed = 7}) =>
    MangaRenderItem(
      line: MangaScriptLine(
        page: 0,
        blocks: const <int>[0],
        speaker: '宮城',
        kind: CastLineKind.spoken,
      ),
      text: segments.join(),
      source: MangaRenderSynth(voice: voice, seed: seed, segments: segments),
    );

void main() {
  late Directory dir;
  late TtsAudioCache cache;
  late IrodoriLocalEngine engine;
  late _AvailablePacks packs;
  late _FakeBatchWorker worker;
  late List<String> logs;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('manga_prepare_');
    cache = TtsAudioCache(root: Directory(p.join(dir.path, 'cache')));
    engine = IrodoriLocalEngine(
      prefs: _MemoryPrefs(),
      httpClientFactory: HttpClient.new,
      supported: true,
    );
    packs = _AvailablePacks(engine);
    worker = _FakeBatchWorker();
    logs = <String>[];
  });

  tearDown(() {
    worker.dispose();
    engine.dispose();
    dir.deleteSync(recursive: true);
  });

  AppMangaRenderBackend backend() => AppMangaRenderBackend(
    // 只有声音包有描述符；edge 预设查不到 → 这一句 voice_unavailable（prepare 跳过）。
    descriptorOf: (String id) => id == kIrodoriPackProviderId ? packs : null,
    host: const TtsHost(),
    batchWorker: worker,
    cache: cache,
    ffmpeg: _NoFfmpeg(),
    log: (String source, String summary) => logs.add('$source: $summary'),
    presets: <TtsVoicePreset>[_spoken, _inner, _narr, _edge],
  );

  /// 期望的缓存键：音色身份 + 生效的演出参数（种子；不挂 LoRA 的短句给定时长）+ 文字。
  String keyOf(TtsVoicePreset preset, String segment, {int seed = 7}) {
    final TtsDirectionSupport support = irodoriPackDirectionSupport(preset);
    final TtsDirection direction = effectiveTtsDirection(
      support,
      TtsDirection(
        seed: seed,
        durationSeconds: irodoriManualSeconds(segment, lora: support.adapter),
      ),
    );
    return TtsAudioCache.keyFor(<String, Object?>{
      ...packs.audioIdentity(preset),
      ...direction.cacheIdentity,
    }, segment);
  }

  Future<void> prepare(AppMangaRenderBackend b, List<MangaRenderItem> items) =>
      b.prepare(items: items, cancel: TtsRenderCancelToken());

  Matcher failure(String code, [String? detail]) => isA<MangaLineFailure>()
      .having((MangaLineFailure f) => f.code, 'code', code)
      .having((MangaLineFailure f) => f.detail, 'detail', detail);

  Future<Object?> synthError(
    AppMangaRenderBackend b,
    TtsVoicePreset preset,
    String segment,
  ) async {
    try {
      await b.synthesizeLine(
        voice: preset.id,
        seed: 7,
        segments: <String>[segment],
        outputPath: p.join(dir.path, 'out.m4a'),
        cancel: TtsRenderCancelToken(),
      );
    } on Object catch (e) {
      return e;
    }
    return null;
  }

  test('只把缺缓存的声音包句段组成一批：键、参考组、种子、短句定长都对，结果落进缓存', () async {
    final AppMangaRenderBackend b = backend();
    await prepare(b, <MangaRenderItem>[
      _synth(_narr.id, <String>['うん', 'そうだね']),
      _synth(_spoken.id, <String>['こんにちは']),
      _synth(_edge.id, <String>['別の声']),
      _synth('pack:nope/x', <String>['ない声']),
      _synth(_inner.id, <String>['心の声']),
      // 同声音、同种子、同文字：只下发一次。
      _synth(_narr.id, <String>['うん']),
    ]);

    expect(worker.jobs, hasLength(1));
    final IrodoriBatchJob job = worker.jobs.single;
    final Map<String, IrodoriBatchItem> byId = <String, IrodoriBatchItem>{
      for (final IrodoriBatchItem i in job.items) i.id: i,
    };
    final Map<String, (TtsVoicePreset, String)> expected =
        <String, (TtsVoicePreset, String)>{
          keyOf(_narr, 'うん'): (_narr, 'うん'),
          keyOf(_narr, 'そうだね'): (_narr, 'そうだね'),
          keyOf(_spoken, 'こんにちは'): (_spoken, 'こんにちは'),
          keyOf(_inner, '心の声'): (_inner, '心の声'),
        };
    expect(job.items, hasLength(4), reason: '非声音包 / 解析失败的声音不进批，重复句段去重');
    expect(byId.keys.toSet(), expected.keys.toSet());

    for (final MapEntry<String, (TtsVoicePreset, String)> e
        in expected.entries) {
      final IrodoriBatchItem item = byId[e.key]!;
      final (TtsVoicePreset preset, String text) = e.value;
      final bool lora =
          preset.providerId == kIrodoriPackProviderId &&
          irodoriPackDirectionSupport(preset).adapter;
      expect(item.text, text);
      expect(item.seed, 7, reason: '整部作品的种子覆盖包的默认种子');
      expect(
        item.seconds,
        irodoriManualSeconds(text, lora: lora),
        reason: '短句定长只给不挂 LoRA 的声音',
      );
      expect(p.basename(item.outputPath), '${e.key}.wav');
      expect(
        p.isWithin(p.join(cache.root.path, '.irodori_batch'), item.outputPath),
        isTrue,
      );
    }
    expect(byId[keyOf(_narr, 'うん')]!.seconds, isNotNull);
    expect(byId[keyOf(_spoken, 'こんにちは')]!.seconds, isNull);

    // 参考组：同 adapter + 参考音频的句段同组；同一 LoRA 的两组参考音频是两组。
    expect(
      byId[keyOf(_narr, 'うん')]!.groupKey,
      byId[keyOf(_narr, 'そうだね')]!.groupKey,
    );
    expect(byId[keyOf(_spoken, 'こんにちは')]!.adapterDir, '/lora/miyagi');
    expect(byId[keyOf(_spoken, 'こんにちは')]!.refs, <String>[
      '/r/a.wav',
      '/r/b.wav',
    ]);
    expect(byId[keyOf(_inner, '心の声')]!.refs, <String>['/r/c.wav']);
    expect(
      byId[keyOf(_inner, '心の声')]!.groupKey,
      isNot(byId[keyOf(_spoken, 'こんにちは')]!.groupKey),
    );
    expect(byId[keyOf(_narr, 'うん')]!.adapterDir, isNull);
    // 交给 worker 的合成顺序：LoRA 组在前、同组连续。
    final List<String> order = irodoriBatchOrder(
      job.items,
    ).map((IrodoriBatchItem i) => i.groupKey).toList();
    expect(order.toSet(), hasLength(3));
    expect(
      order.take(2).every((String g) => g.startsWith('/lora/miyagi')),
      isTrue,
    );
    expect(order[2], order[3]);

    // 结果按键落进缓存（音频就是 worker 写出的那份），scratch 目录收拾干净。
    for (final MapEntry<String, (TtsVoicePreset, String)> e
        in expected.entries) {
      final TtsCachedAudio? hit = await cache.lookup(e.key);
      expect(hit, isNotNull, reason: e.value.$2);
      expect(hit!.durationMs, _msOf(e.value.$2));
    }
    final Directory scratch = Directory(
      p.join(cache.root.path, '.irodori_batch'),
    );
    expect(
      scratch.existsSync() ? scratch.listSync() : const <FileSystemEntity>[],
      isEmpty,
    );
    expect(logs, isEmpty);
    await b.dispose();
  });

  test('已在缓存里的句段不再下发；全命中时不起 worker 任务', () async {
    final AppMangaRenderBackend first = backend();
    await prepare(first, <MangaRenderItem>[
      _synth(_narr.id, <String>['うん']),
    ]);
    await first.dispose();
    expect(worker.jobs, hasLength(1));

    final AppMangaRenderBackend second = backend();
    await prepare(second, <MangaRenderItem>[
      _synth(_narr.id, <String>['うん', '新しい']),
      // 种子不同 = 不同的缓存键，要重新合成。
      _synth(_narr.id, <String>['うん'], seed: 8),
    ]);
    expect(worker.jobs, hasLength(2));
    expect(
      worker.jobs.last.items.map((IrodoriBatchItem i) => i.id).toSet(),
      <String>{keyOf(_narr, '新しい'), keyOf(_narr, 'うん', seed: 8)},
    );

    await prepare(second, <MangaRenderItem>[
      _synth(_narr.id, <String>['うん', '新しい']),
    ]);
    expect(worker.jobs, hasLength(2), reason: '全部命中缓存，不再下发');
    await second.dispose();
  });

  test('单句失败映射成这一句的 MangaLineFailure，同批其余句照常入缓存', () async {
    worker.respond = (IrodoriBatchJob job) => IrodoriBatchResult(
      lines: <String, IrodoriBatchLineResult>{
        for (final IrodoriBatchItem item in job.items)
          item.id: switch (item.text) {
            'fail one' => IrodoriBatchLineResult(
              id: item.id,
              ok: false,
              error: 'RuntimeError: secret text',
            ),
            'fail exit' => IrodoriBatchLineResult(
              id: item.id,
              ok: false,
              error: 'worker_exited',
            ),
            _ => _write(item),
          },
      },
    );
    final AppMangaRenderBackend b = backend();
    await prepare(b, <MangaRenderItem>[
      _synth(_narr.id, <String>['fail one', 'いいよ', 'fail exit']),
    ]);
    // 异常原文不进账本，只记错误码；worker_exited 保留成 detail。
    expect(await synthError(b, _narr, 'fail one'), failure('tts_rejected'));
    expect(
      await synthError(b, _narr, 'fail exit'),
      failure('tts_rejected', 'worker_exited'),
    );
    expect(await cache.lookup(keyOf(_narr, 'fail one')), isNull);
    expect(await cache.lookup(keyOf(_narr, 'いいよ')), isNotNull);
    await b.dispose();
  });

  test('worker 层面失败：没出的句段按失败原因映射（notInstalled / exited）', () async {
    worker.respond = (IrodoriBatchJob job) => const IrodoriBatchResult(
      lines: <String, IrodoriBatchLineResult>{},
      failure: IrodoriBatchFailure.notInstalled,
    );
    final AppMangaRenderBackend missing = backend();
    await prepare(missing, <MangaRenderItem>[
      _synth(_spoken.id, <String>['こんにちは']),
    ]);
    expect(
      await synthError(missing, _spoken, 'こんにちは'),
      failure('tts_notConfigured', 'notInstalled'),
    );
    await missing.dispose();

    // 中途退出：先回报的句段照常入缓存，没回报的记 serverError/exited。
    worker.respond = (IrodoriBatchJob job) => IrodoriBatchResult(
      lines: <String, IrodoriBatchLineResult>{
        for (final IrodoriBatchItem item in job.items)
          if (item.text == 'まず') item.id: _write(item),
      },
      failure: IrodoriBatchFailure.exited,
    );
    final AppMangaRenderBackend exited = backend();
    await prepare(exited, <MangaRenderItem>[
      _synth(_narr.id, <String>['まず', 'つぎ']),
    ]);
    expect(await cache.lookup(keyOf(_narr, 'まず')), isNotNull);
    expect(
      await synthError(exited, _narr, 'つぎ'),
      failure('tts_serverError', 'exited'),
    );
    await exited.dispose();
  });

  test('取消：取消信号传给 worker，prepare 抛 TtsRenderCancelled、不写缓存', () async {
    final TtsRenderCancelToken cancel = TtsRenderCancelToken();
    worker.respond = (IrodoriBatchJob job) {
      cancel.cancel(); // 合成途中用户取消
      return const IrodoriBatchResult(
        lines: <String, IrodoriBatchLineResult>{},
        cancelled: true,
      );
    };
    final AppMangaRenderBackend b = backend();
    await expectLater(
      b.prepare(
        items: <MangaRenderItem>[
          _synth(_narr.id, <String>['うん']),
        ],
        cancel: cancel,
      ),
      throwsA(isA<TtsRenderCancelled>()),
    );
    expect(worker.cancels.single!.isCancelled, isTrue);
    expect(await cache.lookup(keyOf(_narr, 'うん')), isNull);
    await b.dispose();
  });
}
