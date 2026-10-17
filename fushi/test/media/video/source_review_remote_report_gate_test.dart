import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/source_review_remote_report_gate.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

/// 记录所有会改服务器进度的调用；其余成员一律不该被碰到。
class _RecordingClient
    implements RemoteVideoClient, RemoteVideoPlaybackSession {
  final List<String> calls = <String>[];

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async => calls.add('position $id $positionMs ep$episodeIndex');

  @override
  Future<void> startRemoteVideoPlayback(String id, int positionMs) async =>
      calls.add('start $id $positionMs');

  @override
  Future<void> setRemoteVideoPlaybackPaused(
    String id,
    int positionMs, {
    required bool paused,
  }) async => calls.add('paused $id $positionMs $paused');

  @override
  Future<void> stopRemoteVideoPlayback(String id, int positionMs) async =>
      calls.add('stop $id $positionMs');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

/// 只有断点上报、没有会话协议的来源（互联 host / 云盘）。
class _PositionOnlyClient implements RemoteVideoClient {
  final List<String> calls = <String>[];

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async => calls.add('position $id $positionMs');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

/// BUG-3490：卡片片段回看直接串流远端视频，「不影响服务器进度」由闸门保证——
/// 回看中起播 / 心跳 / 暂停 / 停止一条都不发；「从这里继续观看」之后恢复正常上报。
void main() {
  Future<void> reportAll(
    SourceReviewRemoteReportGate gate,
    _RecordingClient client,
  ) async {
    await gate.start(client, 'ep5', 61000);
    await gate.position(client, 'ep5', 62000, 1, episodeIndex: 0);
    await gate.paused(client, 'ep5', 63000, paused: true);
    await gate.paused(client, 'ep5', 63000, paused: false);
    await gate.stop(client, 'ep5', 64000);
  }

  test('回看中四类上报一条都不发', () async {
    final _RecordingClient client = _RecordingClient();
    final SourceReviewRemoteReportGate gate = SourceReviewRemoteReportGate(
      isReview: () => true,
    );
    expect(gate.suppressed, isTrue);
    expect(await gate.start(client, 'ep5', 61000), isFalse);
    expect(await gate.position(client, 'ep5', 62000, 1), isFalse);
    expect(await gate.paused(client, 'ep5', 63000, paused: true), isFalse);
    expect(await gate.stop(client, 'ep5', 64000), isFalse);
    expect(client.calls, isEmpty);
  });

  test('回看态每次现读：继续观看之后恢复上报，之前的一条也不补发', () async {
    final _RecordingClient client = _RecordingClient();
    bool review = true;
    final SourceReviewRemoteReportGate gate = SourceReviewRemoteReportGate(
      isReview: () => review,
    );
    await reportAll(gate, client);
    expect(client.calls, isEmpty);

    review = false; // 「从这里继续观看」
    await reportAll(gate, client);
    expect(client.calls, <String>[
      'start ep5 61000',
      'position ep5 62000 ep0',
      'paused ep5 63000 true',
      'paused ep5 63000 false',
      'stop ep5 64000',
    ]);
  });

  test('非回看时负位置钳到 0', () async {
    final _RecordingClient client = _RecordingClient();
    final SourceReviewRemoteReportGate gate = SourceReviewRemoteReportGate(
      isReview: () => false,
    );
    await gate.start(client, 'a', -5);
    await gate.stop(client, 'a', -1);
    expect(client.calls, <String>['start a 0', 'stop a 0']);
  });

  test('没有会话协议的来源：会话类上报跳过，断点上报照常', () async {
    final _PositionOnlyClient client = _PositionOnlyClient();
    final SourceReviewRemoteReportGate gate = SourceReviewRemoteReportGate(
      isReview: () => false,
    );
    expect(await gate.start(client, 'a', 1000), isFalse);
    expect(await gate.paused(client, 'a', 1000, paused: true), isFalse);
    expect(await gate.stop(client, 'a', 1000), isFalse);
    expect(await gate.position(client, 'a', 1000, 1), isTrue);
    expect(client.calls, <String>['position a 1000']);
  });

  group('回看中的播放选择：暂存，继续观看时补存', () {
    test('回看中不写；继续后按正常逻辑补存，同种只留最后一次', () async {
      bool review = true;
      final List<String> writes = <String>[];
      final SourceReviewDeferredWrites<String> deferred =
          SourceReviewDeferredWrites<String>(isReview: () => review);
      await deferred.save('audio', () async => writes.add('audio 2'));
      await deferred.save('subtitle', () async => writes.add('sub ja.srt'));
      await deferred.save('audio', () async => writes.add('audio 3'));
      expect(writes, isEmpty);
      expect(deferred.pendingKinds, <String>['audio', 'subtitle']);

      review = false; // 「从这里继续观看」
      await deferred.flush();
      expect(writes, <String>['audio 3', 'sub ja.srt']);
      expect(deferred.pendingKinds, isEmpty);

      // 继续之后的切换立即保存。
      await deferred.save('audio', () async => writes.add('audio 4'));
      expect(writes.last, 'audio 4');
      await deferred.flush();
      expect(writes, hasLength(3));
    });

    test('作废的种类不补存；单条失败不影响其余', () async {
      bool review = true;
      final List<String> writes = <String>[];
      final List<Object> errors = <Object>[];
      final SourceReviewDeferredWrites<String> deferred =
          SourceReviewDeferredWrites<String>(isReview: () => review);
      await deferred.save('subtitle', () async => writes.add('deleted.srt'));
      await deferred.save('audio', () async => throw StateError('offline'));
      await deferred.save('delay', () async => writes.add('delay +200'));
      // 字幕文件被删：清理照常执行，暂存的那次选择作废。
      deferred.discard('subtitle');

      review = false;
      await deferred.flush(onError: errors.add);
      expect(writes, <String>['delay +200']);
      expect(errors, hasLength(1));
    });

    test('回看中退出（不 flush）即整批丢弃', () async {
      final List<String> writes = <String>[];
      final SourceReviewDeferredWrites<String> deferred =
          SourceReviewDeferredWrites<String>(isReview: () => true);
      await deferred.save('audio', () async => writes.add('audio 2'));
      expect(writes, isEmpty);
    });
  });
}
