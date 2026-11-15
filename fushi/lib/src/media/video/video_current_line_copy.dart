import 'package:fushi/src/media/video/video_simultaneous_cues.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 「复制当前台词」（_Eb0txdN4H）要写进剪贴板的文本：画面上此刻**正在显示**的那几句
/// （重叠字幕全渲染时可能不止一句，[activeCues]）。
///
/// 同时显示、按 [cuesShowAsOneSentence] 属于同一句的多行（ASS 把一句拆成几条起止相同的
/// Dialogue，反馈 rLCxUJ-2i4）合成一句（[joinSimultaneousCueText]）；不同的句之间以换行
/// 连接。全部按显示顺序（画面自上而下）排。
///
/// 句间空隙里没有在显示的句子时，回落到 [fallback]（页面按播放位置解析出的刚播完那句，
/// 与收藏 / 制卡取句同一判据），并按它所在字幕流 [cues] 补齐与它同时显示的其它行。
/// 都为空返回 null（调用方提示「未选择句子」，不写空剪贴板）。
String? videoCurrentLineCopyText({
  required List<AudioCue> activeCues,
  required List<AudioCue> cues,
  AudioCue? fallback,
}) {
  final List<List<AudioCue>> sentences = <List<AudioCue>>[];
  for (final AudioCue cue in orderCuesTopToBottom(activeCues)) {
    if (cue.text.trim().isEmpty) continue;
    List<AudioCue>? home;
    for (final List<AudioCue> sentence in sentences) {
      if (cuesShowAsOneSentence(sentence.first, cue)) {
        home = sentence;
        break;
      }
    }
    if (home == null) {
      sentences.add(<AudioCue>[cue]);
    } else {
      home.add(cue);
    }
  }
  if (sentences.isNotEmpty) {
    return sentences.map(joinSimultaneousCueText).join('\n');
  }
  if (fallback == null) return null;
  final String text = simultaneousCueText(cues, fallback);
  return text.isEmpty ? null : text;
}
