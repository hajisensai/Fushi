import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart';
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio_panel.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 工作台内嵌「生成字幕」在在线流上的前置一步：不自动开拉（耗流量），点「拉取音频」后
/// 显示进度、可取消；拉好原地换成生成面板；已有副本 / 同一集正在拉时直接接上；失败显示
/// 原因并可重试。ffmpeg 是替身（[gate] 放行前一直「在拉」）。
class _Backend implements FfmpegBackend {
  _Backend({this.returnCode = 0});

  final int returnCode;
  Completer<void> gate = Completer<void>();
  int calls = 0;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls++;
    await gate.future;
    if (returnCode == 0) File(args.last).writeAsBytesSync(<int>[1, 2, 3]);
    return FfmpegRunResult(
      returnCode: returnCode,
      output: returnCode == 0 ? '' : 'HTTP error 403 Forbidden',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;
  late _Backend backend;
  late VideoStreamSubtitleAudioStager stager;
  final List<String> readyFor = <String>[];
  final List<Object> failures = <Object>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('stream_audio_panel_');
    backend = _Backend();
    stager = VideoStreamSubtitleAudioStager(
      root: () async => Directory(p.join(tmp.path, 'stream_audio')),
      backend: () => backend,
    );
    readyFor.clear();
    failures.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  VideoStreamSubtitleAudioStaging start() => stager.start(
    key: 'k',
    title: 'Ep 1',
    durationMs: 0,
    prepare: () async => const VideoStreamSubtitleAudioInput(
      url: 'https://cdn.example.invalid/ep01.mp4',
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    VideoStreamSubtitleAudioStaging? Function()? startOverride,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoStreamSubtitleAudioPanel(
            existing: () => stager.existing(key: 'k', title: 'Ep 1'),
            inflight: () => stager.inflight('k'),
            start: startOverride ?? start,
            onFailed: (Object error, StackTrace _) => failures.add(error),
            ready: (File audio) async {
              readyFor.add(p.basename(audio.path));
              return (BuildContext _) =>
                  const Text('generate panel', key: ValueKey<String>('gen'));
            },
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder fetchButton() =>
      find.byKey(const ValueKey<String>('video-stream-subtitle-audio-fetch'));
  Finder progress() => find.byKey(
    const ValueKey<String>('video-stream-subtitle-audio-progress'),
  );

  /// 真实 IO（副本存在性、写文件）要在 runAsync 里跑：一边让出真实时间一边 pump，直到
  /// [cond] 成立（AnimatedSwitcher 的转场也一并走完）。
  Future<void> until(WidgetTester tester, bool Function() cond) async {
    for (int i = 0; i < 300 && !cond(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(cond(), isTrue);
    await tester.pump(const Duration(seconds: 1));
  }

  bool shown(Finder f) => f.evaluate().isNotEmpty;

  testWidgets('不自动开拉；点拉取后显示进度可取消，拉好原地换成生成面板', (WidgetTester tester) async {
    await tester.runAsync(() => pump(tester));
    await until(tester, () => shown(fetchButton()));
    expect(fetchButton(), findsOneWidget);
    expect(backend.calls, 0, reason: '拉整集要耗流量，用户点了才开始');

    await tester.tap(fetchButton());
    await until(tester, () => shown(progress()));
    expect(progress(), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-stream-subtitle-audio-cancel')),
      findsOneWidget,
    );

    backend.gate.complete();
    await until(tester, () => shown(find.byKey(const ValueKey<String>('gen'))));
    expect(readyFor, <String>['Ep 1 [k].m4a']);
    expect(find.byKey(const ValueKey<String>('gen')), findsOneWidget);
  });

  testWidgets('取消：回到「拉取音频」，不进生成面板', (WidgetTester tester) async {
    await tester.runAsync(() => pump(tester));
    await until(tester, () => shown(fetchButton()));
    await tester.tap(fetchButton());
    await until(tester, () => shown(progress()));
    await tester.tap(
      find.byKey(const ValueKey<String>('video-stream-subtitle-audio-cancel')),
    );
    // 替身后端不支持观察式运行：取消在 ffmpeg 返回后生效。
    backend.gate.complete();
    await until(
      tester,
      () => stager.inflight('k') == null && shown(fetchButton()),
    );
    expect(fetchButton(), findsOneWidget);
    expect(readyFor, isEmpty);
  });

  testWidgets('失败：显示原因、记日志，按钮变成重试', (WidgetTester tester) async {
    backend = _Backend(returnCode: 1);
    await tester.runAsync(() => pump(tester));
    await until(tester, () => shown(fetchButton()));
    await tester.tap(fetchButton());
    backend.gate.complete();
    await until(
      tester,
      () => shown(
        find.byKey(const ValueKey<String>('video-stream-subtitle-audio-error')),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('video-stream-subtitle-audio-error')),
      findsOneWidget,
    );
    expect(find.textContaining('403 Forbidden'), findsOneWidget);
    expect(failures.single, isA<VideoStreamSubtitleAudioUnavailable>());
    expect(fetchButton(), findsOneWidget);
  });

  testWidgets('已有副本：打开就是生成面板，不再拉', (WidgetTester tester) async {
    final File audio = File(p.join(tmp.path, 'stream_audio', 'Ep 1 [k].m4a'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    await tester.runAsync(() => pump(tester));
    await until(tester, () => shown(find.byKey(const ValueKey<String>('gen'))));
    expect(readyFor, <String>[p.basename(audio.path)]);
    expect(find.byKey(const ValueKey<String>('gen')), findsOneWidget);
    expect(backend.calls, 0);
  });

  testWidgets('同一集正在拉（播放器菜单那边开的）：打开就接上进度', (WidgetTester tester) async {
    final VideoStreamSubtitleAudioStaging running = start();
    await tester.runAsync(() => pump(tester));
    await until(tester, () => shown(progress()));
    backend.gate.complete();
    await until(tester, () => shown(find.byKey(const ValueKey<String>('gen'))));
    await tester.runAsync(() => running.done);
    expect(find.byKey(const ValueKey<String>('gen')), findsOneWidget);
    expect(backend.calls, 1);
  });

  testWidgets('换了集（start 给 null）：点了不开拉', (WidgetTester tester) async {
    await tester.runAsync(() => pump(tester, startOverride: () => null));
    await until(tester, () => shown(fetchButton()));
    await tester.tap(fetchButton());
    await tester.pump();
    expect(backend.calls, 0);
    expect(fetchButton(), findsOneWidget);
  });
}
