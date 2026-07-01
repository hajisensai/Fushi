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
  // TODO-1000: 沉浸制卡引擎（ImmersionMiningEngine）接手了媒体降级阶梯 / 无音频中止 /
  // AnkiMiningContext 组装（原在 _mineVideoCard 里）。守卫按重构后真实位置分层扫：
  // shell（_mineVideoCard）扫 OSD/中止接线，engine 扫抽取器编排。行为不变，只是搬了家。
  late String engine;
  setUpAll(() {
    src = readVideoHibikiSource();
    engine = readImmersionMiningEngineSource();
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
    // TODO-1000: shell 把区间端点原样喂进沉浸引擎请求（clipStartMs/clipEndMs 直传），
    // 引擎再把 req.clipStartMs/req.clipEndMs 绑到真实音频抽取器 extractAudioSegmentViaFfmpeg。
    expect(mineCard, contains('clipStartMs: clipStartMs'),
        reason: '区间音频/封面起点必须是传入的 clipStartMs（喂进沉浸引擎请求）。');
    expect(mineCard, contains('clipEndMs: clipEndMs'),
        reason: '区间音频/封面终点必须是传入的 clipEndMs（喂进沉浸引擎请求）。');
    final String engineNorm = engine.replaceAll(RegExp(r'\s+'), ' ');
    expect(engineNorm, contains('startMs: req.clipStartMs'),
        reason: '引擎音频段起点绑到请求 clipStartMs。');
    expect(engineNorm, contains('endMs: req.clipEndMs'),
        reason: '引擎音频段终点绑到请求 clipEndMs。');
    expect(engine, contains('extractAudioSegmentViaFfmpeg'),
        reason: '区间音频走真实 ffmpeg 抽取器（绝无 TTS）。');
  });

  test('_mineVideoCard surfaces a silent sentence-audio clip failure (BUG-296)',
      () {
    // BUG-296 / TODO-390：有区间（hasRange）说明这张卡本应带句子音频，但 ffmpeg
    // 抽段返回 null（真机 ffmpeg 不可用 / 音轨不可解码 / 容器读取失败）时过去是
    // 完全静默丢弃——用户看到「制卡成功」却没句子音频，无从诊断（正是反复报
    // 「ひびき 卡组没句子音频」却定位不到的盲区）。落卡链路必须把这条丢弃变为
    // 可追踪日志 + OSD 提示，并中止本次制卡，不能落一张成功但无句子音频的卡。
    // TODO-1000: 无音频中止判据搬进沉浸引擎（req.requireAudio && req.hasRange &&
    // audioPath == null → 返回 aborted），shell 的 _mineVideoCard 据 res.aborted 出
    // 可追踪 OSD（含底层 ffmpeg 摘要）并中止。分层扫 engine（中止判据）+ shell（surface）。
    final String mineCard = region(
      'Future<MinePopupResult> _mineVideoCard(',
      'Future<void> _recordMinedSentenceForVideo(',
    );
    final String engineNorm = engine.replaceAll(RegExp(r'\s+'), ' ');
    // 引擎：有区间却抽不出音频（audioPath==null）须被显式处理（中止），而非静默落空。
    expect(engineNorm,
        contains('req.requireAudio && req.hasRange && audioPath == null'),
        reason: '抽段失败（有区间应带音频却 audioPath==null）须显式中止，而非静默落空。');
    expect(engineNorm, contains('ImmersionMiningResult(aborted: true)'),
        reason: '缺音频中止走 aborted 信号回 shell。');
    // shell：res.aborted → 用户可见 OSD（复用现有 i18n card_export_failed_detail）。
    expect(mineCard, contains('res.aborted'),
        reason: '抽段失败须被 shell 显式处理（据 aborted），而非静默落空。');
    expect(mineCard, contains('card_export_failed_detail'),
        reason: '抽段失败须给用户可见的 OSD 提示（复用现有 i18n，不静默）。');
    // 底层 ffmpeg 诊断摘要经 onFailure 回调传回（不是只有泛化失败文案）。
    expect(mineCard, contains('String? lastFailure'),
        reason: 'OSD/日志应携带底层 ffmpeg 诊断摘要，而不是只有泛化失败文案。');
    expect(mineCard, contains('onFailure: (String summary)'),
        reason: '抽取器（GIF/音频）的失败摘要必须传回视频制卡路径。');
    expect(mineCard, contains(r'sentence audio export failed: $lastFailure'),
        reason: '用户可见错误应含实际 executable/fallback/0xC000007B 等摘要。');
    // 引擎把 onFailure 转发给 GIF/音频抽取器，故 GIF 失败也留下 ffmpeg 诊断。
    expect(
        engineNorm.contains('await _gif(') &&
            engineNorm.contains('onFailure: onFailure'),
        isTrue,
        reason: 'GIF 导出失败虽可回退截图，也必须经 onFailure 留下 ffmpeg 诊断。');

    // 中止顺序：引擎在构造 AnkiMiningContext 之前就 return aborted（不建缺音频 context）；
    // shell 在读取 res.outcome!（落卡产物）之前据 res.aborted 中止。
    final int engineAbortIdx =
        engineNorm.indexOf('ImmersionMiningResult(aborted: true)');
    final int engineCtxIdx = engineNorm.indexOf('AnkiMiningContext context =');
    expect(engineAbortIdx, greaterThanOrEqualTo(0));
    expect(engineCtxIdx, greaterThan(engineAbortIdx),
        reason: '缺音频中止必须发生在组 AnkiMiningContext / repo.mineEntry 之前。');
    final int shellAbortIdx = mineCard.indexOf('if (res.aborted)');
    final int shellOutcomeIdx = mineCard.indexOf('res.outcome!');
    expect(shellAbortIdx, greaterThanOrEqualTo(0));
    expect(shellOutcomeIdx, greaterThan(shellAbortIdx),
        reason: '句子音频导出失败后必须中止，不能继续读落卡产物 res.outcome!。');
  });

  test(
      'TODO-816 ③: GIF fallback grabs the cue-time frame, not the current '
      'decoded frame', () {
    // 根因（TODO-816 ③）：GIF 不可用时旧兜底直接 controller.screenshot() 截**播放器
    // 当前解码帧**（从不 seek 到 cue 时间），所以一旦退到兜底，封面就是播放器当下停的帧
    // （常是片头/暂停处），与卡片例句不是同一段。GIF 主路径用的是 clipStartMs（经
    // miningClipTimeMs 逆变换回播放器轴的目标毫秒），降级帧必须用同一个 cue 时间从视频
    // 文件抽，才与例句对齐。
    // TODO-1000: 降级阶梯搬进沉浸引擎：GIF -> cue 时间抽单帧(_frame) -> stillFallback
    // (shell 传 controller.screenshot) 最后兜底。cue 抽帧的取帧时间 = req.clipStartMs/1000。
    final String engineNorm = engine.replaceAll(RegExp(r'\s+'), ' ');
    expect(engine, contains('extractVideoFrameViaFfmpeg'),
        reason: 'GIF 不可用时须按 cue 时间从视频文件抽单帧（而非截当前解码帧）。');
    expect(engineNorm, contains('atSeconds: req.clipStartMs / 1000.0'),
        reason: '降级帧的取帧时间必须 = clipStartMs（与 GIF 主路径同一播放器轴坐标）。');
    // shell 把当前解码帧截图作为最后兜底喂进引擎（stillFallback: controller.screenshot）。
    final String mineCard = region(
      'Future<MinePopupResult> _mineVideoCard(',
      'Future<void> _recordMinedSentenceForVideo(',
    );
    expect(mineCard, contains('stillFallback: controller.screenshot'),
        reason: '当前解码帧截图只作最后兜底，经 stillFallback 喂进引擎。');

    // 引擎里：cue 抽帧(_frame) 必须排在 stillFallback（当前解码帧）之前——有区间时优先按
    // cue 取帧，截当前帧只能是 cue 抽帧也失败/无区间后的最后兜底。
    final int frameIdx = engineNorm.indexOf('atSeconds: req.clipStartMs');
    final int stillIdx = engineNorm.indexOf('req.stillFallback!()');
    expect(frameIdx, greaterThanOrEqualTo(0));
    expect(stillIdx, greaterThan(frameIdx),
        reason: '当前帧截图只能是 cue 抽帧失败/无区间后的最后兜底，须排在按 cue 抽帧之后。');
  });

  test('TODO-816 ④: degrading a clip to a still frame surfaces an OSD', () {
    // 根因（TODO-816 ④）：动图降级为静态帧时旧实现仅 debugPrint 静默吞掉，用户不知拿到
    // 的是降级图。必须给用户可感知 OSD（复用 i18n，携带底层失败摘要）。
    // TODO-1000: 引擎显式跟踪「动图降级为静态」状态并回传 res.degradedToStill；shell 据此
    // 出可感知 OSD（复用 i18n，携带 GIF 失败底层摘要），异步路径 mounted 守卫。
    expect(engine, contains('bool degradedToStill'),
        reason: '须显式跟踪「动图降级为静态」状态，作为提示判据。');
    final String mineCard = region(
      'Future<MinePopupResult> _mineVideoCard(',
      'Future<void> _recordMinedSentenceForVideo(',
    );
    expect(mineCard, contains('res.degradedToStill && mounted'),
        reason: '降级提示须据引擎回传状态 + mounted 守卫，避免向已销毁页面 _showOsd。');
    expect(mineCard, contains('card_cover_degraded_to_static'),
        reason: '降级为静态图须给用户可见 OSD（不再只 debugPrint 静默吞掉）。');
    expect(mineCard, contains('reason: gifFailure ??'),
        reason: 'OSD 应携带 GIF 失败的底层 ffmpeg 诊断摘要，最贴近根因。');
  });

  test('TODO-971：制卡成功 OSD 用突出变体（醒目，区别于音量小角标）', () {
    // 视频页刻意不用底部 toast（会遮控制条）。但制卡成功旧走 _showOsd(message) 与
    // 音量/亮度同款左上角小角标，太轻易忽略。根因修复=保留 OSD 通道但制卡成功用
    // 突出（居中、更大、停留更久）变体。文案仍同源 describeMineOutcome →
    // card_exported(deck:)/card_overwritten(deck:)。
    final String mineImpl = region(
      'Future<MinePopupResult> _onMineEntryImpl(',
      'Future<void> _recordMinedSentenceForVideo(',
    );
    // 成功消息仍由 describeMineOutcome 统一产出（含牌组名）。
    expect(mineImpl.contains('describeMineOutcome('), isTrue,
        reason: '制卡成功/覆盖消息须由 describeMineOutcome 统一产出（含 deck 名）。');
    // 成功分支发出突出 OSD。
    expect(
      mineImpl.contains('_showOsd(described.message, prominent: true)'),
      isTrue,
      reason: 'TODO-971：制卡成功须走突出 OSD（prominent: true），不再是易忽略的小角标。',
    );
  });
}
