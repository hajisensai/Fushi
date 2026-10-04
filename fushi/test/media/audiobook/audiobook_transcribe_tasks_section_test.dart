import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_transcribe_tasks_section.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:path/path.dart' as p;

/// 永不结束的转录（取消时按契约抛 Cancelled），让任务停在 running。
class _HangingTranscriber implements AudiobookTranscriber {
  @override
  Future<String> transcribe(
    AudiobookTranscribeJob job, {
    required void Function(AudiobookTranscribeJobPhase phase, double? progress)
    onProgress,
    required AudiobookTranscribeCancelToken cancel,
  }) {
    onProgress(AudiobookTranscribeJobPhase.transcribing, 0.42);
    final Completer<String> c = Completer<String>();
    cancel.onCancel(() {
      if (!c.isCompleted) c.completeError(const AudiobookTranscribeCancelled());
    });
    return c.future;
  }
}

AudiobookTranscribeJob _job(
  AudiobookTranscribeJobStatus status, {
  AudiobookTranscribeJobPhase? phase,
  double? progress,
  String? error,
  String? resultKey,
}) => AudiobookTranscribeJob(
  id: '1',
  title: 'Book',
  audioPaths: const <String>['/a.mp3'],
  createdAt: 0,
  updatedAt: 0,
  status: status,
  phase: phase,
  progress: progress,
  error: error,
  resultKey: resultKey,
);

void main() {
  group('audiobookTranscribeJobStatusLabel', () {
    test('运行中带步骤与百分比;无进度只给步骤', () {
      expect(
        audiobookTranscribeJobStatusLabel(
          _job(
            AudiobookTranscribeJobStatus.running,
            phase: AudiobookTranscribeJobPhase.transcribing,
            progress: 0.426,
          ),
        ),
        '${t.audiobook_transcribe_status_transcribing} · 43%',
      );
      expect(
        audiobookTranscribeJobStatusLabel(
          _job(
            AudiobookTranscribeJobStatus.running,
            phase: AudiobookTranscribeJobPhase.downloadingModel,
          ),
        ),
        t.audiobook_transcribe_status_downloading_model,
      );
    });

    test('完成区分已入库与同名跳过;失败带原文', () {
      expect(
        audiobookTranscribeJobStatusLabel(
          _job(AudiobookTranscribeJobStatus.done, resultKey: 'k'),
        ),
        t.audiobook_transcribe_status_done,
      );
      expect(
        audiobookTranscribeJobStatusLabel(
          _job(AudiobookTranscribeJobStatus.done),
        ),
        t.audiobook_transcribe_status_skipped,
      );
      expect(
        audiobookTranscribeJobStatusLabel(
          _job(AudiobookTranscribeJobStatus.failed, error: 'no speech'),
        ),
        contains('no speech'),
      );
    });
  });

  testWidgets('队列任务并入统一任务列表:状态/进度/动作槽位正确', (WidgetTester tester) async {
    final Directory root = Directory.systemTemp.createTempSync('abts_');
    addTearDown(() => root.deleteSync(recursive: true));
    // 队列必须在真实 zone 里构造：它内部的落盘链从构造时的 Future 起链，
    // 那个 Future 若生在 fake-async zone，后续 then 回调要等 fake zone 冲刷
    // 微任务——而 runAsync 里永远等不到，整条用例挂到超时。
    late final AudiobookTranscribeImportQueue queue;
    await tester.runAsync(() async {
      queue = AudiobookTranscribeImportQueue(
        store: File(p.join(root.path, 'jobs.json')),
        transcriber: _HangingTranscriber(),
        importer: (AudiobookTranscribeJob job, String srt) async => 'k',
      );
      await queue.enqueue(audioPaths: <String>['/a/01.mp3'], title: 'Running');
      await queue.enqueue(audioPaths: <String>['/b/01.mp3'], title: 'Waiting');
      // 让第一本进入 running。
      for (int i = 0; i < 50 && queue.jobs.first.progress == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    List<DownloadTaskEntry> entries = const <DownloadTaskEntry>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AudiobookTranscribeTasksSection(
            queueOverride: queue,
            tasksBuilder: (BuildContext context, List<DownloadTaskEntry> e) {
              entries = e;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(entries.map((DownloadTaskEntry e) => e.title), <String>[
      'Running',
      'Waiting',
    ]);
    final DownloadTaskEntry running = entries.first;
    expect(running.kind, DownloadTaskKind.audiobook);
    expect(running.status, DownloadTaskStatus.active);
    expect(running.progress, closeTo(0.42, 1e-9));
    expect(running.actions.cancel, isNotNull);
    expect(running.actions.retry, isNull);
    expect(running.actions.clear, isNull);
    expect(entries.last.status, DownloadTaskStatus.queued);

    // 取消正在跑的那本 → 列表随队列刷新,可重试/可移出。
    // 等的是「队列广播了终态」而不是「状态字段变了」：终态先写盘再通知，
    // 写盘是真实 IO，只在 runAsync 里推进。
    bool terminalNotified = false;
    void onChange() {
      if (queue.jobs.first.isTerminal) terminalNotified = true;
    }

    queue.addListener(onChange);
    await tester.runAsync(() async {
      await running.actions.cancel!();
      for (int i = 0; i < 200 && !terminalNotified; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    queue.removeListener(onChange);
    expect(terminalNotified, isTrue);
    await tester.pump();
    final DownloadTaskEntry cancelled = entries.first;
    expect(cancelled.status, DownloadTaskStatus.cancelled);
    expect(cancelled.actions.retry, isNotNull);
    expect(cancelled.actions.clear, isNotNull);
    expect(cancelled.actions.cancel, isNull);

    await tester.runAsync(queue.close);
  });
}
