// BUG-3103：选中图形字幕后重开视频，图形字幕不能被库里残留的旧 cue 顶掉。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_restore_plan.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../pages/video_fushi_page_source_corpus.dart';

AudioCue _cue(String text, int start) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = start
  ..endMs = start + 1000
  ..audioFileIndex = 0;

void main() {
  final List<AudioCue> stale = <AudioCue>[_cue('旧的文本字幕', 0)];

  test('重解析出图形轨：清掉库里的旧 cue，把图形轨序号交给播放器渲染', () {
    final SubtitleLoadPlan plan = mergeRestoredEmbeddedSubtitle(
      cachedCues: stale,
      persisted: 'embedded:1',
      restored: (
        persisted: 'embedded:1',
        cues: const <AudioCue>[],
        graphicStreamIndex: 1,
      ),
    );
    expect(plan.cues, isEmpty, reason: '旧文本 cue 不能盖在图形字幕上');
    expect(plan.graphicStreamIndex, 1);
    expect(plan.externalSubtitle, 'embedded:1');
  });

  test('重解析出文本轨：用重解析的 cue（带 ASS 样式）', () {
    final List<AudioCue> fresh = <AudioCue>[_cue('新', 0)];
    final SubtitleLoadPlan plan = mergeRestoredEmbeddedSubtitle(
      cachedCues: stale,
      persisted: 'embedded:0',
      restored: (
        persisted: 'embedded:0',
        cues: fresh,
        graphicStreamIndex: null,
      ),
    );
    expect(plan.cues, same(fresh));
    expect(plan.graphicStreamIndex, isNull);
  });

  test('重解析失败：保留库里的 cue（仅缺样式不缺内容）', () {
    final SubtitleLoadPlan plan = mergeRestoredEmbeddedSubtitle(
      cachedCues: stale,
      persisted: 'embedded:0',
      restored: null,
    );
    expect(plan.cues, same(stale));
    expect(plan.externalSubtitle, 'embedded:0');
    expect(plan.graphicStreamIndex, isNull);
  });

  test('视频页接线：重解析分支走 mergeRestoredEmbeddedSubtitle 并透传图形轨', () {
    final String src = readVideoFushiSource();
    final int start = src.indexOf('Future<void> _loadSingle(');
    final int end = src.indexOf(
      '_relocateSingleMediaPaths(VideoBookRow row)',
      start,
    );
    final String body = src.substring(start, end);
    expect(body.contains('mergeRestoredEmbeddedSubtitle('), isTrue);
    expect(
      body.contains('graphicStreamIndex = plan.graphicStreamIndex;'),
      isTrue,
    );
    // 已确定渲染图形轨就不再走「没 cue → sidecar 兜底」那条链。
    expect(
      body.contains(
        'if (!subtitleExplicitlyOff && cues.isEmpty && graphicStreamIndex == null)',
      ),
      isTrue,
    );
  });

  test('选中图形轨：播放列表里的一集也清掉库里的 cue', () {
    final String src = readVideoFushiSource();
    final int start = src.indexOf('Future<bool> _selectSubtitleSource(');
    final int graphic = src.indexOf('if (source.isGraphicEmbedded) {', start);
    final int end = src.indexOf('return true;', graphic);
    final String branch = src.substring(graphic, end);
    expect(branch.contains('saveSubtitleSelection('), isTrue);
    expect(branch.contains('cues: const <AudioCue>[]'), isTrue);
    expect(
      branch.contains('updateSubtitleSource('),
      isFalse,
      reason: '只写源指针会把旧 cue 留在库里，重开时顶掉图形字幕',
    );
  });
}
