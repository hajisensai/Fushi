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

/// 答案面「新出现」的音频：从答案面音频里按次数扣掉问题面的（`{{FrontSide}}` 带过来的）。
List<String> srsAnswerOnlySounds({
  required String questionHtml,
  required String answerHtml,
}) {
  final Map<String, int> fromQuestion = <String, int>{};
  for (final String name in srsCardSoundNames(questionHtml)) {
    fromQuestion[name] = (fromQuestion[name] ?? 0) + 1;
  }
  final List<String> out = <String>[];
  for (final String name in srsCardSoundNames(answerHtml)) {
    final int left = fromQuestion[name] ?? 0;
    if (left > 0) {
      fromQuestion[name] = left - 1;
    } else {
      out.add(name);
    }
  }
  return out;
}

/// 一面卡该**自动**播哪些音频。
List<String> srsAutoplaySounds({
  required String questionHtml,
  required String answerHtml,
  required bool answerSide,
}) => answerSide
    ? srsAnswerOnlySounds(questionHtml: questionHtml, answerHtml: answerHtml)
    : srsCardSoundNames(questionHtml);

/// 手动**重播**该播哪些音频。[includeQuestion] = 答案面上也先播问题音频（Anki 默认）。
List<String> srsReplaySounds({
  required String questionHtml,
  required String answerHtml,
  required bool answerSide,
  required bool includeQuestion,
}) {
  if (!answerSide) return srsCardSoundNames(questionHtml);
  final List<String> answerOnly = srsAnswerOnlySounds(
    questionHtml: questionHtml,
    answerHtml: answerHtml,
  );
  return includeQuestion
      ? <String>[...srsCardSoundNames(questionHtml), ...answerOnly]
      : answerOnly;
}

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

  /// [DesktopAudioPlayback.playFileToEnd] 在第一个 await 之前就记下了激活代号并排进
  /// 串行队列，随后的 [DesktopAudioPlayback.stop] 会让它放弃开播。
  @override
  Future<bool> playToEnd(String path) =>
      DesktopAudioPlayback.playFileToEnd(path);

  @override
  Future<void> stop() => DesktopAudioPlayback.stop();
}

final Provider<SrsCardAudioOutput> srsCardAudioOutputProvider =
    Provider<SrsCardAudioOutput>(_DefaultSrsCardAudioOutput.new);

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
        if (generation != _generation || path == null) return;
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
/// 机制：
/// - 包一层 `HTMLMediaElement.prototype.play`：关闭时，不在用户输入事件的派发过程
///   里的调用直接返回以 `NotAllowedError` 拒绝的 Promise（与浏览器自动播放策略同一
///   形态，现有片段脚本的 `catch` 照常吞掉）。
/// - 「在用户输入事件的派发过程里」：window 捕获阶段看到可信（`isTrusted`）的点按 /
///   按键事件即置位，`setTimeout(0)` 在这次派发全部结束后复位——同一次点按里卡片
///   脚本转手 `replay.click()`（Lapis「点例句重播」）照样放行，之后的 `canplay` /
///   `ended` / 定时器都不算手势。
/// - `autoplay` 属性不经 `play()`：关闭时 MutationObserver 把新插入的媒体元素上的
///   `autoplay` 摘掉（观察回调是微任务，早于媒体数据就绪）；关闭那一刻也扫一遍现有内容。
/// - 开关由宿主经 `window.__fushiSrsSetAutoplay(bool)` 下发（换卡调用之前）。
const String kSrsCardAutoplayGateScript = r'''
(function(){
  if (window.__fushiSrsSetAutoplay) return;
  var allowed = true;
  var gesture = false;
  var clearTimer = null;
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
  var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
  if (proto && typeof proto.play === 'function') {
    var nativePlay = proto.play;
    proto.play = function(){
      if (!allowed && !gesture) return Promise.reject(refusal());
      return nativePlay.apply(this, arguments);
    };
  }
  function strip(node){
    if (!node || node.nodeType !== 1) return;
    var tag = node.tagName;
    if ((tag === 'AUDIO' || tag === 'VIDEO') && node.hasAttribute('autoplay')) {
      node.removeAttribute('autoplay');
      try { node.autoplay = false; } catch (e) {}
    }
    if (typeof node.querySelectorAll !== 'function') return;
    var list = node.querySelectorAll('audio[autoplay],video[autoplay]');
    for (var j = 0; j < list.length; j++) {
      list[j].removeAttribute('autoplay');
      try { list[j].autoplay = false; } catch (e) {}
    }
  }
  if (window.MutationObserver && document.documentElement) {
    new MutationObserver(function(records){
      if (allowed) return;
      for (var r = 0; r < records.length; r++) {
        var added = records[r].addedNodes || [];
        for (var k = 0; k < added.length; k++) strip(added[k]);
      }
    }).observe(document.documentElement, { childList: true, subtree: true });
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
