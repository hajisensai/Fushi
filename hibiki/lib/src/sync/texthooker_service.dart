import 'package:flutter/foundation.dart';

enum TexthookerLineSource { websocket, engineHook, unknown }

enum TexthookerLineAudioStatus {
  unavailable,
  pending,
  matched,
  fallback,
  missing,
  encoded,
}

@immutable
class TexthookerLineEntry {
  const TexthookerLineEntry({
    required this.id,
    required this.text,
    required this.source,
    required this.receivedAt,
    this.sourceLabel,
    this.sourceSequence,
    this.hookTimestampMs,
    this.audioStatus = TexthookerLineAudioStatus.unavailable,
    this.audioBackend,
    this.audioDurationMs,
    this.fallbackReason,
  });

  final String id;
  final String text;
  final TexthookerLineSource source;
  final String? sourceLabel;
  final int? sourceSequence;
  final int? hookTimestampMs;
  final DateTime receivedAt;
  final TexthookerLineAudioStatus audioStatus;
  final String? audioBackend;
  final int? audioDurationMs;
  final String? fallbackReason;

  TexthookerLineEntry copyWith({
    TexthookerLineAudioStatus? audioStatus,
    String? audioBackend,
    int? audioDurationMs,
    String? fallbackReason,
    bool clearFallbackReason = false,
  }) {
    return TexthookerLineEntry(
      id: id,
      text: text,
      source: source,
      sourceLabel: sourceLabel,
      sourceSequence: sourceSequence,
      hookTimestampMs: hookTimestampMs,
      receivedAt: receivedAt,
      audioStatus: audioStatus ?? this.audioStatus,
      audioBackend: audioBackend ?? this.audioBackend,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      fallbackReason:
          clearFallbackReason ? null : fallbackReason ?? this.fallbackReason,
    );
  }
}

/// 收到的 texthooker 结构化文本行 buffer。
///
/// [lines] 保留旧字符串接口；捕获工作台与句音配对使用 [entries] 的稳定 id、来源、序号
/// 和时间戳，重复台词不会再因以 sentence 字符串作 key 而互相覆盖。
class TexthookerService extends ChangeNotifier {
  TexthookerService._();
  static final TexthookerService instance = TexthookerService._();

  @visibleForTesting
  TexthookerService.test();

  static const int maxLines = 500;

  final List<TexthookerLineEntry> _entries = <TexthookerLineEntry>[];
  int _nextId = 0;

  List<TexthookerLineEntry> get entries =>
      List<TexthookerLineEntry>.unmodifiable(_entries);
  List<String> get lines =>
      List<String>.unmodifiable(_entries.map((entry) => entry.text));

  TexthookerLineEntry? appendLine(
    String line, {
    TexthookerLineSource source = TexthookerLineSource.unknown,
    String? sourceLabel,
    int? sourceSequence,
    int? hookTimestampMs,
    DateTime? receivedAt,
    TexthookerLineAudioStatus audioStatus =
        TexthookerLineAudioStatus.unavailable,
  }) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final DateTime now = receivedAt ?? DateTime.now();
    final TexthookerLineEntry entry = TexthookerLineEntry(
      id: '${now.microsecondsSinceEpoch}-${_nextId++}',
      text: trimmed,
      source: source,
      sourceLabel: sourceLabel,
      sourceSequence: sourceSequence,
      hookTimestampMs: hookTimestampMs,
      receivedAt: now,
      audioStatus: audioStatus,
    );
    _entries.add(entry);
    if (_entries.length > maxLines) {
      _entries.removeRange(0, _entries.length - maxLines);
    }
    notifyListeners();
    return entry;
  }

  bool updateLineAudio(
    String id, {
    required TexthookerLineAudioStatus status,
    String? backend,
    int? durationMs,
    String? fallbackReason,
  }) {
    final int index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    _entries[index] = _entries[index].copyWith(
      audioStatus: status,
      audioBackend: backend,
      audioDurationMs: durationMs,
      fallbackReason: fallbackReason,
      clearFallbackReason: fallbackReason == null,
    );
    notifyListeners();
    return true;
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}
