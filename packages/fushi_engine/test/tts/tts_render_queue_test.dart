import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 假制作端口：每次 run 都像真流程一样先建工作目录写个中间文件，然后按 [outcome]
/// 失败 / 成功（成功时与真流程一样删掉工作目录）。
class _FakeRunner implements TtsRenderRunner {
  _FakeRunner(this.workRoot);

  final Directory workRoot;
  String outcome = 'fail';

  @override
  Future<({bool verified, List<TtsRenderFlag> flags})> run(
    TtsRenderJob job, {
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) async {
    final Directory dir = ttsRenderJobWorkDir(workRoot, job.id);
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'tts_000.m4a')).writeAsBytes(<int>[1, 2, 3]);
    if (outcome == 'fail') throw const TtsRenderFailure('synthesis_failed');
    await dir.delete(recursive: true);
    return (verified: false, flags: const <TtsRenderFlag>[]);
  }
}

Future<void> _untilTerminal(TtsRenderQueue queue, String id) async {
  bool terminal() {
    for (final TtsRenderJob job in queue.jobs) {
      if (job.id == id) return job.isTerminal;
    }
    return true;
  }

  if (terminal()) return;
  final Completer<void> done = Completer<void>();
  void listener() {
    if (terminal() && !done.isCompleted) done.complete();
  }

  queue.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  queue.removeListener(listener);
}

void main() {
  late Directory tmp;
  late Directory workRoot;
  late File store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tts_render_queue_test_');
    workRoot = Directory(p.join(tmp.path, 'tts_render'));
    store = File(p.join(tmp.path, 'tts_render_jobs.json'));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  TtsRenderQueue build(_FakeRunner runner) {
    int tick = 0;
    return TtsRenderQueue(
      store: store,
      workRoot: workRoot,
      runner: runner,
      now: () => DateTime.fromMillisecondsSinceEpoch(1000 + tick++),
    );
  }

  test('remove 删清单条目的同时删掉它的工作目录', () async {
    final _FakeRunner runner = _FakeRunner(workRoot);
    final TtsRenderQueue queue = build(runner);
    final TtsRenderJob job = await queue.enqueue(
      bookKey: 'book-a',
      title: 'A',
      presetId: 'v',
    );
    await _untilTerminal(queue, job.id);
    final Directory dir = ttsRenderJobWorkDir(workRoot, job.id);
    expect(dir.existsSync(), isTrue, reason: '失败任务的工作目录还在（可重试）');

    await queue.remove(job.id);
    expect(queue.jobs, isEmpty);
    expect(dir.existsSync(), isFalse);
    await queue.close();
  });

  test('同一本书排新任务时，之前已结束的任务连条目带目录一起删，别的书不动', () async {
    final _FakeRunner runner = _FakeRunner(workRoot);
    final TtsRenderQueue queue = build(runner);
    final TtsRenderJob first = await queue.enqueue(
      bookKey: 'book-a',
      title: 'A',
      presetId: 'v',
    );
    await _untilTerminal(queue, first.id);
    final TtsRenderJob other = await queue.enqueue(
      bookKey: 'book-b',
      title: 'B',
      presetId: 'v',
    );
    await _untilTerminal(queue, other.id);
    final Directory firstDir = ttsRenderJobWorkDir(workRoot, first.id);
    final Directory otherDir = ttsRenderJobWorkDir(workRoot, other.id);
    expect(firstDir.existsSync(), isTrue);

    final TtsRenderJob second = await queue.enqueue(
      bookKey: 'book-a',
      title: 'A',
      presetId: 'v2',
    );
    expect(second.id, isNot(first.id));
    await _untilTerminal(queue, second.id);

    expect(
      <String>[for (final TtsRenderJob j in queue.jobs) j.id],
      unorderedEquals(<String>[other.id, second.id]),
      reason: '每本书只留最新一条',
    );
    expect(firstDir.existsSync(), isFalse, reason: '被取代的任务目录要删');
    expect(otherDir.existsSync(), isTrue, reason: '别的书的目录不动');
    expect(
      ttsRenderJobWorkDir(workRoot, second.id).existsSync(),
      isTrue,
    );
    await queue.close();
  });

  test('load 清掉清单里没有的孤儿工作目录，保留清单里的', () async {
    final _FakeRunner runner = _FakeRunner(workRoot);
    final TtsRenderQueue first = build(runner);
    final TtsRenderJob job = await first.enqueue(
      bookKey: 'book-a',
      title: 'A',
      presetId: 'v',
    );
    await _untilTerminal(first, job.id);
    await first.close();

    final Directory orphan = Directory(p.join(workRoot.path, 'stale-123'));
    await orphan.create(recursive: true);
    await File(p.join(orphan.path, 'mix.pcm')).writeAsBytes(<int>[0]);
    final File strayFile = File(p.join(workRoot.path, 'note.txt'));
    await strayFile.writeAsString('x');

    final TtsRenderQueue reopened = build(runner);
    await reopened.load();
    expect(orphan.existsSync(), isFalse);
    expect(ttsRenderJobWorkDir(workRoot, job.id).existsSync(), isTrue);
    expect(strayFile.existsSync(), isTrue, reason: '只清目录，不碰别的文件');
    expect(reopened.jobs.single.id, job.id);
    await reopened.close();
  });
}
