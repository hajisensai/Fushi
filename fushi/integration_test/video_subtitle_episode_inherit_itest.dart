// BUG-5464 真 app 复测：本地合集里第 1 集选的内封字幕轨，第 2 集按「语言 + 轨标题」
// 沿用，不按序号照搬。真 app、真 media_kit、真 ffmpeg 抽取内封文本字幕。
//
// 素材：ffmpeg 生成两集 30 秒 mkv，各带 3 条内封 subrip 轨，**两集轨顺序不同**：
//   ep1: [0] jpn「Signs & Songs」 [1] eng「English」 [2] jpn「Full」
//   ep2: [0] jpn「Signs & Songs」 [1] jpn「Full」    [2] eng「English」
// 每集每轨文本互不相同（`EP1 Full 3` 之类）、句数不同，cue 一看就知道是哪集哪条轨。
// 这样三种结果可区分：按描述沿用 → ep2 Full；按序号照搬（embedded:2）→ ep2 English；
// 不沿用（默认内封自动加载挑第一条日语轨）→ ep2 Signs。
//
// 流程：
//   1. 两集入库并建播放列表合集，开连播；与视频卡 onTap 同一入口（`openLocalVideoBook`）
//      开第 1 集，等默认内封轨自动加载出 cue；
//   2. 走页面登记的 [VideoPlayerRemoteControl.selectSubtitle] 选 jpn「Full」（与字幕
//      面板行的 onTap 是同一个 `_selectSubtitleSource`），核对 cue 换成 ep1 Full、库里
//      ep1 行记下 `embedded:2`；
//   3. 走播放器 EOF 回调同一条路径（`debugHandlePlaybackEnded` → `_handlePlaybackCompleted`
//      → 连播倒计时 → `_switchEpisode` 的 pushReplacement）换到第 2 集，核对 ep2 起播就是
//      Full 轨的 cue，且沿用没有写回 ep2 的行；
//   4. 焦点落进画面后按 Escape 退出，再像从书库点卡那样单独打开第 2 集（不传合集 id，
//      由 `openLocalVideoBook` 自己解析归属合集），核对仍是 Full。
//
// 两个坑（同 video_embedded_text_subtitle_switch_itest）：app 的 `main` 会替换
// [FlutterError.onError]，先存原 handler、流程跑完先还原再断言；`flutter test -d windows`
// 的 stdout 只在进程退出时刷出，关键观测同时追加写进
// `<FUSHI_TEST_ROOT>/sub-inherit-report.txt`（flush: true）。
//
// 跑法（在 fushi/ 下）：
//   dart tool/heavy.dart --max-minutes=30 -- powershell -ExecutionPolicy Bypass
//     -File tool/run_windows_itest.ps1 integration_test/video_subtitle_episode_inherit_itest.dart
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
import 'package:fushi/src/media/video/video_subtitle_overlay.dart'
    show VideoSubtitleOverlay;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart' show MediaKind, VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[sub-inherit]';

/// 一条内封轨：语言标签、轨标题、文本前缀（集号 + 种类）、句数。
class _TrackSpec {
  const _TrackSpec(this.language, this.title, this.kind, this.count);

  final String language;
  final String title;
  final String kind;
  final int count;

  String textAt(String episode, int i) => '$episode $kind ${i + 1}';
}

const _TrackSpec _signs = _TrackSpec('jpn', 'Signs & Songs', 'Signs', 6);
const _TrackSpec _english = _TrackSpec('eng', 'English', 'English', 8);
const _TrackSpec _full = _TrackSpec('jpn', 'Full', 'Full', 10);

/// 两集的轨顺序（故意不同）。
const Map<String, List<_TrackSpec>> _kEpisodes = <String, List<_TrackSpec>>{
  'EP1': <_TrackSpec>[_signs, _english, _full],
  'EP2': <_TrackSpec>[_signs, _full, _english],
};

final String _kTestRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

Future<void> _note(String line) async {
  debugPrint('$_tag $line');
  if (_kTestRoot.isEmpty) return;
  await File(
    '$_kTestRoot${Platform.pathSeparator}sub-inherit-report.txt',
  ).writeAsString('$line\n', mode: FileMode.append, flush: true);
}

String _srtTime(int ms) {
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(ms ~/ 3600000)}:${p(ms ~/ 60000 % 60)}:${p(ms ~/ 1000 % 60)},'
      '${p(ms % 1000, 3)}';
}

String _srtFor(String episode, _TrackSpec spec) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < spec.count; i++) {
    final int start = 1000 + i * 2500;
    b
      ..writeln(i + 1)
      ..writeln('${_srtTime(start)} --> ${_srtTime(start + 2000)}')
      ..writeln(spec.textAt(episode, i))
      ..writeln();
  }
  return b.toString();
}

/// 生成一集 30 秒、带 3 条内封 subrip 轨（含语言与标题元数据）的 mkv 并入库，返回 bookUid。
Future<String> _seedEpisode(
  VideoBookRepository repo,
  Directory dir,
  String episode,
) async {
  final String sep = Platform.pathSeparator;
  final List<_TrackSpec> tracks = _kEpisodes[episode]!;
  final List<String> srtPaths = <String>[];
  for (final _TrackSpec spec in tracks) {
    final File f = File('${dir.path}$sep${episode}_${spec.kind}.srt');
    await f.writeAsString(_srtFor(episode, spec), flush: true);
    srtPaths.add(f.path);
  }
  final String videoPath = File(
    '${dir.path}${sep}Series - $episode.mkv',
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
    '30',
    '-c:v',
    'mpeg4',
    '-q:v',
    '5',
    '-c:a',
    'aac',
    '-c:s',
    'srt',
    for (int i = 0; i < tracks.length; i++) ...<String>[
      '-metadata:s:s:$i',
      'language=${tracks[i].language}',
      '-metadata:s:s:$i',
      'title=${tracks[i].title}',
    ],
    videoPath,
  ];
  final FfmpegRunResult r = await resolveFfmpegBackend().run(
    args,
    const Duration(seconds: 180),
  );
  if (!r.isSuccess) {
    throw StateError('ffmpeg 生成 $episode 失败: ${r.failureSummary}');
  }
  final String bookUid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value('Series - $episode'),
      videoPath: Value(videoPath),
    ),
  );
  return bookUid;
}

/// cue 列表是哪集哪条轨（句数与逐句文本全等），如 `EP2 Full`；都对不上返回 null。
String? _matchTrack(List<AudioCue> cues) {
  for (final MapEntry<String, List<_TrackSpec>> ep in _kEpisodes.entries) {
    for (final _TrackSpec spec in ep.value) {
      if (cues.length != spec.count) continue;
      bool all = true;
      for (int i = 0; i < cues.length; i++) {
        if (cues[i].text.trim() != spec.textAt(ep.key, i)) {
          all = false;
          break;
        }
      }
      if (all) return '${ep.key} ${spec.kind}';
    }
  }
  return null;
}

String _describeCues(List<AudioCue> cues) => cues.isEmpty
    ? 'cues=0'
    : 'cues=${cues.length} first="${cues.first.text}" last="${cues.last.text}"';

/// 当前在树上的播放页（换集过渡里新旧两页可能同时在树，取最后挂上的那一页）。
Element? _pageElement() {
  final Iterable<Element> pages = find
      .byType(VideoFushiPage, skipOffstage: false)
      .evaluate();
  return pages.isEmpty ? null : pages.last;
}

String? _currentPageUid() =>
    (_pageElement()?.widget as VideoFushiPage?)?.bookUid;

/// [_pageElement] 那一页的字幕 overlay 上的 cue。
List<AudioCue> _pageCues() {
  final Element? page = _pageElement();
  if (page == null) return const <AudioCue>[];
  final Finder overlay = find.descendant(
    of: find.byElementPredicate((Element e) => identical(e, page)),
    matching: find.byType(VideoSubtitleOverlay),
  );
  if (overlay.evaluate().isEmpty) return const <AudioCue>[];
  return List<AudioCue>.of(
    (overlay.evaluate().first.widget as VideoSubtitleOverlay).controller.cues,
  );
}

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

Future<String?> _rowSubtitle(VideoBookRepository repo, String uid) async =>
    (await repo.getByBookUid(uid))?.subtitleSource;

/// 焦点落进画面后按 Escape 退出播放页（逐级关前台浮层，最多 4 次）。
Future<bool> _exitPage(WidgetTester tester) async {
  final FocusDriver driver = FocusDriver(tester);
  await driver.requestFocusInside(find.byType(Video));
  bool gone = false;
  for (int i = 0; i < 4 && !gone; i++) {
    await tester.sendKeyEvent(
      LogicalKeyboardKey.escape,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    gone = await _pumpUntil(
      tester,
      () => find.byType(VideoFushiPage).evaluate().isEmpty,
      timeout: const Duration(seconds: 5),
    );
  }
  return gone;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('合集换集与从书库开另一集：内封字幕按语言 + 标题沿用', (WidgetTester tester) async {
    final void Function(FlutterErrorDetails)? originalOnError =
        FlutterError.onError;

    String? flowError;
    String? ep1Default;
    String? ep1Selected;
    String? ep1Row;
    String? ep2AfterSwitch;
    String? ep2RowAfterSwitch;
    String? ep2FromLibrary;
    bool exited = false;

    try {
      if (_kTestRoot.isNotEmpty) {
        final File report = File(
          '$_kTestRoot${Platform.pathSeparator}sub-inherit-report.txt',
        );
        if (report.existsSync()) report.deleteSync();
      }
      await launchFushiTestApp();
      final bool homeShown = await waitForHome(tester);
      await _note('home=$homeShown');
      if (!homeShown) throw StateError('主页 90s 内未出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      await appModel.setVideoAutoPlayNext(true);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final Directory dir = _kTestRoot.isEmpty
          ? await Directory.systemTemp.createTemp('fushi_subinherit_')
          : Directory('$_kTestRoot${Platform.pathSeparator}fixtures');
      await dir.create(recursive: true);
      final String ep1 = await _seedEpisode(repo, dir, 'EP1');
      final String ep2 = await _seedEpisode(repo, dir, 'EP2');
      final int collectionId = await appModel.database.createMediaCollection(
        'sub-inherit-series',
        collectionType: 'playlist',
      );
      await appModel.database.addToCollection(
        collectionId,
        MediaKind.video,
        ep1,
      );
      await appModel.database.addToCollection(
        collectionId,
        MediaKind.video,
        ep2,
      );
      await _note('seeded ep1=$ep1 ep2=$ep2 collection=$collectionId');

      // 1. 开第 1 集（与视频卡 onTap 同一入口），等默认内封轨自动加载。
      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      unawaited(
        openLocalVideoBook(
          context: ctx,
          repo: repo,
          bookUid: ep1,
          playlistCollectionId: collectionId,
        ),
      );
      final bool defaultLoaded = await _pumpUntil(
        tester,
        () => _currentPageUid() == ep1 && _pageCues().isNotEmpty,
        timeout: const Duration(seconds: 90),
      );
      ep1Default = _matchTrack(_pageCues());
      await _note(
        'ep1 default loaded=$defaultLoaded track=${ep1Default ?? '-'} '
        '${_describeCues(_pageCues())}',
      );
      if (!defaultLoaded) throw StateError('第 1 集默认内封轨 90s 内没有出 cue');

      // 2. 选 jpn「Full」。
      final VideoPlayerRemoteControl remote =
          videoPlaybackRemotes.current.value! as VideoPlayerRemoteControl;
      final VideoRemoteSubtitleState state = await _pumpFuture(
        tester,
        remote.subtitleState(),
        timeout: const Duration(seconds: 30),
      );
      await _note(
        'ep1 tracks: ${state.tracks.map((VideoRemoteSubtitleTrack t) => '${t.source}/${t.language}/${t.label}${t.primary ? '*' : ''}').join(', ')}',
      );
      final VideoRemoteSubtitleTrack full = state.tracks.firstWhere(
        (VideoRemoteSubtitleTrack t) =>
            t.kind == VideoRemoteSubtitleKind.embedded &&
            t.language == 'jpn' &&
            t.label.contains('Full'),
      );
      await _pumpFuture<void>(
        tester,
        remote.selectSubtitle(full.source, secondary: false),
        timeout: const Duration(seconds: 60),
      );
      await tester.pump(const Duration(milliseconds: 500));
      ep1Selected = _matchTrack(_pageCues());
      ep1Row = await _rowSubtitle(repo, ep1);
      await _note(
        'ep1 selected ${full.source} -> track=${ep1Selected ?? '-'} '
        'row=$ep1Row ${_describeCues(_pageCues())}',
      );

      // 3. 播完 → 连播倒计时 → pushReplacement 到第 2 集。
      final VideoFushiTestHooks hooks =
          tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
      hooks.debugHandlePlaybackEnded(positionMs: 29500, durationMs: 30000);
      final bool switched = await _pumpUntil(
        tester,
        () =>
            _currentPageUid() == ep2 &&
            find.byType(VideoFushiPage).evaluate().length == 1 &&
            _pageCues().isNotEmpty,
        timeout: const Duration(seconds: 90),
      );
      ep2AfterSwitch = _matchTrack(_pageCues());
      ep2RowAfterSwitch = await _rowSubtitle(repo, ep2);
      await _note(
        'ep2 after switch=$switched track=${ep2AfterSwitch ?? '-'} '
        'row=$ep2RowAfterSwitch ${_describeCues(_pageCues())}',
      );
      final ObserveShot shot = await captureFlutterFrame(
        tester,
        'sub-inherit-ep2-after-switch',
        settle: false,
      );
      await _note('shot ${shot.path} saved=${shot.saved}');

      // 4. 退出，再从书库单独打开第 2 集。
      exited = await _exitPage(tester);
      await _note('exited=$exited');
      if (!exited) throw StateError('退出播放页失败');
      final BuildContext homeCtx = tester.element(find.byType(Scaffold).first);
      unawaited(openLocalVideoBook(context: homeCtx, repo: repo, bookUid: ep2));
      final bool reopened = await _pumpUntil(
        tester,
        () => _currentPageUid() == ep2 && _pageCues().isNotEmpty,
        timeout: const Duration(seconds: 90),
      );
      ep2FromLibrary = _matchTrack(_pageCues());
      await _note(
        'ep2 from library=$reopened track=${ep2FromLibrary ?? '-'} '
        '${_describeCues(_pageCues())}',
      );
      await _exitPage(tester);
      await tester.pump(const Duration(seconds: 1));
    } catch (e, s) {
      flowError = '$e\n$s';
      await _note('flow error: $e');
    } finally {
      FlutterError.onError = originalOnError;
    }

    expect(flowError, isNull, reason: flowError);
    expect(ep1Selected, 'EP1 Full', reason: '第 1 集选中后应是 Full 轨的 cue');
    expect(ep1Row, 'embedded:2', reason: '第 1 集的选择应记在它自己的行上');
    expect(
      ep2AfterSwitch,
      'EP2 Full',
      reason:
          '换到第 2 集应按语言 + 标题沿用 Full（EP2 English = 按序号照搬，'
          'EP2 Signs = 没沿用、落回默认内封自动加载）',
    );
    expect(ep2RowAfterSwitch, isNull, reason: '沿用只管本次加载，不写回第 2 集的行');
    expect(exited, isTrue);
    expect(ep2FromLibrary, 'EP2 Full', reason: '从书库单独打开第 2 集同样沿用');
  });
}
