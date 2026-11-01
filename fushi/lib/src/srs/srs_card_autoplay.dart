/// 复习卡面音频的自动播放与重播（对齐 Anki 的「自动播放音频」/「重播时包含问题音频」）。
///
/// - 卡面上的音频就是渲染结果里的 `[sound:x]` 标记（模板里放了哪些音频字段——单词音频、
///   句子音频——就有哪些），按出现顺序**一段接一段**播放。
/// - 问题面：播问题面的全部音频。答案面：只播答案面**新出现**的音频——答案模板里的
///   `{{FrontSide}}` 会把问题面原样带过来，Anki 翻面时不重播这部分（manual：
///   「{{FrontSide}} will not automatically play any audio that was on the front side」）。
/// - 手动「重播」：问题面同上；答案面按 Anki 默认先播问题音频再播答案音频，
///   关掉「重播时包含问题音频」（Anki 的 *Skip question when replaying answer*）则只播答案音频。
/// - 换卡 / 翻面 / 离开复习页都会打断正在播的序列；用户在卡面上手动点了别的音频
///   （共用播放器被换内容），序列也就此停下，不把播放抢回来。
///
/// 纯逻辑 + 一个可注入的播放出口，widget 测试里换成假实现。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/srs/srs_card_video_channel.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsAudioSources, srsVideoSources;
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

final RegExp _soundTag = RegExp(r'\[sound:([^\]]+)\]');

String _htmlUnescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// 卡面 HTML 里的 `[sound:x]` 文件名，按出现顺序（与卡面播放按钮同一套解码）。
List<String> srsCardSoundNames(String html) => <String>[
  for (final Match m in _soundTag.allMatches(html))
    if (_htmlUnescape(m.group(1)!.trim()).isNotEmpty)
      _htmlUnescape(m.group(1)!.trim()),
];

final RegExp _inlineMediaTag = RegExp(
  r'<(audio|video)\b([^>]*)>',
  caseSensitive: false,
);
final RegExp _srcAttr = RegExp(
  r'''\ssrc\s*=\s*(["'])([^"']*)\1''',
  caseSensitive: false,
);
final RegExp _classAttr = RegExp(
  r'''\sclass\s*=\s*(["'])([^"']*)\1''',
  caseSensitive: false,
);

/// 原生卡面的媒体序列：`[sound:x]` 加制卡内嵌的 `<audio src>` / `<video src>`，按出现
/// 顺序、同名只播一次（Lapis 背面把 Picture 渲染多份）。与模板里的页内脚本同一规则：
/// 有视频片段时片段放最后（先单词音频、再片段），句子音频（`fushi-inline-audio`）不播——
/// 片段自带句子声音。整面 WebView 卡面里这些标签由页内脚本自己播，不走这里。
List<String> srsCardMediaNames(String html) {
  final List<(int, String, String)> found = <(int, String, String)>[
    for (final Match m in _soundTag.allMatches(html))
      (m.start, _htmlUnescape(m.group(1)!.trim()), 'sound'),
    for (final Match m in _inlineMediaTag.allMatches(html))
      if (_srcAttr.firstMatch(m.group(2)!) case final Match src)
        (
          m.start,
          _htmlUnescape(src.group(2)!.trim()),
          m.group(1)!.toLowerCase() == 'video'
              ? 'video'
              : (_classAttr.firstMatch(m.group(2)!)?.group(2) ?? '').contains(
                  'fushi-inline-audio',
                )
              ? 'sentence'
              : 'audio',
        ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final bool hasVideo = found.any(((int, String, String) f) => f.$3 == 'video');
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  final List<String> videos = <String>[];
  for (final (int _, String name, String kind) in found) {
    if (name.isEmpty || !seen.add(name)) continue;
    if (kind == 'video') {
      videos.add(name);
    } else if (!(hasVideo && kind == 'sentence')) {
      out.add(name);
    }
  }
  return <String>[...out, ...videos];
}

/// 按出现顺序去重（同一个文件在一面卡上只算一段）。
///
/// 模板把同一音频字段渲染多份（Lapis 背面把 `{{Picture}}` / 音频容器复制进好几处，由 CSS
/// 只显示一处）时，`[sound:x]` 在 HTML 里出现好几次——以前每次都出一颗底部重播键、自动播放
/// 把同一段连播好几遍（#15：一句例句的语法卡出了 🔊1…🔊5）。
List<String> srsDedupeMediaNames(Iterable<String> names) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String n in names)
      if (n.isNotEmpty && seen.add(n)) n,
  ];
}

/// 一面卡的媒体名：[inlineMedia]（原生卡面）走 [srsCardMediaNames]，否则只认 `[sound:]`。
/// 这里保留重复（按次数扣掉问题面带过来的那几次要靠它），选段结果再去重。
List<String> _faceNames(String html, bool inlineMedia) =>
    inlineMedia ? srsCardMediaNames(html) : srsCardSoundNames(html);

/// 答案面「新出现」的媒体（列表版）：从 [answer] 里按次数扣掉 [question] 带过来的
/// （`{{FrontSide}}` 带过来的不算），结果按出现顺序去重。
List<String> srsAnswerOnlyOf(List<String> question, List<String> answer) {
  final Map<String, int> fromQuestion = <String, int>{};
  for (final String name in question) {
    fromQuestion[name] = (fromQuestion[name] ?? 0) + 1;
  }
  final List<String> out = <String>[];
  for (final String name in answer) {
    final int left = fromQuestion[name] ?? 0;
    if (left > 0) {
      fromQuestion[name] = left - 1;
    } else {
      out.add(name);
    }
  }
  return srsDedupeMediaNames(out);
}

/// 一面卡该**自动**播的媒体（列表版，见 [srsAutoplaySounds]）。
List<String> srsAutoplayOf({
  required List<String> question,
  required List<String> answer,
  required bool answerSide,
}) => answerSide
    ? srsAnswerOnlyOf(question, answer)
    : srsDedupeMediaNames(question);

/// 手动**重播**的媒体（列表版，见 [srsReplaySounds]）。
List<String> srsReplayOf({
  required List<String> question,
  required List<String> answer,
  required bool answerSide,
  required bool includeQuestion,
}) {
  if (!answerSide) return srsDedupeMediaNames(question);
  final List<String> answerOnly = srsAnswerOnlyOf(question, answer);
  return includeQuestion
      ? srsDedupeMediaNames(<String>[...question, ...answerOnly])
      : answerOnly;
}

// ------------------------------------------------------------------ 原生 Fushi 卡面

/// 原生 Fushi 卡面上**实际画出来**的媒体（按字段，不扫整面 HTML）。
///
/// 原生卡面只画三样会出声的东西：词条旁的单词音频键（`ExpressionAudio`）、Picture 里的视频
/// 片段、例句卡里的例句音频键（`SentenceAudio`）。以前复习页按整张背面 HTML 收集媒体
/// （[srsCardMediaNames]）——释义区里词典自带的 `<audio>` / `[sound:]`、模板复制的多份
/// 容器都被算进来，于是卡面上只有一两颗发音键、底栏却出一排重播键，自动播放也把它们全播
/// 了（#15）。底栏重播键、自动播放、R 重播与卡面上的发音键现在是同一份清单。
@immutable
class SrsFushiCardMedia {
  const SrsFushiCardMedia({
    required this.front,
    required this.word,
    required this.clip,
    required this.sentence,
  });

  /// 问题面会出声的媒体（只有听力卡正面有发音键，见 `_buildFront`）。
  final List<String> front;

  /// 单词音频（`ExpressionAudio`）。
  final List<String> word;

  /// Picture 里的视频片段（第一个）；没有 = null。
  final String? clip;

  /// 例句音频（`SentenceAudio`）。
  final List<String> sentence;

  /// 片段自带例句声音：例句音频就是片段本身（视频制卡的同步片段，`SentenceAudio` 里的隐藏
  /// `<audio>` 与 `<video>` 是同一个文件），或卡上只有片段没有单独的例句音频。此时例句键
  /// 控制片段（在画面上从头播、有声），不再另起一路纯音频（#10：二者重复、叠音）。
  bool get clipCarriesSentence {
    final String? c = clip;
    return c != null && (sentence.isEmpty || sentence.contains(c));
  }

  /// 例句发音键播什么：片段带声 → 片段；否则例句音频（画面上的动图 / 静音片段经片段通道
  /// 跟着从头播，见 `SrsCardVideoChannel.setSentenceAudio`）。
  List<String> get sentenceUnit =>
      clipCarriesSentence ? <String>[clip!] : sentence;

  /// 只作「画面陪播」的例句音频（片段不带这段声音时）：播它们时画面从头播、片段静音。
  List<String> get companionSentence =>
      clipCarriesSentence ? const <String>[] : sentence;

  /// 答案面的全部媒体（顺序与卡面从上到下一致：单词 → 例句 / 片段）。片段不带例句声音
  /// 时它只陪播画面（静音），不单独进序列——否则例句音频之后片段再出一遍声。
  List<String> get back =>
      srsDedupeMediaNames(<String>[...word, ...sentenceUnit]);
}

/// 从笔记字段（按字段名）算出原生 Fushi 卡面的媒体。[audioCardFront] = 卡型是听力卡
/// （正面放一颗发音键：有例句音频播例句，否则播单词音频，与模板 `{{#SentenceAudio}}` 同义）。
SrsFushiCardMedia srsFushiCardMedia(
  Map<String, String> fields, {
  required bool audioCardFront,
}) {
  final List<String> word = srsAudioSources(fields['TermAudio'] ?? '');
  final List<String> sentence = srsAudioSources(fields['SentenceAudio'] ?? '');
  final String? clip = srsVideoSources(fields['Media'] ?? '').firstOrNull;
  final List<String> front = !audioCardFront
      ? const <String>[]
      : <String>[?(sentence.isNotEmpty ? sentence.first : word.firstOrNull)];
  return SrsFushiCardMedia(
    front: front,
    word: word,
    clip: clip,
    sentence: sentence,
  );
}

/// 答案面「新出现」的音频：从答案面音频里按次数扣掉问题面的（`{{FrontSide}}` 带过来的）。
/// [inlineMedia] 见 [srsCardMediaNames]。
List<String> srsAnswerOnlySounds({
  required String questionHtml,
  required String answerHtml,
  bool inlineMedia = false,
}) => srsAnswerOnlyOf(
  _faceNames(questionHtml, inlineMedia),
  _faceNames(answerHtml, inlineMedia),
);

/// 一面卡该**自动**播哪些音频。
List<String> srsAutoplaySounds({
  required String questionHtml,
  required String answerHtml,
  required bool answerSide,
  bool inlineMedia = false,
}) => srsAutoplayOf(
  question: _faceNames(questionHtml, inlineMedia),
  answer: answerSide ? _faceNames(answerHtml, inlineMedia) : const <String>[],
  answerSide: answerSide,
);

/// 手动**重播**该播哪些音频。[includeQuestion] = 答案面上也先播问题音频（Anki 默认）。
List<String> srsReplaySounds({
  required String questionHtml,
  required String answerHtml,
  required bool answerSide,
  required bool includeQuestion,
  bool inlineMedia = false,
}) => srsReplayOf(
  question: _faceNames(questionHtml, inlineMedia),
  answer: answerSide ? _faceNames(answerHtml, inlineMedia) : const <String>[],
  answerSide: answerSide,
  includeQuestion: includeQuestion,
);

/// 卡面音频的播放出口（测试覆写）。
///
/// 解析与开播拆成两步（BUG-3546）：解析（找媒体库、查文件）是异步的，开播必须在
/// [SrsCardAudioSequencer] 确认「这组还没被取代」之后**同步地**交给播放器——否则
/// 换卡 / 翻面 / 关自动播放时的 [stop] 先到、还在解析中的那段随后照样开播。
abstract class SrsCardAudioOutput {
  /// 媒体库里 [name] 的本地路径；找不到返回 null（序列就此停下）。
  Future<String?> resolve(String name);

  /// 播 [path] 并等它播完。true = 自然播完，可以接着播下一段；false = 没能开播 /
  /// 被别的播放或 [stop] 打断。实现必须在**返回 Future 之前**就把这次播放登记进
  /// 播放器（之后的 [stop] 必须能取消它），中间不得先 await 别的东西。
  Future<bool> playToEnd(String path);

  /// 停掉正在播的音频（包括已登记、尚未真正出声的那一段）。
  Future<void> stop();
}

/// 生产实现：从本 profile 的复习媒体库取文件，交给 app 共用的播放器。
class _DefaultSrsCardAudioOutput implements SrsCardAudioOutput {
  _DefaultSrsCardAudioOutput(this._ref);

  final Ref _ref;

  @override
  Future<String?> resolve(String name) async {
    final SrsMediaStore? store = await _ref.read(srsMediaStoreProvider.future);
    final File? file = store?.resolve(name);
    if (file == null || !await file.exists()) {
      // 自动播放不弹 toast（每张卡都弹太吵）；手动点按钮时卡面自己会提示缺文件。
      ErrorLogService.instance.logDiagnostic(
        'SrsCardAudio.resolve',
        'media missing: $name',
      );
      return null;
    }
    return file.path;
  }

  /// 卡面上挂着同名视频片段（`SrsCardVideoClip`，见 [SrsCardVideoChannel]）时交给它在画面里播，否则走共用音频播放器。
  /// 片段可能还没挂上（翻面后同步起的序列先于片段那一帧构建）：通道等这轮构建跑完再决定，
  /// 不先退回只播音频（否则画面停在首帧、声音由后台播放器单独放）。
  /// 每条路都在第一个 await 之前就登记了这次播放（片段通道同步登记 / 登记等待；
  /// [DesktopAudioPlayback.playFileToEnd] 先记激活代号再排队），随后的 [stop] 能取消它。
  @override
  Future<bool> playToEnd(String path) => _ref
      .read(srsCardVideoChannelProvider)
      .playToEndOrElse(
        p.basename(path),
        () => DesktopAudioPlayback.playFileToEnd(
          path,
          volume: _ref.read(srsReviewVolumeProvider),
        ),
        // 走片段时停掉共用播放器里还在响的上一段（同一时刻只出一路声音，#10）。
        stopAudio: DesktopAudioPlayback.stop,
      );

  @override
  Future<void> stop() async {
    await _ref.read(srsCardVideoChannelProvider).stopAll();
    await DesktopAudioPlayback.stop();
  }
}

final Provider<SrsCardAudioOutput> srsCardAudioOutputProvider =
    Provider<SrsCardAudioOutput>(srsDefaultCardAudioOutput);

/// 生产实现：经 [ref] 所在容器的 `srsMediaStoreProvider` 取文件。远程刷卡在子作用域里覆盖了媒体库，
/// 要在同一个子作用域里用它再覆盖 [srsCardAudioOutputProvider]，否则读到的还是根容器的媒体库。
SrsCardAudioOutput srsDefaultCardAudioOutput(Ref ref) =>
    _DefaultSrsCardAudioOutput(ref);

/// 一段一段播一组音频；新的 [play] / [cancel] 打断上一组。
class SrsCardAudioSequencer {
  SrsCardAudioSequencer(this._output);

  final SrsCardAudioOutput _output;

  /// 当前序列的代号；每次 [play] / [cancel] 自增，旧序列据此知道自己被取代了。
  int _generation = 0;
  bool _playing = false;

  /// 此刻是否有序列在播。
  @visibleForTesting
  bool get isPlaying => _playing;

  /// 依次播放 [names]（空 = 什么都不做，但仍打断上一组）。
  Future<void> play(List<String> names) async {
    final int generation = ++_generation;
    if (names.isEmpty) {
      await _stopIfPlaying();
      return;
    }
    _playing = true;
    try {
      for (final String name in names) {
        if (generation != _generation) return;
        final String? path = await _output.resolve(name);
        // 解析期间被取代（换卡 / 翻面 / 关了自动播放 / 离开复习页）：不再开播。
        // 这一步必须紧挨着开播、中间没有 await，否则 cancel 的 stop 先到、
        // 这段随后照样出声（BUG-3546）。
        if (generation != _generation) return;
        // 媒体库里没有这段（字段引用了没随卡导入的文件）：跳过它接着播后面的，
        // 不让一段缺失的音频把整组都吞掉（#15）。
        if (path == null) continue;
        final bool finished = await _output.playToEnd(path);
        if (!finished) break;
      }
    } finally {
      if (generation == _generation) _playing = false;
    }
  }

  /// 打断当前序列并停掉它在播的音频（没有序列在播时不碰播放器，不误停别处的音频）。
  Future<void> cancel() async {
    _generation++;
    await _stopIfPlaying();
  }

  Future<void> _stopIfPlaying() async {
    if (!_playing) return;
    _playing = false;
    await _output.stop();
  }
}

// ------------------------------------------------------------------ 页内媒体闸门

/// 卡面外壳里的「自动播放」闸门（BUG-3546）：牌组关了自动播放时，卡面页面**自己**
/// 发起的播放一律拒绝，只放行用户在卡面上的点按 / 按键直接引起的播放。
///
/// 为什么需要：`[sound:]` 由宿主（[SrsCardAudioSequencer]）按牌组开关自动播，但卡面
/// HTML 里还有页面自己出声的媒体——视频制卡的同步片段（`anki_note_composer.dart` 的
/// `inlineVideoCoverHtml` / `inlineVideoWordAudioHtml` / `inlineVideoSentenceAudioHtml`：
/// `oncanplay` 里 `play()`）、模板 / 字段里带 `autoplay` 属性的 `<audio>` / `<video>`。
/// 它们约定由宿主在「关了自动播放」时拒绝无手势播放（Anki 的做法：关自动播放 =
/// 恢复「播放需要用户手势」，`play()` 以 `NotAllowedError` 失败，片段脚本静默让出）。
/// 卡面 WebView 原先不看牌组开关：Windows（WebView2）照样自动出声，Android / iOS
/// 默认要手势、开着自动播放也不出声——于是「关了还会播，而且时播时不播」。
///
/// 机制（关闭时，页面能让媒体出声的入口逐个收口；任一入口漏掉 = 照样出声）：
/// - 「用户手势」：window 捕获阶段看到可信（`isTrusted`）的点按 / 按键事件即置位，
///   `setTimeout(0)` 在这次派发全部结束后复位——同一次点按里卡片脚本转手
///   `replay.click()`（Lapis「点例句重播」）照样放行，之后的 `canplay` / `ended` /
///   定时器都不算手势。原生播放控件的点按 / 按键由控件内部消化、页面监听看不到，
///   改认「元素带 `controls` + 此刻有瞬时用户激活（`navigator.userActivation`）」。
/// - `play()`：包一层 `HTMLMediaElement.prototype.play`，手势外的调用直接返回以
///   `NotAllowedError` 拒绝的 Promise（与浏览器自动播放策略同一形态，现有片段脚本的
///   `catch` 照常吞掉）。
/// - `autoplay`：不经 `play()`，插入后再设也照样生效（BUG-3546 第一版只看
///   childList，`el.autoplay = true` / `setAttribute('autoplay')` / 不进文档的
///   `new Audio()` 都绕过去了）。手势外把 `autoplay` 属性 setter 与
///   `setAttribute` / `setAttributeNS` / `toggleAttribute` 写 `autoplay` 一律吞掉（覆盖
///   脱离文档的元素）；新插入节点（换卡 innerHTML、解析出来的 `autoplay` 属性）由
///   MutationObserver 摘掉，关闭那一刻也扫一遍现有内容。
/// - 兜底：文档与每个 shadow root（包 `attachShadow`，`play` 事件不穿出 shadow 边界）
///   上捕获 `play` 事件，不在手势里、不是手势里 `play()` 放行过的元素、也不是用户点
///   原生控件的开播，当场 `pause()`——不管它从哪条路来（例如 iframe 里另一套原型的
///   `play.call(el)`）。脱离文档的元素没有事件可接，靠上面的 `play()` / `autoplay`
///   收口；卡片里嵌的 iframe 自己的文档不在闸门内。
/// - 宿主自己的 `[sound:]` 序列与重播走原生播放器（[SrsCardAudioSequencer]），不经
///   页面媒体元素，不受闸门影响。
/// - 开关由宿主经 `window.__fushiSrsSetAutoplay(bool)` 下发（换卡调用之前）。
const String kSrsCardAutoplayGateScript = r'''
(function(){
  if (window.__fushiSrsSetAutoplay) return;
  var allowed = true;
  var gesture = false;
  var clearTimer = null;
  var permitted = typeof WeakSet === 'function' ? new WeakSet() : null;
  function isMedia(n){
    return !!n && n.nodeType === 1 && (n.tagName === 'AUDIO' || n.tagName === 'VIDEO');
  }
  function blocked(){ return !allowed && !gesture; }
  // 卡面 `[sound:]` 播放按钮的点击委托（srs_card_media.dart）据此拒绝模板脚本在手势外
  // 合成的 `.click()`（#15：关了自动播放，模板脚本照样把一排音频按钮挨个点响）。
  window.__fushiSrsMediaBlocked = blocked;
  function permit(el){ if (permitted && isMedia(el)) permitted.add(el); }
  var kinds = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click',
    'dblclick', 'auxclick', 'touchstart', 'touchend', 'keydown', 'keyup'];
  function onGesture(e){
    if (!e || e.isTrusted !== true) return;
    gesture = true;
    if (clearTimer !== null) clearTimeout(clearTimer);
    clearTimer = setTimeout(function(){ gesture = false; clearTimer = null; }, 0);
  }
  for (var i = 0; i < kinds.length; i++) {
    window.addEventListener(kinds[i], onGesture, true);
  }
  function refusal(){
    var msg = 'Autoplay is turned off for this deck';
    try { return new DOMException(msg, 'NotAllowedError'); }
    catch (e) { var err = new Error(msg); err.name = 'NotAllowedError'; return err; }
  }
  // 页面里开过播的媒体（含不进文档的 `new Audio()`、shadow root 里的）：换卡 / 翻面时由
  // `__fushiSrsStopAllMedia` 一起停掉。换内容只能停到文档里那棵卡面根下的元素，脱离文档
  // 的那些会接着响到播完（N-JACNGS-K：换卡后上一张的音频不停）。
  var sounding = typeof Set === 'function' ? new Set() : null;
  function track(el){ if (sounding && isMedia(el)) sounding.add(el); }
  var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
  if (proto && typeof proto.play === 'function') {
    var nativePlay = proto.play;
    proto.play = function(){
      if (blocked()) return Promise.reject(refusal());
      permit(this);
      track(this);
      return nativePlay.apply(this, arguments);
    };
  }
  window.__fushiSrsStopAllMedia = function(){
    if (!sounding) return;
    sounding.forEach(function(el){ try { el.pause(); } catch (e) {} });
    sounding.clear();
  };
  var autoplayProp = proto && Object.getOwnPropertyDescriptor(proto, 'autoplay');
  if (autoplayProp && autoplayProp.set && autoplayProp.configurable) {
    Object.defineProperty(proto, 'autoplay', {
      configurable: true,
      enumerable: autoplayProp.enumerable,
      get: autoplayProp.get,
      set: function(v){ autoplayProp.set.call(this, blocked() ? false : v); }
    });
  }
  function isAutoplayName(n){
    return typeof n === 'string' && n.toLowerCase().replace(/^.*:/, '') === 'autoplay';
  }
  var elementProto = window.Element && window.Element.prototype;
  function guardAttr(method, nameAt){
    var native = elementProto && elementProto[method];
    if (typeof native !== 'function') return;
    elementProto[method] = function(){
      if (blocked() && isMedia(this) && isAutoplayName(arguments[nameAt])) {
        if (method !== 'toggleAttribute') return undefined;
        // toggleAttribute 只放行「摘掉」。
        if (arguments.length > 1 && arguments[1] !== false) return false;
        if (!this.hasAttribute('autoplay')) return false;
      }
      return native.apply(this, arguments);
    };
  }
  guardAttr('setAttribute', 0);
  guardAttr('setAttributeNS', 1);
  guardAttr('toggleAttribute', 0);
  function unset(el){
    el.removeAttribute('autoplay');
    try { el.autoplay = false; } catch (e) {}
  }
  function strip(node){
    if (!node || node.nodeType !== 1) return;
    if (isMedia(node) && node.hasAttribute('autoplay')) unset(node);
    if (typeof node.querySelectorAll !== 'function') return;
    var list = node.querySelectorAll('audio[autoplay],video[autoplay]');
    for (var j = 0; j < list.length; j++) unset(list[j]);
  }
  var observer = null;
  var observeOpts = { childList: true, subtree: true };
  if (window.MutationObserver) {
    observer = new MutationObserver(function(records){
      if (allowed) return;
      for (var r = 0; r < records.length; r++) {
        var added = records[r].addedNodes || [];
        for (var k = 0; k < added.length; k++) strip(added[k]);
      }
    });
    if (document.documentElement) observer.observe(document.documentElement, observeOpts);
  }
  // 原生播放控件：点按 / 按键由控件内部消化，页面的捕获监听一个也看不到（Chromium
  // 实测），只剩「元素带控件 + 此刻有瞬时用户激活」可认。
  function nativeControlsByUser(el){
    var ua = window.navigator && window.navigator.userActivation;
    return !!el.controls && !!ua && ua.isActive === true;
  }
  function onPlay(e){
    var el = e && e.target;
    if (!isMedia(el)) return;
    if (!blocked() || (permitted && permitted.has(el)) || nativeControlsByUser(el)) {
      track(el);
      return;
    }
    try { el.pause(); } catch (err) {}
  }
  function onStop(e){
    if (!e || !isMedia(e.target)) return;
    if (permitted) permitted['delete'](e.target);
    if (sounding) sounding['delete'](e.target);
  }
  function watchRoot(root){
    if (!root || typeof root.addEventListener !== 'function') return;
    root.addEventListener('play', onPlay, true);
    root.addEventListener('pause', onStop, true);
    root.addEventListener('emptied', onStop, true);
  }
  watchRoot(document);
  if (elementProto && typeof elementProto.attachShadow === 'function') {
    var nativeAttachShadow = elementProto.attachShadow;
    elementProto.attachShadow = function(){
      var root = nativeAttachShadow.apply(this, arguments);
      watchRoot(root);
      if (observer) observer.observe(root, observeOpts);
      return root;
    };
  }
  window.__fushiSrsSetAutoplay = function(on){
    allowed = on !== false;
    if (!allowed) strip(document.body || document.documentElement);
  };
})();
''';

/// 下发自动播放开关的调用（见 [kSrsCardAutoplayGateScript]）。
String srsCardSetAutoplayScript({required bool autoplay}) =>
    'if(window.__fushiSrsSetAutoplay)window.__fushiSrsSetAutoplay($autoplay);';
