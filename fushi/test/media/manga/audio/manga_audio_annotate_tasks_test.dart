// 漫画标注的进程级任务表：离开页面（观察者摘掉）任务照跑到完；只有显式取消才停；
// 同一卷不并行跑两个任务。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_manga_audio_assistant.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Test',
  baseUrl: Uri.parse('https://example.invalid'),
);

MangaAnnotateRunSummary _summary({List<int> failed = const <int>[]}) =>
    MangaAnnotateRunSummary(
      annotatedPages: const <int>[0, 1, 2],
      failedPages: failed,
      rejectedLines: 0,
      reviewedLines: 0,
    );

/// 假运行体：逐页等测试放行（[step]），每页前查取消，像真运行体一样回报进度。
class _FakeRunner {
  _FakeRunner();

  final int pages = 3;
  final List<Completer<void>> _gates = <Completer<void>>[];
  int calls = 0;
  Exception? throwOnStart;

  Future<void> step() async {
    while (_gates.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    _gates.removeAt(0).complete();
    await Future<void>.delayed(Duration.zero);
  }

  Future<MangaAnnotateRunSummary> call(
    MangaAnnotateRequest request,
    MangaAnnotateTaskSink sink,
    bool Function() isCancelled,
  ) async {
    calls++;
    sink.title('Vol ${request.bookKey}');
    final Exception? error = throwOnStart;
    if (error != null) throw error;
    for (int i = 0; i < pages; i++) {
      if (isCancelled()) throw const MangaAnnotateAbort('cancelled');
      final Completer<void> gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
      sink.progress(MangaAnnotatePhase.pages, i + 1, pages);
      sink.failures(<MangaAnnotateFailure>[
        MangaAnnotateFailure(stage: MangaAnnotateStage.page, page: i),
      ]);
    }
    return _summary(failed: <int>[pages - 1]);
  }
}

void main() {
  late _FakeRunner runner;
  late List<MangaAnnotateTask> settled;
  late MangaAnnotateTasks tasks;

  setUp(() {
    runner = _FakeRunner();
    settled = <MangaAnnotateTask>[];
    tasks = MangaAnnotateTasks(runner: runner.call, onSettled: settled.add);
  });

  test(
    'observer leaving does not stop the task; it runs to completion',
    () async {
      final MangaAnnotateTask task = tasks.start(
        MangaAnnotateRequest.annotate(bookKey: 'b1', provider: _provider()),
      );
      // 「页面」挂上观察者、看到一页进度后离开（摘掉观察者）。
      int seen = 0;
      void observer() => seen++;
      task.addListener(observer);
      await runner.step();
      expect(task.progressDone, 1);
      expect(task.phase, MangaAnnotatePhase.pages);
      expect(seen, greaterThan(0));
      task.removeListener(observer);
      final int seenAtLeave = seen;

      await runner.step();
      await runner.step();
      await task.finished;

      expect(seen, seenAtLeave, reason: '离开后的进度不再推给已摘掉的观察者');
      expect(task.status, MangaAnnotateTaskStatus.completed);
      expect(task.progressDone, 3);
      expect(task.progressTotal, 3);
      expect(task.summary?.failedPages, <int>[2]);
      expect(task.failures.map((MangaAnnotateFailure f) => f.page), <int>[2]);
      expect(task.title, 'Vol b1');
      expect(tasks.runningFor('b1'), isNull);
      expect(tasks.taskFor('b1'), same(task), reason: '跑完留着给查状态');
      expect(settled, <MangaAnnotateTask>[task], reason: '跑完告诉用户一次');
      expect(mangaAnnotateTaskResultText(task), contains('Vol b1'));
    },
  );

  test('explicit cancel stops the task', () async {
    final MangaAnnotateTask task = tasks.start(
      MangaAnnotateRequest.annotate(bookKey: 'b1', provider: _provider()),
    );
    await runner.step();
    expect(tasks.cancel('b1'), isTrue);
    expect(task.cancelRequested, isTrue);
    expect(tasks.cancel('b1'), isFalse, reason: '已在取消');
    await runner.step();
    await task.finished;
    expect(task.status, MangaAnnotateTaskStatus.cancelled);
    expect(task.progressDone, 2, reason: '取消只在下一页前生效，已标的页不丢');
    expect(tasks.isRunning('b1'), isFalse);
    expect(tasks.cancel('b1'), isFalse, reason: '没有在跑的任务');
    expect(settled, <MangaAnnotateTask>[task]);
  });

  test(
    'same volume cannot run twice; other volumes and reruns are fine',
    () async {
      final MangaAnnotateTask first = tasks.start(
        MangaAnnotateRequest.annotate(bookKey: 'b1', provider: _provider()),
      );
      expect(
        () => tasks.start(
          MangaAnnotateRequest.retry(
            bookKey: 'b1',
            provider: _provider(),
            failure: MangaAnnotateFailure(
              stage: MangaAnnotateStage.page,
              page: 0,
            ),
          ),
        ),
        throwsA(
          isA<MangaAnnotateBusy>().having(
            (MangaAnnotateBusy e) => e.running,
            'running',
            same(first),
          ),
        ),
      );
      expect(runner.calls, 1);

      final MangaAnnotateTask other = tasks.start(
        MangaAnnotateRequest.annotate(bookKey: 'b2', provider: _provider()),
        announce: false,
      );
      expect(tasks.running, unorderedEquals(<MangaAnnotateTask>[first, other]));

      tasks.cancel('b2');
      // first 三页 + other 取消前已在等的一页。
      for (int i = 0; i < 4; i++) {
        await runner.step();
      }
      await first.finished;
      await other.finished;
      expect(other.status, MangaAnnotateTaskStatus.cancelled);
      expect(settled, <MangaAnnotateTask>[first], reason: 'announce: false 不弹');

      final MangaAnnotateTask again = tasks.start(
        MangaAnnotateRequest.annotate(bookKey: 'b1', provider: _provider()),
      );
      expect(again, isNot(same(first)));
      expect(tasks.taskFor('b1'), same(again));
      tasks.cancel('b1');
      await runner.step();
      await again.finished;
    },
  );

  test('registry notifies on start and finish', () async {
    int changes = 0;
    tasks.addListener(() => changes++);
    final MangaAnnotateTask task = tasks.start(
      MangaAnnotateRequest.annotate(bookKey: 'b1', provider: _provider()),
    );
    expect(changes, 1);
    for (int i = 0; i < 3; i++) {
      await runner.step();
    }
    await task.finished;
    await Future<void>.delayed(Duration.zero);
    expect(changes, 2);
  });

  test('abort and open errors map to statuses with codes', () async {
    runner.throwOnStart = const MangaAnnotateAbort('auth');
    final MangaAnnotateTask aborted = tasks.start(
      MangaAnnotateRequest.annotate(bookKey: 'b1', provider: _provider()),
    );
    await aborted.finished;
    expect(aborted.status, MangaAnnotateTaskStatus.aborted);
    expect(aborted.errorCode, 'auth');

    runner.throwOnStart = const MangaAudioAnnotateError('no_ocr');
    final MangaAnnotateTask failed = tasks.start(
      MangaAnnotateRequest.annotate(bookKey: 'b1', provider: _provider()),
    );
    await failed.finished;
    expect(failed.status, MangaAnnotateTaskStatus.failed);
    expect(failed.errorCode, 'no_ocr');
    expect(settled, <MangaAnnotateTask>[aborted, failed]);
  });
}
