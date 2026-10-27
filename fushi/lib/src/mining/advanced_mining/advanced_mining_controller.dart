import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController, TextSelection;
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/range_playback.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

/// 漫画卡图的取景方式。
enum MangaCropChoice { wholePage, panel, textArea, custom, none }

/// 整页（不裁）的归一化矩形。
const Rect kMangaWholePageRect = Rect.fromLTRB(0, 0, 1, 1);

/// 「高级制卡」对话框的全部可变状态与宿主往返。
///
/// 为什么把状态从 widget 里抽出来：宽屏双栏、窄屏折叠行、手机全屏框选是三套布局，
/// 同一份选择要在它们之间共享（窄屏点开全屏框选页再「完成」回来，选中框必须还在）。
/// 放在某个 State 里就得层层回调；放进 [ChangeNotifier] 后各布局只管读 + 调方法。
///
/// 它也是**唯一**决定「确认时产出什么覆盖项」的地方（[buildOverrides]），UI 不自己拼。
class AdvancedMiningController extends ChangeNotifier {
  AdvancedMiningController(this.capabilities) {
    _initDefaults();
  }

  final AdvancedMiningCapabilities capabilities;

  AdvancedMiningSections get sections => capabilities.sections;
  AdvancedMiningDeckSection? get deckSection => capabilities.deck;
  AdvancedMiningSentenceSection? get sentenceSection => sections.sentence;
  AdvancedMiningAudioSection? get audioSection => sections.audio;
  AdvancedMiningVideoImageSection? get videoSection => sections.videoImage;
  AdvancedMiningMangaImageSection? get mangaSection => sections.mangaImage;
  AdvancedMiningStillImageSection? get stillSection => sections.stillImage;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _editController?.dispose();
    _downloadSub?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 打开后拉一遍所有异步数据（句子预览 → 音频区间；漫画原图与建议框并行）。
  Future<void> load() async {
    await Future.wait(<Future<void>>[
      _loadSentenceThenAudio(),
      if (mangaSection != null) _loadManga(),
      if (stillSection != null) _loadStill(),
    ]);
  }

  Future<void> _loadSentenceThenAudio() async {
    if (sentenceSection != null) await refreshSentences(initial: true);
    await refreshAudioWindow();
  }

  // ───────────────────────────── 忙 / 编辑锁 ─────────────────────────────

  bool _busy = false;

  /// 正在与宿主往返（加减句、编辑落地、确认制卡）。
  bool get busy => _busy;

  set busy(bool value) {
    if (_busy == value) return;
    _busy = value;
    _notify();
  }

  /// 外层控件（加减句 / 试听 / 取消 / 确认 / 关闭 / 各分区选项）是否禁用：正在跟宿主
  /// 通信，或有一句正在编辑——编辑到一半改句数，宿主会整体重解析上下文、改好的文本
  /// 要么丢要么贴错句（沿用旧「调整上下文」对话框的锁）。
  bool get locked => _busy || editing;

  // ───────────────────────────── 句子 ─────────────────────────────

  List<String> prev = const <String>[];
  List<String> next = const <String>[];

  /// 与 [prev] / [next] 逐位对应：该句是否已被移除（宿主未给该字段时全 false）。
  List<bool> prevRemoved = const <bool>[];
  List<bool> nextRemoved = const <bool>[];
  String current = '';
  int? currentOffset;

  /// 上下文句中仍保留的句数（宿主 `total`，不含当前句）。
  int contextTotal = 0;
  bool sentenceLoading = true;

  // 打开时的上下文快照：取消 / 「恢复默认」时还原，不把半调整的草稿留给后续一键「+」。
  int _snapPrev = 0;
  int _snapNext = 0;
  bool _snapped = false;

  /// 到边界（请求更多但宿主返回的句数不再增长：段落 / 章 / 文首文尾封顶）时禁用对应
  /// 「加一句」，给诚实反馈而不是点了没反应。
  bool prevAtMax = false;
  bool nextAtMax = false;

  /// 卡片上一共几句（含当前句）。
  int get sentenceCount => contextTotal + 1;

  SentenceContextSlot? _editSlot;
  int _editIndex = 0;
  TextEditingController? _editController;

  SentenceContextSlot? get editSlot => _editSlot;
  int get editIndex => _editIndex;
  TextEditingController? get editController => _editController;

  /// 是否有一句正在编辑。同一时刻只允许一句可编辑：多句同时开输入框会让「确认修改」
  /// 指向不明。
  bool get editing => _editSlot != null;

  static List<String> _stringList(Object? v) => v is List
      ? <String>[for (final Object? e in v) e.toString()]
      : const <String>[];

  static List<bool> _boolList(Object? v, int length) => <bool>[
    for (int i = 0; i < length; i++) v is List && i < v.length && v[i] == true,
  ];

  Future<void> refreshSentences({bool initial = false}) async {
    final AdvancedMiningSentenceSection? section = sentenceSection;
    if (section == null) return;
    final Map<String, Object?> p = await section.fetchPreview();
    if (_disposed) return;
    prev = _stringList(p['prev']);
    next = _stringList(p['next']);
    prevRemoved = _boolList(p['prevRemoved'], prev.length);
    nextRemoved = _boolList(p['nextRemoved'], next.length);
    current = p['current'] as String? ?? '';
    currentOffset = (p['currentOffset'] as num?)?.toInt();
    contextTotal = (p['total'] as num?)?.toInt() ?? (prev.length + next.length);
    if (initial && !_snapped) {
      _snapPrev = prev.length;
      _snapNext = next.length;
      _snapped = true;
    }
    sentenceLoading = false;
    _notify();
  }

  /// 前文 / 后文整体加一句或减一句（宿主 `setContext` 是整体替换语义）。
  Future<void> adjustContext({
    required bool prevDir,
    required bool plus,
  }) async {
    final AdvancedMiningSentenceSection? section = sentenceSection;
    if (section == null || locked) return;
    if (!plus && (prevDir ? prev.isEmpty : next.isEmpty)) return;
    if (plus && (prevDir ? prevAtMax : nextAtMax)) return;
    busy = true;
    try {
      final int curPrev = prev.length;
      final int curNext = next.length;
      final int newPrev = prevDir
          ? (plus ? curPrev + 1 : curPrev - 1)
          : curPrev;
      final int newNext = prevDir
          ? curNext
          : (plus ? curNext + 1 : curNext - 1);
      final int before = prevDir ? curPrev : curNext;
      await section.setContext(newPrev, newNext);
      await refreshSentences();
      final int after = prevDir ? prev.length : next.length;
      if (prevDir) {
        prevAtMax = plus && after <= before;
        if (!plus) prevAtMax = false;
      } else {
        nextAtMax = plus && after <= before;
        if (!plus) nextAtMax = false;
      }
    } finally {
      busy = false;
    }
    // 句子一变，写进卡片的音频区间（与画面窗口）就变了，重新问宿主。
    unawaited(refreshAudioWindow());
  }

  /// 某一句前文 / 后文的「×」：
  /// * 最外侧那句（离当前句最远）= 句数减一——用户就是想「少要一句」，留一条删除线
  ///   反而让他以为还占着位置；
  /// * 夹在中间的句子 = 移除（删除线 + 恢复），因为「减一句」只能从两端减，中间的
  ///   旁白 / 语气词没有别的办法拿掉。
  Future<void> dismissSentence(SentenceContextSlot slot, int index) async {
    final bool outermost = slot == SentenceContextSlot.prev
        ? index == 0
        : index == next.length - 1;
    if (outermost) {
      await adjustContext(
        prevDir: slot == SentenceContextSlot.prev,
        plus: false,
      );
      return;
    }
    await setSentenceRemoved(slot, index, true);
  }

  /// 移除 / 恢复某一句前文 / 后文，再从宿主拉一次预览。
  Future<void> setSentenceRemoved(
    SentenceContextSlot slot,
    int index,
    bool removed,
  ) async {
    final Future<void> Function(SentenceContextSlot, int, bool)? remove =
        sentenceSection?.removeSentence;
    if (remove == null || locked) return;
    busy = true;
    try {
      await remove(slot, index, removed);
      await refreshSentences();
    } finally {
      busy = false;
    }
    unawaited(refreshAudioWindow());
  }

  /// 「×」对这一句可用吗：最外侧句总能减；中间句要宿主支持移除。
  bool canDismiss(SentenceContextSlot slot, int index) {
    final bool outermost = slot == SentenceContextSlot.prev
        ? index == 0
        : index == next.length - 1;
    return outermost || sentenceSection?.removeSentence != null;
  }

  /// 进入某一句的编辑态：把该句当前文本灌进输入框。
  void startEdit(SentenceContextSlot slot, int index, String text) {
    if (_busy || editing) return;
    _editController?.dispose();
    _editSlot = slot;
    _editIndex = index;
    _editController = TextEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: text.length);
    _notify();
  }

  /// 退出编辑态（不落地）。
  void cancelEdit() {
    if (!editing) return;
    _editController?.dispose();
    _editSlot = null;
    _editIndex = 0;
    _editController = null;
    _notify();
  }

  /// 确认修改：写回宿主草稿，再重新拉一次预览（宿主是唯一真值——它可能把空白句还原
  /// 成原句，UI 不把输入框里的文本直接当成结果显示）。
  ///
  /// 前文 / 后文清空后确认 = 移除这一句（用户的直觉操作：把那句删光再确认）。当前句
  /// 清空仍是还原——当前句不可移除。
  Future<void> commitEdit() async {
    final SentenceContextSlot? slot = _editSlot;
    final AdvancedMiningSentenceSection? section = sentenceSection;
    final Future<void> Function(SentenceContextSlot, int, String)? edit =
        section?.editSentence;
    if (slot == null || edit == null) return;
    final String text = _editController?.text ?? '';
    final int index = _editIndex;
    final Future<void> Function(SentenceContextSlot, int, bool)? remove =
        section?.removeSentence;
    final bool removeInstead =
        text.trim().isEmpty &&
        slot != SentenceContextSlot.current &&
        remove != null;
    cancelEdit();
    busy = true;
    try {
      if (removeInstead) {
        await remove(slot, index, true);
      } else {
        await edit(slot, index, text);
      }
      await refreshSentences();
    } finally {
      busy = false;
    }
    unawaited(refreshAudioWindow());
  }

  /// 把上下文句数还原到打开时的快照。宿主失败尽力而为（取消照样要关窗）。
  Future<void> restoreSentenceSnapshot() async {
    final AdvancedMiningSentenceSection? section = sentenceSection;
    if (section == null || !_snapped) return;
    try {
      await section.setContext(_snapPrev, _snapNext);
    } catch (e, stack) {
      fushiDebugPrint('AdvancedMining.restoreSentenceSnapshot: $e\n$stack');
    }
  }

  // ───────────────────────────── 卡组 ─────────────────────────────

  String? deckName;

  /// 「同时设为默认卡组」。
  bool setDeckAsDefault = false;

  void selectDeck(String? name) {
    if (locked || name == deckName) return;
    deckName = name;
    _notify();
  }

  void toggleDeckAsDefault(bool value) {
    if (locked) return;
    setDeckAsDefault = value;
    _notify();
  }

  /// 主按钮上显示的目标卡组；null = 不知道（没有卡组分区，或尚未选择任何卡组）。
  String? get targetDeckName => deckSection == null ? null : deckName;

  // ───────────────────────────── 音频 ─────────────────────────────

  bool omitAudio = false;
  int audioStartDeltaMs = 0;
  int audioEndDeltaMs = 0;

  /// 最近一次 describe 的结果；null 且 [audioLoaded] = 这几句没有音频。
  AdvancedMiningAudioWindow? audioWindow;
  bool audioLoaded = false;

  /// 试听是否正在播。只驱动按钮外观；真正的播放状态在宿主控制器里，这里跟着宿主交回
  /// 的 [RangePlayback] 走：那段播完 / 被打断就复位（FDN66-xurt）。
  bool previewing = false;

  /// 每次起播 / 停止都 +1：只认最新一次试听的结局，停掉的旧一段晚到的「结束」不能把
  /// 新一段的按钮复位。
  int _previewGen = 0;

  int _describeGen = 0;

  /// 重新问宿主「现在会写进卡片的区间」。只保留最新一次的结果：连按几下微调时，
  /// 先发的请求可能后回来，不能拿旧区间覆盖新区间。
  Future<void> refreshAudioWindow() async {
    final AdvancedMiningAudioSection? section = audioSection;
    if (section == null) return;
    final int gen = ++_describeGen;
    AdvancedMiningAudioWindow? window;
    try {
      window = await section.describe(audioStartDeltaMs, audioEndDeltaMs);
    } catch (e, stack) {
      fushiDebugPrint('AdvancedMining.describe: $e\n$stack');
      window = null;
    }
    if (_disposed || gen != _describeGen) return;
    audioWindow = window;
    audioLoaded = true;
    _notify();
  }

  void setOmitAudio(bool value) {
    if (locked || omitAudio == value) return;
    omitAudio = value;
    // 视频片段是「画面 + 这段句子音频」一个文件：没有音频就做不出来。已选片段时
    // 退回一个不依赖音频的方式，而不是留一个确认后必然失败的组合。
    if (value && videoImageMode == VideoMiningImageMode.videoClip) {
      videoImageMode = _fallbackWithoutClip();
    }
    if (value) unawaited(stopPreview());
    _notify();
  }

  VideoMiningImageMode? _fallbackWithoutClip() {
    final List<VideoMiningImageMode> modes = availableImageModes;
    if (modes.contains(VideoMiningImageMode.gif)) {
      return VideoMiningImageMode.gif;
    }
    for (final VideoMiningImageMode m in modes) {
      if (m != VideoMiningImageMode.videoClip) return m;
    }
    return null;
  }

  /// 起点 / 终点各挪 [deltaMs]（负 = 提前）。画面窗口（动图 / 片段首尾帧）与音频共用
  /// 这一对偏移，所以视频的逐帧挪动也走这里。
  void nudgeAudioEdge({required bool start, required int deltaMs}) {
    if (locked) return;
    if (start) {
      audioStartDeltaMs += deltaMs;
    } else {
      audioEndDeltaMs += deltaMs;
    }
    // 先按偏移量乐观地平移已知区间，让时间标签 / 区间条 / 首尾帧即时跟手；宿主的
    // describe 回来后再以它为准（它可能夹到 0 或媒体时长）。
    final AdvancedMiningAudioWindow? w = audioWindow;
    if (w != null) {
      audioWindow = AdvancedMiningAudioWindow(
        startMs: start ? w.startMs + deltaMs : w.startMs,
        endMs: start ? w.endMs : w.endMs + deltaMs,
      );
    }
    _notify();
    unawaited(refreshAudioWindow());
  }

  /// 试听 / 停止。返回 false = 宿主说这段没有可试听的音频（调用方如实提示）。
  ///
  /// 每次都把**当前**偏移交给宿主重新算区间，而不是复用打开时的那一段：用户在这里
  /// 加减句子、微调起止的目的就是改变那段区间（BUG-2196 ②）。
  ///
  /// 起播后按宿主交回的句柄收尾：那段播完 / 被打断时 [previewing] 自动复位，下一次点击
  /// 就是重新试听，而不是去停一段早已结束的播放（FDN66-xurt）。
  Future<bool> togglePreview() async {
    final AdvancedMiningAudioSection? section = audioSection;
    if (section == null) return false;
    if (previewing) {
      await stopPreview();
      return true;
    }
    final int gen = ++_previewGen;
    previewing = true;
    _notify();
    RangePlayback? playback;
    try {
      playback = await section.preview(audioStartDeltaMs, audioEndDeltaMs);
    } catch (e, stack) {
      fushiDebugPrint('AdvancedMining.preview: $e\n$stack');
      playback = null;
    }
    if (_disposed) return playback != null;
    if (gen != _previewGen) {
      // 起播途中用户已点了停止（stopPreview 已复位按钮）：那次停止早于这次起播落地，
      // 宿主随后才把这段放出来，补停一次，不留一段按钮显示「没在放」却在响的声音。
      if (playback != null && !playback.isEnded) {
        await _stopHostPreview(section);
      }
      return true;
    }
    if (playback == null) {
      previewing = false;
      _notify();
      return false;
    }
    unawaited(_resetWhenPreviewEnds(playback, gen));
    return true;
  }

  Future<void> _resetWhenPreviewEnds(RangePlayback playback, int gen) async {
    await playback.ended;
    if (_disposed || gen != _previewGen || !previewing) return;
    previewing = false;
    _notify();
  }

  Future<void> _stopHostPreview(AdvancedMiningAudioSection section) async {
    try {
      await section.stopPreview();
    } catch (e, stack) {
      fushiDebugPrint('AdvancedMining.stopPreview: $e\n$stack');
    }
  }

  Future<void> stopPreview() async {
    if (!previewing) return;
    _previewGen++;
    final AdvancedMiningAudioSection? section = audioSection;
    if (section != null) await _stopHostPreview(section);
    previewing = false;
    _notify();
  }

  // ───────────────────────────── 视频图片 ─────────────────────────────

  /// 当前选中的图片方式；null = 「不要」。
  VideoMiningImageMode? videoImageMode;
  VideoMiningImageMode? _initialVideoImageMode;

  /// 静态帧（查词时画面 / 字幕开头）相对各自基准挪过的毫秒数，按方式分开记：切到
  /// 另一种方式再切回来，原来挪好的帧不该丢。
  final Map<VideoMiningImageMode, int> _stillDeltaMs =
      <VideoMiningImageMode, int>{};

  /// 对话框里真正可选的方式：宿主给的 [AdvancedMiningVideoImageSection.modes]，去掉
  /// 基准时刻不可用的静态方式（没有查词瞬间那一帧，就没有「查词时画面」可选）。
  List<VideoMiningImageMode> get availableImageModes {
    final AdvancedMiningVideoImageSection? section = videoSection;
    if (section == null) return const <VideoMiningImageMode>[];
    return <VideoMiningImageMode>[
      for (final VideoMiningImageMode m in section.modes)
        if (stillBaseMs(m) != null || !m.isStill) m,
    ];
  }

  /// 静态方式的基准时刻；非静态方式 / 不可用时 null。
  int? stillBaseMs(VideoMiningImageMode mode) {
    final AdvancedMiningVideoImageSection? section = videoSection;
    if (section == null) return null;
    switch (mode) {
      case VideoMiningImageMode.currentFrame:
        return section.lookupFrameMs;
      case VideoMiningImageMode.subtitleStart:
        return section.subtitleStartMs;
      case VideoMiningImageMode.gif:
      case VideoMiningImageMode.videoClip:
        return null;
    }
  }

  /// 视频片段此刻能不能选（不要音频时不能）。
  bool isImageModeEnabled(VideoMiningImageMode mode) =>
      !(mode == VideoMiningImageMode.videoClip && omitAudio);

  void selectVideoImageMode(VideoMiningImageMode? mode) {
    if (locked || mode == videoImageMode) return;
    if (mode != null && !isImageModeEnabled(mode)) return;
    videoImageMode = mode;
    _notify();
  }

  /// 当前静态帧的时刻（基准 + 已挪）；非静态方式时 null。
  int? get stillFrameMs {
    final VideoMiningImageMode? mode = videoImageMode;
    if (mode == null || !mode.isStill) return null;
    final int? base = stillBaseMs(mode);
    if (base == null) return null;
    return base + (_stillDeltaMs[mode] ?? 0);
  }

  /// 静态帧逐帧挪动。
  void nudgeStillFrame({required bool forward}) {
    final VideoMiningImageMode? mode = videoImageMode;
    final AdvancedMiningVideoImageSection? section = videoSection;
    if (locked || mode == null || !mode.isStill || section == null) return;
    final int step = forward ? section.frameStepMs : -section.frameStepMs;
    final int base = stillBaseMs(mode) ?? 0;
    final int next = (_stillDeltaMs[mode] ?? 0) + step;
    // 不挪到播放器轴 0 之前：那一帧不存在。
    _stillDeltaMs[mode] = base + next < 0 ? -base : next;
    _notify();
  }

  /// 动图 / 片段的首帧 / 尾帧逐帧挪动：挪的就是音频起止偏移（画面窗口与音频共用）。
  void nudgeVideoEdge({required bool first, required bool forward}) {
    final AdvancedMiningVideoImageSection? section = videoSection;
    if (section == null) return;
    nudgeAudioEdge(
      start: first,
      deltaMs: forward ? section.frameStepMs : -section.frameStepMs,
    );
  }

  // ───────────────────────────── 漫画裁切 ─────────────────────────────

  MangaCropChoice cropChoice = MangaCropChoice.wholePage;
  MangaCropChoice _initialCropChoice = MangaCropChoice.wholePage;

  /// 「自定义」的框；切到自定义时从当前框继承，免得一切换框就跳回整页。
  Rect customCropRect = kMangaWholePageRect;
  MangaCropSuggestions? cropSuggestions;
  Uint8List? pageBytes;
  bool mangaLoading = false;
  bool panelModelAvailable = false;

  /// 正在下载分镜模型时已收字节；null = 没在下载。
  int? downloadedBytes;
  StreamSubscription<int>? _downloadSub;

  bool get downloadingPanelModel => downloadedBytes != null;

  Future<void> _loadManga() async {
    final AdvancedMiningMangaImageSection? section = mangaSection;
    if (section == null) return;
    mangaLoading = true;
    _notify();
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      _guard<Uint8List?>(section.loadPage, 'loadPage'),
      _guard<MangaCropSuggestions?>(section.loadSuggestions, 'loadSuggestions'),
    ]);
    if (_disposed) return;
    pageBytes = results[0] as Uint8List?;
    cropSuggestions = results[1] as MangaCropSuggestions?;
    _initialCropChoice = _defaultCropChoice();
    cropChoice = _initialCropChoice;
    customCropRect = cropRectFor(cropChoice) ?? kMangaWholePageRect;
    mangaLoading = false;
    _notify();
  }

  static Future<T?> _guard<T>(Future<T?> Function() run, String what) async {
    try {
      return await run();
    } catch (e, stack) {
      fushiDebugPrint('AdvancedMining.$what: $e\n$stack');
      return null;
    }
  }

  /// 默认取景：模型可用且找到所在分镜 → 所在分镜；否则有文字外扩框 → 文字周围；
  /// 都没有 → 整页。
  MangaCropChoice _defaultCropChoice() {
    final MangaCropSuggestions? s = cropSuggestions;
    if (s == null) return MangaCropChoice.wholePage;
    if (panelModelAvailable && s.containingPanel != null) {
      return MangaCropChoice.panel;
    }
    if (s.textAreaRect != null) return MangaCropChoice.textArea;
    return MangaCropChoice.wholePage;
  }

  /// 这个取景方式此刻有没有可用的框（没有所在分镜就不给「所在分镜」）。
  bool isCropChoiceAvailable(MangaCropChoice choice) {
    switch (choice) {
      case MangaCropChoice.panel:
        // 「所在分镜」是分镜模型的结论：模型没下好时宿主即便给了框也不当分镜用。
        return panelModelAvailable && cropSuggestions?.containingPanel != null;
      case MangaCropChoice.textArea:
        return cropSuggestions?.textAreaRect != null;
      case MangaCropChoice.wholePage:
      case MangaCropChoice.custom:
      case MangaCropChoice.none:
        return true;
    }
  }

  /// 某个取景方式对应的归一化框；「不要」为 null。
  Rect? cropRectFor(MangaCropChoice choice) {
    switch (choice) {
      case MangaCropChoice.wholePage:
        return kMangaWholePageRect;
      case MangaCropChoice.panel:
        return cropSuggestions?.containingPanel ?? kMangaWholePageRect;
      case MangaCropChoice.textArea:
        return cropSuggestions?.textAreaRect ?? kMangaWholePageRect;
      case MangaCropChoice.custom:
        return customCropRect;
      case MangaCropChoice.none:
        return null;
    }
  }

  Rect? get cropRect => cropRectFor(cropChoice);

  void selectCropChoice(MangaCropChoice choice) {
    if (locked || choice == cropChoice || !isCropChoiceAvailable(choice)) {
      return;
    }
    // 切到「自定义」：从眼前这个框接着调，而不是跳回上一次的自定义框。
    if (choice == MangaCropChoice.custom) {
      customCropRect = cropRect ?? customCropRect;
    }
    cropChoice = choice;
    _notify();
  }

  /// 用户在图上动过框（拖新框 / 平移 / 调大小 / 键盘微调）→ 自动切到「自定义」；
  /// Tab 切到的分镜若恰好是所在分镜，就记成「所在分镜」而不是一个等价的自定义框。
  void setCropRect(Rect rect, {bool fromPanelCycle = false}) {
    if (locked) return;
    final Rect? containing = cropSuggestions?.containingPanel;
    if (fromPanelCycle && containing != null && _sameRect(rect, containing)) {
      cropChoice = MangaCropChoice.panel;
    } else {
      customCropRect = rect;
      cropChoice = MangaCropChoice.custom;
    }
    _notify();
  }

  static bool _sameRect(Rect a, Rect b) =>
      (a.left - b.left).abs() < 1e-6 &&
      (a.top - b.top).abs() < 1e-6 &&
      (a.right - b.right).abs() < 1e-6 &&
      (a.bottom - b.bottom).abs() < 1e-6;

  /// 全屏框选页「×」用：进页时记下、放弃时还原。
  ({MangaCropChoice choice, Rect custom}) snapshotCrop() =>
      (choice: cropChoice, custom: customCropRect);

  void restoreCrop(({MangaCropChoice choice, Rect custom}) snapshot) {
    cropChoice = snapshot.choice;
    customCropRect = snapshot.custom;
    _notify();
  }

  /// 下载分镜模型：显示进度，完成后重新拿建议框并切到「所在分镜」。返回 false = 失败。
  Future<bool> downloadPanelModel() async {
    final AdvancedMiningMangaImageSection? section = mangaSection;
    final Stream<int> Function()? download = section?.downloadPanelModel;
    if (section == null || download == null || downloadingPanelModel) {
      return false;
    }
    downloadedBytes = 0;
    _notify();
    final Completer<bool> done = Completer<bool>();
    _downloadSub = download().listen(
      (int received) {
        downloadedBytes = received;
        _notify();
      },
      onError: (Object e, StackTrace stack) {
        fushiDebugPrint('AdvancedMining.downloadPanelModel: $e\n$stack');
        if (!done.isCompleted) done.complete(false);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(true);
      },
      cancelOnError: true,
    );
    final bool ok = await done.future;
    _downloadSub = null;
    if (_disposed) return ok;
    downloadedBytes = null;
    if (!ok) {
      _notify();
      return false;
    }
    panelModelAvailable = true;
    final MangaCropSuggestions? fresh = await _guard<MangaCropSuggestions?>(
      section.loadSuggestions,
      'loadSuggestions',
    );
    if (_disposed) return true;
    if (fresh != null) cropSuggestions = fresh;
    if (cropSuggestions?.containingPanel != null) {
      cropChoice = MangaCropChoice.panel;
    }
    _notify();
    return true;
  }

  // ───────────────────────────── 静态截图（galgame） ─────────────────────────────

  /// 冻结的那一帧（[AdvancedMiningStillImageSection.loadImage]）；null 且不在加载 =
  /// 抓不到。
  Uint8List? stillImageBytes;
  bool stillImageLoading = false;

  Future<void> _loadStill() async {
    final AdvancedMiningStillImageSection? section = stillSection;
    if (section == null) return;
    stillImageLoading = true;
    _notify();
    final Uint8List? bytes = await _guard<Uint8List?>(
      section.loadImage,
      'loadStill',
    );
    if (_disposed) return;
    stillImageBytes = bytes == null || bytes.isEmpty ? null : bytes;
    stillImageLoading = false;
    _notify();
  }

  // ───────────────────────────── 打码 ─────────────────────────────

  /// 卡图上的打码区域（相对**未裁切**的原图 / 那一帧，见 [MiningMosaicRegion]）。
  ///
  /// 漫画与裁切共存：打码坐标不随取景框变，先打码再裁，取景框改了已打的码照样落在
  /// 原位（框外的码自然被裁掉）。
  List<MiningMosaicRegion> mosaicRegions = const <MiningMosaicRegion>[];

  /// 此刻的图片选择能不能打码：静态截图分区抓到图就能；漫画选了「不要」时不能；
  /// 视频选了任一图片方式且取得到帧就能——动图 / 片段打了码由宿主降级为「字幕开头」
  /// 静帧（逐帧打码做不到所见即所得），对话框里如实提示（[mosaicForcesStill]）。
  bool get mosaicApplicable {
    if (stillSection != null) return stillImageBytes != null;
    if (mangaSection != null) return cropChoice != MangaCropChoice.none;
    if (videoSection != null) {
      return videoImageMode != null &&
          videoSection!.frameAt != null &&
          mosaicFrameMs != null;
    }
    return false;
  }

  /// 视频打码对着哪一帧（播放器轴毫秒）：静态方式 = 那一帧（含逐帧挪动）；动图 / 片段
  /// = 降级后会出的「字幕开头」那一帧（没有就退查词时画面）。null = 没有可打码的帧。
  int? get mosaicFrameMs {
    final VideoMiningImageMode? mode = videoImageMode;
    final AdvancedMiningVideoImageSection? section = videoSection;
    if (mode == null || section == null) return null;
    if (mode.isStill) return stillFrameMs;
    return section.subtitleStartMs ?? section.lookupFrameMs;
  }

  /// 视频选的是动图 / 片段：打了码会改出静图（对话框据此提示）。
  bool get mosaicForcesStill {
    final VideoMiningImageMode? mode = videoImageMode;
    return videoSection != null && mode != null && !mode.isStill;
  }

  /// 整组替换（打码编辑页「完成」时交回）。
  void setMosaicRegions(List<MiningMosaicRegion> regions) {
    if (locked) return;
    mosaicRegions = List<MiningMosaicRegion>.unmodifiable(regions);
    _notify();
  }

  void clearMosaic() {
    if (locked || mosaicRegions.isEmpty) return;
    mosaicRegions = const <MiningMosaicRegion>[];
    _notify();
  }

  // ───────────────────────────── 默认值 / 产出 ─────────────────────────────

  /// 打开时选中的卡组：设置里的卡组；还没选过而 Anki 已给出卡组列表时取第一个
  /// （对话框里总要显示一个确定的目标，主按钮才能写「制卡到 …」）。
  String? get _initialDeckName {
    final AdvancedMiningDeckSection? deck = deckSection;
    if (deck == null) return null;
    return deck.defaultDeckName ??
        (deck.decks.isEmpty ? null : deck.decks.first);
  }

  void _initDefaults() {
    deckName = _initialDeckName;
    setDeckAsDefault = false;
    omitAudio = false;
    audioStartDeltaMs = 0;
    audioEndDeltaMs = 0;
    _stillDeltaMs.clear();
    final AdvancedMiningVideoImageSection? video = videoSection;
    if (video != null) {
      final List<VideoMiningImageMode> modes = availableImageModes;
      _initialVideoImageMode = modes.contains(video.defaultMode)
          ? video.defaultMode
          : (modes.isEmpty ? null : modes.first);
      videoImageMode = _initialVideoImageMode;
    }
    panelModelAvailable = mangaSection?.panelModelAvailable ?? false;
  }

  /// 「恢复为一键制卡的默认」：所有选择回到打开时的值，句子上下文回到打开时的快照。
  Future<void> resetToDefaults() async {
    if (locked) return;
    unawaited(stopPreview());
    deckName = _initialDeckName;
    setDeckAsDefault = false;
    omitAudio = false;
    audioStartDeltaMs = 0;
    audioEndDeltaMs = 0;
    _stillDeltaMs.clear();
    videoImageMode = _initialVideoImageMode;
    mosaicRegions = const <MiningMosaicRegion>[];
    if (mangaSection != null && !mangaLoading) {
      cropChoice = isCropChoiceAvailable(_initialCropChoice)
          ? _initialCropChoice
          : MangaCropChoice.wholePage;
      customCropRect = cropRectFor(cropChoice) ?? kMangaWholePageRect;
    }
    prevAtMax = false;
    nextAtMax = false;
    _notify();
    if (sentenceSection != null &&
        _snapped &&
        (prev.length != _snapPrev || next.length != _snapNext)) {
      busy = true;
      try {
        await restoreSentenceSnapshot();
        await refreshSentences();
      } finally {
        busy = false;
      }
    }
    await refreshAudioWindow();
  }

  /// 把用户的选择编码成这一张卡的覆盖项。没改动的维度一律不写（null / 0 / false），
  /// 宿主按自己的设置走——这样「什么都没动直接确认」与一键「+」完全等价。
  ///
  /// 例外：漫画分区存在时**总是**带裁切（整页也带 0,0,1,1）。用户打开了取景并确认，
  /// 就是对这张图做了明确选择；宿主据此压过「一键制卡默认裁到分镜」设置，否则用户
  /// 选了「整页」却被宿主默认裁成分镜。
  MiningRequestOverrides buildOverrides() {
    final AdvancedMiningDeckSection? deck = deckSection;
    final String? chosenDeck = deck == null ? null : deckName;
    final AdvancedMiningVideoImageSection? video = videoSection;
    final AdvancedMiningMangaImageSection? manga = mangaSection;

    bool omitImage = false;
    String? modeWire;
    int? coverFrame;
    if (video != null) {
      final VideoMiningImageMode? mode = videoImageMode;
      if (mode == null) {
        omitImage = true;
      } else {
        // 与「打开时选中的方式」比，而不是直接与设置比：设置里的方式在这里不可用时
        // （例如模板不支持片段），对话框会退到别的方式——那是宿主一键制卡本来也会
        // 退到的结果，用户没动就不该写覆盖。设置里的方式可用时两者相同。
        if (mode != _initialVideoImageMode) modeWire = mode.wireName;
        if (mode.isStill && (_stillDeltaMs[mode] ?? 0) != 0) {
          coverFrame = stillFrameMs;
        }
      }
    }

    MiningImageCrop? crop;
    if (manga != null) {
      final Rect? rect = cropRect;
      final MangaCropSuggestions? s = cropSuggestions;
      if (cropChoice == MangaCropChoice.none) {
        omitImage = true;
      } else if (rect != null && s != null) {
        crop = MiningImageCrop(
          pageIndex: s.pageIndex,
          left: rect.left,
          top: rect.top,
          right: rect.right,
          bottom: rect.bottom,
        ).clamped();
      }
    }

    // 只在此刻的图片选择能打码时带上（视频切到动图 / 片段、漫画选了「不要」时已打的
    // 码不生效，对话框里有提示）。
    final List<MiningMosaicRegion> mosaic = !omitImage && mosaicApplicable
        ? mosaicRegions
        : const <MiningMosaicRegion>[];

    final bool audio = audioSection != null;
    return MiningRequestOverrides(
      deckName: chosenDeck != null && chosenDeck != deck?.defaultDeckName
          ? chosenDeck
          : null,
      omitAudio: audio && omitAudio,
      audioStartDeltaMs: audio ? audioStartDeltaMs : 0,
      audioEndDeltaMs: audio ? audioEndDeltaMs : 0,
      omitImage: omitImage,
      videoImageMode: modeWire,
      coverFrameAtMs: coverFrame,
      crop: crop,
      mosaic: mosaic,
    );
  }
}
