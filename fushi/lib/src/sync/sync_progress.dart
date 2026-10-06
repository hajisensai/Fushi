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

  /// Audiobook packages (`audiobook.fushiaudio`；Hibiki 时代的
  /// `audiobook.hibikiaudio` 仍可读) inside each book folder.
  audiobooks,

  /// Video files in the `__videos__` namespace (多端库联合视图 §2.6).
  videos,
}

/// One progress tick within a sync phase.
///
/// [itemIndex] is the number of items already completed in this phase (0-based
/// at the start of the current item), [itemTotal] the phase's item count.
/// [fileFraction] is the in-flight large-file transfer fraction (0..1) for the
/// current item, or null when the item is atomic (for example, small JSON).
class SyncProgress {
  const SyncProgress({
    required this.phase,
    required this.itemIndex,
    required this.itemTotal,
    this.title,
    this.fileFraction,
    this.bytesPerSecond,
  });

  final SyncPhase phase;
  final int itemIndex;
  final int itemTotal;
  final String? title;
  final double? fileFraction;

  /// Current transfer rate, or null when this tick carries no byte count (an
  /// atomic item, a transport that only reports a fraction, or the wait for a
  /// package's first byte) or the meter has not seen enough of a window yet.
  final double? bytesPerSecond;

  /// 0..1 progress within the current phase.
  ///
  /// A measurable file transfer blends its byte fraction into the completed
  /// item count. An atomic item has no inner fraction, so its visible ordinal
  /// is the only progress signal and counts as one whole step. This keeps the
  /// bar consistent with the adjacent `(k/N)` label: `(2/2)` must render 100%,
  /// not 50% (BUG-1973).
  ///
  /// Null when the phase has no items (nothing to do), so the UI can fall back
  /// to an indeterminate bar.
  double? get fraction {
    if (itemTotal <= 0) return null;
    final double file = (fileFraction ?? 1).clamp(0.0, 1.0);
    return ((itemIndex + file) / itemTotal).clamp(0.0, 1.0);
  }
}

/// Sliding-window transfer rate over the per-file byte counts a sync reports.
///
/// Transports report bytes done *within the current file*, so the caller names
/// the file each sample belongs to; when the name changes (or the count drops
/// back, as on a retry of the same file) the meter folds the finished count
/// into a running total instead of treating the drop as negative throughput.
/// The name is the only reliable boundary: a small file's final count can be
/// below the next file's first one, which a "count went down" check misses.
/// Samples
/// older than [window] are discarded, so a long gap (the host packaging the
/// next dictionary) does not drag the average down nor leave a stale rate.
class TransferRateMeter {
  TransferRateMeter({
    DateTime Function()? now,
    this.window = const Duration(seconds: 3),
    this.minSpan = const Duration(milliseconds: 300),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// How far back samples count towards the average.
  final Duration window;

  /// Minimum time the retained samples must span before a rate is reported;
  /// shorter spans divide by near-zero and flicker.
  final Duration minSpan;

  final List<(DateTime, int)> _samples = <(DateTime, int)>[];
  int _finishedBytes = 0;
  int _fileBytes = 0;
  Object? _file;

  /// Records that [file] has [bytesDone] bytes transferred and returns the
  /// rate in bytes per second, or null if not yet measurable. [file] is any
  /// value with equality that identifies the transfer (a record works).
  double? sample(Object file, int bytesDone) {
    if (file != _file || bytesDone < _fileBytes) {
      _finishedBytes += _fileBytes;
      _file = file;
    }
    _fileBytes = bytesDone;

    final DateTime now = _now();
    _samples
      ..add((now, _finishedBytes + bytesDone))
      ..removeWhere(((DateTime, int) s) => now.difference(s.$1) > window);

    final (DateTime t0, int b0) = _samples.first;
    final Duration span = now.difference(t0);
    if (span < minSpan) return null;
    return (_samples.last.$2 - b0) * 1000000 / span.inMicroseconds;
  }
}

/// Callback the orchestrator invokes on each progress tick. Optional everywhere:
/// background auto-sync passes none, so its behaviour is unchanged.
typedef SyncProgressCallback = void Function(SyncProgress progress);
