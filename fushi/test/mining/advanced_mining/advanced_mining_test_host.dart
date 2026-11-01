import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/range_playback.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

/// 「高级制卡」测试用的假宿主：记下对话框对每个回调的调用，并像真宿主一样把句子
/// 增减 / 移除 / 编辑落进自己的草稿，让下一次预览吐出新状态。
class FakeAdvancedMiningHost {
  FakeAdvancedMiningHost({
    this.prevCount = 1,
    this.nextCount = 1,
    this.maxPrev = 5,
    this.maxNext = 5,
    this.audioAvailable = true,
  });

  // ── 句子 ──
  int prevCount;
  int nextCount;
  final int maxPrev;
  final int maxNext;
  final List<List<int>> setContextCalls = <List<int>>[];
  final Map<int, bool> prevRemoved = <int, bool>{};
  final Map<int, bool> nextRemoved = <int, bool>{};
  final List<List<Object>> removeCalls = <List<Object>>[];
  final List<List<Object>> editCalls = <List<Object>>[];
  final Map<String, String> edits = <String, String>{};

  // ── 音频 ──
  bool audioAvailable;
  final List<List<int>> describeCalls = <List<int>>[];
  final List<List<int>> previewCalls = <List<int>>[];
  int stopCalls = 0;
  bool previewResult = true;

  /// 每次成功起播交回的句柄（按顺序）；测试调 `finish` 模拟「这段播完了」。
  final List<RangePlayback> playbacks = <RangePlayback>[];

  /// 非 null 时 preview 卡在这里，模拟起播（seek → play）还在途。
  Completer<void>? previewGate;

  /// true = 像有声书片段播放器那样，播完才从 preview 返回（返回的句柄已结束）。
  bool previewEndsBeforeReturn = false;

  /// 一句 1 秒：区间 = 第一句起 → 最后一句止（未加偏移）。
  static const int sentenceStartMs = 723400;

  // ── 确认 ──
  final List<MiningRequestOverrides> confirms = <MiningRequestOverrides>[];
  bool confirmResult = true;
  Completer<bool>? confirmGate;
  final List<String> setDefaultDeckCalls = <String>[];

  /// 卡片字段分区每次「记住显示哪些字段」的入参。
  final List<Set<String>> setVisibleFieldsCalls = <Set<String>>[];
  int closedCalls = 0;

  // ── 视频 ──
  final List<int> frameRequests = <int>[];

  // ── 漫画 ──
  final List<int> suggestionLoads = <int>[];
  StreamController<int>? downloadController;

  Map<String, Object?> preview() {
    final List<String> prev = <String>[
      for (int i = 0; i < prevCount; i++) edits['prev$i'] ?? 'まえ$i。',
    ];
    final List<String> next = <String>[
      for (int i = 0; i < nextCount; i++) edits['next$i'] ?? 'あと$i。',
    ];
    final int removed =
        prevRemoved.entries
            .where((MapEntry<int, bool> e) => e.key < prevCount && e.value)
            .length +
        nextRemoved.entries
            .where((MapEntry<int, bool> e) => e.key < nextCount && e.value)
            .length;
    return <String, Object?>{
      'prev': prev,
      'current': edits['current'] ?? 'それでも、僕は諦めきれなかった。',
      'currentOffset': edits['current'] == null ? 7 : null,
      'next': next,
      'prevRemoved': <bool>[
        for (int i = 0; i < prevCount; i++) prevRemoved[i] ?? false,
      ],
      'nextRemoved': <bool>[
        for (int i = 0; i < nextCount; i++) nextRemoved[i] ?? false,
      ],
      'total': prev.length + next.length - removed,
    };
  }

  AdvancedMiningSentenceSection sentence({
    bool editable = true,
    bool removable = true,
  }) => AdvancedMiningSentenceSection(
    fetchPreview: () async => preview(),
    setContext: (int p, int n) async {
      setContextCalls.add(<int>[p, n]);
      prevCount = p.clamp(0, maxPrev);
      nextCount = n.clamp(0, maxNext);
      return prevCount + nextCount;
    },
    editSentence: editable
        ? (SentenceContextSlot slot, int index, String text) async {
            editCalls.add(<Object>[slot, index, text]);
            edits[slot == SentenceContextSlot.current
                    ? 'current'
                    : '${slot.name}$index'] =
                text;
          }
        : null,
    removeSentence: removable
        ? (SentenceContextSlot slot, int index, bool removed) async {
            removeCalls.add(<Object>[slot, index, removed]);
            (slot == SentenceContextSlot.prev
                    ? prevRemoved
                    : nextRemoved)[index] =
                removed;
          }
        : null,
  );

  AdvancedMiningAudioSection audio() => AdvancedMiningAudioSection(
    describe: (int s, int e) async {
      describeCalls.add(<int>[s, e]);
      if (!audioAvailable) return null;
      final int count = prevCount + 1 + nextCount;
      return AdvancedMiningAudioWindow(
        startMs: sentenceStartMs + s,
        endMs: sentenceStartMs + count * 1000 + e,
      );
    },
    preview: (int s, int e) async {
      previewCalls.add(<int>[s, e]);
      final Completer<void>? gate = previewGate;
      if (gate != null) await gate.future;
      if (!previewResult) return null;
      final RangePlayback playback = RangePlayback();
      playbacks.add(playback);
      if (previewEndsBeforeReturn) playback.finish(RangePlaybackEnd.reachedEnd);
      return playback;
    },
    stopPreview: () async {
      stopCalls++;
      // 像真宿主一样：停止就是把还在放的那段以「打断」收尾。
      for (final RangePlayback p in playbacks) {
        p.finish(RangePlaybackEnd.interrupted);
      }
    },
  );

  AdvancedMiningVideoImageSection video({
    List<VideoMiningImageMode> modes = VideoMiningImageMode.values,
    VideoMiningImageMode defaultMode = VideoMiningImageMode.gif,
    bool withFrames = true,
  }) => AdvancedMiningVideoImageSection(
    modes: modes,
    defaultMode: defaultMode,
    frameStepMs: 42,
    lookupFrameMs: 725000,
    subtitleStartMs: 724100,
    frameAt: withFrames
        ? (int at) async {
            frameRequests.add(at);
            return null;
          }
        : null,
  );

  static const MangaCropSuggestions mangaSuggestions = MangaCropSuggestions(
    pageIndex: 46,
    pageSize: Size(1640, 2320),
    panels: <Rect>[
      Rect.fromLTRB(0.03, 0.03, 0.97, 0.28),
      Rect.fromLTRB(0.03, 0.30, 0.49, 0.67),
      Rect.fromLTRB(0.51, 0.30, 0.97, 0.67),
      Rect.fromLTRB(0.03, 0.69, 0.97, 0.97),
    ],
    containingPanel: Rect.fromLTRB(0.51, 0.30, 0.97, 0.67),
    textRect: Rect.fromLTRB(0.60, 0.34, 0.74, 0.50),
    textAreaRect: Rect.fromLTRB(0.55, 0.30, 0.80, 0.55),
  );

  AdvancedMiningMangaImageSection manga({
    bool modelAvailable = true,
    Uint8List? pageBytes,
    MangaCropSuggestions? suggestions = mangaSuggestions,
    bool downloadable = true,
  }) => AdvancedMiningMangaImageSection(
    loadPage: () async => pageBytes,
    loadSuggestions: () async {
      suggestionLoads.add(suggestionLoads.length);
      return suggestions;
    },
    panelModelAvailable: modelAvailable,
    panelModelSizeBytes: 9800000,
    downloadPanelModel: downloadable
        ? () {
            downloadController = StreamController<int>();
            return downloadController!.stream;
          }
        : null,
  );

  AdvancedMiningDeckSection deck({
    List<String> decks = const <String>['日语::挖矿', '日语::动画', '日语::听力'],
    String? defaultDeck = '日语::挖矿',
    bool allowSetDefault = true,
  }) => AdvancedMiningDeckSection(
    decks: decks,
    defaultDeckName: defaultDeck,
    setDefaultDeck: allowSetDefault
        ? (String name) async => setDefaultDeckCalls.add(name)
        : null,
  );

  /// 卡片字段分区（Lapis 风格的三个字段；默认显示释义）。
  AdvancedMiningFieldsSection fields({
    Set<String> visible = const <String>{'MainDefinition'},
  }) => AdvancedMiningFieldsSection(
    fields: const <AdvancedMiningField>[
      AdvancedMiningField(name: 'Expression', template: '{expression}'),
      AdvancedMiningField(name: 'Sentence', template: '{sentence}'),
      AdvancedMiningField(name: 'MainDefinition', template: '{glossary-first}'),
    ],
    visibleFields: visible,
    setVisibleFields: (Set<String> names) async =>
        setVisibleFieldsCalls.add(names),
  );

  AdvancedMiningCapabilities capabilities({
    AdvancedMiningDeckSection? deck,
    AdvancedMiningFieldsSection? fields,
    AdvancedMiningSentenceSection? sentence,
    AdvancedMiningAudioSection? audio,
    AdvancedMiningVideoImageSection? video,
    AdvancedMiningMangaImageSection? manga,
    AdvancedMiningStillImageSection? still,
  }) => AdvancedMiningCapabilities(
    matched: '諦め',
    expression: '諦める',
    deck: deck,
    fields: fields,
    sections: AdvancedMiningSections(
      sentence: sentence,
      audio: audio,
      videoImage: video,
      mangaImage: manga,
      stillImage: still,
      onClosed: () async => closedCalls++,
    ),
    onConfirm: (MiningRequestOverrides overrides) async {
      confirms.add(overrides);
      if (confirmGate != null) return confirmGate!.future;
      return confirmResult;
    },
  );

  /// 视频页的全部分区（卡组 + 句子 + 音频 + 视频图片）。
  AdvancedMiningCapabilities videoPage({
    VideoMiningImageMode defaultMode = VideoMiningImageMode.gif,
  }) => capabilities(
    deck: deck(),
    sentence: sentence(),
    audio: audio(),
    video: video(defaultMode: defaultMode),
  );

  /// 漫画页（卡组 + 句子 + 漫画图片）。
  AdvancedMiningCapabilities mangaPage({
    bool modelAvailable = true,
    Uint8List? pageBytes,
  }) => capabilities(
    deck: deck(),
    sentence: sentence(),
    manga: manga(modelAvailable: modelAvailable, pageBytes: pageBytes),
  );
}
