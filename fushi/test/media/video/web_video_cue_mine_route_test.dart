import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_session.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

import '../../helpers/source_guard.dart';

/// gap-webvideo-4：网页视频一句制卡的分流（[webVideoDirectMineVideoId] +
/// [mineWebVideoCueDirectOrQueue]）。内置网页播放器页的本页 / 顶层查词窗口 / 手机遥控制卡与
/// 原生播放器页网页档的制卡共用：YouTube 直裁，裁不出来退回制卡队列；其它站点直接入队。
void main() {
  group('webVideoDirectMineVideoId', () {
    test('YouTube 观看页 / 短链能直裁，返回视频 id', () {
      expect(
        webVideoDirectMineVideoId(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        webVideoDirectMineVideoId('https://youtu.be/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('其它站点只能进队列重放', () {
      expect(
        webVideoDirectMineVideoId('https://www.netflix.com/watch/81234567'),
        isNull,
      );
    });
  });

  group('mineWebVideoCueDirectOrQueue', () {
    Future<(RemoteMineResult?, int, List<String>)> run(
      Future<RemoteMineResult> Function() mineDirect,
    ) async {
      int enqueued = 0;
      final List<String> fallbacks = <String>[];
      final RemoteMineResult? res = await mineWebVideoCueDirectOrQueue(
        mineDirect: mineDirect,
        enqueue: () async => enqueued++,
        onFallback: fallbacks.add,
      );
      return (res, enqueued, fallbacks);
    }

    test('直裁成功：原样返回，不入队', () async {
      final (RemoteMineResult? res, int enqueued, List<String> fb) = await run(
        () async => const RemoteMineResult(result: 'success', deckName: 'D'),
      );
      expect(res?.result, 'success');
      expect(res?.deckName, 'D');
      expect(enqueued, 0);
      expect(fb, isEmpty);
    });

    test('重复卡：原样返回，不入队（重放出来还是同一张重复卡）', () async {
      final (RemoteMineResult? res, int enqueued, _) = await run(
        () async => const RemoteMineResult(result: 'duplicate'),
      );
      expect(res?.result, 'duplicate');
      expect(enqueued, 0);
    });

    test('直裁报错（流解析失败 / 缺音频中止）：退回入队，原因交给 onFallback', () async {
      final (RemoteMineResult? res, int enqueued, List<String> fb) = await run(
        () async => const RemoteMineResult(
          result: 'error',
          message: 'YouTube 视频流解析失败，未制卡',
        ),
      );
      expect(res, isNull);
      expect(enqueued, 1);
      expect(fb, <String>['YouTube 视频流解析失败，未制卡']);
    });

    test('直裁抛出：同样退回入队', () async {
      final (RemoteMineResult? res, int enqueued, List<String> fb) = await run(
        () async => throw StateError('resolver down'),
      );
      expect(res, isNull);
      expect(enqueued, 1);
      expect(fb.single, contains('resolver down'));
    });

    test('退回入队也失败：向外抛，调用方报错', () async {
      await expectLater(
        mineWebVideoCueDirectOrQueue(
          mineDirect: () async => const RemoteMineResult(result: 'error'),
          enqueue: () async => throw StateError('db closed'),
        ),
        throwsStateError,
      );
    });
  });

  test('三处制卡入口都走同一条分流，不再各自判 YouTube', () {
    final String page = compactCode(
      File(
        'lib/src/pages/implementations/web_video_fushi_page.dart',
      ).readAsStringSync(),
    );
    final String native = compactCode(
      File(
        'lib/src/pages/implementations/video_fushi/web_source.part.dart',
      ).readAsStringSync(),
    );
    for (final String src in <String>[page, native]) {
      expect(src, contains('mineWebVideoCueDirectOrQueue('));
      expect(src, isNot(contains('youtubeVideoIdOrNull(')));
    }
    // 内置档页：本页弹窗与顶层查词窗口都经 _mineLocalCue，遥控经同一 helper。
    expect(
      RegExp(r'await_mineLocalCue\(').allMatches(page).length,
      greaterThanOrEqualTo(2),
    );
  });
}
