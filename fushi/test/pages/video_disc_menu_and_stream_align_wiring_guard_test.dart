// 源码接线守卫（反馈批次 bluray-mediaserver）：
// - BUG-3290：原盘菜单的方向键 / 点击走「是否被原盘接收」的入口，不再把未接收当错误；
// - st-N1qypUF：原盘菜单顶栏替换了常规控制条，必须另给全屏键；
// - 5m4b74SHhv：媒体服务器流的波形 / 自动对轴走只裁前 N 分钟的对轴音源，ASR 仍只认整集音源。
// 这三处都在超大页面 / 控制器里，行为测试要起真播放器，故钉源码接线。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// [source] 里从 [start] 开始的那个成员（到下一个两空格缩进的成员声明为止）。
String _member(String source, String start) {
  final int at = source.indexOf(start);
  expect(at, isNonNegative, reason: 'missing: $start');
  final RegExp next = RegExp(r'\n  (?:[A-Za-z_<]|///)');
  final Match? end = next.firstMatch(source.substring(at + start.length));
  return end == null
      ? source.substring(at)
      : source.substring(at, at + start.length + end.start);
}

void main() {
  test('disc input commands report consumption instead of throwing', () {
    final String body = _member(
      _read('lib/src/media/video/video_disc_menu.part.dart'),
      'Future<void> _sendDiscCommand(',
    );
    expect(body, contains('isVideoDiscInputCommand(command)'));
    expect(body, contains('runVideoDiscInputCommand(native, command)'));
    expect(body, contains('runCheckedVideoDiscCommand(native, command)'));
    // 未接收与「当前流已不是可导航原盘」在 mpv 那里是同一个 -12：不能只 debugPrint
    // 吞掉，要留进诊断日志；菜单状态由命令后的重采样判定。
    expect(body, contains('ErrorLogService.instance.logDiagnostic('));
    expect(body, isNot(contains('debugPrint(')));
    final int input = body.indexOf('runVideoDiscInputCommand(native, command)');
    final int resample = body.lastIndexOf('_sampleDiscMenu(player, token)');
    expect(resample, greaterThan(input), reason: '命令后必须重采样菜单状态');
  });

  test('the authored-menu chrome carries its own fullscreen button', () {
    final String body = _member(
      _read('lib/src/pages/implementations/video_fushi/disc_menu.part.dart'),
      'Widget _buildDiscMenuChrome(',
    );
    expect(body, contains('VideoControlItem.fullscreen'));
    expect(body, contains("'bluray-menu-fullscreen'"));
    expect(body, contains('_buildFullscreenButton(desktop: desktop)'));
    expect(body, contains('!isMobilePlatform'));
  });

  test('waveform and auto-align accept stream audio; ASR does not', () {
    final String subtitle = _read(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    );
    final String page = _read(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    for (final String start in <String>[
      'Future<List<double>> _loadSubtitleWaveformEnvelope(',
      'Future<void> _openSubtitleWaveformAlign(',
      'Future<int?> _autoAlignSubtitle(',
    ]) {
      final String body = _member(subtitle, start);
      expect(
        body,
        isNot(contains('_resolveSubtitleTimingAudio()')),
        reason: start,
      );
      expect(
        body,
        isNot(contains('!_canResolveSubtitleTimingAudio')),
        reason: start,
      );
    }
    expect(
      _member(subtitle, 'Future<List<double>> _loadSubtitleWaveformEnvelope('),
      contains('_resolveSubtitleAlignAudio()'),
    );
    expect(
      _member(subtitle, 'Future<String?> _transcribeVideoSpeech('),
      contains('_resolveSubtitleTimingAudio()'),
    );
    // 流对轴音源与制卡同一判据、同一中继。
    final String fetch = _member(
      subtitle,
      'Future<String?> _fetchStreamAlignAudio(',
    );
    expect(fetch, contains('relayFfmpegRemoteInput('));
    expect(fetch, contains('ffmpegRemoteInputFor(relayed.url)'));
    expect(fetch, contains('httpHeaders: headers'));
    expect(
      _member(subtitle, 'String? get _streamAlignAudioSource'),
      contains('videoMiningInputUsesPlaybackRelay('),
    );
    expect(
      RegExp(
        r'_canResolveSubtitleAlignAudio\s*\n?\s*\? _loadSubtitleWaveformEnvelope',
      ).hasMatch(page),
      isTrue,
    );
    expect(
      RegExp(
        r'_canResolveSubtitleAlignAudio\s*\n?\s*\? _autoAlignSubtitle',
      ).hasMatch(page),
      isTrue,
    );
  });

  test('stream align audio, envelope and window share one probe limit', () {
    final String subtitle = _read(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    );
    // 流只拉前 3 分钟：抽音 / -t / cue 栅格化 / 波形窗口都取同一个 getter，
    // 页面里不许再直接用 20 分钟常量（否则两侧栅格长度不一致、窗口与音频错位）。
    expect(
      _member(subtitle, 'int get _subtitleAlignProbeLimitMs'),
      contains('subtitleAlignProbeLimitMs('),
    );
    expect(
      subtitle.contains('limitMs: kSubtitleAutoAlignProbeLimitMs'),
      isFalse,
    );
    expect(
      _member(subtitle, 'Future<String?> _fetchStreamAlignAudio('),
      isNot(contains('kSubtitleAutoAlignProbeLimitMs')),
    );
    expect(
      _member(
        subtitle,
        'Future<_SubtitleTimingAudio?> _resolveSubtitleAlignAudio(',
      ),
      contains('_subtitleAlignProbeLimitMs'),
    );
    final String page = _read(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    expect(page, contains('subtitleProbeLimitMs: _subtitleAlignProbeLimitMs'));
  });
}
