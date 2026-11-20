import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_mine_return_state.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';

/// 制卡队列重放前后的播放状态（集 / 站点字幕轨 / 音轨 / 位置）必须原样还给用户：
/// 用户实测重放后字幕轨变了、停在内置档不回原档（2026-10-27）。根因是每次换档都是站点
/// 整页重载，Netflix 按账号默认重选轨、按被重放 seek 改过的服务器书签起播。
WebVideoPlaybackState _state({
  String videoKey = 'nf:1',
  int? positionMs = 600000,
  String text = 'ja',
  String audio = 'a-ja',
  List<String> texts = const <String>['ja', 'en'],
  List<String> audios = const <String>['a-ja', 'a-en'],
  bool paused = true,
  bool hasVideo = true,
}) => WebVideoPlaybackState(
  href: 'https://www.netflix.com/watch/1',
  videoKey: videoKey,
  hasVideo: hasVideo,
  positionMs: positionMs,
  paused: paused,
  durationMs: 1400000,
  videoWidth: 1920,
  videoHeight: 1080,
  rate: 1,
  fullscreen: false,
  title: 't',
  siteTracks: <WebVideoSiteTrack>[
    for (final String id in texts)
      WebVideoSiteTrack(id: id, lang: id, name: id),
  ],
  siteTrackCurrent: text,
  siteAudioTracks: <WebVideoSiteTrack>[
    for (final String id in audios)
      WebVideoSiteTrack(id: id, lang: id, name: id),
  ],
  siteAudioTrackCurrent: audio,
);

void main() {
  final WebMineReturnState want = WebMineReturnState.of(_state());

  group('planWebMineRestore', () {
    test('already identical: nothing to do', () {
      expect(webMineRestoreDone(planWebMineRestore(want, _state())), isTrue);
    });

    test('replay changed text + audio track and position: restore all', () {
      final WebMineRestorePlan plan = planWebMineRestore(
        want,
        _state(text: 'en', audio: 'a-en', positionMs: 1200000),
      );
      expect(plan.navigateHref, isNull);
      expect(plan.selectTextTrack, 'ja');
      expect(plan.selectAudioTrack, 'a-ja');
      expect(plan.seekMs, 600000);
    });

    test('subtitles were off before replay: turn them off again', () {
      final WebMineReturnState off = WebMineReturnState.of(_state(text: ''));
      expect(planWebMineRestore(off, _state(text: 'en')).selectTextTrack, '');
    });

    test('replay left another episode: navigate back first, nothing else', () {
      final WebMineRestorePlan plan = planWebMineRestore(
        want,
        _state(videoKey: 'nf:2', text: 'en'),
      );
      expect(plan.navigateHref, 'https://www.netflix.com/watch/1');
      expect(plan.selectTextTrack, isNull);
      expect(plan.seekMs, isNull);
    });

    test('position within tolerance is left alone', () {
      final WebMineRestorePlan plan = planWebMineRestore(
        want,
        _state(positionMs: 600000 + kWebMineRestoreSeekToleranceMs - 1),
      );
      expect(plan.seekMs, isNull);
    });

    test('track lists not reported yet: do not touch tracks', () {
      final WebMineRestorePlan plan = planWebMineRestore(
        want,
        _state(
          texts: const <String>[],
          audios: const <String>[],
          text: '',
          audio: '',
        ),
      );
      expect(plan.selectTextTrack, isNull);
      expect(plan.selectAudioTrack, isNull);
    });

    test('snapshot carries play / pause; paused() only flips that', () {
      final WebMineReturnState playing = WebMineReturnState.of(
        _state(paused: false),
      );
      expect(playing.playing, isTrue);
      expect(want.playing, isFalse);
      final WebMineReturnState held = playing.paused();
      expect(held.playing, isFalse);
      expect(held.positionMs, playing.positionMs);
      expect(held.siteTextTrack, playing.siteTextTrack);
      expect(held.siteAudioTrack, playing.siteAudioTrack);
      expect(held.href, playing.href);
    });

    test('rebuilt page auto-plays while original was paused: pause it', () {
      expect(
        planWebMineRestore(want, _state(paused: false)).setPlaying,
        isFalse,
      );
      final WebMineReturnState playing = WebMineReturnState.of(
        _state(paused: false),
      );
      expect(planWebMineRestore(playing, _state()).setPlaying, isTrue);
      expect(planWebMineRestore(want, _state()).setPlaying, isNull);
    });

    test('no video element yet / other episode: play state left alone', () {
      expect(
        planWebMineRestore(
          want,
          _state(paused: false, hasVideo: false),
        ).setPlaying,
        isNull,
      );
      expect(
        planWebMineRestore(
          want,
          _state(videoKey: 'nf:2', paused: false),
        ).setPlaying,
        isNull,
      );
    });

    test('unknown original audio track never forces a switch', () {
      final WebMineReturnState noAudio = WebMineReturnState.of(
        _state(audio: ''),
      );
      expect(
        planWebMineRestore(noAudio, _state(audio: 'a-en')).selectAudioTrack,
        isNull,
      );
    });
  });

  group('replay wiring guard', () {
    final String page = File(
      'lib/src/pages/implementations/web_video_fushi_page.dart',
    ).readAsStringSync();
    final String webSource = File(
      'lib/src/pages/implementations/video_fushi/web_source.part.dart',
    ).readAsStringSync();
    final String glue = File(
      'assets/web_video/web_video_glue.js',
    ).readAsStringSync();

    String body(String src, String start, String end) {
      final int a = src.indexOf(start);
      expect(a, greaterThanOrEqualTo(0), reason: 'missing $start');
      final int b = src.indexOf(end, a + start.length);
      expect(b, greaterThan(a), reason: 'missing $end after $start');
      return src.substring(a, b);
    }

    test('replay hides site subtitles and aligns audio before every cue', () {
      final String run = body(
        page,
        'Future<void> _runMineQueue(',
        'Future<String?> _mineQueuedRow(',
      );
      expect(run, contains('_prepareSiteForReplay()'));
      final String nav = body(
        page,
        'Future<WebMineNavigateOutcome> _navigateForMining(',
        'Future<void> _runMineQueue(',
      );
      expect(nav, contains('_prepareSiteForReplay()'));
      final String prep = body(
        page,
        'Future<void> _prepareSiteForReplay()',
        'void _beginRestore(',
      );
      expect(prep, contains('_setNativeSubtitlesHidden(true)'));
      expect(prep, contains("_selectSiteTextTrack('')"));
      expect(page, contains('_hideNativeSubtitles || _mineRunning'));
    });

    test('replay end restores subtitles, tracks and position', () {
      final String run = body(
        page,
        'Future<void> _runMineQueue(',
        'Future<String?> _mineQueuedRow(',
      );
      // 还原步骤是 [runWebMineQueueRound] 的 cleanup 列表（body 抛不抛都逐步执行，
      // BUG-4829），不再是一个 finally 块。
      final int cleanupAt = run.indexOf('cleanup: <Future<void> Function()>[');
      expect(
        cleanupAt,
        greaterThanOrEqualTo(0),
        reason: 'missing cleanup list',
      );
      final String fin = run.substring(cleanupAt);
      expect(fin, contains('_setNativeSubtitlesHidden(_hideNativeSubtitles)'));
      expect(fin, contains('_beginRestore(_replayOrigin)'));
    });

    test('both handoff paths come back to the original hosting', () {
      final String manualWindowed = body(
        page,
        'void _openBuiltinForMining()',
        ');',
      );
      expect(manualWindowed, contains('returnHostingAfterMining'));
      final String nativeHandoff = body(
        webSource,
        'Future<void> _runWebMineQueue(',
        'void _applyWebPendingRestore(',
      );
      expect(
        nativeHandoff,
        contains('returnHostingAfterMining: WebVideoHosting.windowed'),
      );
      expect(nativeHandoff, contains('mineReturnState:'));
      final String finish = body(
        page,
        'void _finishMining(',
        'WebMineReturnState? _currentReturnState()',
      );
      expect(
        finish,
        contains(
          'final WebMineReturnState? origin = _replayOrigin ?? widget.mineReturnState;',
        ),
      );
      expect(
        finish,
        contains('mineReturnState: auto ? origin?.paused() : origin'),
      );
    });

    // 拍板 design-nmv-webmine-rebuild-paused：空闲自动制卡途中 WebView 进程死掉，重建出的
    // 页面不能在用户不在场时自动播放出声。
    test('idle auto round restores to paused, rebuilt surface held paused', () {
      final String run = body(
        page,
        'Future<void> _runMineQueue(',
        'Future<String?> _mineQueuedRow(',
      );
      expect(
        run,
        contains('_replayOrigin = auto ? origin?.paused() : origin;'),
      );
      expect(run, contains('if (sawError || surfaceLost()) await _pause();'));
      final String fin = run.substring(
        run.indexOf('cleanup: <Future<void> Function()>['),
      );
      final int clear = fin.indexOf('_holdRebuiltSurfacePaused = false;');
      expect(clear, greaterThanOrEqualTo(0));
      expect(clear, lessThan(fin.indexOf('_beginRestore(_replayOrigin)')));
      final String recover = body(
        page,
        'Future<void> _recoverFromProcessGone()',
        'void _seedWarmPopup()',
      );
      expect(
        recover,
        contains('if (_mineRunning) _holdRebuiltSurfacePaused = true;'),
      );
      final String onState = body(page, 'void _onState(', 'void _onKeyToken(');
      expect(
        onState,
        contains('if (_holdRebuiltSurfacePaused && state.isPlaying)'),
      );
      final String apply = body(
        page,
        'void _applyPendingRestore(',
        'Future<void> _preStartSilentAudio()',
      );
      expect(apply, contains('switch (plan.setPlaying)'));
      final String nativeApply = body(
        webSource,
        'void _applyWebPendingRestore(',
        '\n  }\n',
      );
      expect(nativeApply, contains('switch (plan.setPlaying)'));
      expect(nativeApply, contains('controller.pause()'));
    });

    // 后台空闲制卡页（closeAfterMining，用户不在场）：开页前就要静音、开不了跑要按时收尾、
    // 机器驱动的播放不写续播点、关的是自己这条路由。
    test('background mining page pre-starts silent capture', () {
      expect(
        page,
        contains(
          'bool get _isMiningHost =>\n'
          '      widget.returnHostingAfterMining != null || widget.closeAfterMining;',
        ),
      );
      final String created = body(
        page,
        'void _onSurfaceCreated(InAppWebViewController _) {',
        'unawaited(_applyShaderTier());',
      );
      expect(created, contains('if (_isMiningHost && !_windowed'));
      expect(created, contains('_preStartSilentAudio()'));
      // 「会话音量残留还原」只给用户自己的页：后台制卡页开播时做它会把刚压低的会话放出声。
      final String onState = body(page, 'void _onState(', 'void _onKeyToken(');
      expect(onState, contains('!_isMiningHost &&'));
    });

    test('idle auto mining page gives up when it never starts', () {
      final String init = body(page, 'void initState() {', '@override');
      expect(init, contains('if (widget.idleAutoMining)'));
      expect(
        init,
        contains('Timer(kWebMineAutoStartTimeout, _onAutoStartTimeout)'),
      );
      final String timeout = body(
        page,
        'void _onAutoStartTimeout()',
        'Future<void> _initGuarded()',
      );
      expect(timeout, contains('_autoRunTriggered || _mineRunning'));
      expect(timeout, contains('_finishMining(auto: true'));
      expect(
        body(page, 'void dispose() {', '_flushPosition'),
        contains('_autoStartDeadline?.cancel()'),
      );
      // 打开时队列已空：直接收尾，不等截止。
      final String refresh = body(
        page,
        'Future<void> _refreshMinePending()',
        'void _maybeAutoRunMineQueue()',
      );
      expect(refresh, contains('n == 0 &&'));
      expect(refresh, contains('widget.idleAutoMining &&'));
      expect(refresh, contains('_finishMining(auto: true, status: null)'));
    });

    test('background mining page never writes the resume position', () {
      // 判据收成 [_playheadIsUsers]（BUG-4834）：队列重放期间与制卡宿主页
      // （后台制卡页 closeAfterMining 是其中一种）都不是用户的播放头。
      expect(
        page,
        contains(
          'bool get _playheadIsUsers => !_mineRunning && !_isMiningHost;',
        ),
      );
      final String onState = body(page, 'void _onState(', 'void _onKeyToken(');
      expect(onState, contains('if (_playheadIsUsers) {'));
      // dispose / 切宿主档的 flush 与每秒一次的写入都经 [_persistPosition]，门在它开头。
      final String persist = body(
        page,
        'Future<void> _persistPosition(int posMs) async {',
        'Future<void> _flushPosition() async {',
      );
      final int gate = persist.indexOf('if (!_playheadIsUsers) return;');
      expect(gate, greaterThanOrEqualTo(0));
      expect(gate, lessThan(persist.indexOf('setPref(')));
      expect(gate, lessThan(persist.indexOf('updatePosition(')));
      final String flush = body(
        page,
        'Future<void> _flushPosition() async {',
        '/// 每条站点播放快照都过一次',
      );
      expect(flush, contains('await _persistPosition(pos);'));
      expect(flush, isNot(contains('setPref(')));
      expect(flush, isNot(contains('updatePosition(')));
    });

    test('background mining page closes its own route', () {
      final String close = body(
        page,
        'void _closeAfterMining({',
        'WebMineReturnState? _currentReturnState()',
      );
      expect(close, isNot(contains('.maybePop(')));
      expect(close, contains('ModalRoute.of(context)'));
      expect(close, contains('navigator.removeRoute(route)'));
    });

    test('glue: empty track id selects the none track', () {
      final String select = body(
        glue,
        'function selectNetflixTrack(trackId)',
        'function selectNetflixAudioTrack(',
      );
      expect(select, contains("trackId === ''"));
      expect(select, contains('isNoneTrack'));
    });
  });

  group('WebMineRestoreTracker（每项动作最多首发 + 一次补发，不再每秒重发）', () {
    final DateTime t0 = DateTime(2026, 11, 6, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    final WebMineReturnState target = WebMineReturnState.of(
      _state(positionMs: 600000, text: 'ja'),
    );

    test('位置一直对不上：seek 只发两次（首发 + 隔 4 s 补一次），之后结束', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      final List<int?> seeks = <int?>[];
      WebMineRestorePlan? last;
      for (int ms = 0; ms <= 12000; ms += 250) {
        last = tr.step(_state(positionMs: 10000), at(ms));
        if (last == null) break;
        if (last.seekMs != null) seeks.add(ms);
      }
      expect(seeks, <int>[0, kWebMineRestoreRetryGap.inMilliseconds]);
      expect(last, isNull, reason: '次数用完即结束，不再拖到 30 s 期限');
    });

    test('seek 落地后结束，不补发', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      expect(tr.step(_state(positionMs: 10000), at(0))?.seekMs, 600000);
      expect(tr.step(_state(positionMs: 10000), at(250))?.seekMs, isNull);
      expect(tr.step(_state(positionMs: 600200), at(500)), isNull);
    });

    test('seek 落地后轨还没对齐、续播漂出容差：不再补 seek 把用户拉回去', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      expect(
        tr.step(_state(positionMs: 10000, text: 'en'), at(0))?.seekMs,
        600000,
      );
      // 落地（轨还是 en，没报回来）。
      expect(
        tr.step(_state(positionMs: 600100, text: 'en'), at(500))?.seekMs,
        isNull,
      );
      // 站点自动续播 5 s：位置早已超出 1.5 s 容差，但 seek 已对齐过，不再补。
      final WebMineRestorePlan? later = tr.step(
        _state(positionMs: 605000, text: 'en'),
        at(5000),
      );
      expect(later?.seekMs, isNull);
      expect(later?.selectTextTrack, 'ja', reason: '轨照常补发一次');
    });

    test('轨与位置同一拍下发（不再一项一项每秒排队）', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      final WebMineRestorePlan? p = tr.step(
        _state(positionMs: 10000, text: 'en', audio: 'a-en'),
        at(0),
      );
      expect(p?.selectTextTrack, 'ja');
      expect(p?.selectAudioTrack, 'a-ja');
      expect(p?.seekMs, 600000);
    });

    test('不在同一集：只导航一次，之后等新一集报上来再 seek', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      final WebMineRestorePlan? nav = tr.step(_state(videoKey: 'nf:2'), at(0));
      expect(nav?.navigateHref, 'https://www.netflix.com/watch/1');
      expect(tr.step(_state(videoKey: 'nf:2'), at(5000))?.navigateHref, isNull);
      expect(tr.step(_state(positionMs: 0), at(6000))?.seekMs, 600000);
    });

    test('重建页先报暂停、seek 途中才自动播放：照样暂停（没发过不算对齐）', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      final WebMineRestorePlan? first = tr.step(_state(positionMs: 0), at(0));
      expect(first?.seekMs, 600000);
      expect(first?.setPlaying, isNull);
      final WebMineRestorePlan? auto = tr.step(
        _state(positionMs: 600100, paused: false),
        at(500),
      );
      expect(auto?.setPlaying, isFalse);
    });

    test('暂停落地后用户自己按播放：不再被拉回暂停', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      expect(
        tr.step(_state(positionMs: 600000, paused: false), at(0))?.setPlaying,
        isFalse,
      );
      // 暂停落地，其余都已一致 → 本轮结束。
      expect(tr.step(_state(positionMs: 600000), at(500)), isNull);
    });

    test('暂停一直没落地：只发两次', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      final List<int> pauses = <int>[];
      WebMineRestorePlan? last;
      for (int ms = 0; ms <= 12000; ms += 250) {
        last = tr.step(_state(positionMs: 600000, paused: false), at(ms));
        if (last == null) break;
        if (last.setPlaying == false) pauses.add(ms);
      }
      expect(pauses, <int>[0, kWebMineRestoreRetryGap.inMilliseconds]);
      expect(last, isNull);
    });

    test('过了期限就结束', () {
      final WebMineRestoreTracker tr = WebMineRestoreTracker(target, now: t0);
      expect(
        tr.step(
          _state(positionMs: 0),
          t0.add(kWebMineRestoreDeadline + const Duration(seconds: 1)),
        ),
        isNull,
      );
    });
  });
}
