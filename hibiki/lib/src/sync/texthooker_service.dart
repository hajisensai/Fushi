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

/// 一条可由用户选择的文本 Hook 线程。
///
/// [key] 在一次捕获会话内稳定；LunaHook 使用 ThreadParam + hookcode 的哈希，
/// WebSocket/GDI 等没有线程信息的来源不会出现在该列表中。
@immutable
class TexthookerTextThread {
  const TexthookerTextThread({
    required this.key,
    required this.label,
    required this.lineCount,
    required this.latestAt,
    this.hookCode,
    this.nativeThreadId,
  });

  final String key;
  final String label;
  final String? hookCode;
  final int? nativeThreadId;
  final int lineCount;
  final DateTime latestAt;
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
    this.textThreadKey,
    this.textThreadLabel,
    this.textHookCode,
    this.nativeTextThreadId,
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
  final String? textThreadKey;
  final String? textThreadLabel;
  final String? textHookCode;
  final int? nativeTextThreadId;
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
      textThreadKey: textThreadKey,
      textThreadLabel: textThreadLabel,
      textHookCode: textHookCode,
      nativeTextThreadId: nativeTextThreadId,
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

  /// 按稳定行 id 精确取回捕获项。找不到时返回 null，调用方不得回退到最新行。
  TexthookerLineEntry? entryById(String id) {
    for (final TexthookerLineEntry entry in _entries.reversed) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// 当前缓冲中出现过的可选文本线程，最近活跃的排在前面。
  List<TexthookerTextThread> get textThreads {
    final Map<String, TexthookerTextThread> byKey =
        <String, TexthookerTextThread>{};
    for (final TexthookerLineEntry entry in _entries) {
      final String? key = entry.textThreadKey;
      if (key == null || key.isEmpty) continue;
      final TexthookerTextThread? previous = byKey[key];
      byKey[key] = TexthookerTextThread(
        key: key,
        label: entry.textThreadLabel ?? previous?.label ?? key,
        hookCode: entry.textHookCode ?? previous?.hookCode,
        nativeThreadId: entry.nativeTextThreadId ?? previous?.nativeThreadId,
        lineCount: (previous?.lineCount ?? 0) + 1,
        latestAt: entry.receivedAt,
      );
    }
    final List<TexthookerTextThread> result = byKey.values.toList()
      ..sort((a, b) => b.latestAt.compareTo(a.latestAt));
    return List<TexthookerTextThread>.unmodifiable(result);
  }

  /// [threadKey] 为 null 时返回所有行；否则只返回指定 Hook 线程的文本。
  List<TexthookerLineEntry> entriesForTextThread(String? threadKey) {
    if (threadKey == null) return entries;
    return List<TexthookerLineEntry>.unmodifiable(
      _entries.where((entry) => entry.textThreadKey == threadKey),
    );
  }

  TexthookerLineEntry? appendLine(
    String line, {
    TexthookerLineSource source = TexthookerLineSource.unknown,
    String? sourceLabel,
    int? sourceSequence,
    int? hookTimestampMs,
    String? textThreadKey,
    String? textThreadLabel,
    String? textHookCode,
    int? nativeTextThreadId,
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
      textThreadKey: textThreadKey,
      textThreadLabel: textThreadLabel,
      textHookCode: textHookCode,
      nativeTextThreadId: nativeTextThreadId,
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
