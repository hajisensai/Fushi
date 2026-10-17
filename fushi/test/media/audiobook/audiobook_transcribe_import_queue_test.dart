import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:path/path.dart' as p;

/// 可控的假转录端口：每个任务一个 Completer，测试决定何时完成/失败；取消时
/// 按真实端口的契约抛 [AudiobookTranscribeCancelled]。
class _FakeTranscriber implements AudiobookTranscriber {
  final Map<String, Completer<String>> pending = <String, Completer<String>>{};
  final List<String> started = <String>[];

  @override
  Future<String> transcribe(
    AudiobookTranscribeJob job, {
    required void Function(AudiobookTranscribeJobPhase phase, double? progress)
    onProgress,
    required AudiobookTranscribeCancelToken cancel,
  }) {
    started.add(job.title);
    onProgress(AudiobookTranscribeJobPhase.transcribing, 0.5);
    final Completer<String> c = Completer<String>();
    pending[job.title] = c;
    cancel.onCancel(() {
      if (!c.isCompleted) c.completeError(const AudiobookTranscribeCancelled());
    });
    return c.future;
  }
}

Future<void> _until(bool Function() condition) async {
  for (int i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not reached');
}

void main() {
  late Directory root;
  late File store;
  late _FakeTranscriber transcriber;
  late List<String> imported;
  late String? importResult;

  AudiobookTranscribeImportQueue newQueue() => AudiobookTranscribeImportQueue(
    store: store,
    transcriber: transcriber,
    importer: (AudiobookTranscribeJob job, String subtitlePath) async {
      imported.add('${job.title}<-$subtitlePath');
      return importResult;
    },
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('abtq_');
    store = File(p.join(root.path, 'jobs.json'));
    transcriber = _FakeTranscriber();
    imported = <String>[];
    importResult = 'book-key';
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> stored() => <Map<String, Object?>>[
    for (final Object? raw
        in jsonDecode(store.readAsStringSync()) as List<Object?>)
      Map<String, Object?>.from(raw! as Map<Object?, Object?>),
  ];

  test('转完即入库,结果落盘', () async {
    final AudiobookTranscribeImportQueue queue = newQueue();
    final AudiobookTranscribeJob job = await queue.enqueue(
      audioPaths: <String>['/a/01.mp3'],
      title: 'Book',
    );
    await _until(() => transcriber.pending.containsKey('Book'));
    expect(job.status, AudiobookTranscribeJobStatus.running);
    expect(job.phase, AudiobookTranscribeJobPhase.transcribing);
    transcriber.pending['Book']!.complete('/asr/transcript.srt');
    await _until(() => job.isTerminal);
    await queue.close();

    expect(job.status, AudiobookTranscribeJobStatus.done);
    expect(job.resultKey, 'book-key');
    expect(imported, <String>['Book<-/asr/transcript.srt']);
    expect(stored().single['status'], 'done');
    expect(stored().single['resultKey'], 'book-key');
  });

  test('同名书已在库:done 且 resultKey 为 null', () async {
    importResult = null;
    final AudiobookTranscribeImportQueue queue = newQueue();
    final AudiobookTranscribeJob job = await queue.enqueue(
      audioPaths: <String>['/a/01.mp3'],
      title: 'Book',
    );
    await _until(() => transcriber.pending.containsKey('Book'));
    transcriber.pending['Book']!.complete('/asr/t.srt');
    await _until(() => job.isTerminal);
    await queue.close();
    expect(job.status, AudiobookTranscribeJobStatus.done);
    expect(job.resultKey, isNull);
  });

  test('失败落 failed 带原因;重试后能跑完', () async {
    final AudiobookTranscribeImportQueue queue = newQueue();
    final AudiobookTranscribeJob job = await queue.enqueue(
      audioPaths: <String>['/a/01.mp3'],
      title: 'Book',
    );
    await _until(() => transcriber.pending.containsKey('Book'));
    transcriber.pending.remove('Book')!.completeError(StateError('no model'));
    await _until(() => job.isTerminal);
    expect(job.status, AudiobookTranscribeJobStatus.failed);
    expect(job.error, contains('no model'));

    await queue.retry(job.id);
    await _until(() => transcriber.pending.containsKey('Book'));
    transcriber.pending['Book']!.complete('/asr/t.srt');
    await _until(() => job.isTerminal);
    await queue.close();
    expect(job.status, AudiobookTranscribeJobStatus.done);
    expect(job.error, isNull);
  });

  test('取消正在跑的任务 → cancelled,不入库', () async {
    final AudiobookTranscribeImportQueue queue = newQueue();
    final AudiobookTranscribeJob job = await queue.enqueue(
      audioPaths: <String>['/a/01.mp3'],
      title: 'Book',
    );
    await _until(() => transcriber.pending.containsKey('Book'));
    await queue.cancel(job.id);
    await _until(() => job.isTerminal);
    await queue.close();
    expect(job.status, AudiobookTranscribeJobStatus.cancelled);
    expect(imported, isEmpty);
  });

  test('串行:第二本等第一本结束才开始;同一组音频不重复排', () async {
    final AudiobookTranscribeImportQueue queue = newQueue();
    final AudiobookTranscribeJob first = await queue.enqueue(
      audioPaths: <String>['/a/01.mp3'],
      title: 'A',
    );
    final AudiobookTranscribeJob dup = await queue.enqueue(
      audioPaths: <String>['/a/01.mp3'],
      title: 'A again',
    );
    expect(identical(dup, first), isTrue);
    final AudiobookTranscribeJob second = await queue.enqueue(
      audioPaths: <String>['/b/01.mp3'],
      title: 'B',
    );
    await _until(() => transcriber.pending.containsKey('A'));
    expect(transcriber.started, <String>['A']);
    expect(second.status, AudiobookTranscribeJobStatus.queued);

    transcriber.pending['A']!.complete('/asr/a.srt');
    await _until(() => transcriber.pending.containsKey('B'));
    transcriber.pending['B']!.complete('/asr/b.srt');
    await _until(() => second.isTerminal);
    await queue.close();
    expect(transcriber.started, <String>['A', 'B']);
    expect(queue.jobs, hasLength(2));
  });

  test('进程中断:running 的任务下次 load 回到队列并续跑', () async {
    final AudiobookTranscribeImportQueue first = newQueue();
    await first.enqueue(audioPaths: <String>['/a/01.mp3'], title: 'Book');
    await _until(() => transcriber.pending.containsKey('Book'));
    // 模拟进程退出：close 让在跑的任务回到 queued（不是用户取消）。
    await first.close();
    expect(stored().single['status'], 'queued');

    transcriber = _FakeTranscriber();
    final AudiobookTranscribeImportQueue second = newQueue();
    await second.load();
    await _until(() => transcriber.pending.containsKey('Book'));
    transcriber.pending['Book']!.complete('/asr/t.srt');
    final AudiobookTranscribeJob job = second.jobs.single;
    await _until(() => job.isTerminal);
    await second.close();
    expect(job.status, AudiobookTranscribeJobStatus.done);
  });

  test('盘上残留 running 状态(进程被杀) → load 后重新跑', () async {
    store.writeAsStringSync(
      jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'x',
          'title': 'Killed',
          'audioPaths': <String>['/k/01.mp3'],
          'contentPath': null,
          'createdAt': 1,
          'updatedAt': 1,
          'status': 'running',
          'phase': 'transcribing',
          'progress': 0.4,
        },
      ]),
    );
    final AudiobookTranscribeImportQueue queue = newQueue();
    await queue.load();
    await _until(() => transcriber.pending.containsKey('Killed'));
    transcriber.pending['Killed']!.complete('/asr/k.srt');
    await _until(() => queue.jobs.single.isTerminal);
    await queue.close();
    expect(queue.jobs.single.status, AudiobookTranscribeJobStatus.done);
  });

  test('清单损坏不让队列起不来:挪成 .corrupt 后按空队列继续', () async {
    store.writeAsStringSync('{not json');
    final AudiobookTranscribeImportQueue queue = newQueue();
    await queue.load();
    expect(queue.jobs, isEmpty);
    expect(File('${store.path}.corrupt').existsSync(), isTrue);
    await queue.close();
  });

  test('只能移除已结束的任务', () async {
    final AudiobookTranscribeImportQueue queue = newQueue();
    final AudiobookTranscribeJob job = await queue.enqueue(
      audioPaths: <String>['/a/01.mp3'],
      title: 'Book',
    );
    await _until(() => transcriber.pending.containsKey('Book'));
    await queue.remove(job.id);
    expect(queue.jobs, hasLength(1));
    transcriber.pending['Book']!.complete('/asr/t.srt');
    await _until(() => job.isTerminal);
    await queue.remove(job.id);
    expect(queue.jobs, isEmpty);
    await queue.close();
    expect(stored(), isEmpty);
  });
}
