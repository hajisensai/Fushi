// 内封字幕整轨抽取的后续两项（PR #3679 的后续）：
//  1. 抽取开始的回调（[loadSubtitleCueResult] / [loadDefaultTextEmbeddedSubtitleCues] 的
//     onExtractionStarted）：只有缓存未命中、真要读整个容器时才回调——播放页据此先借
//     播放器解码出字。
//  2. 下一集预热（prewarmEmbeddedSubtitleCache background: true）不和同一块盘上当前集
//     的读盘同时跑：等它结束 / 被取消再开始；还在排队时取消 = 不再开始。
// 假 ffmpeg 后端按输入文件分别挂起，记录哪几个文件的抽取同时在跑。
import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi_engine/platform/media_disk_identity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `ffmpeg -i` 枚举列出两条 subrip 轨；整轨抽取（runWatched）按输入文件挂起，直到
/// [release] 该文件（写出全部轨、退出 0）或 watch.cancel（返回取消标记）。
class _PerFileBackend implements FfmpegBackend, FfmpegWatchedRunner {
  final List<String> started = <String>[];
  final Set<String> running = <String>{};
  int maxConcurrent = 0;
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};
  final Map<String, Completer<void>> _startedSignals =
      <String, Completer<void>>{};

  Future<void> whenStarted(String input) =>
      (_startedSignals[p.normalize(input)] ??= Completer<void>()).future;

  void release(String input) {
    final Completer<void> gate = _gates.putIfAbsent(
      p.normalize(input),
      Completer<void>.new,
    );
    if (!gate.isCompleted) gate.complete();
  }

  static String _input(List<String> args) =>
      p.normalize(args[args.indexOf('-i') + 1]);

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(
        returnCode: 1,
        output: '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Subtitle: subrip (srt) (default)
  Stream #0:2(eng): Subtitle: subrip (srt)
''',
      );

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    final String input = _input(args);
    started.add(input);
    running.add(input);
    if (running.length > maxConcurrent) maxConcurrent = running.length;
    final Completer<void> signal = _startedSignals.putIfAbsent(
      input,
      Completer<void>.new,
    );
    if (!signal.isCompleted) signal.complete();
    try {
      final Completer<void> gate = _gates.putIfAbsent(
        input,
        Completer<void>.new,
      );
      final Future<void>? cancel = watch.cancel;
      final bool cancelled = await Future.any(<Future<bool>>[
        gate.future.then((_) => false),
        if (cancel != null) cancel.then((_) => true),
      ]);
      if (cancelled) {
        return const FfmpegRunResult(
          returnCode: null,
          output: kFfmpegCancelledMarker,
        );
      }
      for (int i = 0; i + 2 < args.length; i++) {
        if (args[i] != '-map' || !RegExp(r'^0:s:\d+$').hasMatch(args[i + 1])) {
          continue;
        }
        if (args[i + 2].startsWith('-')) continue;
        final File out = File(args[i + 2]);
        out.parent.createSync(recursive: true);
        out.writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n');
      }
      return const FfmpegRunResult(returnCode: 0, output: '');
    } finally {
      running.remove(input);
    }
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '{"format":{}}');
}

const SubtitleSource _jpn0 = SubtitleSource.embedded(
  streamIndex: 0,
  label: '内封 0: jpn / subrip',
  language: 'jpn',
  codec: 'subrip',
);

/// 让排队判定（等盘标识、等别的读盘结束）跑几轮。
Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory tempDir;
  late _PerFileBackend backend;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_vsub_queue_');
    backend = _PerFileBackend();
    setFfmpegBackendForTesting(backend);
    debugResetMediaDiskIdentityCache();
  });

  tearDown(() {
    setFfmpegBackendForTesting(null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String video(String name) {
    final File f = File(p.join(tempDir.path, '$name.mkv'))
      ..writeAsStringSync('fake bytes for $name');
    return f.path;
  }

  group('mediaDiskIdentity / mayShareDisk', () {
    test('判不出（null）按可能同盘处理；有交集才算同盘', () {
      expect(mayShareDisk(null, <String>{'disk:0'}), isTrue);
      expect(mayShareDisk(<String>{'disk:0'}, null), isTrue);
      expect(mayShareDisk(<String>{'disk:0'}, <String>{'disk:1'}), isFalse);
      expect(
        mayShareDisk(<String>{'disk:0', 'disk:2'}, <String>{'disk:2'}),
        isTrue,
        reason: '跨盘的卷与其中任一块盘都算同盘',
      );
    });

    test('同一块盘上的两个目录判成同盘，且判得出来（不靠 null 兜底）', () async {
      final Directory sub = Directory(p.join(tempDir.path, 'season2'))
        ..createSync();
      final Set<String>? a = await mediaDiskIdentity(video('a'));
      final Set<String>? b = await mediaDiskIdentity(p.join(sub.path, 'b.mkv'));
      expect(a, isNotNull, reason: '本机（Windows / Linux / macOS）必须判得出');
      expect(a, b);
      expect(mayShareDisk(a, b), isTrue);
    }, testOn: 'windows || linux || mac-os');
  });

  group('onExtractionStarted：只在真要读整个容器时回调', () {
    test('缓存未命中回调一次；之后缓存命中不回调', () async {
      final String path = video('ep1');
      int calls = 0;
      final Future<SubtitleCueLoadResult> first = loadSubtitleCueResult(
        _jpn0,
        path,
        'video/ep1',
        onExtractionStarted: () => calls++,
      );
      await backend.whenStarted(path);
      expect(calls, 1, reason: '回调要在抽取开始之前到，播放页才能抽取期间先出字');
      backend.release(path);
      expect((await first).isFailure, isFalse);

      final SubtitleCueLoadResult second = await loadSubtitleCueResult(
        _jpn0,
        path,
        'video/ep1',
        onExtractionStarted: () => calls++,
      );
      expect(second.isFailure, isFalse);
      expect(calls, 1, reason: '缓存命中瞬时出结果，不必借播放器解码');
    });

    test('默认加载把挑中的源交给回调', () async {
      final String path = video('auto');
      SubtitleSource? chosen;
      final Future<DefaultEmbeddedSubtitleLoadResult> load =
          loadDefaultTextEmbeddedSubtitleCues(
            videoPath: path,
            bookUid: 'video/auto',
            onExtractionStarted: (SubtitleSource s) => chosen = s,
          );
      await backend.whenStarted(path);
      expect(chosen?.streamIndex, 0);
      backend.release(path);
      expect((await load).status, DefaultEmbeddedSubtitleLoadStatus.loaded);
    });
  });

  group('下一集预热排在同一块盘上当前集的读盘之后', () {
    test('当前集抽取在跑时下一集预热不开始；当前集读完后才开始', () async {
      final String ep1 = video('ep1');
      final String ep2 = video('ep2');
      final Future<void> current = prewarmEmbeddedSubtitleCache(ep1);
      final Future<void> next = prewarmEmbeddedSubtitleCache(
        ep2,
        background: true,
      );
      await backend.whenStarted(ep1);
      await _settle();
      expect(backend.started, <String>[p.normalize(ep1)]);
      expect(debugRunningBackgroundSubtitlePrewarms(), isEmpty);

      backend.release(ep1);
      await current;
      await backend.whenStarted(ep2);
      expect(backend.maxConcurrent, 1, reason: '同一块盘上两个整片读不能同时跑');
      backend.release(ep2);
      await next;
      expect(backend.started, <String>[p.normalize(ep1), p.normalize(ep2)]);
    });

    test('前台读盘在同一段同步代码里登记：预热先调用也抢不到前面', () async {
      final String ep1 = video('ep1');
      final String ep2 = video('ep2');
      // 后台预热先发起（它要先问系统这块盘是谁），当前集的菜单切轨紧跟其后。
      final Future<void> next = prewarmEmbeddedSubtitleCache(
        ep2,
        background: true,
      );
      final Future<SubtitleCueLoadResult> manual = loadSubtitleCueResult(
        _jpn0,
        ep1,
        'video/ep1',
      );
      await backend.whenStarted(ep1);
      await _settle();
      expect(backend.started, <String>[p.normalize(ep1)]);
      backend.release(ep1);
      expect((await manual).isFailure, isFalse);
      await backend.whenStarted(ep2);
      backend.release(ep2);
      await next;
      expect(backend.maxConcurrent, 1);
    });

    test('当前集抽取被取消也放行排队的预热', () async {
      final String ep1 = video('ep1');
      final String ep2 = video('ep2');
      final Completer<void> cancelCurrent = Completer<void>();
      final Future<void> current = prewarmEmbeddedSubtitleCache(
        ep1,
        cancel: cancelCurrent.future,
      );
      final Future<void> next = prewarmEmbeddedSubtitleCache(
        ep2,
        background: true,
      );
      await backend.whenStarted(ep1);
      await _settle();
      cancelCurrent.complete();
      await current;
      await backend.whenStarted(ep2);
      backend.release(ep2);
      await next;
      expect(backend.started, <String>[p.normalize(ep1), p.normalize(ep2)]);
    });

    test('还在排队时撤掉（换集）：不再开始，也不留在登记里', () async {
      final String ep1 = video('ep1');
      final String ep2 = video('ep2');
      final Completer<void> cancelNext = Completer<void>();
      final Future<void> current = prewarmEmbeddedSubtitleCache(ep1);
      final Future<void> next = prewarmEmbeddedSubtitleCache(
        ep2,
        cancel: cancelNext.future,
        background: true,
      );
      await backend.whenStarted(ep1);
      await _settle();
      cancelNext.complete();
      await next;
      backend.release(ep1);
      await current;
      await _settle();
      expect(backend.started, <String>[p.normalize(ep1)]);
      expect(debugRunningBackgroundSubtitlePrewarms(), isEmpty);
    });

    test('两条后台预热也不同时读同一块盘', () async {
      final String ep2 = video('ep2');
      final String ep3 = video('ep3');
      final Future<void> a = prewarmEmbeddedSubtitleCache(
        ep2,
        background: true,
      );
      final Future<void> b = prewarmEmbeddedSubtitleCache(
        ep3,
        background: true,
      );
      await Future.any(<Future<void>>[
        backend.whenStarted(ep2),
        backend.whenStarted(ep3),
      ]);
      await _settle();
      expect(backend.started, hasLength(1));
      final String first = backend.started.single;
      final String second = first == p.normalize(ep2)
          ? p.normalize(ep3)
          : p.normalize(ep2);
      backend.release(first);
      await backend.whenStarted(second);
      backend.release(second);
      await Future.wait(<Future<void>>[a, b]);
      expect(backend.maxConcurrent, 1);
    });

    test('预热的正是新当前集时，前台加入同一次抽取、立即开始', () async {
      final String ep2 = video('ep2');
      final String ep3 = video('ep3');
      // ep2 的后台预热先占着盘在读（上一集已经看完了）。
      final Future<void> prewarm2 = prewarmEmbeddedSubtitleCache(
        ep2,
        background: true,
      );
      await backend.whenStarted(ep2);
      // 换到 ep2：当前集前台读盘加入同一次抽取，ep3 的预热排在后面。
      final Future<SubtitleCueLoadResult> manual = loadSubtitleCueResult(
        _jpn0,
        ep2,
        'video/ep2',
      );
      final Future<void> prewarm3 = prewarmEmbeddedSubtitleCache(
        ep3,
        background: true,
      );
      await _settle();
      expect(backend.started, <String>[p.normalize(ep2)]);
      backend.release(ep2);
      expect((await manual).isFailure, isFalse);
      await prewarm2;
      await backend.whenStarted(ep3);
      backend.release(ep3);
      await prewarm3;
      expect(backend.started, <String>[p.normalize(ep2), p.normalize(ep3)]);
    });
  });
}
