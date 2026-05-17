import 'dart:async';

/// Text-to-speech engine abstraction.
/// Android: MethodChannel to native TTS + MediaExtractor.
/// Desktop: system TTS or web service.
abstract class TtsEngine {
  Future<void> speak(String text, {String? locale});
  Future<void> stop();
  Future<String?> synthesizeToFile(
    String text,
    String outputPath, {
    String? locale,
  });
  Future<bool> isAvailable();
}
