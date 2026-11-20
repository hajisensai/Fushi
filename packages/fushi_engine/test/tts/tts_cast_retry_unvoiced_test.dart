import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:test/test.dart';

/// 小说选角表的本书重试候选声音、制作任务的未配音句数：落盘往返与叠在系列上的顺序。
void main() {
  test('TtsCast retry voices round-trip and come before the series', () {
    final TtsCast cast = TtsCast(retryVoices: <String>['b1', 'shared']);
    final TtsCast back = TtsCast.fromJson(cast.toJson());
    expect(back.retryVoices, <String>['b1', 'shared']);
    back.series = CastVoiceAssignment(retryVoices: <String>['shared', 's1']);
    expect(back.ownAssignment.retryVoicesOver(back.series), <String>[
      'b1',
      'shared',
      's1',
    ]);
    // 没设过的不写进文件。
    expect(TtsCast().toJson().containsKey('retry'), isFalse);
    expect(TtsCast.fromJson(TtsCast().toJson()).retryVoices, isEmpty);
  });

  test('TtsRenderJob keeps the unvoiced count', () {
    final TtsRenderJob job = TtsRenderJob(
      id: 'j',
      bookKey: 'b',
      title: 't',
      presetId: 'p',
      sections: const <int>[],
      verify: false,
      createdAt: 0,
      updatedAt: 0,
    )..unvoiced = 3;
    expect(TtsRenderJob.fromJson(job.toJson()).unvoiced, 3);
    job.unvoiced = 0;
    expect(job.toJson().containsKey('unvoiced'), isFalse);
    expect(TtsRenderJob.fromJson(job.toJson()).unvoiced, 0);
  });
}
