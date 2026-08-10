// KiriKiri 游戏内查词 — Dart 编排层（仅 Windows）。
//
// 见 docs/specs/2026-08-10-kirikiri-ingame-lookup-plan.md。三段职责里 Dart 只占中间
// 一小段，而且**位图永远不经过这里**：
//
//   注入进游戏的 hook（几何传感 / 命中测试 / 输入转发）
//        │ onGalLookupHit(整行台词, 字符下标, 字形矩形, 视口尺寸)
//        ▼
//   本控制器 ── 走 app 既有查词链（GlobalLookupController.lookupText →
//        │       AppModel.searchDictionary → 离屏 WebView2 popup.html）
//        │ galLookupPresent(seq, anchor, highlight)
//        ▼
//   runner（取帧）→ 共享内存 → hook memcpy 进游戏 Layer
//
// 本文件里**一行查词逻辑都没有**：不分词、不筛词典、不定 maximumTerms、不排版。
// 词条从哪来、去屈折怎么做、卡片长什么样，全部与阅读器 / 视频 / 剪贴板查词同一份
// 实现；这里只回答三个问题——查哪个串、卡片放哪、高亮哪一段。
//
// 坐标域纪律：hook 报上来的 glyph/view 尺寸在**游戏 primaryLayer 像素**域，卡片位图
// 是逐像素 memcpy 进 Layer 的，所以「卡片在游戏里的尺寸」== 位图的**物理像素**尺寸
// （GlobalLookupController.onRevealed 回报的就是它）。两者同域可直接比较，全程不乘
// dpr——dpr 只属于 Windows 窗口那一侧。

import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/lookup/global_lookup_layout.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

/// 偏好读取口。与 `GalHookPreferenceReader` 同形——独立声明只为不让台词浮窗控制器与
/// 本控制器互相 import 成环，语义完全一致（key + 默认值，测试可注入替身）。
typedef GalIngameLookupPreferenceReader = Object? Function(
  String key, {
  required Object? defaultValue,
});

/// 按台词文本回溯本局会话里的行，给出该行的 gal 制卡 handler（截图 + 语音 + 标签）。
///
/// 制卡链本身在 [GalHookTextOverlayController] 里（`_mineFromLookup`）——它持有
/// mining coordinator、Anki repo 与全部制卡偏好。这里只要一个「这句话对应哪一行」
/// 的解析口，绝不复制那条链。找不到对应行返回 null（卡照样能建，只是没有 gal 媒体）。
typedef GalIngameMiningResolver = OverlayMiningHandler? Function(String line);

/// 游戏内查词编排器（进程级单例）。
class GalIngameLookupController {
  GalIngameLookupController._({
    GalIngameLookupPreferenceReader? preferenceReader,
  }) : _preferenceReader = preferenceReader;

  static final GalIngameLookupController instance =
      GalIngameLookupController._();

  @visibleForTesting
  GalIngameLookupController.test({
    GalIngameLookupPreferenceReader? preferenceReader,
  }) : this._(preferenceReader: preferenceReader);

  /// 「游戏内查词」开关的持久化 key（与其余 gal hook 偏好同一命名族）。
  static const String enabledPreferenceKey = 'gal_hook_ingame_lookup_enabled';

  GalIngameLookupPreferenceReader? _preferenceReader;

  AppModel? _appModel;
  GalIngameMiningResolver? _miningResolver;
  bool _started = false;

  /// galgame 会话是否在跑（由台词浮窗控制器的会话同步喂进来，不另起第二个监听）。
  bool _sessionActive = false;

  /// 已推给 runner 的开关值，避免每轮会话同步都发一次 channel 调用。
  bool _pushedEnabled = false;

  /// 当前屏上这张卡对应的命中。null = 游戏里没有卡（此时 onRevealed 的回调属于普通
  /// 桌面查词，不该投进游戏）。
  GalLookupHit? _activeHit;

  /// latest-wins 待处理命中：查词在途时又点了新字，只留最后一个（连点不排队）。
  GalLookupHit? _pendingHit;
  bool _draining = false;

  /// 最近一次已投出的高亮范围，用于悬停去抖——鼠标在同一个字上抖动不该反复过桥。
  int _presentedHighlightStart = -1;
  int _presentedHighlightLen = -1;

  /// 最近一次已投出的卡片落点（primaryLayer px）。悬停只换高亮、不换卡片，必须把
  /// 同一个 anchor 原样回传，否则卡片会跟着鼠标乱跑。null = 屏上没有卡片。
  int? _presentedAnchorX;
  int? _presentedAnchorY;

  /// 平台门：galgame hook 只做 Windows，且必须有覆盖窗（卡片像素的唯一来源）。
  static bool get isSupported =>
      GalHookTextOverlayChannel.supportsCurrentPlatform &&
      GlobalLookupController.isSupported;

  @visibleForTesting
  bool get debugSessionActive => _sessionActive;

  @visibleForTesting
  bool get debugPushedEnabled => _pushedEnabled;

  @visibleForTesting
  GalLookupHit? get debugActiveHit => _activeHit;

  /// 接线。幂等；非 Windows 上直接空转（不是崩）。
  ///
  /// [miningResolver] 由台词浮窗控制器提供，见 [GalIngameMiningResolver]。
  /// [preferenceReader] 同样由它透传（测试替身；生产为 null 时读 [AppModel]）。
  ///
  /// 重复调用只刷新依赖、不重复挂回调链——覆盖窗的两个回调是单消费者字段，挂两遍
  /// 会让同一次 reveal 投两帧。
  Future<void> start({
    required AppModel appModel,
    GalIngameMiningResolver? miningResolver,
    GalIngameLookupPreferenceReader? preferenceReader,
  }) async {
    if (!isSupported) return;
    _appModel = appModel;
    _miningResolver = miningResolver;
    _preferenceReader = preferenceReader ?? _preferenceReader;
    if (_started) return;
    _started = true;
    final GlobalLookupController overlay = GlobalLookupController.instance;
    // 「卡片内容已渲染、尺寸已定」是投帧的唯一前置条件，真值只有覆盖窗知道。
    // 链上既有消费者（今天为空）：本控制器接管这两个单消费者回调时不吞掉别人。
    final void Function(int, int)? previousRevealed = overlay.onRevealed;
    overlay.onRevealed = (int w, int h) {
      previousRevealed?.call(w, h);
      _onOverlayRevealed(w, h);
    };
    final void Function()? previousHidden = overlay.onHidden;
    overlay.onHidden = () {
      previousHidden?.call();
      unawaited(_onOverlayHidden());
    };
  }

  @visibleForTesting
  Future<void> stopForTesting() async {
    _started = false;
    _sessionActive = false;
    _pushedEnabled = false;
    _activeHit = null;
    _pendingHit = null;
    _draining = false;
    _presentedHighlightStart = -1;
    _presentedHighlightLen = -1;
    _presentedAnchorX = null;
    _presentedAnchorY = null;
  }

  /// galgame 会话开始 / 结束。会话不在跑时游戏内查词必须彻底关掉——hook 侧
  /// `lookup_enabled=0` 即零写入，不留半开状态。
  Future<void> setSessionActive(bool active) async {
    if (_sessionActive == active) return;
    _sessionActive = active;
    await _syncEnabled();
  }

  /// 设置页改完开关后调用，与 `applyHoverAutoLookupFromPreferences` 同款纪律：
  /// 漏掉这一步，开关只落了盘，本局游戏里不生效。
  Future<void> applyEnabledFromPreferences() async {
    if (!_started) return;
    await _syncEnabled();
  }

  /// 换行 / 换页：屏上那句话已经不在了，卡片必须跟着消场，否则卡片还挂在旧句子的
  /// 字形位置上。由台词浮窗控制器在「显示行变了」那一刻调。
  Future<void> onLineChanged() async {
    await _dismissCurrent();
  }

  /// hook 报上来一次命中。
  ///
  /// [GalLookupHit.submit] 分流：
  ///  - false（悬停）：**不查词**，只把高亮挪到光标那个字。悬停事件是鼠标移动的
  ///    频率，每次都查词会把引擎和离屏 WebView2 一起打爆。
  ///  - true（点击 / hook 侧判定的悬停即查词）：走完整查词链。
  ///
  /// 「悬停要不要自动查词」由 hook 侧决定并体现在 submit 上，Dart 不再解释一遍——
  /// 两处各判一次必然漂。
  Future<void> handleHit(GalLookupHit hit) async {
    if (!_started || !_enabledNow) return;
    if (!hit.submit) {
      await _updateHoverHighlight(hit);
      return;
    }
    // latest-wins：在途查词不打断，但只保留最后一次意图。
    _pendingHit = hit;
    if (_draining) return;
    _draining = true;
    try {
      while (_pendingHit != null) {
        final GalLookupHit next = _pendingHit!;
        _pendingHit = null;
        await _runLookup(next);
      }
    } finally {
      _draining = false;
    }
  }

  /// hook 转发的卡片内输入：原样丢回 runner 的既有 popup 输入注入口。
  ///
  /// 这里**故意不解释语义**（不判断点到哪个词条、要不要翻页、滚多少行）——那是
  /// popup.js 与 WebView2 的事，Dart 插一脚只会造出第二套解释规则。
  Future<void> handleInput(GalLookupInput input) async {
    if (!_started || !_enabledNow) return;
    if (_activeHit == null) return; // 游戏里没有卡，输入无处可去。
    final GalLookupCallResult result =
        await GalHookTextOverlayChannel.galLookupInput(input);
    if (!result.ok) {
      glog('gal-ingame: input kind=${input.kind} FAILED ${result.error}');
    }
  }

  // ── 内部 ──────────────────────────────────────────────────────────────────

  bool get _enabledNow => _sessionActive && _readEnabledPreference();

  bool _readEnabledPreference() {
    final GalIngameLookupPreferenceReader? reader = _preferenceReader;
    if (reader != null) {
      return reader(
            enabledPreferenceKey,
            defaultValue: PreferencesRepository.galIngameLookupEnabledDefault,
          ) ==
          true;
    }
    final AppModel? model = _appModel;
    if (model == null) return false;
    // best-effort：App 尚未初始化完时 prefsRepo 是 late 字段，读它会抛
    // （与 GlobalLookupController._recordLookupCount 同款兜底）。读不到就按默认
    // 「关」处理——绝不因为读偏好失败把 galgame 会话本身带崩。
    try {
      return model.galIngameLookupEnabled;
    } catch (_) {
      return PreferencesRepository.galIngameLookupEnabledDefault;
    }
  }

  Future<void> _syncEnabled() async {
    final bool desired = _enabledNow;
    if (desired == _pushedEnabled) return;
    _pushedEnabled = desired;
    final GalLookupCallResult result =
        await GalHookTextOverlayChannel.galLookupSetEnabled(desired);
    glog('gal-ingame: setEnabled=$desired session=$_sessionActive '
        '-> ${result.error ?? "ok"}');
    if (!desired) await _dismissCurrent();
  }

  /// 悬停：只挪高亮，不查词。
  ///
  /// 悬停拿不到引擎的 `bestLength`（那要真查一次），所以只标光标那**一个字素簇**；
  /// 用户真点下去（submit）才铺成整词跨度。范围没变就整条丢弃，鼠标在同一个字上
  /// 抖动不过桥。
  Future<void> _updateHoverHighlight(GalLookupHit hit) async {
    final int len = _graphemeLengthAt(hit.line, hit.charIndex);
    if (len <= 0) return;
    if (hit.charIndex == _presentedHighlightStart &&
        len == _presentedHighlightLen) {
      return;
    }
    _presentedHighlightStart = hit.charIndex;
    _presentedHighlightLen = len;
    // 悬停没有新位图：anchor 沿用当前卡片的落点（没有卡时用字形下方兜底）。
    // runner 的 present 会重取一次当前 popup 画面，所以这条路径不能没有去抖——
    // 上面的「范围没变就丢弃」正是它，一次鼠标划过整行也只走过字数那么多次。
    final ({int x, int y}) anchor = _resolveAnchorForCurrentCard(hit);
    final GalLookupCallResult result =
        await GalHookTextOverlayChannel.galLookupPresent(
      seq: hit.seq,
      anchorX: anchor.x,
      anchorY: anchor.y,
      highlightStart: hit.charIndex,
      highlightLen: len,
    );
    if (!result.ok) {
      glog('gal-ingame: hover present seq=${hit.seq} FAILED ${result.error}');
    }
  }

  /// 真查词：把「从命中字起的一段」交给 app 既有查词链。
  ///
  /// 查询串用共享的 [lookupQueryFromIndex]（与 texthooker 逐字查词同一份）：引擎按
  /// 查询串做最长匹配并回报 `bestLength`，所以点「永」命中「永遠」、点「遠」能单独
  /// 查到「遠」。整行原样当作 `sentence`（制卡 `{sentence}` 与卡片句子横幅都用它）
  /// ——与台词浮窗点词（`_onLookupText`）逐字同形，hook 侧也正是为此不截断整行。
  Future<void> _runLookup(GalLookupHit hit) async {
    final String query = lookupQueryFromIndex(hit.line, hit.charIndex);
    if (query.isEmpty) {
      await _dismissCurrent();
      return;
    }
    if (!hit.hasConsistentCharCount) {
      // 不丢弃（下标本身已经过范围校验），但必须留痕：这是「两侧字符计数单位漂了」
      // 的唯一早期信号，静默下去只会表现成「高亮总是偏几个字」。
      glog('gal-ingame: charCount mismatch seq=${hit.seq} '
          'reported=${hit.charCount} actual=${hit.line.length}');
    }
    // 先记住这次命中：卡片渲染完成的回调（onRevealed）要靠它算 anchor 与高亮。
    _activeHit = hit;
    _presentedHighlightStart = -1;
    _presentedHighlightLen = -1;
    // 新一次查词的落点要等新卡片量出尺寸才知道，旧落点作废（否则中间到达的悬停会
    // 把上一张卡的位置又投一遍）。
    _presentedAnchorX = null;
    _presentedAnchorY = null;
    glog('gal-ingame: lookup seq=${hit.seq} idx=${hit.charIndex} '
        'query="$query"');
    final bool taken = await GlobalLookupController.instance.lookupText(
      query,
      sentence: hit.line,
      // 不传 anchorScreenRect：卡片落点在**游戏 Layer 坐标**里，与 Windows 屏幕坐标
      // 无关，由 galLookupPresent 的 anchor 决定。覆盖窗自身照旧离屏渲染出帧。
      miningHandler: _miningResolver?.call(hit.line),
    );
    if (!taken) {
      glog('gal-ingame: overlay refused lookup seq=${hit.seq}');
      _activeHit = null;
      await _dismissCurrent();
    }
  }

  /// 覆盖窗回报「卡片已渲染、尺寸已定」（物理 px）→ 投帧。
  ///
  /// 首帧 reveal 与后续 resize（卡内点词压出子卡 / Ctrl+滚轮改字号）都会走到这里，
  /// 所以游戏里的卡片会跟着内容重新定位，而不是停在首帧几何上。
  void _onOverlayRevealed(int physicalWidth, int physicalHeight) {
    final GalLookupHit? hit = _activeHit;
    // 没有在途的游戏内命中 = 这次 reveal 属于普通桌面查词（热键 / 剪贴板），不投。
    if (hit == null || !_enabledNow) return;
    if (physicalWidth <= 0 || physicalHeight <= 0) return;
    final int start = hit.charIndex;
    final int len = _highlightLength(hit);
    final ({int x, int y}) anchor =
        _resolveAnchor(hit, physicalWidth, physicalHeight);
    _presentedHighlightStart = start;
    _presentedHighlightLen = len;
    _presentedAnchorX = anchor.x;
    _presentedAnchorY = anchor.y;
    glog('gal-ingame: present seq=${hit.seq} anchor=(${anchor.x},${anchor.y}) '
        'card=${physicalWidth}x$physicalHeight hl=$start+$len');
    unawaited(_present(hit, anchor, start, len));
  }

  /// 投帧并把 runner 的应答记下来。
  ///
  /// runner 不抛异常，失败编码成 `{error: token}`（旧 helper 无 v14 查词区 / 开关没
  /// 开 / 取帧失败 / 卡片超预算被裁）。这里**不吞**：吞掉就等于把「ready」当成
  /// 「投出去了」，正是阶段证据门禁止的那种推断。
  Future<void> _present(
    GalLookupHit hit,
    ({int x, int y}) anchor,
    int highlightStart,
    int highlightLen,
  ) async {
    final GalLookupCallResult result =
        await GalHookTextOverlayChannel.galLookupPresent(
      seq: hit.seq,
      anchorX: anchor.x,
      anchorY: anchor.y,
      highlightStart: highlightStart,
      highlightLen: highlightLen,
    );
    if (!result.ok) {
      glog('gal-ingame: present seq=${hit.seq} FAILED ${result.error}');
      return;
    }
    if (result.clamped) {
      // 卡片比游戏画面/字节预算还大，投进去的是被切过的图。处置在用户手上（把
      // 弹窗最大宽高调小），这里先如实记账，不假装成功。
      glog('gal-ingame: present seq=${hit.seq} CLAMPED to '
          '${result.width}x${result.height}');
    }
  }

  /// 覆盖窗被真正关掉（点外 / Esc / 前台钩子）→ 游戏里的卡片跟着消场。
  Future<void> _onOverlayHidden() async {
    await _dismissCurrent();
  }

  Future<void> _dismissCurrent() async {
    final GalLookupHit? hit = _activeHit;
    _activeHit = null;
    _pendingHit = null;
    _presentedHighlightStart = -1;
    _presentedHighlightLen = -1;
    _presentedAnchorX = null;
    _presentedAnchorY = null;
    if (hit == null) return;
    final GalLookupCallResult result =
        await GalHookTextOverlayChannel.galLookupDismiss(hit.seq);
    glog('gal-ingame: dismiss seq=${hit.seq} -> ${result.error ?? "ok"}');
  }

  /// 命中高亮跨度（UTF-16）= 引擎匹配长度 `bestLength`，钳进行尾。
  ///
  /// 与弹窗内高亮、剪贴板面板横幅高亮同一真值口径；引擎没给（无结果）时退回光标那
  /// 一个字素簇，绝不给 0 —— 0 会让游戏里「点了没反应」。
  int _highlightLength(GalLookupHit hit) {
    final int best = GlobalLookupController.instance.rootBestLength;
    final int remaining = hit.line.length - hit.charIndex;
    if (best <= 0) return _graphemeLengthAt(hit.line, hit.charIndex);
    return best > remaining ? remaining : best;
  }

  /// 卡片左上角（primaryLayer px）。
  ///
  /// 复用覆盖窗自己的级联定位纯函数 [computeFrameRect]：卡片放在被点字形的下方，
  /// 下方空间不够就翻到上方（这就是「避让字幕」——字形矩形本身即台词所在的那一行），
  /// 中心 X 取字形中心并 clamp 进视口。**不另写一套定位**。
  ///
  /// 之后再夹一次 `[0, view - card]`：[computeFrameRect] 在空间不足时会把**它算出来
  /// 的**宽高收缩，而我们要投的位图尺寸是固定的（收缩不了），所以卡片比视口还大的
  /// 退化情形要显式贴边，否则右/下会溢出到视口外被裁掉。
  /// 测试入口：定位算法必须被**直接**测到，不许在测试里转写一份。
  ///
  /// 这条不是洁癖。本次改造里 replay 的判据就是「参照实现」，生产代码的收卡判据改完
  /// 之后它照样绿——那种绿只证明参照实现自洽。定位算法同理：转写一份就等于把 bug
  /// 复制两遍，然后互相验证说没问题。
  @visibleForTesting
  ({int x, int y}) debugResolveAnchor(GalLookupHit hit, int cardW, int cardH) =>
      _resolveAnchor(hit, cardW, cardH);

  ({int x, int y}) _resolveAnchor(GalLookupHit hit, int cardW, int cardH) {
    if (hit.viewW <= 0 || hit.viewH <= 0) {
      // hook 没报视口（老 hook / 取不到 primaryLayer 尺寸）：退化成「字形正下方」，
      // 不猜屏幕边界。
      return (x: hit.glyphX, y: hit.glyphY + hit.glyphH + _kCardGap);
    }
    final GlobalLookupFrameRect frame = computeFrameRect(
      selectionRect: hit.glyphRect,
      screenW: hit.viewW.toDouble(),
      screenH: hit.viewH.toDouble(),
      maxWidth: cardW.toDouble(),
      maxHeight: cardH.toDouble(),
      // 本样本（KiriKiri + textrender.dll）是横排；竖排排期在 P1 之后，届时由
      // profile 给出真值再传进来，不在这里猜。
      isVertical: false,
    );
    return (
      x: _clampInt(frame.left.round(), 0, hit.viewW - cardW),
      y: _clampInt(frame.top.round(), 0, hit.viewH - cardH),
    );
  }

  /// 悬停时没有新位图，也就没有权威的卡片尺寸：卡片还在屏上就把**它现在的**落点
  /// 原样回传（换成悬停字形下方会让卡片跟着鼠标跑），没有卡片时才给字形下方兜底。
  ({int x, int y}) _resolveAnchorForCurrentCard(GalLookupHit hit) {
    final int? x = _presentedAnchorX;
    final int? y = _presentedAnchorY;
    if (x != null && y != null) return (x: x, y: y);
    return (x: hit.glyphX, y: hit.glyphY + hit.glyphH + _kCardGap);
  }

  /// [index] 处**字素簇**的 UTF-16 长度（绝不劈开代理对 / 浊点 / 组合字，与
  /// texthooker 逐字命中同一粒度）。越界返回 0。
  static int _graphemeLengthAt(String text, int index) {
    if (index < 0 || index >= text.length) return 0;
    int offset = 0;
    for (final String grapheme in text.characters) {
      if (offset == index) return grapheme.length;
      if (offset > index) break;
      offset += grapheme.length;
    }
    // 下标落在某个字素簇中间（脏数据）：按一个 code unit 处理，不抛。
    return 1;
  }

  static int _clampInt(int value, int min, int max) {
    if (max < min) return min;
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}

/// 卡片与被点字形之间的间距（primaryLayer px）。与覆盖窗 `computeFrameRect` 的
/// `popupPadding` 同量级，仅用于「hook 没报视口」的退化分支。
const int _kCardGap = 4;
