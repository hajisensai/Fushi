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
abstract class SrsCardAudioOutput {
  /// 播媒体库里的 [name] 并等它播完。true = 自然播完，可以接着播下一段；
  /// false = 没找到 / 没能开播 / 被别的播放打断（序列就此停下）。
  Future<bool> playToEnd(String name);

  /// 停掉正在播的音频。
  Future<void> stop();
}

/// 生产实现：从本 profile 的复习媒体库取文件，交给 app 共用的播放器。
class _DefaultSrsCardAudioOutput implements SrsCardAudioOutput {
  _DefaultSrsCardAudioOutput(this._ref);

  final Ref _ref;

  @override
  Future<bool> playToEnd(String name) async {
    final SrsMediaStore? store = await _ref.read(srsMediaStoreProvider.future);
    final File? file = store?.resolve(name);
    if (file == null || !await file.exists()) {
      // 自动播放不弹 toast（每张卡都弹太吵）；手动点按钮时卡面自己会提示缺文件。
      ErrorLogService.instance.logDiagnostic(
        'SrsCardAudio.playToEnd',
        'media missing: $name',
      );
      return false;
    }
    return DesktopAudioPlayback.playFileToEnd(file.path);
  }

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
        final bool finished = await _output.playToEnd(name);
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
