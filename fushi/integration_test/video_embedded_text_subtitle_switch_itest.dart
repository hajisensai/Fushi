// BUG-4838 正常路径回归：真 app、真 media_kit、真 ffmpeg 抽取内封文本字幕。
//
// 素材：ffmpeg 生成 60 秒 mkv，内封 3 条带语言标签的 subrip 文本轨（jpn / eng / chi），
// 各轨文本互不相同、句数也不同（12 / 10 / 8），不带外挂字幕。流程：
//   1. 从书库打开视频（`openLocalVideoBook`），等默认内封文本轨自动加载出 cue，
//      核对句数与文本对得上某一条轨；
//   2. 走页面的选字幕入口切到另一条内封文本轨，核对 cue 换成该轨内容；
//   3. 再切第三条轨，核对仍是缓存命中：抽取在途表为空、缓存文件 mtime 不变（整轨
//      抽取只在首开跑一次 ffmpeg）；
//   4. 焦点落进画面后按 Escape 退出播放页（返回键逐级关前台浮层，最多按 4 次），
//      核对页面已卸载、遥控登记已注销、没有残留的在途抽取。
//
// 选字幕入口：字幕轨行在设置面板「字幕」分类的浮层里，离屏 runner 没有能稳定把焦点
// 送进那张浮层的键位（没有打开字幕分类的快捷键），所以这里调页面登记的
// [VideoPlayerRemoteControl.selectSubtitle]——它与面板字幕行的 onTap 是同一个
// `_selectSubtitleSource`（抽 cue → 切 overlay → 持久化），不是另写的测试捷径。
//
// 两个坑（见协调说明）：
//   - app 的 `main` 会替换 [FlutterError.onError]；先存原 handler，流程跑完先还原再断言，
//     否则失败的 expect 到不了框架，app 进程挂着占租约；
//   - `flutter test -d windows` 的 stdout 只在进程退出时刷出，关键观测同时追加写进
//     `<FUSHI_TEST_ROOT>/embedded-sub-switch-report.txt`（flush: true）。
//
// 跑法（在 fushi/ 下）：
//   dart tool/heavy.dart --max-minutes=30 -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/video_embedded_text_subtitle_switch_itest.dart
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
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
    show VideoFushiPage;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show debugEmbeddedSubtitleExtractInFlight, embeddedSubtitleCacheDir;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[embedded-sub-switch]';

/// 一条内封轨的素材：语言标签、每句文本前缀、句数。
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

/// 追加一行观测到报告文件并打进 command.log。
Future<void> _note(String line) async {
  debugPrint('$_tag $line');
  if (_kTestRoot.isEmpty) return;
  await File(
    '$_kTestRoot${Platform.pathSeparator}embedded-sub-switch-report.txt',
  ).writeAsString('$line\n', mode: FileMode.append, flush: true);
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

/// 生成 60 秒、带 3 条内封 subrip 轨的 mkv 并入库，返回 (bookUid, 视频绝对路径)。
Future<(String, String)> _seedVideo(VideoBookRepository repo) async {
  final Directory dir = _kTestRoot.isEmpty
      ? await Directory.systemTemp.createTemp('fushi_embsub_')
      : Directory('$_kTestRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  final String sep = Platform.pathSeparator;
  final List<String> srtPaths = <String>[];
  for (final _TrackSpec spec in _kTracks) {
    final File f = File('${dir.path}${sep}embsub_${spec.language}.srt');
    await f.writeAsString(_srtFor(spec), flush: true);
    srtPaths.add(f.path);
  }
  final String videoPath = File(
    '${dir.path}${sep}embedded-sub-switch.mkv',
  ).absolute.path;
  final List<String> args = <String>[
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
  ];
  final FfmpegRunResult r = await resolveFfmpegBackend().run(
    args,
    const Duration(seconds: 180),
  );
  if (!r.isSuccess) {
    throw StateError('ffmpeg 生成素材失败: ${r.failureSummary}');
  }
  final String bookUid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: const Value('embedded-sub-switch'),
      videoPath: Value(videoPath),
    ),
  );
  return (bookUid, videoPath);
}

/// cue 列表对得上哪条轨（句数与逐句文本全等）；都对不上返回 null。
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

/// 缓存目录里各抽取文件的 mtime（毫秒）。
Future<Map<String, int>> _cacheMtimes(String videoPath) async {
  final Directory dir = await embeddedSubtitleCacheDir(videoPath);
  final Map<String, int> out = <String, int>{};
  if (!dir.existsSync()) return out;
  await for (final FileSystemEntity e in dir.list()) {
    if (e is! File) continue;
    final String name = e.uri.pathSegments.last;
    out[name] = (await e.stat()).modified.millisecondsSinceEpoch;
  }
  return out;
}

VideoPlayerController? _overlayController() {
  final Finder f = find.byType(VideoSubtitleOverlay);
  if (f.evaluate().isEmpty) return null;
  return (f.evaluate().first.widget as VideoSubtitleOverlay).controller;
}

/// 有界 pump 直到 [done] 为真；不 pumpAndSettle（视频页有永不 settle 的动画）。
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required Duration timeout,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (done()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return done();
}

/// 边 pump 边等 [future]（页内选字幕会等帧回调，不能干 await）。
Future<T> _pumpFuture<T>(
  WidgetTester tester,
  Future<T> future, {
  required Duration timeout,
}) async {
  bool finished = false;
  T? value;
  Object? error;
  StackTrace? stack;
  unawaited(
    future.then(
      (T v) {
        value = v;
        finished = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        finished = true;
      },
    ),
  );
  if (!await _pumpUntil(tester, () => finished, timeout: timeout)) {
    throw TimeoutException('等待超时', timeout);
  }
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value as T;
}

/// 选主字幕到 [spec] 那条内封轨，返回切换耗时（毫秒）。
Future<int> _selectTrack(
  WidgetTester tester,
  VideoPlayerRemoteControl remote,
  VideoRemoteSubtitleState state,
  _TrackSpec spec,
) async {
  final VideoRemoteSubtitleTrack track = state.tracks.firstWhere(
    (VideoRemoteSubtitleTrack t) =>
        t.kind == VideoRemoteSubtitleKind.embedded &&
        t.language == spec.language,
    orElse: () => throw StateError(
      '轨表里没有语言 ${spec.language} 的内封轨：'
      '${state.tracks.map((VideoRemoteSubtitleTrack t) => '${t.source}/${t.language}/${t.kind.name}').join(', ')}',
    ),
  );
  final Stopwatch sw = Stopwatch()..start();
  await _pumpFuture<void>(
    tester,
    remote.selectSubtitle(track.source, secondary: false),
    timeout: const Duration(seconds: 60),
  );
  return sw.elapsedMilliseconds;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('内封文本轨：默认自动加载、切轨换内容、二次切轨命中缓存、退出', (WidgetTester tester) async {
    // 坑 (a)：app main 会换掉 FlutterError.onError，先存框架原 handler。
    final void Function(FlutterErrorDetails)? originalOnError =
        FlutterError.onError;

    bool homeShown = false;
    String? flowError;
    String? videoPath;
    String? defaultLanguage;
    List<String> defaultMismatch = <String>[];
    final Map<String, String?> afterSwitch = <String, String?>{};
    final Map<String, List<String>> switchMismatch = <String, List<String>>{};
    Map<String, int> mtimesAfterDefault = <String, int>{};
    Map<String, int> mtimesAfterSwitches = <String, int>{};
    final List<bool> inFlightAfterSwitch = <bool>[];
    bool? inFlightAfterExit;
    bool pageGone = false;
    int escPresses = 0;
    bool remoteCleared = false;
    final List<String> switchOrder = <String>[];

    try {
      if (_kTestRoot.isNotEmpty) {
        final File report = File(
          '$_kTestRoot${Platform.pathSeparator}embedded-sub-switch-report.txt',
        );
        if (report.existsSync()) report.deleteSync();
      }
      await launchFushiTestApp();
      homeShown = await waitForHome(tester);
      await _note('home=$homeShown');
      if (!homeShown) throw StateError('主页 90s 内未出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final (String uid, String path) = await _seedVideo(repo);
      videoPath = path;
      await _note('seeded video=$path');

      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));

      // 1. 默认内封文本轨自动加载。
      final Stopwatch openSw = Stopwatch()..start();
      final bool cuesLoaded = await _pumpUntil(
        tester,
        () => (_overlayController()?.cues.isNotEmpty ?? false),
        timeout: const Duration(seconds: 90),
      );
      final List<AudioCue> defaultCues = List<AudioCue>.of(
        _overlayController()?.cues ?? const <AudioCue>[],
      );
      final _TrackSpec? defaultSpec = _matchTrack(defaultCues);
      defaultLanguage = defaultSpec?.language;
      if (defaultSpec == null) {
        defaultMismatch = <String>[_describeCues(defaultCues)];
      }
      await _note(
        'default loaded=$cuesLoaded in ${openSw.elapsedMilliseconds}ms '
        'track=${defaultLanguage ?? '-'} ${_describeCues(defaultCues)}',
      );
      if (!cuesLoaded) throw StateError('默认内封文本轨 90s 内没有出 cue');
      // 等整轨抽取收尾，记缓存文件 mtime（首开那一趟 ffmpeg 的产物）。
      await _pumpUntil(
        tester,
        () => false,
        timeout: const Duration(seconds: 1),
      );
      mtimesAfterDefault = await _cacheMtimes(path);
      await _note('cache after default: $mtimesAfterDefault');

      final VideoPlayerRemoteControl remote =
          videoPlaybackRemotes.current.value! as VideoPlayerRemoteControl;
      final VideoRemoteSubtitleState state = await _pumpFuture(
        tester,
        remote.subtitleState(),
        timeout: const Duration(seconds: 30),
      );
      await _note(
        'tracks: ${state.tracks.map((VideoRemoteSubtitleTrack t) => '${t.source}/${t.language}/${t.kind.name}${t.primary ? '*' : ''}').join(', ')}',
      );

      // 2./3. 依次切到另外两条轨。
      final List<_TrackSpec> targets = _kTracks
          .where((_TrackSpec s) => s.language != defaultLanguage)
          .toList();
      for (final _TrackSpec spec in targets) {
        switchOrder.add(spec.language);
        final int ms = await _selectTrack(tester, remote, state, spec);
        final bool inFlight = await debugEmbeddedSubtitleExtractInFlight(path);
        inFlightAfterSwitch.add(inFlight);
        await tester.pump(const Duration(milliseconds: 500));
        final List<AudioCue> cues = List<AudioCue>.of(
          _overlayController()?.cues ?? const <AudioCue>[],
        );
        final _TrackSpec? matched = _matchTrack(cues);
        afterSwitch[spec.language] = matched?.language;
        if (matched?.language != spec.language) {
          switchMismatch[spec.language] = <String>[_describeCues(cues)];
        }
        await _note(
          'switch -> ${spec.language} took ${ms}ms inFlight=$inFlight '
          'matched=${matched?.language ?? '-'} ${_describeCues(cues)}',
        );
      }
      mtimesAfterSwitches = await _cacheMtimes(path);
      await _note('cache after switches: $mtimesAfterSwitches');

      // 4. 退出播放页：焦点落进画面后按 Escape（用户的返回键路径；每按一次逐级关
      // 一层前台浮层，没有浮层时退出页面），最多按 4 次。
      final ModalRoute<Object?>? pageRoute = ModalRoute.of(
        tester.element(find.byType(VideoFushiPage)),
      );
      await _note('exit routeIsCurrent=${pageRoute?.isCurrent}');
      final FocusDriver driver = FocusDriver(tester);
      final bool focused = await driver.requestFocusInside(find.byType(Video));
      for (int i = 0; i < 4 && !pageGone; i++) {
        escPresses++;
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
      await _note('exit focused=$focused escPresses=$escPresses');
      remoteCleared = videoPlaybackRemotes.current.value == null;
      inFlightAfterExit = await debugEmbeddedSubtitleExtractInFlight(path);
      await _note(
        'exit pageGone=$pageGone remoteCleared=$remoteCleared '
        'inFlightAfterExit=$inFlightAfterExit',
      );
      await tester.pump(const Duration(seconds: 1));
    } catch (e, s) {
      flowError = '$e\n$s';
      await _note('flow error: $e');
    } finally {
      // 坑 (a)：先还原框架的 handler，再做任何可能失败的断言。
      FlutterError.onError = originalOnError;
    }

    expect(flowError, isNull, reason: flowError);
    expect(videoPath, isNotNull);
    expect(
      defaultLanguage,
      isNotNull,
      reason: '默认 cue 应与某条内封轨逐句一致：$defaultMismatch',
    );
    expect(switchOrder, hasLength(2));
    for (final String lang in switchOrder) {
      expect(
        afterSwitch[lang],
        lang,
        reason: '切到 $lang 后 cue 应换成该轨内容：${switchMismatch[lang]}',
      );
    }
    expect(inFlightAfterSwitch, everyElement(isFalse), reason: '切轨不应再起抽取');
    expect(
      mtimesAfterDefault.length,
      _kTracks.length,
      reason: '首开整轨抽取应写出 3 个缓存文件：$mtimesAfterDefault',
    );
    expect(mtimesAfterSwitches, mtimesAfterDefault, reason: '切轨应命中缓存（文件不重写）');
    expect(pageGone, isTrue, reason: '退出后播放页应卸载');
    expect(remoteCleared, isTrue, reason: '退出后遥控登记应注销');
    expect(inFlightAfterExit, isFalse, reason: '退出后不应残留在途抽取');
  });
}
