/// Progress reporting for a manual full sync ([SyncOrchestrator.run]).
///
/// A full sync runs as a sequence of phases (import remote books → per-book
/// reading data → dictionaries → local audio → audiobooks). A single global
/// percentage is dishonest because the per-phase totals aren't known until each
/// phase lists its remote side, so progress is reported PER PHASE: each phase
/// knows its item count up front, and large-file transfers blend their
/// byte-level fraction into the current item. This mirrors the determinate bar
/// the compare dialog already shows on Apply.
library;

/// The phase a [SyncProgress] event belongs to. The UI maps this to a localized
/// label; keeping it an enum (not a pre-localized string) keeps i18n in the
/// widget layer and makes the orchestrator testable.
enum SyncPhase {
  /// Downloading + importing books that exist remotely but not locally.
  books,

  /// Per-book reading data: progress / stats / content / audiobook position.
  readingData,

  /// Dictionary packages in the `__dictionaries__` namespace.
  dictionaries,

  /// Local-audio source DBs in the `__local_audio__` namespace.
  localAudio,

  /// Audiobook packages (`audiobook.hibikiaudio`) inside each book folder.
  audiobooks,
}

/// One progress tick within a sync phase.
///
/// [itemIndex] is the number of items already completed in this phase (0-based
/// at the start of the current item), [itemTotal] the phase's item count.
/// [fileFraction] is the in-flight large-file transfer fraction (0..1) for the
/// current item, or null when there is no measurable transfer (small JSON).
class SyncProgress {
  const SyncProgress({
    required this.phase,
    required this.itemIndex,
    required this.itemTotal,
    this.title,
    this.fileFraction,
  });

  final SyncPhase phase;
  final int itemIndex;
  final int itemTotal;
  final String? title;
  final double? fileFraction;

  /// 0..1 progress within the current phase, blending the in-flight file
  /// fraction into the completed-item count. Null when the phase has no items
  /// (nothing to do) so the UI can fall back to an indeterminate bar.
  double? get fraction {
    if (itemTotal <= 0) return null;
    final double file = (fileFraction ?? 0).clamp(0.0, 1.0);
    return ((itemIndex + file) / itemTotal).clamp(0.0, 1.0);
  }
}

/// Callback the orchestrator invokes on each progress tick. Optional everywhere:
/// background auto-sync passes none, so its behaviour is unchanged.
typedef SyncProgressCallback = void Function(SyncProgress progress);
