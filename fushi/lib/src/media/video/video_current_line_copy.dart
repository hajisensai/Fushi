import 'package:fushi_audio/fushi_audio.dart';

/// 「复制当前台词」（_Eb0txdN4H）要写进剪贴板的文本：画面上此刻**正在显示**的那几句
/// （重叠字幕全渲染时可能不止一句，[activeCues]，按显示顺序以换行连接）；句间空隙里
/// 没有在显示的句子时，回落到 [fallback]（页面按播放位置解析出的刚播完那句，与收藏 /
/// 制卡取句同一判据）。都为空返回 null（调用方提示「未选择句子」，不写空剪贴板）。
String? videoCurrentLineCopyText({
  required List<AudioCue> activeCues,
  AudioCue? fallback,
}) {
  final List<String> showing = <String>[
    for (final AudioCue cue in activeCues)
      if (cue.text.trim().isNotEmpty) cue.text.trim(),
  ];
  if (showing.isNotEmpty) return showing.join('\n');
  final String? text = fallback?.text.trim();
  if (text == null || text.isEmpty) return null;
  return text;
}
