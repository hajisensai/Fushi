import 'dart:async';

/// Platform integration for intents, sharing, wakelock, and file picking.
/// Android: receive_intent + share_plus + wakelock_plus + file_picker.
/// Desktop: OS-specific IPC + native file dialogs.
abstract class PlatformIntegration {
  /// Incoming text from external apps (Android PROCESS_TEXT/SEND intents).
  Stream<String> get incomingTextStream;

  /// One-time initial intent that launched the app.
  Future<String?> getInitialText();

  Future<void> shareText(String text);
  Future<void> shareFile(String filePath, {String? mimeType});

  Future<void> setWakeLock({required bool enabled});

  Future<String?> pickFile({List<String>? allowedExtensions});
  Future<List<String>?> pickFiles({List<String>? allowedExtensions});
}
