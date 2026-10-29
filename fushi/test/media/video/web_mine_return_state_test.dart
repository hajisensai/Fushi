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
}) => WebVideoPlaybackState(
  href: 'https://www.netflix.com/watch/1',
  videoKey: videoKey,
  hasVideo: true,
  positionMs: positionMs,
  paused: true,
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
        'Future<bool> _navigateForMining(',
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
      final String fin = run.substring(run.indexOf('} finally {'));
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
        contains('mineReturnState: widget.mineReturnState ?? _replayOrigin'),
      );
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
        'onWebViewCreated: (InAppWebViewController controller) {',
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
      final String onState = body(page, 'void _onState(', 'void _onKeyToken(');
      expect(
        onState,
        contains('if (!_mineRunning && !widget.closeAfterMining)'),
      );
      expect(
        page,
        contains('if (!widget.closeAfterMining) unawaited(_flushPosition());'),
      );
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
}
