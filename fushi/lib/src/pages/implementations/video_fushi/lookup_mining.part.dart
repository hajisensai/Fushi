// GENERATED-NOTE: extracted from video_fushi_page.dart (TODO-590 batch14).
part of '../video_fushi_page.dart';

/// Dictionary-lookup mining (制卡) domain extracted via part-of (TODO-590
/// batch14); shared private scope. Behaviour-preserving: every method body is
/// moved character-for-character. The stat write that used to go through the
/// mixin's @protected `recordMined()` (via a 1-line shell forwarder) is now
/// [_recordVideoMineStat]: the same `recordMiningEvent` call, but on the
/// database and identity frozen at click time, because an online-video card can
/// land in the background after the page is gone (see [VideoOnlineMiningMode]).
/// No host-class static needed re-qualification: every collaborator
/// ([miningClipTimeMs], [resolveMiningCueForPosition],
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
/// [_setSentenceContextToDraft], [_clearSentenceDraft]), the mining range
/// resolver ([_resolveVideoMiningRange]), the mine/update entry bodies
/// ([_onMineEntryImpl], [_onUpdateEntryImpl]), the card landing path
/// ([_mineVideoCard]) and the mined-sentence history row ([_recordMinedSentenceForVideo]).
extension _VideoLookupMining on _VideoFushiPageState {
  /// 本机 Anki 仓库 + 制卡后自动重排（与 `ankiRepositoryProvider` 的本地分支同构，
  /// 只是不套待发队列、也不随「制卡到已配对设备」改道）。每次遥控制卡取一份新仓库，
  /// 读的是当下的 Anki 设置；调度器防抖到期跑完一轮即空闲，不挂在页面上——遥控
  /// 打开收藏会替换页面，挂在页面上会把未到期的重排一起丢掉。
  BaseAnkiRepository _localAutoRepositionAnkiRepository() {
    return withAnkiAutoReposition(
      ref.read(platformServicesProvider).createAnkiRepository(),
      showFailure: (String message) =>
          _showOsd(message, severity: ToastSeverity.error),
    ).repository;
  }

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

  /// 以当前查词 cue（[_lastLookupCue]）为锚，在**锚点所属的那条字幕流**
  /// （[VideoPlayerController.cueStreamOwning]，按 startMs 升序）里取它之前 [prevCount] 条、
  /// 之后 [nextCount] 条作上下文，整体设进草稿（覆盖上次选择，不累积）。无 cue / 无控制器
  /// 时清空上下文返回 0。
  ///
  /// BUG-1592：以前硬取主字幕流 [VideoPlayerController.cues]。副字幕上查词时锚点不在主流里，
  /// `indexOf` 恒 -1 → 上下 N 句**静默失效**（用户只看到上下文没生效，没有任何报错）。
  Future<int> _setSentenceContextToDraft(int prevCount, int nextCount) async {
    final VideoPlayerController? controller = _controller;
    final AudioCue? anchor = _lastLookupCue;
    if (controller == null || anchor == null) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final List<AudioCue> cues = controller.cueStreamOwning(anchor);
    final int idx = cues.indexOf(anchor);
    if (idx < 0) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    // 与有声书歌词模式同一个切法（cueContextNeighbors）：一条 cue 就是一句。
    final ({List<AudioCue> prev, List<AudioCue> next}) around =
        cueContextNeighbors(
          cues: cues,
          anchorIndex: idx,
          prevCount: prevCount,
          nextCount: nextCount,
        );
    MiningDraftSentence toEntry(AudioCue cue) =>
        MiningDraftSentence(sentence: cue.text, audioRange: _cueRange(cue));
    _miningDraft.setContext(
      prev: <MiningDraftSentence>[
        for (final AudioCue cue in around.prev) toEntry(cue),
      ],
      next: <MiningDraftSentence>[
        for (final AudioCue cue in around.next) toEntry(cue),
      ],
    );
    return _miningDraft.length;
  }

  /// 手改草稿里某一句的文本（[DictionaryPageMixin.onEditSentenceContextText] 的私有
  /// 目标）。**只改文本，不动区间**：这句仍是原来那条 cue、仍是同一段时间窗，GIF 与
  /// 句子音频的裁法一字不改，改的只是最终写进卡片 sentence 字段的那行字。
  Future<void> _editSentenceContextText(
    SentenceContextSlot slot,
    int index,
    String text,
  ) async {
    _miningDraft.editSentence(slot: slot, index: index, text: text);
  }

  /// 移除 / 恢复草稿里某一句前文/后文（[DictionaryPageMixin.onRemoveSentenceContext]
  /// 的私有目标）。被移除的 cue 不进卡片文本与音频区间。
  Future<void> _removeSentenceContext(
    SentenceContextSlot slot,
    int index,
    bool removed,
  ) async {
    _miningDraft.setSentenceRemoved(slot: slot, index: index, removed: removed);
  }

  Future<int> _clearSentenceDraft() async {
    _miningDraft.clear();
    return _miningDraft.length;
  }

  /// 「选择句子上下文」对话框的试听（[DictionaryPageMixin.onPreviewSentenceAudioToDraft]
  /// 的私有目标）：放**这张卡会写进去的那段**——与写卡同一个函数算出的最终区间
  /// （[_videoMiningAudioWindow]，含首尾留白、A/V 偏移），不再按 cue 边界放
  /// （BUG-3339：旧实现按 cue 边界 replayCue，试听比卡上的句子音频少了
  /// 首尾留白）。
  Future<bool> _previewSentenceContextAudio() async =>
      await _previewVideoMiningAudio(startDeltaMs: 0, endDeltaMs: 0) != null;

  /// 这张卡会写进去的句子音频区间（播放器轴），[startDeltaMs] / [endDeltaMs] 是高级制卡
  /// 的起止偏移。与 [_onMineEntryImpl] 走**同一对函数**（[_resolveVideoMiningRange] +
  /// [applyVideoMiningOverrides]）：试听、区间描述、写卡三处同源（BUG-2196 ②）。
  /// 没有区间（无 cue、无草稿）返回 null。
  AdvancedMiningAudioWindow? _videoMiningAudioWindow(
    VideoPlayerController controller, {
    required int startDeltaMs,
    required int endDeltaMs,
  }) {
    final VideoMiningRange range = applyVideoMiningOverrides(
      _resolveVideoMiningRange(controller),
      MiningRequestOverrides(
        audioStartDeltaMs: startDeltaMs,
        audioEndDeltaMs: endDeltaMs,
      ),
    );
    if (range.clipEndMs <= range.clipStartMs) return null;
    return AdvancedMiningAudioWindow(
      startMs: range.clipStartMs,
      endMs: range.clipEndMs,
    );
  }

  /// 本机播放器试听 [_videoMiningAudioWindow]：毫秒级起止，播到终点自动停
  /// （[VideoPlayerController.playRangeMs]）。没有区间返回 null；否则返回这段的句柄
  /// （播完 / 被打断时完成，高级制卡的试听按钮据此复位，FDN66-xurt）。
  Future<RangePlayback?> _previewVideoMiningAudio({
    required int startDeltaMs,
    required int endDeltaMs,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return null;
    final AdvancedMiningAudioWindow? window = _videoMiningAudioWindow(
      controller,
      startDeltaMs: startDeltaMs,
      endDeltaMs: endDeltaMs,
    );
    if (window == null) return null;
    // 试听挪了播放头：对话框关闭时要把它放回查词位置（见 [_closeAdvancedMiningSession]）。
    _advancedMiningSession?.previewed = true;
    return controller.playRangeMs(window.startMs, window.endMs);
  }

  /// 制卡（覆写 [DictionaryPageMixin.onMineEntry]）：在词典 [fields]（已含单词
  /// 发音 `{audio}`、例句字段等）基础上，注入视频专属上下文——当前帧截图
  /// coverPath（→`{book-cover}`）+ 当前字幕 cue 的音频片段（裁**当前选中音轨**）
  /// sasayakiAudioPath（→`{sentence-audio}`）+ 例句 sentence。复用现有 Anki 字段。
  /// 视频制卡/覆盖共用的「解析这一张卡的区间 + 文本」。把两个并存入口收口成一处，避免
  /// [onMineEntry] / [onUpdateEntry] 两份漂移：**查词窗口多句合一草稿**（TODO-270 E）：
  /// 当前 cue 取「lookup 缓存 → currentCue → 按位置解析」多段兜底（含 gap，BUG-188）；
  /// 文本用 [MiningSentenceDraft.composeText] 合并草稿全部句 + 当前句，区间用
  /// [MiningSentenceDraft.composeAudioRange] 合并成首句起→末句止（草稿空时等价于单句
  /// 原行为：trim 文本 + 单 cue 区间）。
  ({
    int clipStartMs,
    int clipEndMs,
    int stillFrameAtMs,
    String sentence,
    String? cueSentence,
  })
  _resolveVideoMiningRange(VideoPlayerController controller) {
    final CardSourceLink? restored = widget.sourceReview;
    final (String currentUid, int currentEpisode) = _isRemote
        ? _remotePositionKeyForIndex(_currentEpisode)
        : (_activeBookUid, 0);
    if (restored?.startMs != null &&
        restored?.endMs != null &&
        restored?.uid == currentUid &&
        restored?.episodeIndex == currentEpisode &&
        _lastLookupCue == null &&
        _miningDraft.isEmpty) {
      final String text = controller.miningCues
          .where((AudioCue cue) {
            final int delayMs = controller.delayMsForCue(cue);
            return miningClipTimeMs(cue.endMs, delayMs) > restored!.startMs! &&
                miningClipTimeMs(cue.startMs, delayMs) < restored.endMs!;
          })
          .map((AudioCue cue) => cue.text)
          .join('\n');
      return (
        clipStartMs: restored!.startMs!,
        clipEndMs: restored.endMs!,
        // 回看会话没有「未 pad 的字幕起点」可用，封面锚在卡片自己记的片段起点。
        stillFrameAtMs: restored.startMs!,
        sentence: text,
        cueSentence: text,
      );
    }
    // 查词窗口多句合一（TODO-270 E）。当前 cue 多段兜底（含 gap，BUG-188）。
    // BUG-1592：按位置兜底走**有效流**（主字幕流为空即副字幕流）。命中项已带 cue 的入口
    // （点击 / hover / 手柄光标 / 列表）走 [_lastLookupCue]，这条只服务「没有命中项」的
    // 入口（如无查词直接制卡）——它以前硬认主流，主字幕关闭时恒 null → 区间 `0..0`。
    final AudioCue? cue =
        _lastLookupCue ??
        controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.miningCues,
          // BUG-3313：取句时钟跟有效流走（文本流 = 字幕时钟；图形时间表 = 真实位置，
          // 与控制器图形锚点按位置取句同一个时钟）。
          positionMs: controller.miningPositionMs ?? 0,
          // TODO-2837：按位置解析必须与有效流的 cue 命中同一根轴（主流空落副流
          // 时用副轨生效轴，否则副轨独立调轴后锚错句）。
          delayMs: controller.miningDelayMs,
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
    // 方向相反，保证裁的就是用户实际听到/看到的那段。TODO-2837：主副分开调轴后
    // 按锚定 cue 所属流取轴（查副字幕词制卡时用副轨生效轴；无 cue 回落有效流轴）。
    final int clipDelayMs = cue == null
        ? controller.miningDelayMs
        : controller.delayMsForCue(cue);
    // 头/尾 padding（用户偏好，对齐 asbplayer）：字幕 cue 的时间窗通常比实际发声短，
    // 尾音直接被硬切。与有声书制卡共用 [padSentenceRange]：在字幕文件时基（未加
    // delay）上加 padding，并夹在锚定 cue 所属流的相邻 cue 边界内，不把邻句混进来；
    // 之后再整体逆变换回播放器轴（先 pad 再 shift，与有声书链同序）。非正区间（无
    // cue → `0..0`）不 pad——那是下游「不抽媒体」的哨兵，pad 了会把哨兵变成真区间。
    final AudioPlaybackRange? paddedRange =
        (mergedRange == null || mergedRange.endMs <= mergedRange.startMs)
        ? mergedRange
        : padSentenceRange(
            mergedRange,
            cues: cue == null
                ? controller.miningCues
                : controller.cueStreamOwning(cue),
            headPadMs: appModel.miningAudioHeadPadMs,
            tailPadMs: appModel.miningAudioTailPadMs,
          );
    return (
      clipStartMs: miningClipTimeMs(paddedRange?.startMs ?? 0, clipDelayMs),
      clipEndMs: miningClipTimeMs(paddedRange?.endMs ?? 0, clipDelayMs),
      // 「字幕起始帧」封面锚点用**未 pad** 的字幕起点（同一逆变换）：封面承诺的是字幕
      // 开始那一刻的画面，不能跟着音频头 padding 往前退到上一个镜头。
      // BUG-3319：没有任何区间（无 cue、草稿空）时锚在**当前播放位置**（已是播放器轴，
      // 不再逆变换），与 [_mineVideoCard] 的 `sourceStartMs` 同一口径——以前落 0，静帧
      // 抽的是片头黑帧。
      // 硬字幕暂停 OCR 的默认窗口（[frameOcrFallbackCue]）：窗口起点早于文字出现，静帧
      // 锚在暂停位置（那一刻文字一定在屏）。加了上下文句（草稿非空）就回到首句起点。
      stillFrameAtMs:
          (cue == null || !_miningDraft.isEmpty
              ? null
              : controller.frameOcrFallbackStillMs(cue)) ??
          (mergedRange == null
              ? (controller.positionMs ?? 0)
              : miningClipTimeMs(mergedRange.startMs, clipDelayMs)),
      // 多句时 cueSentence 用合并文本与 sentence 一致；草稿空时退回单 cue 文本作 fallback。
      cueSentence: _miningDraft.isEmpty ? cue?.text : mergedSentence,
      sentence: mergedSentence,
    );
  }

  Future<MinePopupResult> _onMineEntryImpl(Map<String, String> fields) async {
    // 网页档：画面归站点（硬件 DRM 截不到）、没有本地媒体源——只入队，由内置档重放落卡
    // （见 web_source.part.dart）。
    if (_webMode) return _onWebMineEntry(fields);
    final VideoPlayerController? controller = _controller;
    if (controller == null || !_discExtractionAllowed(controller)) {
      return const MinePopupResult();
    }

    // 「高级制卡」为这张卡做的调整：必须在首个 await 之前同步读完——视频车道的对话框
    // 以 `releaseWhenPayloadConsumed: true` 回点「+」，宿主读走制卡上下文后对话框就
    // 关了（onClosed 会把播放头放回查词位置、释放锁帧），之后再读就读到别的状态。
    final MiningRequestOverrides? overrides = MiningRequestOverrides.readFrom(
      fields,
    );
    final ({
      int clipStartMs,
      int clipEndMs,
      int stillFrameAtMs,
      String sentence,
      String? cueSentence,
    })
    range = applyVideoMiningOverrides(
      _resolveVideoMiningRange(controller),
      overrides,
    );
    final int queuedEpisode = _currentEpisode;
    final AudioCue? historyCue = _lastLookupCue;
    final VideoMiningHistorySnapshot historySnapshot =
        VideoMiningHistorySnapshot.capture(
          fields: fields,
          sentence: range.sentence,
          documentTitle: _title ?? _activeBookUid,
          bookKey: _activeBookUid,
          sectionIndex: _favoriteSectionIndex,
          cueStartMs: historyCue?.startMs,
          cueEndMs: historyCue?.endMs,
          dateKey: statTodayKey(),
        );

    final bool recordHistory = _sourceReviewSession == null;
    // 后台落卡时页面可能已经关了：历史行写进点击时的库，不经 `ref`。
    final FushiDatabase historyDb = appModel.database;
    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      // 音频/封面区间 = 合并后的首句起→末句止（单句即该 cue 时间窗，两端相等→不抽）。
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      stillFrameAtMs: range.stillFrameAtMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
      overrides: overrides,
      historySnapshot: recordHistory ? historySnapshot : null,
      // 在线视频后台制卡：卡在弹窗返回之后才落地，历史行跟着落地时再写。
      onBackgroundLanded: (MinePopupResult landed) {
        if (landed.ankiConnect && recordHistory) {
          unawaited(
            _recordMinedSentenceForVideo(
              historySnapshot,
              landed.noteId,
              db: historyDb,
            ),
          );
        }
      },
    );
    if (result.queued) {
      // 后台 / 看完再制卡：请求已冻结了草稿里的句子，当场清空（popup.js 在同一次回包
      // 里把上下文角标归零），下一次查词从空草稿重新累积。与落卡路径同一道门：页面
      // 已销毁或已换集就不碰新页面 / 新集的草稿。
      if (!mounted || _currentEpisode != queuedEpisode) return result;
      _miningDraft.clear();
      return result;
    }
    // result.ankiConnect 是「制卡成功」信号（两后端成功时都置 true；noteId 仅
    // AnkiConnect 非空，故清选中句不能以 noteId 为判据，否则 AnkiDroid 成功也不清）。
    if (result.ankiConnect) {
      // TODO-633: success also lands one mined-sentence history row with the
      // video locator (bookUid + episode + cue time window), mirroring the
      // favorite-sentence anchors so collections can jump back via the video page.
      if (_sourceReviewSession == null) {
        unawaited(_recordMinedSentenceForVideo(historySnapshot, result.noteId));
      }
      if (!mounted || _currentEpisode != queuedEpisode) return result;
      // TODO-270 E：合并卡已落地 → 清空多句草稿（popup.js 同事件把角标清零，两端在
      // 同一事件归零、不漂移）。下一次查词从空草稿重新累积。
      _miningDraft.clear();
    }
    return result;
  }

  Future<MinePopupResult> _onUpdateEntryImpl(
    int noteId,
    Map<String, String> fields,
  ) async {
    // 网页档覆盖最新那张卡：没有可裁的媒体，只覆盖字段（mixin 路径）。
    if (_webMode) return _updateFieldsOnly(noteId, fields);
    final VideoPlayerController? controller = _controller;
    if (controller == null || !_discExtractionAllowed(controller)) {
      return const MinePopupResult();
    }

    // 同 [_onMineEntryImpl]：覆盖项在首个 await 之前同步读完。
    final MiningRequestOverrides? overrides = MiningRequestOverrides.readFrom(
      fields,
    );
    final ({
      int clipStartMs,
      int clipEndMs,
      int stillFrameAtMs,
      String sentence,
      String? cueSentence,
    })
    range = applyVideoMiningOverrides(
      _resolveVideoMiningRange(controller),
      overrides,
    );
    final int queuedEpisode = _currentEpisode;

    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      stillFrameAtMs: range.stillFrameAtMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
      overrides: overrides,
      updateNoteId: noteId,
    );
    if (result.ankiConnect) {
      if (!mounted || _currentEpisode != queuedEpisode) return result;
      _miningDraft.clear();
    }
    return result;
  }

  /// BUG-3492：卡还在后台写入时的覆盖请求（[onQueueOverwrite]）。
  ///
  /// 覆盖要用的输入（区间 / 句子 / 覆盖项 / 查词画面）在这里**同步冻结**——视频车道的
  /// 「高级制卡」对话框以 `releaseWhenPayloadConsumed: true` 回点，宿主一返回对话框就
  /// 关了，锁帧与草稿随之失效。真正的覆盖等那次后台写入落地后再跑
  /// （[_settleQueuedOverwrite]），同一个词只保留最后一次请求。
  Future<QueuedOverwriteReply> _onQueueOverwriteImpl(
    Map<String, String> fields,
  ) async {
    final VideoPlayerController? controller = _controller;
    final String key = mineEntryKeyOf(
      fields['expression'] ?? '',
      fields['reading'] ?? '',
    );
    if (controller == null || !_discExtractionAllowed(controller)) {
      return const QueuedOverwriteReply();
    }
    if (!_pendingOverwrites.isAddPending(key)) {
      // 这次后台写入在弹窗问过 Anki 之后、请求到这里之前已经落地 / 失败了：把结局
      // 告诉弹窗，由它走已制卡的正常覆盖路径（落地）或撤掉「已加入」（失败），
      // 不能再说「还在写入」。不是这条后台写入路径上的卡（看完再制卡的暂存）：不收。
      return switch (_pendingOverwrites.lastLanded(key)) {
        true => const QueuedOverwriteReply(
          settled: QueuedOverwriteSettled.landed,
        ),
        false => QueuedOverwriteReply(
          settled: QueuedOverwriteSettled.failed,
          message: t.video_mine_overwrite_cancelled,
        ),
        null => const QueuedOverwriteReply(),
      };
    }
    final MiningRequestOverrides? overrides = MiningRequestOverrides.readFrom(
      fields,
    );
    final VideoMiningRange range = applyVideoMiningOverrides(
      _resolveVideoMiningRange(controller),
      overrides,
    );
    final bool omitCover = overrides?.omitImage ?? false;
    final Future<Uint8List?>? frame = omitCover
        ? null
        : _advancedMiningSessionFor(controller)?.lookupFrame ??
              controller.screenshot().then(
                (Uint8List? bytes) => bytes,
                onError: (Object error, StackTrace stack) {
                  ErrorLogService.instance.log(
                    'queueOverwrite.snapshotCurrentFrame',
                    error,
                    stack,
                  );
                  return null;
                },
              );
    _pendingOverwrites.queue(
      key,
      _QueuedVideoOverwrite(
        fields: fields,
        range: range,
        overrides: overrides,
        controller: controller,
        episode: _currentEpisode,
        frame: frame,
        repo: ref.read(ankiRepositoryProvider),
      ),
    );
    // 请求已冻结了草稿里的句子：与后台制卡收下时同口径当场清空，下一次查词从空草稿
    // 重新累积。
    _miningDraft.clear();
    return QueuedOverwriteReply(
      accepted: true,
      message: t.popup_mine_overwrite_queued,
    );
  }

  /// 后台写入落地（成功或失败）：结算这个词排队的覆盖请求。
  Future<void> _settleQueuedOverwrite(
    String key,
    int addId,
    Map<String, String> fields,
    MinePopupResult landed, {
    String? failureReason,
  }) async {
    try {
      await _pendingOverwrites.settle(
        key,
        addId,
        landed: landed.ankiConnect,
        noteId: landed.noteId,
        findNoteId: (_QueuedVideoOverwrite request) async {
          // AnkiDroid 不回 note id：按词反查，取最新的那张（note id 即创建时刻）。
          final List<MinedNoteRef> matches = await request.repo
              .findMatchingNotes(
                fields['expression'] ?? '',
                fields['reading'] ?? '',
              );
          int? newest;
          for (final MinedNoteRef match in matches) {
            if (newest == null || match.noteId > newest) newest = match.noteId;
          }
          return newest;
        },
        overwrite: (int noteId, _QueuedVideoOverwrite request) =>
            _runQueuedOverwrite(noteId, request),
        onCancelled: (_QueuedVideoOverwrite _, PendingOverwriteCancel reason) {
          if (!mounted) return;
          // 写入失败：OSD 只有一条，后来的会顶掉 [_landVideoMine] 刚报的失败原因，
          // 所以原因并进这一条一起说。写入成功却找不到那张笔记是另一回事，不能说
          // 「卡没写进 Anki」。
          final String? why = failureReason;
          _showOsd(switch (reason) {
            PendingOverwriteCancel.noTargetNote =>
              t.video_mine_overwrite_cancelled_no_target,
            PendingOverwriteCancel.addFailed
                when why != null && why.isNotEmpty =>
              t.video_mine_overwrite_cancelled_reason(reason: why),
            PendingOverwriteCancel.addFailed =>
              t.video_mine_overwrite_cancelled,
          }, severity: ToastSeverity.warning);
        },
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('settleQueuedOverwrite', e, stack);
    }
  }

  /// 后台写入没成时给用户看的原因（与 [_landVideoMine] 报的同一句）。
  String _videoMineFailureReason(ImmersionMiningResult res) {
    if (res.aborted) return res.abortReason ?? 'sentence audio export failed';
    final Object? outcome = res.outcome;
    if (outcome is! MineOutcome) return '';
    return describeMineOutcome(outcome).message;
  }

  /// 执行一次排队的覆盖：用排队时冻结的输入，按 id 覆盖后台刚写下的那张笔记。结局
  /// （「已覆盖」/ 失败原因）由 [_landVideoMine] 照常报 OSD。
  Future<void> _runQueuedOverwrite(
    int noteId,
    _QueuedVideoOverwrite request,
  ) async {
    // 换集 / 换播放器后，排队时的区间对不上现在的媒体：不覆盖，说一声。页面已关时
    // 没有可抽取的播放器，同样作罢。
    if (!mounted ||
        !identical(_controller, request.controller) ||
        _currentEpisode != request.episode) {
      if (mounted) {
        _showOsd(
          t.video_mine_overwrite_cancelled_episode,
          severity: ToastSeverity.warning,
        );
      }
      return;
    }
    await _mineVideoCard(
      fields: request.fields,
      clipStartMs: request.range.clipStartMs,
      clipEndMs: request.range.clipEndMs,
      stillFrameAtMs: request.range.stillFrameAtMs,
      sentence: request.range.sentence,
      cueSentence: request.range.cueSentence,
      overrides: request.overrides,
      updateNoteId: noteId,
      frozenCurrentFrame: request.frame,
      detachedFromDialog: true,
    );
  }

  /// 制卡 `documentTitle`（渲染到 Anki `{document-title}`）。播放列表（[_isPlaylist]）
  /// 且系列名（[_playlistTitle]）非空时拼「系列名 - 剧集名」；单视频 / 远端退化为剧集名
  /// （[_title]）。纯拼接逻辑下沉到顶层 [composeVideoMiningDocumentTitle] 便于单测。
  String? _videoMiningDocumentTitle() => composeVideoMiningDocumentTitle(
    isPlaylist: _isPlaylist,
    playlistTitle: _playlistTitle,
    episodeTitle: _title,
  );

  /// 视频制卡/覆盖的落卡链路（单句 [onMineEntry]/[onUpdateEntry] 走这里）：把音频/封面
  /// 区间 `[clipStartMs, clipEndMs]`（单句即该 cue 的时间窗）抽成 GIF + 音频片段，配
  /// [sentence]/[cueSentence]/[fields] 经 [BaseAnkiRepository] 生成**一张**卡，回 OSD。
  /// [updateNoteId] 为空时新制一张（计入视频统计），非空时按 id 覆盖那张卡（不计入统计、
  /// 走 [BaseAnkiRepository.updateMinedNote]）。返回 [MinePopupResult]：成功带回 note id
  /// （新制时来自 addNote，覆盖时即 [updateNoteId]），让弹窗保持「最新可改」第三态。
  /// 区间非正（`clipEndMs <= clipStartMs`，如无 cue）时不抽媒体、回退当前帧截图作封面。
  ///
  /// [writeFieldsMedia]：把 [fields] 里的词典媒体写进 Anki 媒体缓存。本方法在冻结
  /// 播放器输入**之后**才调用它，引擎在队列里等它写完再落卡（见
  /// [ImmersionMiningRequest.fieldsMediaReady]）——调用方不得先 await 写缓存再调本方法，
  /// 那段 await 里换集，卡片就会裁到新一集。
  Future<MinePopupResult> _mineVideoCard({
    required Map<String, String> fields,
    required int clipStartMs,
    required int clipEndMs,
    required int stillFrameAtMs,
    required String sentence,
    String? cueSentence,
    MiningRequestOverrides? overrides,
    int? updateNoteId,
    VideoMiningHistorySnapshot? historySnapshot,
    void Function(MinePopupResult result)? onBackgroundLanded,
    bool silent = false,
    bool forceForeground = false,
    bool forceSubtitleStart = false,
    bool localOnly = false,
    void Function(String code)? onFailure,
    Future<void> Function()? writeFieldsMedia,
    Future<Uint8List?>? frozenCurrentFrame,
    bool detachedFromDialog = false,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !_discExtractionAllowed(controller)) {
      onFailure?.call('video_extraction_unavailable');
      return const MinePopupResult();
    }
    // 在线视频：弹窗等不等这张卡（见 [VideoOnlineMiningMode]）。覆盖已有卡片 / 回看会话
    // 要拿到落卡结果才有意义，恒等待；本地文件本就秒出，恒等待（= 改动前行为）。
    final VideoOnlineMiningMode onlineMode = resolveVideoOnlineMiningMode(
      preferred: appModel.videoOnlineMiningMode,
      mediaSource: controller.miningSource,
      overwrite: updateNoteId != null || forceForeground,
      sourceReview: _sourceReviewSession != null,
    );

    // 入队前立即冻结所有播放器/页面输入。换集会复用或 dispose controller，后续任务绝不能
    // 到真正出队时再读“当前集”。截图 Future 也在点击当下启动，current-frame 模式不会因
    // 本地 pushReplacement / 远端换流而截到下一集或访问已释放播放器。
    // 遥控制卡（[localOnly]）强制本机 Anki：不经「制卡到已配对设备」转发、不进待发
    // 队列（失败要当场报回手机），但自动重排与普通制卡同一套。
    final BaseAnkiRepository repo = localOnly
        ? _localAutoRepositionAnkiRepository()
        : ref.read(ankiRepositoryProvider);
    final MiningMediaCompression mediaCompression =
        MiningMediaCompression.resolve(
          imageTier: appModel.miningImageQuality,
          audioTier: appModel.miningAudioQuality,
          // 顶格档的动图参数随格式变（AVIF 源直通 / WebP·GIF 封顶），故必须把格式一并传进来
          // 解析——否则顶格档会拿到 GIF 的封顶值，用户选了 AVIF 也享受不到原图档。
          format: appModel.videoMiningAnimatedFormat,
        );
    String? mediaSource = controller.miningSource;
    final String? audioSource = controller.miningAudioSource;
    // BUG-2642 残留：在线视频源（扩展 hoster / 粘贴的流）常把 HLS 分片伪装成图片——
    // `.jpg` / `.image` 名、正文前垫一张 PNG。播放器经本机中继 + mpv 自己的放宽都能播，
    // 制卡 ffmpeg 直连原始地址则被扩展名白名单拒掉、或把分片认成一张图。改走与播放器
    // 同一条中继；地址当场改写（同步，保持点击顺序入队），登记在队列里等。
    // 媒体服务器同理，判据见 [videoMiningInputUsesPlaybackRelay]。
    Future<void>? mediaSourceRouteReady;
    if (mediaSource != null &&
        videoMiningInputUsesPlaybackRelay(
          remoteClient: _effectiveRemoteClient,
          mediaSource: mediaSource,
        )) {
      final ({String url, Future<void> ready}) relayed = relayFfmpegRemoteInput(
        mediaSource,
        isHls: controller.isHlsStream(),
        headers: _streamHttpHeaderFields,
      );
      mediaSource = relayed.url;
      mediaSourceRouteReady = relayed.ready;
    }
    final int? audioStreamIndex = controller.currentAudioStreamIndex;
    final int audioStreamCount = controller.realAudioStreamCount;
    final int episode = _currentEpisode;
    final SourceReviewSession? reviewSession = _sourceReviewSession;
    final (String sourceUid, int sourceEpisode) = _isRemote
        ? _remotePositionKeyForIndex(episode)
        : (_activeBookUid, 0);
    final String sourceId =
        reviewSession?.link.sourceId ?? CardSourceLink.newSourceId();
    final String? localSourcePath = controller.videoPath;
    // BUG-3490：媒体库里的在线条目（粘贴链接 / YouTube / 在线视频源剧集）没有本地
    // 字节可比指纹，但库身份就是内容本身（见 isContentAddressedVideoUid），卡片照样
    // 带来源链接，回看时直接在线播放。
    final bool contentAddressedStream =
        _resolvedStreamInfo != null &&
        CardSourceLink.isContentAddressedVideoUid(sourceUid);
    // A still-only card has no subtitle range, but its source is the frame
    // being viewed now; it must not accidentally link to the start of the film.
    final int sourceStartMs = clipEndMs > clipStartMs
        ? clipStartMs
        : (controller.positionMs ?? clipStartMs);
    final int sourceEndMs = clipEndMs > clipStartMs ? clipEndMs : sourceStartMs;
    Future<CardSourceLink?> resolveSourceLink() async {
      final String? fingerprint;
      if (VideoSourceFingerprint.isLocalPath(localSourcePath)) {
        fingerprint = await VideoSourceFingerprint.instance.fingerprint(
          localSourcePath!,
        );
      } else if (contentAddressedStream) {
        fingerprint = null;
      } else {
        return null;
      }
      return CardSourceLink(
        kind: CardSourceKind.video,
        uid: sourceUid,
        sourceId: sourceId,
        episodeIndex: sourceEpisode,
        startMs: sourceStartMs,
        endMs: sourceEndMs,
        fingerprint: fingerprint,
      );
    }

    final String? documentTitle = _videoMiningDocumentTitle();
    // 高级制卡的图片方式覆盖替换设置值，之后仍过 forceSubtitleStart（遥控制卡）与引擎
    // 里的模板降级判断；逐帧挪过的封面帧改按时刻抽（见 [resolveVideoMiningImageMode]）。
    final VideoMiningImageMode imageMode = resolveVideoMiningImageMode(
      preferred: appModel.videoMiningImageMode,
      overrides: overrides,
      forceSubtitleStart: forceSubtitleStart,
    );
    final bool omitCover = overrides?.omitImage ?? false;
    final bool omitAudio = overrides?.omitAudio ?? false;
    // 本页的高级制卡对话框会话（若有）：对话框打开那一刻就锁住了查词时的画面，此刻
    // 播放头可能已被试听挪走——「查词时画面」与各模式的当前帧兜底都用锁住的那一帧。
    // BUG-3492：排队的覆盖（[detachedFromDialog]）执行时，当初那个对话框早关了——
    // 此刻开着的对话框属于另一次查词，不能借它的锁帧和副本。
    final _VideoAdvancedMiningSession? advancedSession = detachedFromDialog
        ? null
        : _advancedMiningSessionFor(controller);
    final MiningAnimatedFormat animatedFormat =
        appModel.videoMiningAnimatedFormat;
    final MiningStillFormat stillFormat = appModel.videoMiningStillFormat;
    final MiningClipFormat clipFormat = appModel.videoMiningClipFormat;
    final String? bookTitleTag = appModel.autoAddBookNameToTags
        ? BaseAnkiRepository.sanitizeTitleTag(_title)
        : null;
    final String? collectionTag = appModel.autoAddBookNameToTags
        ? BaseAnkiRepository.sanitizeTitleTag(_playlistTitle)
        : null;
    // 不要图片时不截（截图只为封面服务）；有对话框锁帧时用锁帧，不再现场截。
    final Future<Uint8List?> currentFrameSnapshot =
        forceSubtitleStart || omitCover
        ? Future<Uint8List?>.value(null)
        : frozenCurrentFrame ??
              advancedSession?.lookupFrame ??
              controller.screenshot().catchError((
                Object error,
                StackTrace stack,
              ) {
                // 截图在入队时就启动，必须立刻接住异常；否则任务排队期间 Future 已失败会
                // 成为 unhandled async error。GIF/字幕起点帧路径仍可继续，截图只作为对应
                // 模式/兜底。
                try {
                  ErrorLogService.instance.log(
                    'mineVideoCard.snapshotCurrentFrame',
                    error,
                    stack,
                  );
                } catch (_) {}
                return null;
              });
    // 不 await：先把本任务按点击顺序送进共享队列，轮到它时再解析临时目录。否则两个
    // 连续点击可能因 path_provider 返回先后不同而逆序入队。
    final Future<String> tempDir = getTemporaryDirectory().then(
      (Directory value) => value.path,
    );
    // 在线视频：这句多半刚播完、还在播放器缓冲里——点击当下就让播放器把它落成本地
    // 副本（落盘毫秒级），引擎对副本抽取，不再为音频和封面各开一次远端流。必须现在
    // 发起而不是等轮到本任务：那时缓冲可能已被挤掉、甚至已换集。分离音轨（YouTube）
    // 不在播放的这条流里，不落副本。拿不到副本引擎照旧远端抽取。
    final String? playbackSource = controller.miningSource;
    // 图片和音频都不要：没有任何东西要从媒体里抽，不落副本。
    final bool needsMedia = !(omitCover && omitAudio);
    // 高级制卡对话框打开时已经落过一份覆盖这段的副本（缩略图从它抽）：够用就直接交给
    // 引擎，不再落第二份；交出去之后归引擎删（用完即删），会话关闭时不再碰它。
    final Future<CachedMediaSnapshot?>? dialogSnapshot =
        needsMedia && audioSource == null
        ? advancedSession?.takeSnapshotCovering(
            clipStartMs: clipStartMs,
            clipEndMs: clipEndMs,
            stillFrameAtMs: stillFrameAtMs,
          )
        : null;
    final Future<CachedMediaSnapshot?>? cachedSnapshot =
        dialogSnapshot ??
        (needsMedia &&
                playbackSource != null &&
                isNetworkStreamUri(playbackSource) &&
                audioSource == null &&
                clipEndMs > clipStartMs
            ? tempDir.then(
                (String dir) => controller.snapshotCachedRange(
                  startMs: math.min(clipStartMs, stillFrameAtMs),
                  endMs: clipEndMs,
                  outputPath: p.join(
                    dir,
                    'mine_snapshot_${DateTime.now().microsecondsSinceEpoch}.mkv',
                  ),
                ),
              )
            : null);
    // 统计 / 历史归属在点击当下冻结：后台落卡时页面可能已经关了。
    final FushiDatabase mineDb = appModel.database;
    final ({String bookKey, String title}) statIdentity = (
      bookKey: _activeBookUid,
      title: _title ?? '',
    );
    // 看完再制卡：媒体照常备好，但交给暂存队列而不是 Anki（见 [VideoMineQueue]）。
    Future<MineOutcome> Function({
      required String rawPayloadJson,
      required AnkiMiningContext context,
    })?
    stageNote;
    if (onlineMode == VideoOnlineMiningMode.deferred) {
      final Future<VideoMineQueue> queueFuture = _videoMineQueue();
      final String queueBookUid = _activeBookUid;
      final String videoKey = '$sourceUid#$sourceEpisode';
      final VideoMineStagedMeta meta = VideoMineStagedMeta(
        documentTitle: _videoMiningDocumentTitle(),
        bookTitleTag: appModel.autoAddBookNameToTags
            ? BaseAnkiRepository.sanitizeTitleTag(_title)
            : null,
        collectionTag: appModel.autoAddBookNameToTags
            ? BaseAnkiRepository.sanitizeTitleTag(_playlistTitle)
            : null,
        statBookKey: statIdentity.bookKey,
        statTitle: statIdentity.title,
        recordHistory: historySnapshot != null,
        historyDateKey: historySnapshot?.dateKey ?? '',
        historyDocumentTitle: historySnapshot?.documentTitle,
        historyBookKey: historySnapshot?.bookKey,
        historySectionIndex: historySnapshot?.sectionIndex,
        historyCueStartMs: historySnapshot?.positionMs,
        historyCueLengthMs: historySnapshot?.durationMs,
      );
      stageNote =
          ({
            required String rawPayloadJson,
            required AnkiMiningContext context,
          }) async {
            final VideoMineQueue queue = await queueFuture;
            await queue.stage(
              bookUid: queueBookUid,
              videoKey: videoKey,
              fields: decodeWebMineFields(rawPayloadJson),
              context: context,
              meta: meta,
            );
            return const MineOutcome.success();
          };
    }
    // BUG-891：远端 Fushi 库视频的 miningSource 是自签 https 流 URL。把该 host 当前会话
    // 已 TOFU 钉扎的证书指纹带给引擎，使 ffmpeg（自编 ffmpeg-kit `--enable-gnutls` + pin
    // 补丁）按指纹接受自签流抽音频/帧，绕过「Protocol not found」。非 Fushi host（本地 /
    // YouTube / 直链）为 null，不钉扎。
    final RemoteVideoClient? remoteClient = _effectiveRemoteClient;
    final String? mediaSourceTlsPin = remoteClient is InterconnectSyncBackend
        ? remoteClient.activeFingerprintSha256
        : null;
    // BUG-1004：互联 host（LAN Fushi 库）远端流——注入「host 端裁音频段」裁切器：host 用
    // 本地文件裁好句子音频再经已鉴权/钉扎的下载通道回传，client 全程不用 ffmpeg 抓远端流，
    // 从根上绕开 client ffmpeg 打不开 host 自签 https/token 流的整类失败（BUG-891 pin 路径
    // 的残余缺口：移动端指纹缺失/URL 编码/网络脆弱仍 I/O error）。老 host 无 clipaudio 端点
    // → 404 → 裁切器返 null → 引擎回退现有 ffmpeg-over-URL 抽取。非 Fushi host（本地/
    // YouTube/直链）不注入。
    final RemoteVideoInfo? remoteInfo = _effectiveRemoteInfo;
    Future<String?> Function({
      required int startMs,
      required int endMs,
      required String outputPath,
    })?
    remoteAudioClipper;
    if (remoteClient is InterconnectSyncBackend && remoteInfo != null) {
      final InterconnectSyncBackend backend = remoteClient;
      final String remoteId = remoteInfo.id;
      final int ac = mediaCompression.audioChannels;
      final String bitrate = mediaCompression.audioBitrate;
      remoteAudioClipper =
          ({
            required int startMs,
            required int endMs,
            required String outputPath,
          }) async {
            final File dest = File(outputPath);
            try {
              await backend.getRemoteVideoAudioClip(
                remoteId,
                dest,
                startMs: startMs,
                endMs: endMs,
                episodeIndex: episode,
                audioStreamIndex: audioStreamIndex,
                audioStreamCount: audioStreamCount,
                audioChannels: ac,
                audioBitrate: bitrate,
              );
              if (dest.existsSync() && dest.lengthSync() > 0) return dest.path;
            } catch (e, st) {
              // 老 host 无端点(404)/网络失败：记录并回 null，让引擎回退直连 ffmpeg 抽取。
              ErrorLogService.instance.log(
                'mineVideoCard.remoteAudioClip',
                e,
                st,
              );
            }
            if (dest.existsSync()) {
              try {
                dest.deleteSync();
              } catch (_) {}
            }
            return null;
          };
    }
    // TODO-1000：委托统一沉浸制卡引擎。媒体降级阶梯 / 无音频中止 / 组 context / 落卡都在
    // 引擎内；本壳只管 OSD + 视频统计。
    //
    // BUG-1205：两个失败摘要过去靠**同一个 onFailure 的调用顺序**区分（首个当 GIF、末个
    // 当音频）。引擎现在让封面与音频并行跑，顺序不再确定——改按来源取：封面失败进
    // [coverFailure]（喂「降级为静态」OSD 的原因），音频失败进 [audioFailure]（喂「无音频
    // 中止」OSD 的原因）。语义由参数名承载，不再依赖时序。
    String? coverFailure;
    String? audioFailure;
    final Future<ImmersionMiningResult> job = ImmersionMiningEngine().mine(
      ImmersionMiningRequest(
        fields: fields,
        mediaSource: mediaSource,
        audioSource: audioSource,
        mediaSourceTlsPinSha256: mediaSourceTlsPin,
        // BUG-2625：制卡源是远端流时，把**播放器取到这条流用的同一组防盗链请求头**
        // 一起交给引擎。在线视频源（Aniyomi 扩展）的 hoster 直链几乎都校验
        // Referer/UA，ffmpeg 裸请求会被 403（`required audio missing`）。本地文件与
        // 无防盗链源这里是空 map，抽取器据此 no-op，既有路径零影响。
        mediaSourceHttpHeaders: _streamHttpHeaderFields,
        mediaSourceRouteReady: mediaSourceRouteReady,
        // 词典媒体缓存：输入已全部冻结，这时才开写，引擎落卡前等它。
        fieldsMediaReady: writeFieldsMedia?.call(),
        // BUG-1004：互联 host 远端流句子音频优先走 host 端裁（绕开 client ffmpeg 抓远端流）。
        remoteAudioClipper: remoteAudioClipper,
        clipStartMs: clipStartMs,
        clipEndMs: clipEndMs,
        stillFrameAtMs: stillFrameAtMs,
        sentence: sentence,
        cueSentence: cueSentence,
        // TODO-761（方案 B）：播放列表下拼「系列名 - 剧集名」，单视频/远端仍是剧集名，零变化。
        documentTitle: documentTitle,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
        // TODO-115：视频来源 → 卡片追加 `video` 分类标签。
        source: AnkiMiningSource.video,
        sourceLinkResolver: resolveSourceLink,
        sourceReviewMine: reviewSession == null
            ? null
            : ({
                required String rawPayloadJson,
                required AnkiMiningContext context,
              }) => _mineSourceReview(
                reviewSession,
                rawPayloadJson: rawPayloadJson,
                context: context,
              ),
        // TODO-681 / BUG-393：番名/标题作书名标签，开关关闭或无标题时 null 不追加。
        bookTitleTag: bookTitleTag,
        // 合集/系列名标签（同上开关）：播放列表下用系列名 _playlistTitle（col.name，已在内存）
        // 作独立 tag，与剧集名并列；单视频/远端无系列名时为 null 不追加。
        collectionTag: collectionTag,
        updateNoteId: updateNoteId,
        stillFallback: () => currentFrameSnapshot,
        // 高级制卡「不要音频 / 不要图片」（只对这一张卡）：引擎跳过对应抽取，两者都
        // 省略时出纯文本卡。
        omitAudio: omitAudio,
        omitCover: omitCover,
        coverMosaic: omitCover
            ? const <MiningMosaicRegion>[]
            : overrides?.mosaic ?? const <MiningMosaicRegion>[],
        // 用户在 Anki 设置里选的封面图片模式（片段 / GIF / 制卡时当前帧 / 字幕开头帧）；
        // 默认 videoClip。静态模式引擎不置 degradedToStill，故不弹「降级为静态」OSD。
        imageMode: imageMode,
        // 动图编码格式（默认 AVIF）。引擎在编码失败时会自动降级 GIF 重试一次——旧版本
        // 包捆绑的 ffmpeg 没有 libsvtav1/libwebp，靠这条保证不会因换默认格式而制不出卡。
        animatedFormat: animatedFormat,
        // 静图编码格式（默认 JPG）：两种截图档与动图抽取失败后的静帧降级都走它。
        // 选 PNG 而捕绑 ffmpeg 缺编码器时引擎自动退回 JPG，不会因换格式而丢封面。
        stillFormat: stillFormat,
        // 音画同步片段格式（默认 WebM VP9，卡片内嵌播放）：编不出来按 AV1→VP9→MP4 降级。
        clipFormat: clipFormat,
        // 在线视频的本地缓冲副本（拿不到就是 null，引擎远端抽取）。
        cachedMediaSnapshot: cachedSnapshot,
        // 看完再制卡：备好媒体后暂存，不落卡。
        stageNote: stageNote,
      ),
      compression: mediaCompression,
      tempDir: tempDir,
      repo: repo,
      // 各取首个摘要：同一来源多次回退（GIF→起点帧→当前帧）时，最先的那条最贴近根因。
      onCoverFailure: (String summary) => coverFailure ??= summary,
      onAudioFailure: (String summary) => audioFailure ??= summary,
    );
    MinePopupResult land(ImmersionMiningResult res) => _landVideoMine(
      res,
      coverFailure: coverFailure,
      audioFailure: audioFailure,
      staged: stageNote != null,
      overwrite: reviewSession != null || updateNoteId != null,
      recordStats: reviewSession == null,
      mineDb: mineDb,
      statIdentity: statIdentity,
      silent: silent,
      onFailure: onFailure,
    );
    if (onlineMode == VideoOnlineMiningMode.wait) return land(await job);
    // BUG-3492：后台**写入 Anki** 的这张卡（不是暂存、不是回看改卡）在落地前可以被排队
    // 覆盖。登记在途，落地时（成功或失败）结算排队的覆盖请求。
    final String? overwriteKey =
        stageNote == null && reviewSession == null && updateNoteId == null
        ? mineEntryKeyOf(fields['expression'] ?? '', fields['reading'] ?? '')
        : null;
    final int? overwriteAddId = overwriteKey == null
        ? null
        : _pendingOverwrites.addStarted(overwriteKey);
    // 写入出错（job 抛错，或落地收尾 [land] 自己抛错）同样要结算：在途标记必须清掉、
    // 排队的覆盖取消并说明，错误照旧交给后台跟踪报 OSD。
    void settleFailed(Object error) {
      if (overwriteKey == null || overwriteAddId == null) return;
      unawaited(
        _settleQueuedOverwrite(
          overwriteKey,
          overwriteAddId,
          fields,
          const MinePopupResult(),
          failureReason: '$error',
        ),
      );
    }

    // 后台 / 看完再制卡：弹窗不陪着等。结局（成功 / 暂存 / 失败）在落地时由 OSD 报告。
    _trackBackgroundMine(
      job
          .then<MinePopupResult>(
            (ImmersionMiningResult res) {
              final MinePopupResult landed;
              try {
                landed = land(res);
              } on Object catch (error) {
                settleFailed(error);
                rethrow;
              }
              if (overwriteKey != null && overwriteAddId != null) {
                unawaited(
                  _settleQueuedOverwrite(
                    overwriteKey,
                    overwriteAddId,
                    fields,
                    landed,
                    failureReason: landed.ankiConnect
                        ? null
                        : _videoMineFailureReason(res),
                  ),
                );
              }
              return landed;
            },
            onError: (Object error, StackTrace stack) {
              settleFailed(error);
              Error.throwWithStackTrace(error, stack);
            },
          )
          .then((MinePopupResult landed) {
            // BUG-3492：弹窗早就拿到了「已加入」，卡真正进 Anki 是现在。通知正在显示这个
            // 词的弹窗重问一次 Anki，把「已加入」换成真 ✓——之后同一个弹窗里点 ✓ / 从高级
            // 制卡回点，才能走覆盖，而不是要关掉弹窗重新查词。
            if (landed.ankiConnect) {
              MinedStateSignal.instance.notifyWord(fields['expression'] ?? '');
            }
            onBackgroundLanded?.call(landed);
          }),
    );
    return const MinePopupResult.queued();
  }

  /// 一张视频卡落地后的收尾（OSD / 统计），等待与后台两条路共用。后台路径上页面可能
  /// 已经关了：OSD 自带 mounted 判断，统计用点击时冻结的 [mineDb] / [statIdentity]。
  ///
  /// [staged] = 看完再制卡：这次只是暂存成功，不是制卡成功——不记统计、报「已加入待制卡」，
  /// 回给调用方的是「未落卡」（不写制卡历史），真正的账在写入 Anki 时记。
  MinePopupResult _landVideoMine(
    ImmersionMiningResult res, {
    required String? coverFailure,
    required String? audioFailure,
    required bool staged,
    required bool overwrite,
    required bool recordStats,
    required FushiDatabase mineDb,
    required ({String bookKey, String title}) statIdentity,
    bool silent = false,
    void Function(String code)? onFailure,
  }) {
    // BUG-296 / TODO-390：应带句子音频却抽取失败 → 显式 OSD + 中止，不建无音频卡。
    if (res.aborted) {
      onFailure?.call(res.abortReason ?? 'sentence_audio_export_failed');
      if (mounted && !silent) {
        _showOsd(
          t.card_export_failed_detail(
            reason:
                res.abortReason ??
                (audioFailure == null
                    ? 'sentence audio export failed'
                    : 'sentence audio export failed: $audioFailure'),
          ),
          severity: ToastSeverity.error,
        );
      }
      return const MinePopupResult();
    }
    // W2a：动图降级为静态帧时可感知 OSD（原因取 GIF 失败摘要，最贴近根因）。
    if (res.degradedToStill && mounted && !silent) {
      _showOsd(
        t.card_cover_degraded_to_static(
          reason: coverFailure ?? 'animated clip unavailable',
        ),
        severity: ToastSeverity.warning,
      );
    }
    final MineOutcome outcome = res.outcome! as MineOutcome;
    if (outcome.result != MineResult.success &&
        outcome.result != MineResult.queued) {
      onFailure?.call(outcome.errorCode ?? outcome.result.name);
    }
    if (staged) {
      // 看完再制卡：只是进了待制卡列表。统计 / 历史等写入 Anki 时再记。
      if (outcome.result == MineResult.success) unawaited(_onVideoMineStaged());
      return const MinePopupResult();
    }
    final MinePopupResult result =
        outcome.result == MineResult.success ||
            outcome.result == MineResult.queued
        ? MinePopupResult.mined(outcome)
        : MinePopupResult.failed(outcome);
    // 牌组名由后端随成功结果带回（outcome.deckName，BUG-1549）。
    // overwrite=true（updateNoteId 非空）→ 收口产 card_overwritten + record=false；
    // 新制 → card_exported + record=true（消息/记账判定统一在 describeMineOutcome）。
    final described = describeMineOutcome(outcome, overwrite: overwrite);
    // 新制成功计入视频统计（dictionarySourceType=video）；覆盖 record=false 故不记账。
    // 本页覆写了 onMineEntry、绕过基类成功分支，故在此显式记账（与 mixin 的
    // recordMined 同一次 DB 写入）。用点击时冻结的库与归属：后台制卡落地时页面可能
    // 已经关了，卡进了 Anki，账也得记上。
    if (described.record && recordStats) {
      unawaited(_recordVideoMineStat(mineDb, statIdentity));
    }
    // State 的 `mounted`，不是 `context.mounted`：后台落地时页面可能早已 unmount，
    // 那时连取 `context` 都会抛（debug FlutterError / release 空检查），落地回调
    // （写制卡历史）就跟着没了，还会记一条假失败。
    if (!mounted) return result;
    // 手机遥控出卡（silent）：结果回给手机，电脑这边不弹 OSD。
    if (silent) return result;
    // TODO-971：制卡成功（card_exported / card_overwritten，含牌组名）走突出 OSD——
    // 居中、更大、停留更久，区别于音量/亮度小角标，避免用户「制卡了没反馈」。
    // describeMineOutcome 早就算出了 status，此前只被拿去选 prominent 布尔、颜色
    // 整个丢掉，于是视频页制卡成功与失败长得一模一样。透传语义即可对齐其它入口。
    // 经 _showMineOsd 过「制卡提示」开关（关掉成功 / 重复提示后不再弹）。
    _showMineOsd(described.message, described.status);
    return result;
  }

  /// 视频制卡的统计记账（= [DictionaryPageMixin.recordMined] 对视频来源的那一次写入），
  /// 但不经 `ref`：后台落卡时页面可能已经销毁。best-effort，失败吞掉。
  Future<void> _recordVideoMineStat(
    FushiDatabase db,
    ({String bookKey, String title}) identity,
  ) async {
    try {
      await db.recordMiningEvent(
        bookKey: identity.bookKey,
        title: identity.title,
        sourceType: kStatSourceVideo,
        at: DateTime.now(),
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] video recordMiningEvent failed: $e\n$st');
    }
  }

  /// TODO-633: land one mined-sentence history row for a video card. Locator
  /// anchors mirror _toggleFavoriteSentenceForVideo (bookUid + episode +
  /// cue.startMs/duration) so collections reuses _openVideoSentence to jump back.
  /// Best-effort; failure is swallowed + logged (does not break mining).
  Future<void> _recordMinedSentenceForVideo(
    VideoMiningHistorySnapshot snapshot,
    int? noteId, {
    FushiDatabase? db,
  }) async {
    try {
      await (db ?? appModel.database).addMinedSentence(
        source: kStatSourceVideo,
        dateKey: snapshot.dateKey,
        expression: snapshot.expression,
        reading: snapshot.reading,
        glossary: snapshot.glossary,
        sentence: snapshot.sentence,
        documentTitle: snapshot.documentTitle,
        bookKey: snapshot.bookKey,
        sectionIndex: snapshot.sectionIndex,
        positionMs: snapshot.positionMs,
        durationMs: snapshot.durationMs,
        noteId: noteId,
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] video addMinedSentence failed: $e\n$st');
    }
  }
}

/// 制卡 ffmpeg 的远端输入是否改走本机中继（与播放器同一条取流路径）。
///
/// - 在线视频源（[RemoteVideoStreamHeaders]：扩展 hoster / 粘贴的流）：BUG-2642 残留，
///   伪装成图片的 HLS 分片只有中继 + 放开扩展名才读得动。
/// - 媒体服务器（[MediaServerBrowser]：Emby / Jellyfin）：BUG-2692。播放器早就经
///   [nativePlaybackUri] 走中继（Dart 的 TLS + 应用代理），制卡 ffmpeg 却直连原始
///   https——移动端 ffmpeg-kit 用自己编进去的 TLS、也不认应用代理，于是「能播放、
///   制不了卡」，截图 / 动图 / 句子音频三条抽取全报 `I/O error`。
/// - 互联主机**不在此列**：它有指纹钉扎（`-tls_pin_sha256` 只对 https 输入有效，
///   改成中继的明文地址反而让 ffmpeg 报选项不认）与 host 端裁音频两条专用通道。
/// - 本地文件 / YouTube（没有远端 client）不改道。
bool videoMiningInputUsesPlaybackRelay({
  required RemoteVideoClient? remoteClient,
  required String mediaSource,
}) {
  if (!isNetworkStreamUri(mediaSource)) return false;
  return remoteClient is RemoteVideoStreamHeaders ||
      remoteClient is MediaServerBrowser;
}

/// 纯函数：据是否播放列表 + 系列名 + 剧集名算制卡 `documentTitle`（TODO-761，方案 B）。
///
/// - 播放列表且系列名非空 → 「系列名 - 剧集名」（剧集名为空时只回系列名，避免尾随分隔符）。
/// - 单视频 / 远端 / 系列名为空（[isPlaylist] 假或 [playlistTitle] 空）→ 原 [episodeTitle]，
///   向后兼容零变化。
/// 分隔符固定 " - "（与卡片标题习惯一致）；不做系列名==剧集名去重（避免过度设计）。
/// 远端 / 在线视频的作品名（BUG-3332）：取 [RemoteVideoInfo.collection] 的合集名——
/// 在线视频源（Aniyomi 扩展）每集都带作品名作合集归属，互联 / 媒体服务器下发的合集
/// 成员同理。没有归属（散卡）或名字为空时 null。供制卡的作品名标签与 documentTitle
/// 使用，与本地播放列表的合集名（[_VideoFushiPageState._playlistTitle]）同一个槽位。
String? remoteVideoWorkTitle(RemoteVideoInfo info) {
  final String name = info.collection?.collectionName.trim() ?? '';
  return name.isEmpty ? null : name;
}

String? composeVideoMiningDocumentTitle({
  required bool isPlaylist,
  required String? playlistTitle,
  required String? episodeTitle,
}) {
  if (!isPlaylist || playlistTitle == null || playlistTitle.isEmpty) {
    return episodeTitle;
  }
  if (episodeTitle == null || episodeTitle.isEmpty) {
    return playlistTitle;
  }
  return '$playlistTitle - $episodeTitle';
}

/// BUG-3492：一次排队的覆盖请求——排队那一刻冻结的全部输入。
class _QueuedVideoOverwrite {
  const _QueuedVideoOverwrite({
    required this.fields,
    required this.range,
    required this.overrides,
    required this.controller,
    required this.episode,
    required this.frame,
    required this.repo,
  });

  /// 词典 payload（已并入「高级制卡」覆盖项）。
  final Map<String, String> fields;

  /// 排队时解析的句子与音频 / 画面区间（含草稿里的上下文句与覆盖项微调）。
  final VideoMiningRange range;
  final MiningRequestOverrides? overrides;

  /// 排队时的播放器与集数：落地时变了就不覆盖。
  final VideoPlayerController controller;
  final int episode;

  /// 排队时的查词画面（高级制卡锁帧或当时截图）；不要图片时 null。
  final Future<Uint8List?>? frame;

  /// 排队时的 Anki 仓库：落地时页面可能已经关了，不经 `ref` 读。
  final BaseAnkiRepository repo;
}
