import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis_models.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis_service.dart';
import 'package:fushi_compute/fushi_compute.dart'
    show FfcManaEvent, FfcManaEventKind, FfcManaSubmitFlags, FfcStatus;
import 'package:path/path.dart' as p;

/// Rust 写出的夹具（见 music_audio_analysis_test.dart），flags = 拍点模型 | 鼓轨模型。
Uint8List _golden() =>
    File('test/media/music/analysis/fixtures/golden.fma').readAsBytesSync();

/// 只换 flags 字段（偏移 8）的夹具。
Uint8List _withFlags(int flags) {
  final Uint8List b = Uint8List.fromList(_golden());
  ByteData.sublistView(b).setUint32(8, flags, Endian.little);
  return b;
}

class _Submit {
  _Submit(this.token, this.pcm, this.out, this.flags);
  final int token;
  final String pcm;
  final String out;
  final int flags;
}

class _FakeEngine implements MusicAudioAnalysisEngine {
  final StreamController<FfcManaEvent> controller =
      StreamController<FfcManaEvent>.broadcast(sync: true);
  final List<_Submit> submits = <_Submit>[];
  final List<int> cancels = <int>[];
  final List<(String?, String?, String?)> configs =
      <(String?, String?, String?)>[];
  final List<int> backends = <int>[];
  int configureStatus = FfcStatus.ok;

  @override
  Stream<FfcManaEvent> get events => controller.stream;
  @override
  int get pipelineVersion => 2;
  @override
  int start() => FfcStatus.ok;
  @override
  int configure({
    required String? ortPath,
    required String? beatThisModel,
    required String? htdemucsModel,
    required int threads,
    int backend = 0,
  }) {
    configs.add((ortPath, beatThisModel, htdemucsModel));
    backends.add(backend);
    return beatThisModel == null && htdemucsModel == null
        ? FfcStatus.ok
        : configureStatus;
  }

  @override
  int submit({
    required int token,
    required String pcmPath,
    required String outPath,
    int flags = 0,
  }) {
    submits.add(_Submit(token, pcmPath, outPath, flags));
    return FfcStatus.ok;
  }

  @override
  int cancel(int token) {
    cancels.add(token);
    return FfcStatus.ok;
  }

  @override
  String? takeLastError() => 'boom';

  void emit(FfcManaEventKind kind, int token, [int value = 0]) =>
      controller.add(FfcManaEvent(kind, token, value));

  /// 模拟引擎写出结果并发 updated + done。
  Future<void> finish(_Submit s, Uint8List bytes) async {
    await File(s.out).writeAsBytes(bytes);
    emit(FfcManaEventKind.updated, s.token);
    emit(FfcManaEventKind.done, s.token);
  }
}

class _FakeDecoder implements MusicAnalysisPcmDecoder {
  final List<String> inputs = <String>[];
  bool fail = false;

  @override
  Future<void> decode({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  }) async {
    inputs.add(input);
    if (fail) throw MusicAnalysisDecodeException(input, 'bad file');
    await File(output).writeAsBytes(<int>[0, 0, 0, 0]);
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<MusicAudioAnalysisSnapshot> _until(
  ValueListenable<MusicAudioAnalysisSnapshot> l,
  bool Function(MusicAudioAnalysisSnapshot s) test,
) async {
  for (int i = 0; i < 200; i++) {
    if (test(l.value)) return l.value;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out; last ${l.value}');
}

void main() {
  late Directory root;
  late _FakeEngine engine;
  late _FakeDecoder decoder;

  MusicAudioAnalysisService service({bool desktop = true}) =>
      MusicAudioAnalysisService(
        cacheDir: () async => Directory(p.join(root.path, 'cache')),
        modelsDir: () async => Directory(p.join(root.path, 'models')),
        tempDir: () async => Directory(p.join(root.path, 'tmp')),
        engine: () => engine,
        decoder: decoder,
        ortPath: () async => 'ort.dll',
        backend: () async => 1,
        desktop: desktop,
        threads: 2,
      );

  MusicAudioAnalysisTarget track(String name) {
    final File f = File(p.join(root.path, '$name.flac'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    return MusicAudioAnalysisTarget(trackUid: 'uid-$name', path: f.path);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('mana_service_test');
    engine = _FakeEngine();
    decoder = _FakeDecoder();
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('decodes, submits, and turns engine events into snapshots', () async {
    final MusicAudioAnalysisService s = service();
    final ValueListenable<MusicAudioAnalysisSnapshot> l = s.analyze(track('a'));
    await _until(l, (_) => engine.submits.isNotEmpty);
    final _Submit sub = engine.submits.single;
    expect(sub.flags & FfcManaSubmitFlags.deleteInput, isNonZero);
    expect(sub.flags & FfcManaSubmitFlags.urgent, isNonZero);
    expect(File(sub.pcm).existsSync(), isTrue);
    expect(l.value.phase, MusicAudioAnalysisPhase.running);
    // 没下载模型：只配了 DSP。
    expect(engine.configs.single, (null, null, null));

    engine.emit(FfcManaEventKind.progress, sub.token, (1 << 16) | 500);
    expect(l.value.progress, 0.5);
    await engine.finish(sub, _withFlags(0));
    final MusicAudioAnalysisSnapshot done = await _until(
      l,
      (MusicAudioAnalysisSnapshot v) =>
          v.phase == MusicAudioAnalysisPhase.ready,
    );
    expect(done.audio!.beatTimesMs, <int>[0, 500, 1000, 1500]);
    await s.dispose();
  });

  test('a complete cached result is ready without decoding', () async {
    final MusicAudioAnalysisService s = service();
    final MusicAudioAnalysisTarget t = track('b');
    final ValueListenable<MusicAudioAnalysisSnapshot> l = s.analyze(t);
    await _until(l, (_) => engine.submits.isNotEmpty);
    await engine.finish(engine.submits.single, _withFlags(0));
    await _until(l, (v) => v.phase == MusicAudioAnalysisPhase.ready);

    // 新服务实例（如重启后）：缓存命中，不再解码。
    final MusicAudioAnalysisService again = service();
    final ValueListenable<MusicAudioAnalysisSnapshot> l2 = again.analyze(t);
    await _until(l2, (v) => v.phase == MusicAudioAnalysisPhase.ready);
    expect(decoder.inputs, hasLength(1));
    await s.dispose();
    await again.dispose();
  });

  test('with models installed an old DSP-only result is upgraded', () async {
    final MusicAudioAnalysisTarget t = track('c');
    final MusicAudioAnalysisService first = service();
    final ValueListenable<MusicAudioAnalysisSnapshot> l = first.analyze(t);
    await _until(l, (_) => engine.submits.isNotEmpty);
    await engine.finish(engine.submits.single, _withFlags(0));
    await _until(l, (v) => v.phase == MusicAudioAnalysisPhase.ready);
    await first.dispose();

    // 「下载」模型（长度对即算就绪）。
    final Directory models = Directory(p.join(root.path, 'models'))
      ..createSync(recursive: true);
    for (final MusicAnalysisModelFile f in <MusicAnalysisModelFile>[
      kMusicBeatThisModel,
      kMusicHtdemucsModel,
    ]) {
      final RandomAccessFile raf = File(
        p.join(models.path, f.fileName),
      ).openSync(mode: FileMode.write);
      raf
        ..truncateSync(f.expectedBytes)
        ..closeSync();
    }
    engine = _FakeEngine();
    final MusicAudioAnalysisService s = service();
    final ValueListenable<MusicAudioAnalysisSnapshot> l2 = s.analyze(t);
    await _until(l2, (_) => engine.submits.isNotEmpty);
    // 旧结果先给出来，同时补模型那几步。
    expect(l2.value.audio, isNotNull);
    expect(engine.configs.single.$1, 'ort.dll');
    expect(engine.configs.single.$2, endsWith('beat_this.onnx'));
    expect(engine.configs.single.$3, endsWith('htdemucs.onnx'));
    expect(engine.backends.single, 1);
    await engine.finish(
      engine.submits.single,
      _withFlags(
        MusicAudioAnalysisFlags.beatsModel |
            MusicAudioAnalysisFlags.drumsModel |
            MusicAudioAnalysisFlags.vocalModel,
      ),
    );
    final MusicAudioAnalysisSnapshot v = await _until(
      l2,
      (v) => v.phase == MusicAudioAnalysisPhase.ready,
    );
    expect(v.audio!.vocalFromModel, isTrue);
    await s.dispose();
  });

  test('mobile does not ask for the stem model', () async {
    final Directory models = Directory(p.join(root.path, 'models'))
      ..createSync(recursive: true);
    final RandomAccessFile raf = File(
      p.join(models.path, kMusicBeatThisModel.fileName),
    ).openSync(mode: FileMode.write);
    raf
      ..truncateSync(kMusicBeatThisModel.expectedBytes)
      ..closeSync();
    final MusicAudioAnalysisService s = service(desktop: false);
    expect(s.requiredModels, <MusicAnalysisModelFile>[kMusicBeatThisModel]);
    final ValueListenable<MusicAudioAnalysisSnapshot> l = s.analyze(track('m'));
    await _until(l, (_) => engine.submits.isNotEmpty);
    expect(engine.configs.single.$3, isNull);
    await engine.finish(
      engine.submits.single,
      _withFlags(MusicAudioAnalysisFlags.beatsModel),
    );
    await _until(l, (v) => v.phase == MusicAudioAnalysisPhase.ready);
    expect(s.models.value.installed, isTrue);
    await s.dispose();
  });

  test(
    'an urgent request preempts a running prefetch, which is requeued',
    () async {
      final MusicAudioAnalysisService s = service();
      final MusicAudioAnalysisTarget next = track('next');
      final MusicAudioAnalysisTarget now = track('now');
      s.prefetch(<MusicAudioAnalysisTarget>[next]);
      final ValueListenable<MusicAudioAnalysisSnapshot> nextL = s.analyze(
        next,
        urgent: false,
      );
      await _until(nextL, (_) => engine.submits.isNotEmpty);
      final _Submit prefetch = engine.submits.single;
      expect(prefetch.flags & FfcManaSubmitFlags.urgent, 0);

      final ValueListenable<MusicAudioAnalysisSnapshot> nowL = s.analyze(now);
      await _settle();
      expect(engine.cancels, <int>[prefetch.token]);
      engine.emit(FfcManaEventKind.cancelled, prefetch.token);
      await _until(nowL, (_) => engine.submits.length == 2);
      expect(engine.submits[1].flags & FfcManaSubmitFlags.urgent, isNonZero);
      expect(nextL.value.phase, MusicAudioAnalysisPhase.queued);

      await engine.finish(engine.submits[1], _withFlags(0));
      await _until(nowL, (v) => v.phase == MusicAudioAnalysisPhase.ready);
      // 预取的那首接着跑。
      await _until(nextL, (_) => engine.submits.length == 3);
      expect(engine.submits[2].out, prefetch.out);
      await engine.finish(engine.submits[2], _withFlags(0));
      await _until(nextL, (v) => v.phase == MusicAudioAnalysisPhase.ready);
      await s.dispose();
    },
  );

  test('cancelExcept drops queued work and cancels the running one', () async {
    final MusicAudioAnalysisService s = service();
    final MusicAudioAnalysisTarget a = track('x');
    final MusicAudioAnalysisTarget b = track('y');
    final ValueListenable<MusicAudioAnalysisSnapshot> la = s.analyze(a);
    final ValueListenable<MusicAudioAnalysisSnapshot> lb = s.analyze(
      b,
      urgent: false,
    );
    await _until(la, (_) => engine.submits.isNotEmpty);
    await _until(lb, (v) => v.phase == MusicAudioAnalysisPhase.queued);
    s.cancelExcept(<MusicAudioAnalysisTarget>{});
    expect(lb.value.phase, MusicAudioAnalysisPhase.idle);
    expect(engine.cancels, <int>[engine.submits.single.token]);
    engine.emit(FfcManaEventKind.cancelled, engine.submits.single.token);
    await _until(la, (v) => v.phase == MusicAudioAnalysisPhase.idle);
    await _settle();
    expect(engine.submits, hasLength(1));
    await s.dispose();
  });

  test(
    'missing files are unsupported; decode and engine failures are reported',
    () async {
      final MusicAudioAnalysisService s = service();
      final ValueListenable<MusicAudioAnalysisSnapshot> gone = s.analyze(
        MusicAudioAnalysisTarget(
          trackUid: 'u',
          path: p.join(root.path, 'missing.flac'),
        ),
      );
      await _until(gone, (v) => v.phase == MusicAudioAnalysisPhase.unsupported);

      decoder.fail = true;
      final ValueListenable<MusicAudioAnalysisSnapshot> bad = s.analyze(
        track('bad'),
      );
      final MusicAudioAnalysisSnapshot f = await _until(
        bad,
        (v) => v.phase == MusicAudioAnalysisPhase.failed,
      );
      expect(f.error, 'bad file');

      decoder.fail = false;
      final ValueListenable<MusicAudioAnalysisSnapshot> eng = s.analyze(
        track('eng'),
      );
      await _until(eng, (_) => engine.submits.isNotEmpty);
      engine.emit(FfcManaEventKind.failed, engine.submits.single.token);
      final MusicAudioAnalysisSnapshot ef = await _until(
        eng,
        (v) => v.phase == MusicAudioAnalysisPhase.failed,
      );
      expect(ef.error, 'boom');
      await s.dispose();
    },
  );

  test('cache names change with the file fingerprint only', () {
    const MusicAudioAnalysisTarget t = MusicAudioAnalysisTarget(
      trackUid: 'u',
      path: '/a.flac',
    );
    final String a = musicAudioAnalysisCacheName(
      target: t,
      fileSize: 10,
      fileModifiedMs: 1,
    );
    expect(a, endsWith('.fma'));
    expect(
      musicAudioAnalysisCacheName(target: t, fileSize: 11, fileModifiedMs: 1),
      isNot(a),
    );
    expect(
      musicAudioAnalysisCacheName(target: t, fileSize: 10, fileModifiedMs: 2),
      isNot(a),
    );
  });

  test(
    'completeness needs the wanted flags, whole stems and this pipeline',
    () {
      final MusicAudioAnalysis whole = MusicAudioAnalysis.tryParse(
        _withFlags(MusicAudioAnalysisFlags.beatsModel),
      )!;
      expect(
        musicAudioAnalysisComplete(
          whole,
          MusicAudioAnalysisFlags.beatsModel,
          pipelineVersion: 2,
        ),
        isTrue,
      );
      expect(
        musicAudioAnalysisComplete(
          whole,
          MusicAudioAnalysisFlags.beatsModel,
          pipelineVersion: 3,
        ),
        isFalse,
      );
      final MusicAudioAnalysis partial = MusicAudioAnalysis.tryParse(
        _withFlags(
          MusicAudioAnalysisFlags.beatsModel |
              MusicAudioAnalysisFlags.drumsModel |
              MusicAudioAnalysisFlags.vocalModel |
              MusicAudioAnalysisFlags.stemsPartial,
        ),
      )!;
      expect(partial.stemsPartial, isTrue);
      expect(
        musicAudioAnalysisComplete(
          partial,
          MusicAudioAnalysisFlags.beatsModel,
          pipelineVersion: 2,
        ),
        isFalse,
      );
    },
  );

  test(
    'an older-pipeline cached result is shown at once and re-analysed',
    () async {
      final MusicAudioAnalysisTarget t = track('old');
      final MusicAudioAnalysisService first = service();
      final ValueListenable<MusicAudioAnalysisSnapshot> l = first.analyze(t);
      await _until(l, (_) => engine.submits.isNotEmpty);
      // 引擎（升级前）写的是 v1 布局、管线 1。
      final Uint8List v1 = File(
        'test/media/music/analysis/fixtures/golden_v1.fma',
      ).readAsBytesSync();
      ByteData.sublistView(v1).setUint32(8, 0, Endian.little);
      await engine.finish(engine.submits.single, v1);
      await _until(l, (v) => v.audio != null);
      await first.dispose();

      engine = _FakeEngine();
      final MusicAudioAnalysisService s = service();
      final ValueListenable<MusicAudioAnalysisSnapshot> l2 = s.analyze(t);
      await _until(l2, (_) => engine.submits.isNotEmpty);
      // 同一个缓存文件（名字不含管线版本）：旧结果先给出来，同时重算。
      expect(l2.value.audio?.formatVersion, 1);
      expect(engine.submits.single.out, endsWith('.fma'));
      await engine.finish(engine.submits.single, _withFlags(0));
      final MusicAudioAnalysisSnapshot v = await _until(
        l2,
        (MusicAudioAnalysisSnapshot v) =>
            v.phase == MusicAudioAnalysisPhase.ready,
      );
      expect(v.audio!.formatVersion, 2);
      expect(v.audio!.hasBeatAccents, isTrue);
      await s.dispose();
    },
  );

  test('partial stem updates refresh the snapshot while running', () async {
    final MusicAudioAnalysisService s = service();
    final ValueListenable<MusicAudioAnalysisSnapshot> l = s.analyze(
      track('partial'),
    );
    await _until(l, (_) => engine.submits.isNotEmpty);
    final _Submit sub = engine.submits.single;
    final Uint8List partial = _withFlags(
      MusicAudioAnalysisFlags.drumsModel |
          MusicAudioAnalysisFlags.vocalModel |
          MusicAudioAnalysisFlags.stemsPartial,
    );
    ByteData.sublistView(partial).setUint32(56, 1200, Endian.little);
    await File(sub.out).writeAsBytes(partial);
    engine.emit(FfcManaEventKind.updated, sub.token);
    final MusicAudioAnalysisSnapshot mid = await _until(
      l,
      (MusicAudioAnalysisSnapshot v) => v.audio?.stemsPartial ?? false,
    );
    expect(mid.audio!.stemsUntilMs, 1200);
    expect(mid.phase, MusicAudioAnalysisPhase.running);
    // 执行器退回 CPU 的事件只记日志，不影响状态。
    engine.emit(FfcManaEventKind.backendFallback, sub.token, 1);
    expect(l.value.phase, MusicAudioAnalysisPhase.running);
    await engine.finish(
      sub,
      _withFlags(
        MusicAudioAnalysisFlags.drumsModel | MusicAudioAnalysisFlags.vocalModel,
      ),
    );
    final MusicAudioAnalysisSnapshot done = await _until(
      l,
      (MusicAudioAnalysisSnapshot v) =>
          v.phase == MusicAudioAnalysisPhase.ready,
    );
    expect(done.audio!.stemsPartial, isFalse);
    await s.dispose();
  });

  test('ffmpeg arguments decode 44.1 kHz stereo s16le, capped length', () {
    final List<String> args = FfmpegMusicAnalysisPcmDecoder.argsFor(
      input: 'in.flac',
      output: 'out.raw',
      startMs: 1500,
      durationMs: 200000,
    );
    expect(args, containsAllInOrder(<String>['-ss', '1.500', '-i', 'in.flac']));
    expect(args, containsAllInOrder(<String>['-t', '200.000']));
    expect(
      args,
      containsAllInOrder(<String>[
        '-ac',
        '2',
        '-ar',
        '44100',
        '-f',
        's16le',
        'out.raw',
      ]),
    );
    final List<String> whole = FfmpegMusicAnalysisPcmDecoder.argsFor(
      input: 'in.flac',
      output: 'out.raw',
    );
    expect(whole, isNot(contains('-ss')));
    expect(whole, containsAllInOrder(<String>['-t', '1200.000']));
  });

  test(
    'model download reports progress and refreshes the engine config',
    () async {
      final List<String> downloaded = <String>[];
      final MusicAudioAnalysisService s = MusicAudioAnalysisService(
        cacheDir: () async => Directory(p.join(root.path, 'cache')),
        modelsDir: () async => Directory(p.join(root.path, 'models')),
        tempDir: () async => Directory(p.join(root.path, 'tmp')),
        engine: () => engine,
        decoder: decoder,
        ortPath: () async => null,
        desktop: false,
        threads: 1,
        download:
            (
              Directory dir,
              List<MusicAnalysisModelFile> files,
              onProgress,
            ) async {
              dir.createSync(recursive: true);
              for (final MusicAnalysisModelFile f in files) {
                downloaded.add(f.fileName);
                final RandomAccessFile raf = File(
                  p.join(dir.path, f.fileName),
                ).openSync(mode: FileMode.write);
                raf
                  ..truncateSync(f.expectedBytes)
                  ..closeSync();
              }
            },
      );
      final ValueListenable<MusicAudioAnalysisSnapshot> l = s.analyze(
        track('d'),
      );
      await _until(l, (_) => engine.submits.isNotEmpty);
      expect(s.models.value.installed, isFalse);
      await s.downloadModels();
      expect(downloaded, <String>['beat_this.onnx']);
      expect(s.models.value.installed, isTrue);
      expect(engine.configs.last.$2, endsWith('beat_this.onnx'));
      await s.deleteModels();
      expect(s.models.value.installed, isFalse);
      expect(engine.configs.last, (null, null, null));
      await s.dispose();
    },
  );
}
