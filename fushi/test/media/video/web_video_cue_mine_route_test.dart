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

    test('拿不到媒体（流解析失败 / 缺音频中止）：退回入队，原因交给 onFallback', () async {
      final (RemoteMineResult? res, int enqueued, List<String> fb) = await run(
        () async => const RemoteMineResult(
          result: 'error',
          message: 'YouTube 视频流解析失败，未制卡',
          mediaUnavailable: true,
        ),
      );
      expect(res, isNull);
      expect(enqueued, 1);
      expect(fb, <String>['YouTube 视频流解析失败，未制卡']);
    });

    test('Anki 未配置：原样返回当场报，不入队（重放落卡也是同一处失败）', () async {
      final (RemoteMineResult? res, int enqueued, List<String> fb) = await run(
        () async => const RemoteMineResult(result: 'notConfigured'),
      );
      expect(res?.result, 'notConfigured');
      expect(enqueued, 0);
      expect(fb, isEmpty);
    });

    test('落卡阶段的 Anki 错误 / 无效时间窗：原样返回当场报，不入队', () async {
      for (final RemoteMineResult direct in const <RemoteMineResult>[
        RemoteMineResult(
          result: 'error',
          message: 'AnkiConnect 不可达',
          errorKind: RemoteMineErrorKind.transient,
          errorCode: 'ANKI_CONNECTION_REFUSED',
        ),
        RemoteMineResult(
          result: 'error',
          message: 'YouTube 字幕时间窗无效（零/负长度），未制卡',
          errorKind: RemoteMineErrorKind.permanent,
        ),
      ]) {
        final (RemoteMineResult? res, int enqueued, List<String> fb) =
            await run(() async => direct);
        expect(res, same(direct), reason: direct.message);
        expect(enqueued, 0, reason: direct.message);
        expect(fb, isEmpty, reason: direct.message);
      }
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
          mineDirect: () async =>
              const RemoteMineResult(result: 'error', mediaUnavailable: true),
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
    // 与取媒体无关的失败原样回来后两页都当场报失败，不当成功：遥控回 mining_failed，原生页
    // 网页档抛给 _trackBackgroundMine，内置档页 toast 失败原因。
    final String remote = compactCode(
      File(
        'lib/src/pages/implementations/video_fushi/remote_control.part.dart',
      ).readAsStringSync(),
    );
    for (final String src in <String>[page, remote]) {
      expect(src, contains("'error':'mining_failed'"));
    }
    expect(
      compactCode(
        methodBody(
          File(
            'lib/src/pages/implementations/video_fushi/web_source.part.dart',
          ).readAsStringSync(),
          'Future<void> _mineWebYoutubeCue(',
        ),
      ),
      contains('default:throwStateError('),
    );
    expect(
      compactCode(
        methodBody(
          File(
            'lib/src/pages/implementations/web_video_fushi_page.dart',
          ).readAsStringSync(),
          'Future<void> _mineYoutubeCueInBackground(',
        ),
      ),
      contains('t.card_export_failed_detail('),
    );
    // 制卡重放宿主页：本页弹窗制卡经 _mineLocalCue（窗口档的顶层查词窗口已随窗口档移出本页）。
    expect(
      RegExp(r'await_mineLocalCue\(').allMatches(page).length,
      greaterThanOrEqualTo(1),
    );
  });

  test('YouTube / bilibili 直裁只在取媒体那一步失败时标 mediaUnavailable', () {
    final String mine = compactCode(
      maskComments(
        methodBody(
          File('lib/src/models/app_model.dart').readAsStringSync(),
          'Future<RemoteMineResult> _mineImmersion(',
        ),
      ),
    );
    for (final String marked in <String>[
      'errorKind:youtubeMineResolveErrorKind(e),mediaUnavailable:true,',
      'detail:ytRes.abortReason,mediaUnavailable:true,',
      'detail:biRes.abortReason,mediaUnavailable:true,',
    ]) {
      expect(mine, contains(marked), reason: marked);
    }
    // 无效时间窗不标：换成重放也是同一个无效窗。
    expect(
      mine,
      isNot(
        contains('errorKind:RemoteMineErrorKind.permanent,mediaUnavailable'),
      ),
    );
  });
}
