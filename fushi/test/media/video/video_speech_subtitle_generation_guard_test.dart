import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The page requires the native media_kit surface. These guards cover its
// orchestration; ASR conversion and subtitle parsing have separate unit tests.
void main() {
  late String source;
  setUpAll(() {
    source = File(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    ).readAsStringSync();
  });

  test('PGS and videos without cues can generate learning subtitles', () {
    final String generation = source
        .split('Future<void> _generateSubtitleWithSpeechModel(')[1]
        .split('Future<String?> _transcribeVideoSpeech(')[0];
    expect(source, contains('t.video_subtitle_asr_generate'));
    expect(source, contains('t.video_subtitle_graphic_learning_hint'));
    expect(generation, isNot(contains('if (cues.isEmpty)')));
    expect(generation, contains('_importExternalSubtitle(controller, target)'));
    expect(generation, contains('_applyRemoteSubtitle(controller, target)'));
    expect(generation, contains('await _setDelayMs(0)'));
    expect(generation, contains('_episodeLoadSeq == loadSeq'));
    expect(generation, contains('identical(_controller, controller)'));
    expect(generation, contains('transcriptSrt == null || !isCurrent()'));
    expect(generation, contains('catch (error, stack)'));
    expect(generation, contains("'video.subtitleSpeechGeneration'"));
    expect(generation, contains('t.video_subtitle_import_failed'));
  });

  test('ASR receives the selected audio track and the full episode', () {
    final String preparation = source
        .split('Future<String?> _transcribeVideoSpeech(')[1]
        .split('Future<void> _retimeSubtitleWithSpeechModel(')[0];
    expect(preparation, contains('extractAudioSegmentViaFfmpeg('));
    expect(preparation, contains('startMs: 0'));
    expect(preparation, contains('endMs: durationMs'));
    expect(preparation, contains('audioStreamIndex: audio.audioStreamIndex'));
    expect(preparation, contains('audioStreamCount: audio.audioStreamCount'));
    expect(preparation, contains('audioPaths: <String>[audioPath]'));
    // Video is mixed audio (BGM / effects): the sheet must get a mixedAudio
    // service. Without it the shared default is the audiobook (cleanSpeech)
    // service — Japanese then runs ReazonSpeech behind an energy gate instead of
    // Parakeet with sliding windows (8 anime episodes: kana CER 20.7% vs 13.9%).
    expect(preparation, contains('service: createAsrTranscriptionService('));
    expect(preparation, contains('audioProfile: AsrAudioProfile.mixedAudio'));
    // Both generating text and correcting existing text use that same track.
    // The call may forward the caller's `transcribe:` override (desktop CLI runs
    // the same transcription service headless) — the track preparation above is
    // still the single shared path, so match the call with optional named args.
    expect(
      RegExp(
        r'_transcribeVideoSpeech\(\s*controller\s*(?:,\s*transcribe:\s*transcribe\s*,?\s*)?\)',
      ).allMatches(source),
      hasLength(2),
    );
    final String retiming = source
        .split('Future<void> _retimeSubtitleWithSpeechModel(')[1]
        .split('Future<void> _alignSubtitleToEmbeddedTracks(')[0];
    expect(retiming, isNot(contains('if (!mounted) return;')));
    expect(retiming, contains('identical(_controller, controller)'));
    expect(retiming, contains('_episodeLoadSeq == loadSeq'));
    expect('if (!isCurrent()) return;'.allMatches(retiming), hasLength(3));
  });
}
