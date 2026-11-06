import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:path/path.dart' as p;

/// 一条假转录产物：每段识别成什么（null / 空串 = 这段没识别出字，不出 cue）。
typedef FakeSegmentText = String? Function(asr.AsrSegmentSpan span);

/// 假转录服务：`plan` 报模型就绪（或缺），`start(segments:)` 记下分段，`run` 按
/// [text] 在 [jobDir] 里写 `transcript.srt` + `state.json` + `transcript.tokens.jsonl`
/// （与上游「按给定分段识别」同一契约：每段至多一条 cue、起止 = 分段）。
class FakeAsrTranscriptionService implements asr.AsrTranscriptionService {
  FakeAsrTranscriptionService({
    required this.jobDir,
    required this.text,
    this.modelReady = true,
    this.holdUntilPaused = false,
  });

  final Directory jobDir;
  final FakeSegmentText text;
  final bool modelReady;

  /// true：run 不结束，直到 requestPause（测取消）。
  final bool holdUntilPaused;

  final List<List<asr.AsrSegmentSpan>?> startedWith =
      <List<asr.AsrSegmentSpan>?>[];
  final List<asr.AsrAudioProfile> profiles = <asr.AsrAudioProfile>[];
  int pauses = 0;

  @override
  asr.AsrAudioProfile get audioProfile => asr.AsrAudioProfile.mixedAudio;

  @override
  Future<asr.AsrTranscribePlan> plan({
    required asr.AsrLanguage language,
    required asr.AsrAccelerationPreference preference,
  }) async => asr.AsrTranscribePlan(
    language: language,
    variant: asr.AsrEncoderVariant.fp32,
    expectedProvider: asr.OnnxExecutionProvider.cpu,
    modelStatus: asr.AsrModelStatus(
      ready: modelReady,
      diskBytes: 0,
      totalBytes: 0,
      obtainedBytes: 0,
    ),
  );

  @override
  Future<asr.AsrRunningTranscription> start({
    required List<String> audioPaths,
    required asr.AsrLanguage language,
    required asr.AsrEncoderVariant variant,
    required asr.AsrAccelerationPreference preference,
    List<asr.AsrSegmentSpan>? segments,
  }) async {
    startedWith.add(segments);
    return _FakeRunning(this, segments ?? const <asr.AsrSegmentSpan>[]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _srtTime(int ms) {
  final int h = ms ~/ 3600000;
  final int m = ms ~/ 60000 % 60;
  final int s = ms ~/ 1000 % 60;
  final int r = ms % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)},${r.toString().padLeft(3, '0')}';
}

class _FakeRunning implements asr.AsrRunningTranscription {
  _FakeRunning(this.service, this.spans);

  final FakeAsrTranscriptionService service;
  final List<asr.AsrSegmentSpan> spans;
  final Completer<void> _paused = Completer<void>();

  @override
  Stream<asr.AsrTranscribeEvent> run() async* {
    const asr.AsrTranscribeProgress half = asr.AsrTranscribeProgress(
      fileIndex: 0,
      filesTotal: 1,
      processedMs: 1,
      totalMs: 2,
      speechMs: 0,
      segmentsDone: 0,
      elapsed: Duration.zero,
    );
    yield const asr.AsrTranscribeProgressEvent(half);
    if (service.holdUntilPaused) {
      await _paused.future;
      yield const asr.AsrTranscribePausedEvent(half);
      return;
    }
    final Directory dir = service.jobDir..createSync(recursive: true);
    final List<asr.AsrSegmentSpan> sorted = List<asr.AsrSegmentSpan>.of(spans)
      ..sort(
        (asr.AsrSegmentSpan a, asr.AsrSegmentSpan b) =>
            a.startMs.compareTo(b.startMs),
      );
    final StringBuffer srt = StringBuffer();
    final StringBuffer tokens = StringBuffer();
    int n = 0;
    for (final asr.AsrSegmentSpan s in sorted) {
      final String? t = service.text(s);
      if (t == null || t.isEmpty) continue;
      n++;
      srt
        ..writeln(n)
        ..writeln('${_srtTime(s.startMs)} --> ${_srtTime(s.endMs)}')
        ..writeln(t)
        ..writeln();
      final List<String> chars = t.split('');
      tokens.writeln(
        jsonEncode(<String, Object?>{
          't': chars,
          'o': <int>[for (int i = 0; i < chars.length; i++) i * 100],
          'e': <int>[for (int i = 0; i < chars.length; i++) i * 100 + 80],
        }),
      );
    }
    final File srtFile = File(p.join(dir.path, asr.AsrJobFiles.srt))
      ..writeAsStringSync(srt.toString());
    File(p.join(dir.path, asr.AsrJobFiles.state)).writeAsStringSync('{}');
    File(
      p.join(dir.path, asr.AsrJobFiles.cueTokens),
    ).writeAsStringSync(tokens.toString());
    yield asr.AsrTranscribeFinishedEvent(
      asr.AsrTranscribeResult(
        srtPath: srtFile.path,
        segmentsPath: p.join(dir.path, asr.AsrJobFiles.segments),
        cueCount: n,
        segmentCount: n,
        totalMs: 0,
        fileDurationsMs: const <int>[0],
      ),
    );
  }

  @override
  void requestPause({bool discardPending = false}) {
    service.pauses++;
    if (!_paused.isCompleted) _paused.complete();
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假子进程：[onStart] 决定它做什么、何时退出（[FakeProcess.exit]）。
class FakeProcess implements Process {
  FakeProcess();

  final Completer<int> _exit = Completer<int>();
  final StreamController<List<int>> _out = StreamController<List<int>>();
  final StreamController<List<int>> _err = StreamController<List<int>>();
  bool killed = false;

  void stdoutWrite(String text) => _out.add(utf8.encode(text));

  void exit(int code, {String stderrText = ''}) {
    if (_exit.isCompleted) return;
    if (stderrText.isNotEmpty) _err.add(utf8.encode(stderrText));
    _out.close();
    _err.close();
    _exit.complete(code);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    exit(-1);
    return true;
  }

  @override
  int get pid => 4242;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);
}

/// 起进程的记录 + 行为。
class FakeProcessStarter {
  FakeProcessStarter(this.behave);

  /// 拿到参数与新进程，决定写什么文件、何时 exit。
  final void Function(String executable, List<String> args, FakeProcess proc)
  behave;
  final List<List<String>> calls = <List<String>>[];
  final List<FakeProcess> processes = <FakeProcess>[];

  Future<Process> call(String executable, List<String> arguments) async {
    calls.add(<String>[executable, ...arguments]);
    final FakeProcess proc = FakeProcess();
    processes.add(proc);
    behave(executable, arguments, proc);
    return proc;
  }
}

/// 假 audiocpp_cli：往 `--text-out` 写 [raw] 后退出 0。
void Function(String, List<String>, FakeProcess) fakeAudioCppCli(String raw) =>
    (String exe, List<String> args, FakeProcess proc) {
      final int at = args.indexOf('--text-out');
      File(args[at + 1]).writeAsStringSync(raw);
      scheduleMicrotask(() => proc.exit(0));
    };
