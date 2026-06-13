import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue? buildSelectedSubtitleCueContext({
  required List<AudioCue> cues,
  required Set<int> selectedStartMs,
}) {
  if (cues.isEmpty || selectedStartMs.isEmpty) return null;

  final List<AudioCue> selected = cues
      .where((AudioCue cue) => selectedStartMs.contains(cue.startMs))
      .toList(growable: false);
  if (selected.isEmpty) return null;
  if (selected.length == 1) return selected.first;

  return AudioCue()
    ..startMs = selected.first.startMs
    ..endMs = selected.last.endMs
    ..text = selected
        .map((AudioCue cue) => cue.text.trim())
        .where((String text) => text.isNotEmpty)
        .join('\n');
}
