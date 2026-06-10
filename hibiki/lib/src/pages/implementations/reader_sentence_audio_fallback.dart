/// 判定书籍制卡时是否应为整句合成 OS TTS 句子音频作为兜底。
///
/// reader 优先用绑定的有声书音频裁剪真实句子音频；纯文本书（无有声书 / SRT）
/// 没有真实音频源时 [realSentenceAudioPath] 为 null。本函数只在**真实句子音频
/// 缺失**且**句子非空**时返回 true，让调用方走 `TtsChannel.ttsToFile` 兜底。
/// 真实音频存在时绝不合成（有声书优先，避免用机械音覆盖真人音）。
bool shouldSynthesizeSentenceTtsFallback({
  required String? realSentenceAudioPath,
  required String sentence,
}) {
  final bool hasRealAudio =
      realSentenceAudioPath != null && realSentenceAudioPath.isNotEmpty;
  if (hasRealAudio) return false;
  return sentence.trim().isNotEmpty;
}
