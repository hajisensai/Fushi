import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// Source guard for video mining context.
///
/// media_kit cannot be driven in headless widget tests here, but the regression
/// is in the ownership of the mining cue: the user clicks a subtitle sentence,
/// then may spend time in the dictionary popup before pressing mine. The audio
/// clip and GIF must use that lookup cue, not whatever cue is current later.
void main() {
  // TODO-590 batch13: `_lookupAt` 已搬进 lookup_favorite.part.dart，改读合并语料。
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
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

    // TODO-590 batch13: `_lookupAt` 与 `_refreshVideoSentenceFavorite` 同搬进
    // lookup_favorite.part.dart 且相邻；end marker 由留主壳的 `_onDismissBarrierTap`
    // 改成 part 里紧跟 `_lookupAt` 的 `_refreshVideoSentenceFavorite`，精确夹住
    // `_lookupAt` 体（合并语料把 part 拼末尾，旧 marker 在 start 前会切片失败）。
    final String lookup = region(
      'Future<void> _lookupAt(',
      'Future<void> _refreshVideoSentenceFavorite(',
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
    // TODO-270 D：onMineEntry 返回类型从 Future<bool> 改为 Future<MinePopupResult>。
    // TODO-270 E：制卡 cue / 区间 / 文本解析收口到 _resolveVideoMiningRange（onMineEntry
    // 与 onUpdateEntry 共用，避免两份漂移），守卫锚点随之搬到该 helper。语义不变：选中句
    // 优先（字幕列表多选，独立入口）→ 否则查词草稿合并，当前 cue 走 lookup 缓存兜底。
    // TODO-590 batch14: `_resolveVideoMiningRange` / `onMineEntry` 体 / `_mineVideoCard`
    // 等制卡方法已搬进 lookup_mining.part.dart；合并语料把主壳排在 part 前，所以
    // end marker 必须用 part 内紧跟 `_resolveVideoMiningRange` 的 `_onMineEntryImpl`
    // 签名（旧 `onMineEntry(` 已变主壳里的瘦转发器、位于 start 之前会切片失败）。
    final String resolve = region(
      '_resolveVideoMiningRange(VideoPlayerController controller) {',
      'Future<MinePopupResult> _onMineEntryImpl(',
    );
    // 字幕列表多选（TODO-102）优先：合成 cue 单段区间 + join 文本，不掺草稿。
    expect(resolve, contains('if (selectedCue != null) {'),
        reason:
            'Mining must prefer the selected cue (subtitle list multi-select).');
    expect(resolve, contains('usedSelectedCue: true'));
    // 否则查词草稿路径：当前 cue lookup 缓存（不漂移）→ currentCue → 按位置解析多段兜底，
    // 覆盖未经查词捕获 / 制卡瞬间字幕又消失的边界（TODO-104b / BUG-188，保证句子音频非空）。
    expect(resolve, contains('_lastLookupCue ??'),
        reason:
            'Draft path must anchor on the cached lookup cue, no later drift.');
    expect(resolve, contains('controller.currentCue ??'));
    expect(resolve, contains('resolveMiningCueForPosition('),
        reason: 'currentCue 为空（gap/末句后）时须按位置解析，制卡才有句子音频。');
    // 制卡区间 = 合并后的首句起→末句止（单句即该 cue 时间窗）；草稿空时退回单 cue 起止。
    expect(resolve, contains('mergedRange?.startMs ?? cue?.startMs ?? 0'),
        reason: '制卡音频/封面区间起点 = 合并区间起点（单句即该 cue 的 startMs）。');
    expect(resolve, contains('mergedRange?.endMs ?? cue?.endMs ?? 0'),
        reason: '制卡音频/封面区间终点 = 合并区间终点（单句即该 cue 的 endMs）。');

    // onMineEntry 把解析结果喂给落卡链路 _mineVideoCard（单句/多句同一出口）。
    // TODO-590 batch14: onMineEntry 体搬进 part 的 `_onMineEntryImpl`；end marker
    // 改用 part 内紧随其后的 `_onUpdateEntryImpl` 签名（旧 `TODO-270 D：覆盖` 文案
    // 跟着 onUpdateEntry 瘦转发器留在主壳，位于 start 之前会切片失败）。
    final String mine = region(
      'Future<MinePopupResult> _onMineEntryImpl(Map<String, String> fields) async {',
      'Future<MinePopupResult> _onUpdateEntryImpl(',
    );
    expect(mine, contains('_resolveVideoMiningRange(controller)'));
    expect(mine, contains('clipStartMs: range.clipStartMs'));
    expect(mine, contains('clipEndMs: range.clipEndMs'));
    expect(mine, contains('sentence: range.sentence'));
    expect(mine, contains('cueSentence: range.cueSentence'));
  });

  test('_mineVideoCard extracts the passed [clipStartMs, clipEndMs] range', () {
    // 落卡链路把区间端点喂给真实的 ffmpeg 抽取器（单句 = cue 时间窗）。
    // TODO-270 D：返回类型改为 Future<MinePopupResult>（成功带回 note id）。
    // TODO-590 batch14: `_mineVideoCard` 搬进 lookup_mining.part.dart，部内紧随其后
    // 的是 `_recordMinedSentenceForVideo`；end marker 改用它（`_handleBackOrExit` 留主壳、
    // 在合并语料里排在 part 之前，会切片失败）。
    final String mineCard = region(
      'Future<MinePopupResult> _mineVideoCard(',
      'Future<void> _recordMinedSentenceForVideo(',
    );
    expect(mineCard, contains('startMs: clipStartMs'),
        reason: '区间音频/封面起点必须是传入的 clipStartMs。');
    expect(mineCard, contains('endMs: clipEndMs'),
        reason: '区间音频/封面终点必须是传入的 clipEndMs。');
    expect(mineCard, contains('extractAudioSegmentViaFfmpeg('),
        reason: '区间音频走真实 ffmpeg 抽取器（绝无 TTS）。');
  });

  test('_mineVideoCard surfaces a silent sentence-audio clip failure (BUG-296)',
      () {
    // BUG-296 / TODO-390：有区间（hasRange）说明这张卡本应带句子音频，但 ffmpeg
    // 抽段返回 null（真机 ffmpeg 不可用 / 音轨不可解码 / 容器读取失败）时过去是
    // 完全静默丢弃——用户看到「制卡成功」却没句子音频，无从诊断（正是反复报
    // 「ひびき 卡组没句子音频」却定位不到的盲区）。落卡链路必须把这条丢弃变为
    // 可追踪日志 + OSD 提示，并中止本次制卡，不能落一张成功但无句子音频的卡。
    // TODO-590 batch14: `_mineVideoCard` 搬进 lookup_mining.part.dart，部内紧随其后
    // 的是 `_recordMinedSentenceForVideo`；end marker 改用它（`_handleBackOrExit` 留主壳、
    // 在合并语料里排在 part 之前，会切片失败）。
    final String mineCard = region(
      'Future<MinePopupResult> _mineVideoCard(',
      'Future<void> _recordMinedSentenceForVideo(',
    );
    expect(mineCard, contains('if (audioPath == null) {'),
        reason: '抽段失败（audioPath==null）须被显式处理，而非静默落空。');
    expect(mineCard, contains('sentence-audio clip failed'),
        reason: '抽段失败须打可追踪日志（含区间端点供诊断）。');
    expect(mineCard, contains('card_export_failed_detail'),
        reason: '抽段失败须给用户可见的 OSD 提示（复用现有 i18n，不静默）。');
    expect(mineCard, contains('String? audioFailure'),
        reason: 'OSD/日志应携带底层 ffmpeg 诊断摘要，而不是只有泛化失败文案。');
    expect(mineCard, contains('onFailure: (String summary)'),
        reason: 'extractAudioSegmentViaFfmpeg 的失败摘要必须传回视频制卡路径。');
    expect(mineCard, contains(r'sentence audio export failed: $audioFailure'),
        reason: '用户可见错误应含实际 executable/fallback/0xC000007B 等摘要。');
    expect(mineCard, contains('GIF clip export failed'),
        reason: 'GIF 导出失败虽可回退截图，也必须留下 ffmpeg 诊断。');

    final int failureGuardIndex = mineCard.indexOf('if (audioPath == null) {');
    final int abortIndex = mineCard.indexOf(
      'return const MinePopupResult();',
      failureGuardIndex,
    );
    final int contextIndex =
        mineCard.indexOf('final AnkiMiningContext miningContext');
    expect(failureGuardIndex, greaterThanOrEqualTo(0));
    expect(abortIndex, greaterThan(failureGuardIndex),
        reason: '句子音频导出失败后必须中止视频制卡，不能继续构造缺音频 context。');
    expect(abortIndex, lessThan(contextIndex),
        reason: '中止必须发生在 repo.mineEntry/updateMinedNote 之前。');
  });
}
