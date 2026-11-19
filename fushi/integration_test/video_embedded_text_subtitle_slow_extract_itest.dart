// PR #3679 的后续（反馈 ZTDA2WQJj4「切内封字幕时字幕菜单置灰一分多钟」）：真 app、真
// media_kit、真 ffmpeg，本地视频内封文本轨的整轨抽取**还没完成**时的行为。
//
// 怎么造慢：把 ffmpeg 后端换成一层闸门（[_GatedExtractBackend]）：枚举（`ffmpeg -i`）
// 照常直通，整轨抽取（`runWatched`）先挂在闸门上，测试放闸才交给真 ffmpeg 跑；挂着时
// 收到取消信号就按真 runner 的约定返回「已取消」。与真实慢盘的差别：闸门挡的是抽取
// 「开始」，期间没有真实的读盘吞吐、也没有与 libmpv 抢盘，播放本身不受影响；按进度判活
// 的看门狗在闸门放开前不计时（真慢盘上它一直看得到进度在走，同样不会判卡死）。要观察的
// 是「抽取期间」页面与播放器的状态，这一层与真慢盘一致：抽取在途、结果迟迟不到。
//
// 素材与 video_embedded_text_subtitle_switch_itest.dart 同款：ffmpeg 生成 60 秒 mkv，内封
// jpn / eng / chi 三条 subrip 轨（12 / 10 / 8 句，文本互异），无外挂。
//
// 流程：
//  A. 打开视频，默认 jpn 轨自动加载 → 抽取挂在闸门上 → 播放器解码的 jpn 句子即时上屏
//     （可点 overlay），字幕面板顶部出现「正在读取完整字幕」行，其余行不禁用；截图 01。
//  B. 抽取还挂着时经页面选字幕入口改选 eng（不报「正在加载」忙）→ eng 句子即时上屏；
//     截图 02。
//  C. 放闸：同一次抽取完成；eng 换成完整 10 句（自动加载的 jpn 结果不得盖掉用户选的
//     eng），换装那一刻 overlay 当前句不出现「同一句 → 空 → 同一句」；截图 03。
//  D. 删掉缓存、合上闸门，改选 chi → 新的抽取挂着、chi 句子即时上屏；按「停止读取」→ ffmpeg 被取消、无在途抽取、读取行消失，chi 字幕继续随播放出现；
//     截图 04。
//  E. Escape 退出播放页，无残留在途抽取。
//
// 选字幕入口同 switch itest：调页面登记的 [VideoPlayerRemoteControl.selectSubtitle]，与
// 面板字幕行 onTap 是同一个 `_selectSubtitleSource`；字幕面板经测试钩子
// `debugOpenSubtitleSettings` 打开（离屏没有打开字幕分类的快捷键）。「停止读取」按钮
// 不能焦点驱动：字幕面板按设计不接焦点（BUG-2040，见 D 段注释），改为调它的 onPressed。
//
// 截图不用 captureFlutterFrame：它先 pumpAndSettle，而这里视频在播、读取行的转圈是无限
// 动画，永远 settle 不了。[_capture] 用同一套 RenderView 图层取图，只是不等 settle。
//
// 两个坑：app 的 main 换掉 FlutterError.onError（先存、finally 里还原后再断言）；关键
// 观测同时追加写进 `<FUSHI_TEST_ROOT>/embedded-sub-slow-report.txt`。
//
// 跑法（在 fushi/ 下）：
//   dart tool/heavy.dart --max-minutes=25 -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/video_embedded_text_subtitle_slow_extract_itest.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/rendering.dart' show OffsetLayer, RenderView;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/media/video/video_playback_remote.dart'
    show
        VideoPlayerRemoteControl,
        VideoRemoteSubtitleKind,
        VideoRemoteSubtitleState,
        VideoRemoteSubtitleTrack,
        videoPlaybackRemotes;
import 'package:fushi/src/media/video/video_player_controller.dart'
    show VideoPlayerController;
import 'package:fushi/src/media/video/video_subtitle_overlay.dart'
    show VideoSubtitleOverlay;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiListTileControl;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show debugEmbeddedSubtitleExtractInFlight, embeddedSubtitleCacheDir;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart' show observeScreenshotDir;
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[embedded-sub-slow]';

class _TrackSpec {
  const _TrackSpec(this.language, this.prefix, this.count);

  final String language;
  final String prefix;
  final int count;

  String textAt(int i) => '$prefix ${i + 1}';
}

const List<_TrackSpec> _kTracks = <_TrackSpec>[
  _TrackSpec('jpn', 'にほんご字幕', 12),
  _TrackSpec('eng', 'English line', 10),
  _TrackSpec('chi', '中文字幕', 8),
];

final String _kTestRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

Future<void> _note(String line) async {
  debugPrint('$_tag $line');
  if (_kTestRoot.isEmpty) return;
  await File(
    '$_kTestRoot${Platform.pathSeparator}embedded-sub-slow-report.txt',
  ).writeAsString('$line\n', mode: FileMode.append, flush: true);
}

/// 整轨抽取挂在闸门上；其余 ffmpeg 调用直通真后端。
class _GatedExtractBackend implements FfmpegBackend, FfmpegWatchedRunner {
  _GatedExtractBackend(this.inner);

  final FfmpegBackend inner;
  Completer<void> _gate = Completer<void>();
  int held = 0;
  int cancelled = 0;
  int passed = 0;

  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }

  void close() {
    if (_gate.isCompleted) _gate = Completer<void>();
  }

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      inner.run(args, timeout);

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      inner.runQuery(args, timeout);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      inner.runProbe(args, timeout);

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    held++;
    final Future<void> gate = _gate.future;
    final bool wasCancelled;
    try {
      final Future<void>? cancel = watch.cancel;
      wasCancelled = await Future.any(<Future<bool>>[
        gate.then((_) => false),
        if (cancel != null) cancel.then((_) => true),
      ]);
    } finally {
      held--;
    }
    if (wasCancelled) {
      cancelled++;
      return const FfmpegRunResult(
        returnCode: null,
        output: kFfmpegCancelledMarker,
      );
    }
    passed++;
    return (inner as FfmpegWatchedRunner).runWatched(args, watch);
  }
}

String _srtTime(int ms) {
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(ms ~/ 3600000)}:${p(ms ~/ 60000 % 60)}:${p(ms ~/ 1000 % 60)},'
      '${p(ms % 1000, 3)}';
}

String _srtFor(_TrackSpec spec) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < spec.count; i++) {
    final int start = 1000 + i * 4500;
    b
      ..writeln(i + 1)
      ..writeln('${_srtTime(start)} --> ${_srtTime(start + 3000)}')
      ..writeln(spec.textAt(i))
      ..writeln();
  }
  return b.toString();
}

Future<(String, String)> _seedVideo(
  VideoBookRepository repo,
  FfmpegBackend ffmpeg,
) async {
  final Directory dir = _kTestRoot.isEmpty
      ? await Directory.systemTemp.createTemp('fushi_embsub_slow_')
      : Directory('$_kTestRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  final String sep = Platform.pathSeparator;
  final List<String> srtPaths = <String>[];
  for (final _TrackSpec spec in _kTracks) {
    final File f = File('${dir.path}${sep}embslow_${spec.language}.srt');
    await f.writeAsString(_srtFor(spec), flush: true);
    srtPaths.add(f.path);
  }
  final String videoPath = File(
    '${dir.path}${sep}embedded-sub-slow.mkv',
  ).absolute.path;
  final FfmpegRunResult r = await ffmpeg.run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=640x360:rate=24',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=mono',
    for (final String p in srtPaths) ...<String>['-i', p],
    '-map',
    '0:v',
    '-map',
    '1:a',
    for (int i = 0; i < srtPaths.length; i++) ...<String>['-map', '${i + 2}:0'],
    '-t',
    '60',
    '-c:v',
    'mpeg4',
    '-q:v',
    '5',
    '-c:a',
    'aac',
    '-c:s',
    'srt',
    for (int i = 0; i < _kTracks.length; i++) ...<String>[
      '-metadata:s:s:$i',
      'language=${_kTracks[i].language}',
    ],
    videoPath,
  ], const Duration(seconds: 180));
  if (!r.isSuccess) {
    throw StateError('ffmpeg 生成素材失败: ${r.failureSummary}');
  }
  final String bookUid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: const Value('embedded-sub-slow'),
      videoPath: Value(videoPath),
    ),
  );
  return (bookUid, videoPath);
}

_TrackSpec? _matchTrack(List<AudioCue> cues) {
  for (final _TrackSpec spec in _kTracks) {
    if (cues.length != spec.count) continue;
    bool all = true;
    for (int i = 0; i < cues.length; i++) {
      if (cues[i].text.trim() != spec.textAt(i)) {
        all = false;
        break;
      }
    }
    if (all) return spec;
  }
  return null;
}

String _describeCues(List<AudioCue> cues) => cues.isEmpty
    ? 'cues=0'
    : 'cues=${cues.length} first="${cues.first.text}" last="${cues.last.text}"';

VideoPlayerController? _overlayController() {
  final Finder f = find.byType(VideoSubtitleOverlay);
  if (f.evaluate().isEmpty) return null;
  return (f.evaluate().first.widget as VideoSubtitleOverlay).controller;
}

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required Duration timeout,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (done()) return true;
    await tester.pump(const Duration(milliseconds: 200));
  }
  return done();
}

/// 根 RenderView 图层取图落盘（同 captureFlutterFrame 的取法，不等 settle）。
Future<String> _capture(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer? layer = view.debugLayer as OffsetLayer?;
  if (layer == null) return '(no layer)';
  final ui.Image image = await layer.toImage(view.paintBounds);
  try {
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (png == null) return '(encode failed)';
    final String path = '${observeScreenshotDir().path}/$name.png';
    await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);
    return path;
  } finally {
    image.dispose();
  }
}

VideoRemoteSubtitleTrack _trackFor(
  VideoRemoteSubtitleState state,
  _TrackSpec spec,
) => state.tracks.firstWhere(
  (VideoRemoteSubtitleTrack t) =>
      t.kind == VideoRemoteSubtitleKind.embedded && t.language == spec.language,
);

bool _tileEnabled(String key) {
  final Finder f = find.byKey(ValueKey<String>(key));
  if (f.evaluate().isEmpty) return false;
  return (f.evaluate().first.widget as FushiListTileControl).enabled;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('内封文本轨抽取期间：先出字、菜单可改选、可停止、完整列表不覆盖新选择', (
    WidgetTester tester,
  ) async {
    final void Function(FlutterErrorDetails)? originalOnError =
        FlutterError.onError;
    final FfmpegBackend realFfmpeg = resolveFfmpegBackend();
    final _GatedExtractBackend gate = _GatedExtractBackend(realFfmpeg);

    String? flowError;
    String? path;
    // A
    bool autoLive = false;
    String? autoLiveText;
    int autoLiveCueCount = -1;
    int heldDuringAuto = -1;
    bool pendingRowShown = false;
    bool offRowEnabled = false;
    String? sourceDuringAuto;
    String? autoLanguage;
    String? pickBLanguage;
    String? pickDLanguage;
    String? expectedAutoSource;
    String? expectedBSource;
    String? expectedDSource;
    // B
    bool engLive = false;
    String? engLiveText;
    String? sourceAfterEng;
    // C
    String? fullTrack;
    String? sourceAfterFull;
    bool liveAfterFull = true;
    bool pendingGoneAfterFull = false;
    String? stillEngAfterSettle;
    final List<String?> swapSamples = <String?>[];
    // D
    bool chiLive = false;
    int heldDuringChi = -1;
    bool stopFocused = false;
    bool stopObserved = false;
    int cancelledCount = -1;
    bool? inFlightAfterStop;
    bool pendingGoneAfterStop = false;
    bool liveAfterStop = false;
    String? sourceAfterStop;
    int chiCuesAtStop = -1;
    int chiCuesLater = -1;
    // E
    bool pageGone = false;
    bool? inFlightAfterExit;
    final List<String> shots = <String>[];

    try {
      if (_kTestRoot.isNotEmpty) {
        final File report = File(
          '$_kTestRoot${Platform.pathSeparator}embedded-sub-slow-report.txt',
        );
        if (report.existsSync()) report.deleteSync();
      }
      await launchFushiTestApp();
      if (!await waitForHome(tester)) throw StateError('主页 90s 内未出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final (String uid, String videoPath) = await _seedVideo(repo, realFfmpeg);
      path = videoPath;
      final Directory cache = await embeddedSubtitleCacheDir(videoPath);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
      await _note('seeded video=$videoPath');
      setFfmpegBackendForTesting(gate);

      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
      final bool pageUp = await _pumpUntil(
        tester,
        () => find.byType(VideoFushiPage).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      if (!pageUp) throw StateError('播放页 60s 内没打开');
      VideoFushiTestHooks hooks() =>
          tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
              as VideoFushiTestHooks;
      await _pumpUntil(
        tester,
        () => hooks().debugPositionMs != null,
        timeout: const Duration(seconds: 30),
      );
      await hooks().debugPlay();

      // A. 自动加载：抽取挂着，播放器解码的 jpn 句子上屏。
      // 自动加载挑哪条轨取决于主字幕默认语言偏好（测试根里没设 = 第一条文本轨），
      // 按上屏文本认出是哪条，后面改选另外两条。
      _TrackSpec? liveSpec() {
        final String? text = _overlayController()?.currentCue?.text;
        if (text == null) return null;
        for (final _TrackSpec spec in _kTracks) {
          if (text.startsWith(spec.prefix)) return spec;
        }
        return null;
      }

      autoLive = await _pumpUntil(
        tester,
        () => hooks().debugPlayerDecodedSubtitleActive && liveSpec() != null,
        timeout: const Duration(seconds: 60),
      );
      autoLiveText = _overlayController()?.currentCue?.text;
      final _TrackSpec autoSpec = liveSpec() ?? _kTracks[0];
      final List<_TrackSpec> others = _kTracks
          .where((_TrackSpec s) => s != autoSpec)
          .toList();
      final _TrackSpec pickB = others[0];
      final _TrackSpec pickD = others[1];
      autoLanguage = autoSpec.language;
      pickBLanguage = pickB.language;
      pickDLanguage = pickD.language;
      expectedAutoSource = 'embedded:${_kTracks.indexOf(autoSpec)}';
      expectedBSource = 'embedded:${_kTracks.indexOf(pickB)}';
      expectedDSource = 'embedded:${_kTracks.indexOf(pickD)}';
      autoLiveCueCount = _overlayController()?.cues.length ?? -1;
      heldDuringAuto = gate.held;
      sourceDuringAuto = hooks().debugCurrentSubtitleSource;
      hooks().debugOpenSubtitleSettings();
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('video-subtitle-full-load'))
            .evaluate()
            .isNotEmpty,
        timeout: const Duration(seconds: 10),
      );
      pendingRowShown = find
          .byKey(const ValueKey<String>('video-subtitle-full-load'))
          .evaluate()
          .isNotEmpty;
      offRowEnabled = _tileEnabled('video-subtitle-off');
      shots.add(await _capture(tester, 'embedded-slow-01-auto-live-pending'));
      await _note(
        'A auto=$autoLanguage autoLive=$autoLive text=$autoLiveText liveCues=$autoLiveCueCount '
        'held=${gate.held} source=$sourceDuringAuto '
        'pendingRow=$pendingRowShown offEnabled=$offRowEnabled',
      );
      if (!autoLive) throw StateError('抽取期间没有出播放器解码的字幕');

      // B. 抽取还挂着时改选 eng。
      final VideoPlayerRemoteControl remote =
          videoPlaybackRemotes.current.value! as VideoPlayerRemoteControl;
      bool stateDone = false;
      late VideoRemoteSubtitleState state;
      unawaited(
        remote.subtitleState().then((VideoRemoteSubtitleState s) {
          state = s;
          stateDone = true;
        }),
      );
      await _pumpUntil(
        tester,
        () => stateDone,
        timeout: const Duration(seconds: 30),
      );
      await hooks().debugSeekMs(0);
      bool engDone = false;
      Object? engError;
      unawaited(
        remote
            .selectSubtitle(_trackFor(state, pickB).source, secondary: false)
            .then(
              (_) => engDone = true,
              onError: (Object e) {
                engError = e;
                engDone = true;
              },
            ),
      );
      engLive = await _pumpUntil(
        tester,
        () => hooks().debugPlayerDecodedSubtitleActive && liveSpec() == pickB,
        timeout: const Duration(seconds: 30),
      );
      engLiveText = _overlayController()?.currentCue?.text;
      sourceAfterEng = hooks().debugCurrentSubtitleSource;
      shots.add(await _capture(tester, 'embedded-slow-02-switched-eng-live'));
      await _note(
        'B pick=$pickBLanguage live=$engLive text=$engLiveText source=$sourceAfterEng '
        'held=${gate.held} engDone=$engDone engError=$engError',
      );
      if (engError != null) throw StateError('抽取期间改选被拒：$engError');

      // C. 放闸：完整列表到达，eng 不被自动加载的 jpn 盖掉。
      final VideoPlayerController controller = _overlayController()!;
      void sample() => swapSamples.add(controller.currentCue?.text);
      controller.addListener(sample);
      gate.open();
      await _pumpUntil(
        tester,
        () => engDone,
        timeout: const Duration(seconds: 60),
      );
      await _pumpUntil(
        tester,
        () => _matchTrack(controller.cues) != null,
        timeout: const Duration(seconds: 30),
      );
      controller.removeListener(sample);
      fullTrack = _matchTrack(controller.cues)?.language;
      sourceAfterFull = hooks().debugCurrentSubtitleSource;
      liveAfterFull = hooks().debugPlayerDecodedSubtitleActive;
      pendingGoneAfterFull = find
          .byKey(const ValueKey<String>('video-subtitle-full-load'))
          .evaluate()
          .isEmpty;
      await tester.pump(const Duration(seconds: 2));
      stillEngAfterSettle = _matchTrack(controller.cues)?.language;
      shots.add(await _capture(tester, 'embedded-slow-03-full-list-eng'));
      await _note(
        'C full=$fullTrack ${_describeCues(controller.cues)} source=$sourceAfterFull '
        'live=$liveAfterFull pendingGone=$pendingGoneAfterFull '
        'after2s=$stillEngAfterSettle passed=${gate.passed} samples=$swapSamples',
      );

      // D. 新抽取挂着时停止读取。
      gate.close();
      if (cache.existsSync()) cache.deleteSync(recursive: true);
      await hooks().debugSeekMs(0);
      unawaited(
        remote
            .selectSubtitle(_trackFor(state, pickD).source, secondary: false)
            .catchError((Object e) => _note('select chi error: $e')),
      );
      chiLive = await _pumpUntil(
        tester,
        () =>
            hooks().debugPlayerDecodedSubtitleActive &&
            gate.held > 0 &&
            liveSpec() == pickD,
        timeout: const Duration(seconds: 30),
      );
      heldDuringChi = gate.held;
      if (find
          .byKey(const ValueKey<String>('video-subtitle-full-load-cancel'))
          .evaluate()
          .isEmpty) {
        hooks().debugOpenSubtitleSettings();
        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey<String>('video-subtitle-full-load-cancel'))
              .evaluate()
              .isNotEmpty,
          timeout: const Duration(seconds: 10),
        );
      }
      final FocusDriver driver = FocusDriver(tester);
      // 「停止读取」按钮的触发：视频页字幕面板按设计只由指针 / 触屏操作，焦点留在画面上
      // （panel_focus_scope.dart 文件头 BUG-2040：焦点领进列表会让裸方向键与播放快捷键
      // 失效），Tab 遍历走不到面板里的任何行（实测 120 步停在页面 Focus 上）。这里直接
      // 调按钮的 onPressed——与鼠标点击是同一个回调；不用坐标点击。
      final Finder stopButton = find.byKey(
        const ValueKey<String>('video-subtitle-full-load-cancel'),
      );
      final VoidCallback? onStop = stopButton.evaluate().isEmpty
          ? null
          : (stopButton.evaluate().first.widget as FushiIconButtonControl)
                .onPressed;
      stopFocused = onStop != null;
      onStop?.call();
      stopObserved = await _pumpUntil(
        tester,
        () => gate.cancelled > 0 && gate.held == 0,
        timeout: const Duration(seconds: 15),
      );
      cancelledCount = gate.cancelled;
      inFlightAfterStop = await debugEmbeddedSubtitleExtractInFlight(videoPath);
      pendingGoneAfterStop = find
          .byKey(const ValueKey<String>('video-subtitle-full-load'))
          .evaluate()
          .isEmpty;
      liveAfterStop = hooks().debugPlayerDecodedSubtitleActive;
      sourceAfterStop = hooks().debugCurrentSubtitleSource;
      chiCuesAtStop = _overlayController()?.cues.length ?? -1;
      // 停止后字幕继续随播放出现：再等一句新的回流进来。
      await _pumpUntil(
        tester,
        () => (_overlayController()?.cues.length ?? 0) > chiCuesAtStop,
        timeout: const Duration(seconds: 15),
      );
      chiCuesLater = _overlayController()?.cues.length ?? -1;
      shots.add(await _capture(tester, 'embedded-slow-04-stopped-chi-live'));
      await _note(
        'D pick=$pickDLanguage live=$chiLive heldDuringChi=$heldDuringChi stopFocused=$stopFocused '
        'stopObserved=$stopObserved cancelled=$cancelledCount '
        'inFlight=$inFlightAfterStop pendingGone=$pendingGoneAfterStop '
        'live=$liveAfterStop source=$sourceAfterStop '
        'cues $chiCuesAtStop -> $chiCuesLater text=${_overlayController()?.currentCue?.text}',
      );

      // E. 退出。
      await driver.requestFocusInside(find.byType(Video));
      for (int i = 0; i < 4 && !pageGone; i++) {
        await tester.sendKeyEvent(
          LogicalKeyboardKey.escape,
          physicalKey: PhysicalKeyboardKey.escape,
        );
        pageGone = await _pumpUntil(
          tester,
          () => find.byType(VideoFushiPage).evaluate().isEmpty,
          timeout: const Duration(seconds: 5),
        );
      }
      inFlightAfterExit = await debugEmbeddedSubtitleExtractInFlight(videoPath);
      await _note('E pageGone=$pageGone inFlightAfterExit=$inFlightAfterExit');
      await _note('shots: $shots');
      await tester.pump(const Duration(seconds: 1));
    } catch (e, s) {
      flowError = '$e\n$s';
      await _note('flow error: $e');
    } finally {
      gate.open();
      setFfmpegBackendForTesting(null);
      FlutterError.onError = originalOnError;
    }

    expect(flowError, isNull, reason: flowError);
    expect(path, isNotNull);
    // A
    expect(autoLive, isTrue, reason: '抽取期间应先出播放器解码的字幕');
    expect(heldDuringAuto, 1, reason: '截图那一刻整轨抽取确实还挂着（只有一个共享抽取）');
    expect(
      autoLiveCueCount,
      lessThan(_kTracks.firstWhere((s) => s.language == autoLanguage).count),
      reason: '回流是边播边累积的，不是完整列表',
    );
    expect(sourceDuringAuto, expectedAutoSource);
    expect(pendingRowShown, isTrue, reason: '字幕面板顶部显示「正在读取完整字幕」');
    expect(offRowEnabled, isTrue, reason: '读取期间菜单不锁');
    // B
    expect(engLive, isTrue, reason: '抽取期间改选 $pickBLanguage 立即出它的字幕');
    expect(sourceAfterEng, expectedBSource);
    // C
    expect(
      fullTrack,
      pickBLanguage,
      reason: '完整列表是用户改选的那条，不被自动加载的 $autoLanguage 盖掉',
    );
    expect(stillEngAfterSettle, pickBLanguage);
    expect(sourceAfterFull, expectedBSource);
    expect(liveAfterFull, isFalse, reason: '换上完整列表后不再借播放器解码');
    expect(pendingGoneAfterFull, isTrue);
    for (int i = 1; i + 1 < swapSamples.length; i++) {
      final bool flash =
          swapSamples[i] == null &&
          swapSamples[i - 1] != null &&
          swapSamples[i - 1] == swapSamples[i + 1];
      expect(flash, isFalse, reason: '换装时当前句闪空：$swapSamples');
    }
    // D
    expect(chiLive, isTrue);
    expect(heldDuringChi, 1);
    expect(stopFocused, isTrue, reason: '读取行上有可用的「停止读取」按钮');
    expect(stopObserved, isTrue, reason: '停止后 ffmpeg 抽取被取消');
    expect(inFlightAfterStop, isFalse);
    expect(pendingGoneAfterStop, isTrue);
    expect(liveAfterStop, isTrue, reason: '停止的是补全列表，播放器解码的字幕继续显示');
    expect(sourceAfterStop, expectedDSource);
    expect(chiCuesLater, greaterThan(chiCuesAtStop), reason: '停止后字幕继续随播放出现');
    // E
    expect(pageGone, isTrue);
    expect(inFlightAfterExit, isFalse);
  });
}
