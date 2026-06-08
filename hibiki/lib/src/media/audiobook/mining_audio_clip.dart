import 'package:hibiki_audio/hibiki_audio.dart';

const int kMiningSentenceAudioTailPaddingMs = 350;

/// Returns the audio time window used when exporting sentence audio for Anki.
///
/// Cue end timestamps are alignment boundaries, not guaranteed perceptual
/// sentence tails. Card audio keeps a short tail so tight subtitles or encoder
/// frame boundaries do not cut off the final sound.
AudioCue miningSentenceAudioClip(AudioCue cue) {
  final AudioCue clip = AudioCue()
    ..bookKey = cue.bookKey
    ..chapterHref = cue.chapterHref
    ..sentenceIndex = cue.sentenceIndex
    ..textFragmentId = cue.textFragmentId
    ..text = cue.text
    ..startMs = cue.startMs
    ..endMs = cue.endMs + kMiningSentenceAudioTailPaddingMs
    ..audioFileIndex = cue.audioFileIndex
    ..markup = cue.markup;
  clip.id = cue.id;
  return clip;
}
