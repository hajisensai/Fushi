/// 有声书制作里「没配上音」的句子：占位、记账、熔断（纯计算，供制作流程与测试共用）。
///
/// 一句在 `ttsWithRetry` 用尽后仍合成失败（或它的声音解析不到）时不让整章失败、也不
/// 悄悄跳过：成品里按字数放一段占位静音（[estimatePlaceholderMs]），cue 照常排，账本
/// （[CastVoicingLedger]）记下这次尝试，之后在制作台补回。
///
/// 例外：整个服务挂了（连续 [kTtsUnvoicedAbortStreak] 句失败、中间一句都没成功）时
/// 不再一句句占位下去，整个任务按那个失败码失败——那不是「某句没配上」，是引擎不可用。
library;

import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

/// 章清单里占位句的键前缀：重跑时期望键里永远没有这个前缀，含占位的章因此总会
/// 重新合成（失败过的句子顺带再试一次），不会被当成已完成的章跳过。
const String kTtsPlaceholderKeyPrefix = 'unvoiced:';

/// 占位句在章清单里的键。
String ttsPlaceholderManifestKey(String key) => '$kTtsPlaceholderKeyPrefix$key';

/// 连续这么多句失败且中间没有一句成功：判定引擎不可用，整个任务失败。
const int kTtsUnvoicedAbortStreak = 12;

/// 句子的行身份（账本键）：与选角表同一套坐标，不随计划下标平移。
String ttsSentenceLineId(TtsPlanSentence sentence) =>
    ttsLineKey(sentence.section, sentence.matchStart);

/// 这句实际要念的文字：选角表里手动填写的念法优先，否则计划里的念法。
String ttsSentenceSpokenText(TtsCast cast, TtsPlanSentence sentence) =>
    cast.sayFor(sentence.section, sentence.matchStart) ?? sentence.spokenText;

/// 一句合成失败能不能占位（而不是让任务失败）：引擎对这一句报的失败都算；取消不算
/// （那是用户在停任务），其它异常（文件系统、程序错误）也不算。
bool ttsFailureIsPerLine(Object error) =>
    error is TtsFailure && error.code != TtsFailureCode.cancelled;

/// 记进账本的失败码：引擎失败用 `TtsFailureCode.name`，声音解析失败用制作的错误码。
String ttsUnvoicedCode(Object error) => switch (error) {
  TtsFailure(code: final TtsFailureCode code) => code.name,
  TtsRenderFailure(code: final String code) => code,
  _ => 'internal',
};

String? ttsUnvoicedDetail(Object error) => switch (error) {
  TtsFailure(detail: final String? detail) => detail,
  TtsRenderFailure(detail: final String? detail) => detail,
  _ => null,
};

/// 熔断计数：连续失败数，任一成功清零。
class TtsUnvoicedBreaker {
  TtsUnvoicedBreaker({this.threshold = kTtsUnvoicedAbortStreak})
    : assert(threshold > 0);

  final int threshold;
  int _streak = 0;

  int get streak => _streak;

  void recordSuccess() => _streak = 0;

  /// 记一次失败；返回是否到了熔断线。
  bool recordFailure() => ++_streak >= threshold;
}

/// 本次渲染里没配上的一句。
class TtsUnvoicedLine {
  const TtsUnvoicedLine({
    required this.planIndex,
    required this.lineId,
    required this.text,
    required this.voice,
    required this.code,
    this.detail,
  });

  final int planIndex;
  final String lineId;

  /// 试着念的文字（占位长度按它估）。
  final String text;

  /// 用的声音预设 id。
  final String? voice;
  final String code;
  final String? detail;
}

/// 渲染完成后对账：本次渲染范围内（[renderedLineIds]）不在 [failures] 里的行都已
/// 有真音频，从账本删掉；[failures] 每句记一次尝试；计划里已不存在的行（重新分句、
/// 改正文后）清掉。返回账本（就地修改）。
CastVoicingLedger reconcileTtsVoicingLedger({
  required CastVoicingLedger ledger,
  required Set<String> renderedLineIds,
  required Set<String> liveLineIds,
  required List<TtsUnvoicedLine> failures,
  DateTime? now,
}) {
  final Set<String> failed = <String>{
    for (final TtsUnvoicedLine f in failures) f.lineId,
  };
  for (final String id in renderedLineIds) {
    if (!failed.contains(id)) ledger.resolve(id);
  }
  for (final TtsUnvoicedLine f in failures) {
    ledger.recordFailure(
      lineId: f.lineId,
      text: f.text,
      voice: f.voice,
      code: f.code,
      detail: f.detail,
      now: now,
    );
  }
  ledger.retainOnly(liveLineIds);
  return ledger;
}

/// 一章里每句拼进成品的时长：有音频的取实际时长，占位句取 [estimatePlaceholderMs]。
/// [voicedDurationsMs] 按顺序对应 [placeholder] 里为 false 的句子。
List<int> ttsChapterDurationsWithPlaceholders({
  required List<bool> placeholder,
  required List<int> voicedDurationsMs,
  required List<String> texts,
}) {
  final List<int> out = <int>[];
  int v = 0;
  for (int k = 0; k < placeholder.length; k++) {
    out.add(
      placeholder[k] ? estimatePlaceholderMs(texts[k]) : voicedDurationsMs[v++],
    );
  }
  if (v != voicedDurationsMs.length) {
    throw ArgumentError('voiced durations do not match placeholder mask');
  }
  return out;
}
