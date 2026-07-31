import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

class _RecordingRepo implements BaseAnkiRepository {
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    payloads.add(
      Map<String, dynamic>.from(
        jsonDecode(rawPayloadJson) as Map<String, dynamic>,
      ),
    );
    return MineOutcome.success(noteId: payloads.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('视频制卡历史快照冻结字段、标题与集定位，不读取换集后状态', () {
    final Map<String, String> fields = <String, String>{
      'expression': 'old expression',
      'reading': 'old reading',
      'glossary': 'old glossary',
    };
    final VideoMiningHistorySnapshot snapshot =
        VideoMiningHistorySnapshot.capture(
      fields: fields,
      sentence: 'old sentence',
      documentTitle: 'Old episode',
      bookKey: 'old-book',
      sectionIndex: 1,
      cueStartMs: 1200,
      cueEndMs: 2450,
      dateKey: '2026-07-29',
    );

    // 模拟任务排队期间 popup fields 与远端当前集都已切到下一集。
    fields
      ..['expression'] = 'new expression'
      ..['reading'] = 'new reading'
      ..['glossary'] = 'new glossary';

    expect(snapshot.expression, 'old expression');
    expect(snapshot.reading, 'old reading');
    expect(snapshot.glossary, 'old glossary');
    expect(snapshot.sentence, 'old sentence');
    expect(snapshot.documentTitle, 'Old episode');
    expect(snapshot.bookKey, 'old-book');
    expect(snapshot.sectionIndex, 1);
    expect(snapshot.normCharOffset, 1200);
    expect(snapshot.normCharLength, 1250);
    expect(snapshot.dateKey, '2026-07-29');
  });

  test('连续制卡整笔串行，换集后仍使用各自入队快照', () async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('immersion_mining_queue');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    final Completer<void> firstStarted = Completer<void>();
    final Completer<void> releaseFirst = Completer<void>();
    final Completer<String> firstTempDir = Completer<String>();
    final List<String> startedSources = <String>[];

    Future<String?> gif({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      int fps = 8,
      int width = 320,
      MiningAnimatedFormat format = MiningAnimatedFormat.gif,
      FfmpegFailureReporter? onFailure,
      String? tlsPinSha256,
    }) async {
      startedSources.add(inputPath);
      if (inputPath == '/episode-1.mp4') {
        firstStarted.complete();
        await releaseFirst.future;
      }
      return outputPath;
    }

    Future<String?> audio({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      int? audioStreamIndex,
      int? audioStreamCount,
      FfmpegFailureReporter? onFailure,
      int audioChannels = 1,
      String audioBitrate = '64k',
      String? tlsPinSha256,
    }) async =>
        outputPath;

    final ImmersionMiningEngine engine = ImmersionMiningEngine(
      gifExtractor: gif,
      audioExtractor: audio,
    );
    final _RecordingRepo repo = _RecordingRepo();
    final Map<String, String> firstFields = <String, String>{
      'expression': 'episode one',
    };

    final Future<ImmersionMiningResult> first = engine.mine(
      ImmersionMiningRequest(
        fields: firstFields,
        clipStartMs: 1000,
        clipEndMs: 2000,
        sentence: 'first',
        mediaSource: '/episode-1.mp4',
        source: AnkiMiningSource.video,
      ),
      compression: MiningMediaCompression.highFidelity,
      tempDir: firstTempDir.future,
      repo: repo,
    );

    final Future<ImmersionMiningResult> second = engine.mine(
      const ImmersionMiningRequest(
        fields: <String, String>{'expression': 'episode two'},
        clipStartMs: 3000,
        clipEndMs: 4000,
        sentence: 'second',
        mediaSource: '/episode-2.mp4',
        source: AnkiMiningSource.video,
      ),
      compression: MiningMediaCompression.highFidelity,
      tempDir: tmp.path,
      repo: repo,
    );

    // 模拟弹窗字段和当前播放集在任务等待期间已经变化。
    firstFields['expression'] = 'mutated after enqueue';
    await Future<void>.delayed(Duration.zero);
    expect(
      startedSources,
      isEmpty,
      reason: '第一张仍在解析临时目录时，第二张也不得越过它先执行',
    );

    firstTempDir.complete(tmp.path);
    await firstStarted.future;
    expect(
      startedSources,
      <String>['/episode-1.mp4'],
      reason: '第一集整笔任务完成前，第二集不得开始抽媒体',
    );

    releaseFirst.complete();
    await Future.wait<ImmersionMiningResult>(
      <Future<ImmersionMiningResult>>[first, second],
    );

    expect(
      startedSources,
      <String>['/episode-1.mp4', '/episode-2.mp4'],
      reason: '换集只改变后续入队快照，不取消或篡改第一集任务',
    );
    expect(
      repo.payloads.map((Map<String, dynamic> p) => p['expression']),
      <String>['episode one', 'episode two'],
      reason: '字段必须在入队时冻结，不能读到弹窗后续修改',
    );
  });
}
