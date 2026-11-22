import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:path/path.dart' as p;

/// 在线流「生成字幕」的取整集音频一步：判据（哪些播放形态能拉）、音源挑选（外挂 /
/// 分离音轨优先）、副本位置与稳定文件名、ffmpeg 参数（请求头、音轨映射、单声道 AAC）、
/// 拉取（现取输入只调一次、已有副本复用、同一集在途合并、失败 / 取消不留半截文件、
/// 进度按已处理时间 / 片长）。ffmpeg 是替身（按参数最后一项写出文件）。
class _Backend implements FfmpegBackend {
  _Backend({this.returnCode = 0, this.output = ''});

  final int returnCode;
  final int bytes = 1000;
  final String output;
  final List<List<String>> calls = <List<String>>[];
  Completer<void>? gate;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    await gate?.future;
    File(args.last).writeAsBytesSync(List<int>.filled(bytes, 0));
    return FfmpegRunResult(returnCode: returnCode, output: output);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 观察式后端替身：按脚本报进度；[cancel] 完成即「强杀」返回 null 退出码。
class _WatchedBackend extends _Backend implements FfmpegWatchedRunner {
  _WatchedBackend({this.progress = const <Duration>[]});

  final List<Duration> progress;
  FfmpegWatch? lastWatch;
  Completer<void>? hold;

  /// 拉取已真正起了 ffmpeg、脚本里的进度都报完时完成。测试等它，而不是 `pumpEventQueue`：
  /// 起 ffmpeg 之前还有真实文件 IO（查副本、建目录），IO 完成不在微任务 / 零延时定时器
  /// 队列里，机器一忙 20 轮事件循环就跑不到这里（dist 的 self-win 上读到 null 进度）。
  final Completer<void> reported = Completer<void>();

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    calls.add(args);
    lastWatch = watch;
    for (final Duration d in progress) {
      watch.onProgress?.call(d);
    }
    if (!reported.isCompleted) reported.complete();
    final Completer<void>? h = hold;
    if (h != null) {
      bool cancelled = false;
      await Future.any(<Future<void>>[
        h.future,
        if (watch.cancel != null)
          watch.cancel!.then((_) {
            cancelled = true;
          }),
      ]);
      if (cancelled) {
        // 真实实现强杀时 ffmpeg 可能已写出半截文件。
        File(args.last).writeAsBytesSync(<int>[1, 2, 3]);
        return const FfmpegRunResult(
          returnCode: null,
          output: kFfmpegCancelledMarker,
        );
      }
    }
    File(args.last).writeAsBytesSync(List<int>.filled(bytes, 0));
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('stream_subtitle_audio_');
    root = videoStreamSubtitleAudioRootUnder(
      Directory(p.join(tmp.path, 'video_subtitles')),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const VideoStreamSubtitleAudioInput input = VideoStreamSubtitleAudioInput(
    url: 'https://cdn.example.invalid/ep01.m3u8?sig=x',
    headers: <String, String>{
      'Referer': 'https://site.example.invalid/',
      'X-Token': 'abc',
    },
    audioStreamIndex: 1,
    audioStreamCount: 2,
  );

  group('判据与音源挑选', () {
    test('非互联远端的网络流能拉；本机文件 / 互联 host / 非远端都不走这条', () {
      expect(
        videoStreamSubtitleAudioAvailable(
          isRemote: true,
          hasHostTarget: false,
          miningSource: 'https://cdn.example.invalid/v.mp4',
          miningAudioSource: null,
        ),
        isTrue,
      );
      // 云盘流：本机中继的明文 loopback 地址也是网络流。
      expect(
        videoStreamSubtitleAudioAvailable(
          isRemote: true,
          hasHostTarget: false,
          miningSource: 'http://127.0.0.1:41234/cloud/abc',
          miningAudioSource: null,
        ),
        isTrue,
      );
      // 互联 host 的视频由 host 裁音频 / 跑管线。
      expect(
        videoStreamSubtitleAudioAvailable(
          isRemote: true,
          hasHostTarget: true,
          miningSource: 'https://host.invalid/v.mkv',
          miningAudioSource: null,
        ),
        isFalse,
      );
      expect(
        videoStreamSubtitleAudioAvailable(
          isRemote: false,
          hasHostTarget: false,
          miningSource: 'https://cdn.example.invalid/v.mp4',
          miningAudioSource: null,
        ),
        isFalse,
      );
      // 远端蓝光标题的 edl:// 不设成制卡源（miningSource 为 null）时没有可拉的流。
      expect(
        videoStreamSubtitleAudioAvailable(
          isRemote: true,
          hasHostTarget: false,
          miningSource: null,
          miningAudioSource: null,
        ),
        isFalse,
      );
    });

    test('外挂 / 分离音轨优先（纯音频，音轨下标不适用），否则读视频流本身', () {
      expect(
        currentVideoStreamSubtitleAudio(
          miningSource: 'https://g.example.invalid/video-only',
          miningAudioSource: 'http://127.0.0.1:5000/yt/audio',
        ),
        (url: 'http://127.0.0.1:5000/yt/audio', audioOnly: true),
      );
      expect(
        currentVideoStreamSubtitleAudio(
          miningSource: 'https://g.example.invalid/muxed',
          miningAudioSource: null,
        ),
        (url: 'https://g.example.invalid/muxed', audioOnly: false),
      );
      expect(
        currentVideoStreamSubtitleAudio(
          miningSource: r'C:\videos\ep01.mkv',
          miningAudioSource: null,
        ),
        isNull,
      );
    });
  });

  group('副本位置与身份', () {
    test('目录在 video_subtitles 下（存储页「字幕」类目），导出目录同根', () {
      final Directory subs = Directory(p.join(tmp.path, 'video_subtitles'));
      expect(root.path, p.join(subs.path, 'stream_audio'));
      expect(
        videoStreamSubtitleExportDirUnder(subs).path,
        p.join(subs.path, 'generated'),
      );
    });

    test('键只认来源 / 视频 / 集 / 音轨，与地址无关；文件名稳定且安全', () {
      final String a = videoStreamSubtitleAudioKey(
        sourceId: 'anime-source:x:42',
        videoId: 'ep1',
        episode: 0,
        audioTrack: 'a:-',
      );
      expect(
        videoStreamSubtitleAudioKey(
          sourceId: 'anime-source:x:42',
          videoId: 'ep1',
          episode: 0,
          audioTrack: 'a:-',
        ),
        a,
      );
      expect(a, hasLength(16));
      for (final String other in <String>[
        videoStreamSubtitleAudioKey(
          sourceId: 'anime-source:x:42',
          videoId: 'ep2',
          episode: 0,
          audioTrack: 'a:-',
        ),
        videoStreamSubtitleAudioKey(
          sourceId: 'anime-source:x:42',
          videoId: 'ep1',
          episode: 1,
          audioTrack: 'a:-',
        ),
        videoStreamSubtitleAudioKey(
          sourceId: 'anime-source:x:42',
          videoId: 'ep1',
          episode: 0,
          audioTrack: 'a:1',
        ),
      ]) {
        expect(other, isNot(a));
      }
      final File f = videoStreamSubtitleAudioFileIn(
        root,
        key: a,
        title: 'Re:Zero / 第1話',
      );
      expect(p.dirname(f.path), root.path);
      expect(p.basename(f.path), endsWith(' [$a].m4a'));
      expect(p.basename(f.path), isNot(contains(':')));
      expect(p.basename(f.path), isNot(contains('/')));
      expect(
        p.basename(
          videoStreamSubtitleAudioFileIn(root, key: a, title: '  ').path,
        ),
        'stream [$a].m4a',
      );
    });
  });

  test('ffmpeg 参数：请求头下发、按当前音轨映射、单声道 64k AAC、mp4 容器、输出在最后', () {
    final List<String> args = videoStreamSubtitleAudioArgs(
      input: input,
      outputPath: '/out/a.m4a.part',
    );
    expect(args.last, '/out/a.m4a.part');
    expect(args, contains('-headers'));
    expect(args[args.indexOf('-referer') + 1], 'https://site.example.invalid/');
    expect(args[args.indexOf('-i') + 1], input.url);
    expect(args[args.indexOf('-map') + 1], '0:a:1?');
    expect(args[args.indexOf('-ac') + 1], '1');
    expect(args[args.indexOf('-c:a') + 1], 'aac');
    expect(args[args.indexOf('-b:a') + 1], '64k');
    expect(args[args.indexOf('-f') + 1], 'mp4');
    expect(args, containsAll(<String>['-vn', '-sn', '-dn']));
    // 纯音频流（只有一条音轨）不映射。
    final List<String> audioOnly = videoStreamSubtitleAudioArgs(
      input: const VideoStreamSubtitleAudioInput(
        url: 'https://cdn.example.invalid/a.m4a',
      ),
      outputPath: '/out/b.m4a.part',
    );
    expect(audioOnly, isNot(contains('-map')));
  });

  group('拉取', () {
    test('现取输入只调一次，写到稳定文件名；已有副本直接复用、不再取流', () async {
      final _Backend backend = _Backend();
      final VideoStreamSubtitleAudioStager stager =
          VideoStreamSubtitleAudioStager(
            root: () async => root,
            backend: () => backend,
          );
      int prepared = 0;
      Future<VideoStreamSubtitleAudioInput> prepare() async {
        prepared++;
        return input;
      }

      expect(await stager.existing(key: 'k1', title: 'Ep 1'), isNull);
      final VideoStreamSubtitleAudioStaging staging = stager.start(
        key: 'k1',
        title: 'Ep 1',
        durationMs: 60000,
        prepare: prepare,
      );
      final File audio = await staging.done;
      expect(audio.path, p.join(root.path, 'Ep 1 [k1].m4a'));
      expect(audio.existsSync(), isTrue);
      expect(File('${audio.path}.part').existsSync(), isFalse);
      expect(prepared, 1);
      expect(backend.calls.single.last, '${audio.path}.part');
      expect(staging.progress.value, 1);
      expect(
        (await stager.existing(key: 'k1', title: 'Ep 1'))?.path,
        audio.path,
      );
      expect(stager.inflight('k1'), isNull);

      final File again = await stager
          .start(key: 'k1', title: 'Ep 1', durationMs: 60000, prepare: prepare)
          .done;
      expect(again.path, audio.path);
      expect(prepared, 1, reason: '已有副本不再现取地址');
      expect(backend.calls, hasLength(1));
    });

    test('同一集同时两个入口：合并成同一次在途拉取', () async {
      final _Backend backend = _Backend()..gate = Completer<void>();
      final VideoStreamSubtitleAudioStager stager =
          VideoStreamSubtitleAudioStager(
            root: () async => root,
            backend: () => backend,
          );
      int prepared = 0;
      final VideoStreamSubtitleAudioStaging a = stager.start(
        key: 'k2',
        title: 'Ep 2',
        durationMs: 0,
        prepare: () async {
          prepared++;
          return input;
        },
      );
      final VideoStreamSubtitleAudioStaging b = stager.start(
        key: 'k2',
        title: 'Ep 2',
        durationMs: 0,
        prepare: () async => fail('second prepare must not run'),
      );
      expect(identical(a, b), isTrue);
      expect(stager.inflight('k2'), same(a));
      backend.gate!.complete();
      expect((await a.done).path, (await b.done).path);
      expect(prepared, 1);
    });

    test('取流失败 / ffmpeg 失败：如实报出原因，不留半截文件', () async {
      final VideoStreamSubtitleAudioStager refused =
          VideoStreamSubtitleAudioStager(
            root: () async => root,
            backend: () => _Backend(),
          );
      await expectLater(
        refused
            .start(
              key: 'k3',
              title: 'Ep 3',
              durationMs: 0,
              prepare: () async => throw const HttpException('403 signed'),
            )
            .done,
        throwsA(
          isA<VideoStreamSubtitleAudioUnavailable>().having(
            (VideoStreamSubtitleAudioUnavailable e) => e.message,
            'message',
            contains('403 signed'),
          ),
        ),
      );

      final _Backend broken = _Backend(
        returnCode: 1,
        output: 'line 1\nServer returned 403 Forbidden',
      );
      final VideoStreamSubtitleAudioStager stager =
          VideoStreamSubtitleAudioStager(
            root: () async => root,
            backend: () => broken,
          );
      await expectLater(
        stager
            .start(
              key: 'k3',
              title: 'Ep 3',
              durationMs: 0,
              prepare: () async => input,
            )
            .done,
        throwsA(
          isA<VideoStreamSubtitleAudioUnavailable>().having(
            (VideoStreamSubtitleAudioUnavailable e) => e.message,
            'message',
            contains('403 Forbidden'),
          ),
        ),
      );
      expect(root.listSync(), isEmpty);
      expect(stager.inflight('k3'), isNull, reason: '失败后下次重新拉');
    });

    test('观察式后端：进度 = 已处理时间 / 片长；取消强杀并删半截文件', () async {
      final _WatchedBackend watched = _WatchedBackend(
        progress: const <Duration>[
          Duration(seconds: 15),
          Duration(seconds: 30),
        ],
      )..hold = Completer<void>();
      final VideoStreamSubtitleAudioStager stager =
          VideoStreamSubtitleAudioStager(
            root: () async => root,
            backend: () => watched,
          );
      final VideoStreamSubtitleAudioStaging staging = stager.start(
        key: 'k4',
        title: 'Ep 4',
        durationMs: 60000,
        prepare: () async => input,
      );
      await watched.reported.future;
      expect(staging.progress.value, closeTo(0.5, 1e-9));
      expect(
        watched.lastWatch!.stallTimeout,
        kVideoStreamSubtitleAudioStallTimeout,
      );
      staging.cancel();
      await expectLater(
        staging.done,
        throwsA(isA<VideoStreamSubtitleAudioCancelled>()),
      );
      expect(root.listSync(), isEmpty);
      expect(stager.inflight('k4'), isNull);
    });

    test('取流阶段就取消：取完即放弃，不起 ffmpeg', () async {
      final _Backend backend = _Backend();
      final VideoStreamSubtitleAudioStager stager =
          VideoStreamSubtitleAudioStager(
            root: () async => root,
            backend: () => backend,
          );
      final Completer<VideoStreamSubtitleAudioInput> slow =
          Completer<VideoStreamSubtitleAudioInput>();
      final VideoStreamSubtitleAudioStaging staging = stager.start(
        key: 'k5',
        title: 'Ep 5',
        durationMs: 0,
        prepare: () => slow.future,
      );
      staging.cancel();
      slow.complete(input);
      await expectLater(
        staging.done,
        throwsA(isA<VideoStreamSubtitleAudioCancelled>()),
      );
      expect(backend.calls, isEmpty);
    });
  });
}
