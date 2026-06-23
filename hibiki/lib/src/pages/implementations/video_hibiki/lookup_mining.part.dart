// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch14).
part of '../video_hibiki_page.dart';

/// Dictionary-lookup mining (制卡) domain extracted via part-of (TODO-590
/// batch14); shared private scope. Behaviour-preserving: every method body is
/// moved character-for-character except two kinds of @protected-member
/// normalisations forced by the extension boundary (an extension is not seen as
/// an instance member of the State subclass, so it cannot call @protected
/// members directly):
/// 1. the two `setState(...)` rebuilds (inside [_toggleCueSelectedForCard] and
///    [_clearSelectedMiningCues]) → routed through the main shell's
///    `_rebuild(...)` forwarder;
/// 2. the `recordMined()` call (inside [_mineVideoCard]) → routed through the
///    main shell's `_recordMinedForVideo()` forwarder.
/// Both forwarders are the established part paradigm (pure 1-line delegation,
/// zero behaviour change). No host-class static needed re-qualification: every collaborator
/// ([buildSelectedSubtitleCueContext], [miningClipTimeMs], [resolveMiningCueForPosition],
/// [extractClipGifViaFfmpeg], [extractAudioSegmentViaFfmpeg], [describeMineOutcome],
/// [statTodayKey], [downsampleCardScreenshot], [AnkiMiningContext], etc.) is a
/// top-level / mixin symbol in the same library.
///
/// The three @override mixin hooks — [onMineEntry], [onUpdateEntry] and the two
/// `onSetSentenceContextToDraft` / `onClearSentenceDraftToDraft` getters — must
/// stay in the main shell (an extension cannot carry `@override`). The two
/// getters already forward to private targets ([_setSentenceContextToDraft] /
/// [_clearSentenceDraft]), so only their private targets moved here. The two
/// `Future<MinePopupResult>` hooks became one-line forwarders in the shell
/// delegating to the byte-exact bodies [_onMineEntryImpl] / [_onUpdateEntryImpl]
/// living here. [buildPopupHeaderFor] stays in the shell (favourite header).
///
/// Covers the sentence-context draft helpers ([_cueRange],
/// [_setSentenceContextToDraft], [_clearSentenceDraft]), the subtitle-list card
/// selection ([_isCueSelectedForCard], [_toggleCueSelectedForCard],
/// [_clearSelectedMiningCues], [_selectedMiningCueForCard]), the mining range
/// resolver ([_resolveVideoMiningRange]), the mine/update entry bodies
/// ([_onMineEntryImpl], [_onUpdateEntryImpl]), the card landing path
/// ([_mineVideoCard]) and the mined-sentence history row ([_recordMinedSentenceForVideo]).
extension _VideoLookupMining on _VideoHibikiPageState {
  /// 把一条 cue 的画面/音频时间窗转成草稿可合并的区间。视频所有 cue 同属一个视频文件，
  /// [audioFileIndex] 统一用 0（合并恒成功，取 min start / max end）。null cue → null
  /// 区间（草稿据此退化为只合文本，不静默拼坏区间）。
  AudioPlaybackRange? _cueRange(AudioCue? cue) {
    if (cue == null) return null;
    return AudioPlaybackRange(
      audioFileIndex: 0,
      startMs: cue.startMs,
      endMs: cue.endMs,
    );
  }

  /// 以当前查词 cue（[_lastLookupCue]）为锚，在 [VideoPlayerController.cues]（按 startMs
  /// 升序）里取它之前 [prevCount] 条、之后 [nextCount] 条作上下文，整体设进草稿（覆盖
  /// 上次选择，不累积）。无 cue / 无控制器时清空上下文返回 0。
  Future<int> _setSentenceContextToDraft(int prevCount, int nextCount) async {
    final VideoPlayerController? controller = _controller;
    final AudioCue? anchor = _lastLookupCue;
    if (controller == null || anchor == null) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final List<AudioCue> cues = controller.cues;
    final int idx = cues.indexOf(anchor);
    if (idx < 0) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final int prevStart = (idx - prevCount).clamp(0, idx);
    final List<MiningDraftSentence> prev = <MiningDraftSentence>[
      for (int i = prevStart; i < idx; i++)
        MiningDraftSentence(
            sentence: cues[i].text, audioRange: _cueRange(cues[i])),
    ];
    final int nextEnd = (idx + 1 + nextCount).clamp(idx + 1, cues.length);
    final List<MiningDraftSentence> next = <MiningDraftSentence>[
      for (int i = idx + 1; i < nextEnd; i++)
        MiningDraftSentence(
            sentence: cues[i].text, audioRange: _cueRange(cues[i])),
    ];
    _miningDraft.setContext(prev: prev, next: next);
    return _miningDraft.length;
  }

  Future<int> _clearSentenceDraft() async {
    _miningDraft.clear();
    return _miningDraft.length;
  }

  /// 制卡（覆写 [DictionaryPageMixin.onMineEntry]）：在词典 [fields]（已含单词
  /// 发音 `{audio}`、例句字段等）基础上，注入视频专属上下文——当前帧截图
  /// coverPath（→`{book-cover}`）+ 当前字幕 cue 的音频片段（裁**当前选中音轨**）
  /// sasayakiAudioPath（→`{sasayaki-audio}`）+ 例句 sentence。复用现有 Anki 字段。
  bool _isCueSelectedForCard(AudioCue cue) =>
      _selectedMiningCueStarts.contains(cue.startMs);

  void _toggleCueSelectedForCard(AudioCue cue) {
    _rebuild(() {
      if (!_selectedMiningCueStarts.add(cue.startMs)) {
        _selectedMiningCueStarts.remove(cue.startMs);
      }
    });
  }

  void _clearSelectedMiningCues() {
    if (_selectedMiningCueStarts.isEmpty) return;
    _rebuild(_selectedMiningCueStarts.clear);
  }

  AudioCue? _selectedMiningCueForCard(VideoPlayerController controller) {
    return buildSelectedSubtitleCueContext(
      cues: controller.cues,
      selectedStartMs: _selectedMiningCueStarts,
    );
  }

  /// 视频制卡/覆盖共用的「解析这一张卡的区间 + 文本」。把三个并存入口收口成一处，避免
  /// [onMineEntry] / [onUpdateEntry] 两份漂移：
  /// - **字幕列表多选**（TODO-102，[_selectedMiningCueStarts] 非空）优先：用
  ///   [buildSelectedSubtitleCueContext] 合成的单段区间 + join 文本，**不掺查词草稿**。
  /// - 否则**查词窗口多句合一草稿**（TODO-270 E）：当前 cue 取「lookup 缓存 → currentCue
  ///   → 按位置解析」多段兜底（含 gap，BUG-188）；文本用 [MiningSentenceDraft.composeText]
  ///   合并草稿全部句 + 当前句，区间用 [MiningSentenceDraft.composeAudioRange] 合并成首句
  ///   起→末句止（草稿空时等价于单句原行为：trim 文本 + 单 cue 区间）。
  ///
  /// [usedSelectedCue] 回传「本次是否走了字幕列表多选」，供成功后清多选用。
  ({
    int clipStartMs,
    int clipEndMs,
    String sentence,
    String? cueSentence,
    bool usedSelectedCue
  }) _resolveVideoMiningRange(VideoPlayerController controller) {
    final AudioCue? selectedCue = _selectedMiningCueForCard(controller);
    if (selectedCue != null) {
      // 字幕列表多选（独立入口）：单段区间就是合成 cue 的时间窗，文本即其 join。
      // TODO-680 / BUG-392：cue 时间是字幕文件坐标，裁音频/封面前逆变换回播放器轴
      // （+ delayMs），否则字幕调轴后裁的位置整体偏移 delayMs。
      return (
        clipStartMs: miningClipTimeMs(selectedCue.startMs, controller.delayMs),
        clipEndMs: miningClipTimeMs(selectedCue.endMs, controller.delayMs),
        sentence: selectedCue.text,
        cueSentence: selectedCue.text,
        usedSelectedCue: true,
      );
    }

    // 查词窗口多句合一（TODO-270 E）。当前 cue 多段兜底（含 gap，BUG-188）。
    final AudioCue? cue = _lastLookupCue ??
        controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.cues,
          positionMs: controller.positionMs ?? 0,
          delayMs: controller.delayMs,
        );
    // 草稿全部句 + 当前查词句合成 sentence（草稿空 → 单句 _lastLookupSentence trim）。
    final String mergedSentence = _miningDraft.composeText(_lastLookupSentence);
    // 草稿全部句区间 + 当前 cue 区间合并成首句起→末句止（草稿空 → 单 cue 区间）。
    final AudioPlaybackRange? mergedRange = _miningDraft.composeAudioRange(
      cue == null
          ? null
          : AudioPlaybackRange(
              audioFileIndex: 0,
              startMs: cue.startMs,
              endMs: cue.endMs,
            ),
    );
    // TODO-680 / BUG-392：mergedRange / cue 的 startMs/endMs 都是字幕文件坐标，裁
    // 音频/封面前逆变换回播放器轴（+ delayMs），与字幕显示用的 effectiveSubtitlePositionMs
    // 方向相反，保证裁的就是用户实际听到/看到的那段。
    return (
      clipStartMs: miningClipTimeMs(
          mergedRange?.startMs ?? cue?.startMs ?? 0, controller.delayMs),
      clipEndMs: miningClipTimeMs(
          mergedRange?.endMs ?? cue?.endMs ?? 0, controller.delayMs),
      // 多句时 cueSentence 用合并文本与 sentence 一致；草稿空时退回单 cue 文本作 fallback。
      cueSentence: _miningDraft.isEmpty ? cue?.text : mergedSentence,
      sentence: mergedSentence,
      usedSelectedCue: false,
    );
  }

  Future<MinePopupResult> _onMineEntryImpl(Map<String, String> fields) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();

    final ({
      int clipStartMs,
      int clipEndMs,
      String sentence,
      String? cueSentence,
      bool usedSelectedCue,
    }) range = _resolveVideoMiningRange(controller);

    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      // 音频/封面区间 = 合并后的首句起→末句止（单句即该 cue 时间窗，两端相等→不抽）。
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
    );
    // result.ankiConnect 是「制卡成功」信号（两后端成功时都置 true；noteId 仅
    // AnkiConnect 非空，故清选中句不能以 noteId 为判据，否则 AnkiDroid 成功也不清）。
    if (result.ankiConnect) {
      // TODO-633: success also lands one mined-sentence history row with the
      // video locator (bookUid + episode + cue time window), mirroring the
      // favorite-sentence anchors so collections can jump back via the video page.
      unawaited(
          _recordMinedSentenceForVideo(fields, range.sentence, result.noteId));
      if (range.usedSelectedCue) {
        _clearSelectedMiningCues();
      } else {
        // TODO-270 E：合并卡已落地 → 清空多句草稿（popup.js 同事件把角标清零，两端在
        // 同一事件归零、不漂移）。下一次查词从空草稿重新累积。
        _miningDraft.clear();
      }
    }
    return result;
  }

  Future<MinePopupResult> _onUpdateEntryImpl(
    int noteId,
    Map<String, String> fields,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();

    final ({
      int clipStartMs,
      int clipEndMs,
      String sentence,
      String? cueSentence,
      bool usedSelectedCue,
    }) range = _resolveVideoMiningRange(controller);

    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
      updateNoteId: noteId,
    );
    if (result.ankiConnect) {
      if (range.usedSelectedCue) {
        _clearSelectedMiningCues();
      } else {
        _miningDraft.clear();
      }
    }
    return result;
  }

  /// 视频制卡/覆盖的落卡链路（单句 [onMineEntry]/[onUpdateEntry] 走这里）：把音频/封面
  /// 区间 `[clipStartMs, clipEndMs]`（单句即该 cue 的时间窗）抽成 GIF + 音频片段，配
  /// [sentence]/[cueSentence]/[fields] 经 [BaseAnkiRepository] 生成**一张**卡，回 OSD。
  /// [updateNoteId] 为空时新制一张（计入视频统计），非空时按 id 覆盖那张卡（不计入统计、
  /// 走 [BaseAnkiRepository.updateMinedNote]）。返回 [MinePopupResult]：成功带回 note id
  /// （新制时来自 addNote，覆盖时即 [updateNoteId]），让弹窗保持「最新可改」第三态。
  /// 区间非正（`clipEndMs <= clipStartMs`，如无 cue）时不抽媒体、回退当前帧截图作封面。
  Future<MinePopupResult> _mineVideoCard({
    required Map<String, String> fields,
    required int clipStartMs,
    required int clipEndMs,
    required String sentence,
    String? cueSentence,
    int? updateNoteId,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final Directory tmp = await getTemporaryDirectory();
    final String? videoPath = controller.videoPath;
    final bool hasRange = clipEndMs > clipStartMs;
    // TODO-757 压缩开关：开=压缩档（GIF 320/8·音频 ac1 64k·截图 1000/90，=现状）；
    // 关=高保真档（GIF 480/12·音频 ac2 128k·截图 2000/95）。一处选档喂三条媒体链路。
    final MiningMediaCompression mediaCompression =
        MiningMediaCompression.forCompressionEnabled(
      appModel.compressMiningMedia,
    );

    // 视频卡片封面 → coverPath（→`{book-cover}`）：优先把**区间时间段**导出成循环 GIF
    // （单句=该 cue 时间窗；跨字幕=整段区间）。桌面走系统 ffmpeg、移动端走捆绑 ffmpeg-kit
    // （resolveFfmpegBackend）；无区间 / 导出失败（ffmpeg 真不可用等）时回退当前帧截图。
    String? coverPath;
    String? gifFailure;
    if (hasRange && videoPath != null) {
      coverPath = await extractClipGifViaFfmpeg(
        inputPath: videoPath,
        startMs: clipStartMs,
        endMs: clipEndMs,
        outputPath: '${tmp.path}/video_mine_clip.gif',
        fps: mediaCompression.gifFps,
        width: mediaCompression.gifWidth,
        onFailure: (String summary) {
          gifFailure = summary;
        },
      );
    }
    if (coverPath == null) {
      if (gifFailure != null) {
        debugPrint('[VideoHibiki] mine: GIF clip export failed: $gifFailure');
      }
      final Uint8List? shot = await controller.screenshot();
      if (shot != null && shot.isNotEmpty) {
        // TODO-646 近无损压缩：截图按原始解码帧分辨率输出（1080p/4K），降采样到
        // 长边 1000px（卡面 + 灯箱放大都不糊）再写盘，省媒体库体积。解码失败/已不
        // 超限时原样返回，不破坏制卡。
        final Uint8List cover = downsampleCardScreenshot(
          shot,
          maxLongEdge: mediaCompression.screenshotMaxLongEdge,
          quality: mediaCompression.screenshotQuality,
        );
        final File f = File('${tmp.path}/video_mine_shot.jpg');
        await f.writeAsBytes(cover);
        coverPath = f.path;
      }
    }

    // 区间音频片段（桌面 ffmpeg 按时间裁，映射到当前选中音轨）→ sasayakiAudioPath。
    // 跨字幕时这就是 [startCue.startMs, endCue.endMs] 一整段（不逐句抽再拼，TODO-102）。
    String? audioPath;
    String? audioFailure;
    if (hasRange && videoPath != null) {
      audioPath = await extractAudioSegmentViaFfmpeg(
        inputPath: videoPath,
        startMs: clipStartMs,
        endMs: clipEndMs,
        outputPath: '${tmp.path}/video_mine_audio.aac',
        audioStreamIndex: controller.currentAudioStreamIndex,
        audioStreamCount: controller.realAudioStreamCount,
        audioChannels: mediaCompression.audioChannels,
        audioBitrate: mediaCompression.audioBitrate,
        onFailure: (String summary) {
          audioFailure = summary;
        },
      );
      // BUG-296 / TODO-390: sentence-audio "should-have-but-failed" visibility,
      // symmetric with reader BUG-172. hasRange means this card was supposed to
      // carry sentence audio, but ffmpeg returned null (ffmpeg unavailable on
      // device / current audio track undecodable / interleaved container read
      // failure) so the card's {sasayaki-audio}/SentenceAudio renders empty.
      // This used to be a fully silent drop (user sees "card created" with no
      // sentence audio and no way to diagnose - exactly the TODO-390 blind spot
      // behind repeated "Hibiki deck has no sentence audio" reports). Treat it
      // like the reader/audiobook path: surface the root cause and abort this
      // mining attempt rather than creating a "successful" no-audio card.
      if (audioPath == null) {
        debugPrint(
          '[VideoHibiki] mine: sentence-audio clip failed for range '
          '[$clipStartMs,$clipEndMs] '
          '(audioStreamIndex=${controller.currentAudioStreamIndex}; '
          '${audioFailure ?? 'ffmpeg returned null'}).',
        );
        if (mounted) {
          _showOsd(t.card_export_failed_detail(
            reason: audioFailure == null
                ? 'sentence audio export failed'
                : 'sentence audio export failed: $audioFailure',
          ));
        }
        return const MinePopupResult();
      }
    }

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      cueSentence: cueSentence,
      documentTitle: _title,
      coverPath: coverPath,
      sasayakiAudioPath: audioPath,
      // TODO-115: 视频来源 → 卡片追加 `video` 分类标签（本页覆写了 onMineEntry，
      // 绕过 DictionaryPageMixin 的 source 注入，故在此显式指定）。
      source: AnkiMiningSource.video,
      // TODO-681 / BUG-393：「自动添加书名到标签」开关原只对书籍生效，现视频同样吃——
      // 视频的「书名」= 番名/标题（_title）。开关关闭或无标题时传 null，不追加。
      bookTitleTag: appModel.autoAddBookNameToTags
          ? BaseAnkiRepository.sanitizeTitleTag(_title)
          : null,
    );
    final MineOutcome outcome = updateNoteId == null
        ? await repo.mineEntry(
            rawPayloadJson: jsonEncode(fields),
            context: miningContext,
          )
        : await repo.updateMinedNote(
            noteId: updateNoteId,
            rawPayloadJson: jsonEncode(fields),
            context: miningContext,
          );
    final MinePopupResult result = outcome.result == MineResult.success
        ? MinePopupResult(ankiConnect: true, noteId: outcome.noteId)
        : const MinePopupResult();
    if (!context.mounted) return result;
    // 牌组名仅 success 需要（避免给失败分支白白 loadSettings）。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    // overwrite=true（updateNoteId 非空）→ 收口产 card_overwritten + record=false；
    // 新制 → card_exported + record=true（消息/记账判定统一在 describeMineOutcome）。
    final described = describeMineOutcome(
      outcome,
      deckName: deckName,
      overwrite: updateNoteId != null,
    );
    // 新制成功计入视频统计（dictionarySourceType=video）；覆盖 record=false 故不记账。
    // 本页覆写了 onMineEntry、绕过基类成功分支，故在此显式记账（与 mixin 同一路径）。
    if (described.record) unawaited(_recordMinedForVideo());
    _showOsd(described.message);
    return result;
  }

  /// TODO-633: land one mined-sentence history row for a video card. Locator
  /// anchors mirror _toggleFavoriteSentenceForVideo (bookUid + episode +
  /// cue.startMs/duration) so collections reuses _openVideoSentence to jump back.
  /// Best-effort; failure is swallowed + logged (does not break mining).
  Future<void> _recordMinedSentenceForVideo(
    Map<String, String> fields,
    String sentence,
    int? noteId,
  ) async {
    try {
      final AudioCue? cue = _lastLookupCue;
      await appModel.database.addMinedSentence(
        source: kStatSourceVideo,
        dateKey: statTodayKey(),
        expression: fields['expression'] ?? '',
        reading: fields['reading'] ?? '',
        glossary: fields['glossary'] ?? '',
        sentence: sentence,
        documentTitle: _title ?? widget.bookUid,
        bookKey: widget.bookUid,
        sectionIndex: _episodes.isEmpty ? null : _currentEpisode,
        normCharOffset: cue?.startMs,
        normCharLength: cue == null
            ? null
            : (cue.endMs - cue.startMs).clamp(0, 1 << 31).toInt(),
        noteId: noteId,
      );
    } catch (e, st) {
      debugPrint('[hibiki-stats] video addMinedSentence failed: $e\n$st');
    }
  }
}
