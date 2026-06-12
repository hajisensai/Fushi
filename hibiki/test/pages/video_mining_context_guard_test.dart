import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for video mining context.
///
/// media_kit cannot be driven in headless widget tests here, but the regression
/// is in the ownership of the mining cue: the user clicks a subtitle sentence,
/// then may spend time in the dictionary popup before pressing mine. The audio
/// clip and GIF must use that lookup cue, not whatever cue is current later.
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue);
    src = page.readAsStringSync();
  });

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('video mining caches the cue at subtitle lookup time', () {
    expect(src.contains('AudioCue? _lastLookupCue'), isTrue,
        reason:
            'Video mining needs the subtitle cue from the original lookup.');

    final String lookup = region(
      'Future<void> _lookupAt(',
      'void _onDismissBarrierTap(',
    );
    // 点字幕字符时仍快照当前 cue……
    expect(lookup.contains('_lastLookupCue = controller.currentCue'), isTrue,
        reason: 'Tapping a subtitle character must snapshot the current cue.');
    // ……但 currentCue 在字幕 gap / 末句后被清成 null（BUG-074）。TODO-104b / BUG-188：
    // 用户常在字幕刚消失那一瞬制卡，故 null 时必须按位置独立解析最近一条 cue，
    // 否则制卡缺真实句子音频（绝无 TTS）。
    expect(
      lookup.contains('resolveMiningCueForPosition('),
      isTrue,
      reason: 'gap 时（currentCue==null）须按播放位置解析最近 cue，保证句子音频非空。',
    );
  });

  test('video mining exports media from the cached lookup cue', () {
    final String mine = region(
      'Future<bool> onMineEntry(Map<String, String> fields) async {',
      'void _showAudioTrackMenu(VideoPlayerController controller) {',
    );
    // 制卡 cue 取值：lookup 缓存优先（不漂移到后来的 cue），其后以 currentCue →
    // 按位置解析二段兜底，覆盖未经查词捕获 / 制卡瞬间字幕又消失的边界
    // （TODO-104b / BUG-188，保证有 cue 可裁真实句子音频）。
    expect(mine, contains('final AudioCue? cue = _lastLookupCue ??'),
        reason:
            'Mining must start from the cached lookup cue, no later drift.');
    expect(mine, contains('controller.currentCue ??'));
    expect(mine, contains('resolveMiningCueForPosition('),
        reason: 'currentCue 为空（gap/末句后）时须按位置解析，制卡才有句子音频。');
    // TODO-102 重构后单句制卡把 cue 的时间窗作区间 [clipStartMs, clipEndMs] 传给统一落卡
    // 链路 _mineVideoCard（与跨字幕共用一条音频/封面抽取链路），故区间来自 cue 的起止。
    expect(mine, contains('clipStartMs: cue?.startMs ?? 0'),
        reason: '单句制卡音频区间起点必须是该 cue 的 startMs（经 _mineVideoCard）。');
    expect(mine, contains('clipEndMs: cue?.endMs ?? 0'),
        reason: '单句制卡音频区间终点必须是该 cue 的 endMs（经 _mineVideoCard）。');
    expect(mine, contains('cueSentence: cue?.text'));
  });

  test(
      'TODO-102: _mineVideoCard extracts the passed [clipStartMs, clipEndMs] range',
      () {
    // 统一落卡链路把区间端点喂给真实的 ffmpeg 抽取器（单句 = cue 时间窗；跨字幕 = 整段）。
    final String mineCard = region(
      'Future<bool> _mineVideoCard(',
      'void _toggleCrossSubtitleRecording() {',
    );
    expect(mineCard, contains('startMs: clipStartMs'),
        reason: '区间音频/封面起点必须是传入的 clipStartMs。');
    expect(mineCard, contains('endMs: clipEndMs'),
        reason: '区间音频/封面终点必须是传入的 clipEndMs。');
    expect(mineCard, contains('extractAudioSegmentViaFfmpeg('),
        reason: '区间音频走真实 ffmpeg 抽取器（绝无 TTS）。');
  });
}
