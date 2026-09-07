import 'package:fushi/src/sync/texthooker_service.dart';

/// One Windows galgame popup owns one host occurrence. Text layout folding may
/// replace its sourceSequence while intentionally preserving the row ID.
/// Resolve the committed event once, then retain that exact row; this is not a
/// cache of aliases and never searches by text or adopts a newer occurrence.
class GalIngameMiningBinding {
  GalIngameMiningBinding({
    required this.textEventId,
    required this.sessionStartedAt,
    required this.targetHwnd,
    required Iterable<TexthookerLineEntry> selectedLines,
  }) {
    _bindExactEvent(selectedLines);
  }

  final int textEventId;
  final DateTime? sessionStartedAt;
  final int? targetHwnd;
  TexthookerLineEntry? _boundOccurrence;

  void _bindExactEvent(Iterable<TexthookerLineEntry> selectedLines) {
    if (_boundOccurrence != null || textEventId <= 0) return;
    final List<TexthookerLineEntry> matches = selectedLines
        .where(
          (TexthookerLineEntry entry) =>
              entry.source == TexthookerLineSource.engineHook &&
              entry.sourceSequence == textEventId,
        )
        .take(2)
        .toList();
    if (matches.length == 1) _boundOccurrence = matches.single;
  }

  String? resolve({
    required DateTime? currentSessionStartedAt,
    required int? currentTargetHwnd,
    required Iterable<TexthookerLineEntry> selectedLines,
  }) {
    if (sessionStartedAt == null ||
        targetHwnd == null ||
        currentSessionStartedAt != sessionStartedAt ||
        currentTargetHwnd != targetHwnd) {
      return null;
    }
    // The exact event may arrive after the hit. Once bound, disappearance is
    // terminal for that row: even an identical new row cannot replace it.
    _bindExactEvent(selectedLines);
    final TexthookerLineEntry? bound = _boundOccurrence;
    if (bound == null) return null;
    for (final TexthookerLineEntry entry in selectedLines) {
      if (entry.id == bound.id &&
          entry.source == bound.source &&
          entry.sourceLabel == bound.sourceLabel &&
          entry.textThreadKey == bound.textThreadKey) {
        return entry.id;
      }
    }
    return null;
  }
}
