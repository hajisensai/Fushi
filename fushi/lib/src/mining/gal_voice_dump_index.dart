import 'dart:async';
import 'dart:collection';
import 'dart:io';

typedef GalVoiceDumpLoader = Future<List<GalVoiceDumpEntry>> Function(
    Directory directory);
typedef GalVoiceDumpEntryLoader = Future<GalVoiceDumpEntry?> Function(
    String path);
typedef GalVoiceDumpWatcher = Stream<FileSystemEvent> Function(
    Directory directory);

enum GalVoiceDumpKind { oggLike, wav }

const int kGalVoiceResourcePairingWindowMs = 1500;

/// Parsed ownership/time evidence carried by a dumped resource filename.
final class GalVoiceResourceName {
  const GalVoiceResourceName({
    required this.tick,
    required this.basename,
    this.textEventId,
  });

  final int tick;
  final String basename;
  final int? textEventId;
}

/// Parses `<tick>_[fushi_textseq<textSeq>_]<basename>`.
///
/// A malformed explicit marker is rejected instead of being downgraded to a
/// time-only candidate.
GalVoiceResourceName? parseGalVoiceResourceName(String fileName) {
  final int underscore = fileName.indexOf('_');
  if (underscore <= 0) return null;
  final int? tick = int.tryParse(fileName.substring(0, underscore));
  if (tick == null) return null;
  String basename = fileName.substring(underscore + 1);
  if (basename.isEmpty) return null;
  int? textEventId;
  if (basename.startsWith('fushi_textseq')) {
    final RegExpMatch? match =
        RegExp(r'^fushi_textseq(\d+)_(.+)$').firstMatch(basename);
    if (match == null) return null;
    textEventId = int.tryParse(match.group(1)!);
    if (textEventId == null || textEventId <= 0) return null;
    basename = match.group(2)!;
  }
  return GalVoiceResourceName(
    tick: tick,
    basename: basename,
    textEventId: textEventId,
  );
}

final RegExp _nonVoiceBasenamePattern = RegExp(
  r'^(bgm|se|sys|amb|env|title|logo|movie|jingle)',
  caseSensitive: false,
);

bool isGalNonVoiceBasename(String basename) =>
    _nonVoiceBasenamePattern.hasMatch(basename);

final class GalVoiceDumpEntry {
  const GalVoiceDumpEntry({
    required this.name,
    required this.path,
    required this.modified,
    required this.kind,
  });

  final String name;
  final String path;
  final DateTime modified;
  final GalVoiceDumpKind? kind;
}

final class GalVoiceDumpSnapshot {
  GalVoiceDumpSnapshot._({
    required this.revision,
    required this.entries,
    required this.voiceEntries,
    required this.byName,
  });

  factory GalVoiceDumpSnapshot.fromEntries({
    required int revision,
    required List<GalVoiceDumpEntry> entries,
  }) {
    final Map<String, GalVoiceDumpEntry> byName = <String, GalVoiceDumpEntry>{};
    for (final GalVoiceDumpEntry entry in entries) {
      byName[entry.name] = entry;
    }
    final List<GalVoiceDumpEntry> stableEntries =
        List<GalVoiceDumpEntry>.unmodifiable(byName.values);
    final List<GalVoiceDumpEntry> voiceEntries =
        List<GalVoiceDumpEntry>.unmodifiable(
      stableEntries.where((GalVoiceDumpEntry entry) => entry.kind != null),
    );
    return GalVoiceDumpSnapshot._(
      revision: revision,
      entries: stableEntries,
      voiceEntries: voiceEntries,
      byName: Map<String, GalVoiceDumpEntry>.unmodifiable(byName),
    );
  }

  factory GalVoiceDumpSnapshot.empty(int revision) =>
      GalVoiceDumpSnapshot.fromEntries(
        revision: revision,
        entries: const <GalVoiceDumpEntry>[],
      );

  final int revision;
  final List<GalVoiceDumpEntry> entries;
  final List<GalVoiceDumpEntry> voiceEntries;
  final Map<String, GalVoiceDumpEntry> byName;
}

enum _GalVoiceDumpMutation { upsert, delete }

final class _IndexedVoice {
  const _IndexedVoice({
    required this.entry,
    required this.parsed,
    required this.ordinal,
  });

  final GalVoiceDumpEntry entry;
  final GalVoiceResourceName parsed;
  final int ordinal;
}

/// Per-engine-session index for `%TEMP%/fushi_gal_voice`.
///
/// Pairing runs on the 80 ms text poll. That path must never enumerate or stat
/// the dump directory: one permanently unmatched line otherwise turns a stable
/// directory into an unbounded allocation loop. This index subscribes before
/// its initial asynchronous scan, coalesces file-system changes, and publishes
/// immutable snapshots. A session epoch prevents an old scan or watcher from
/// writing into a restarted source.
final class GalVoiceDumpIndex {
  GalVoiceDumpIndex({
    required this.directory,
    GalVoiceDumpLoader? loader,
    GalVoiceDumpEntryLoader? entryLoader,
    GalVoiceDumpWatcher? watcher,
    DateTime Function()? now,
    this.eventDebounce = const Duration(milliseconds: 40),
    this.watchRecoveryInterval = const Duration(milliseconds: 250),
    this.watchRecoveryMaxInterval = const Duration(seconds: 30),
  })  : _loader = loader ?? _loadDirectory,
        _entryLoader = entryLoader ?? _loadFile,
        _watcher = watcher ?? _watchDirectory,
        _now = now ?? DateTime.now,
        _currentWatchRecoveryInterval = watchRecoveryInterval;

  final Directory directory;
  final GalVoiceDumpLoader _loader;
  final GalVoiceDumpEntryLoader _entryLoader;
  final GalVoiceDumpWatcher _watcher;
  final DateTime Function() _now;
  final Duration eventDebounce;
  final Duration watchRecoveryInterval;
  final Duration watchRecoveryMaxInterval;
  Duration _currentWatchRecoveryInterval;

  GalVoiceDumpSnapshot _snapshot = GalVoiceDumpSnapshot.empty(0);
  GalVoiceDumpSnapshot get snapshot => _snapshot;

  int _revision = 0;
  int _sessionEpoch = 0;
  int _changeGeneration = 0;
  bool _started = false;
  bool _dirty = false;
  bool _watchHealthy = false;
  bool _loadFailed = false;
  DateTime _nextWatchRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _debounceTimer;
  Object? _watchToken;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  ({int epoch, Future<void> future})? _initialiseInFlight;
  ({int epoch, Future<void> future})? _recoveryInFlight;
  ({int epoch, Future<bool> future})? _scanInFlight;
  ({int epoch, Future<void> future})? _synchronizeInFlight;

  final Map<String, GalVoiceDumpEntry> _entriesByPath =
      <String, GalVoiceDumpEntry>{};
  final Map<String, _IndexedVoice> _voicesByPath = <String, _IndexedVoice>{};
  final SplayTreeMap<int, List<_IndexedVoice>> _wavByTick =
      SplayTreeMap<int, List<_IndexedVoice>>();
  final SplayTreeMap<int, List<_IndexedVoice>> _oggUnmarkedByTick =
      SplayTreeMap<int, List<_IndexedVoice>>();
  final SplayTreeMap<int, List<_IndexedVoice>> _voicesByModified =
      SplayTreeMap<int, List<_IndexedVoice>>();
  final Map<int, List<_IndexedVoice>> _wavByEvent =
      <int, List<_IndexedVoice>>{};
  final Map<int, List<_IndexedVoice>> _oggByEvent =
      <int, List<_IndexedVoice>>{};
  final Map<
      String,
      ({
        String path,
        _GalVoiceDumpMutation mutation,
      })> _pendingMutations = <String,
      ({
    String path,
    _GalVoiceDumpMutation mutation,
  })>{};
  bool _fullRescanRequired = false;
  int _nextOrdinal = 0;

  Future<void> startSession() {
    final ({int epoch, Future<void> future})? current = _initialiseInFlight;
    if (_started) {
      return current?.future ?? Future<void>.value();
    }
    _started = true;
    final int epoch = ++_sessionEpoch;
    _dirty = true;
    _fullRescanRequired = true;
    _pendingMutations.clear();
    _clearEntries();
    _loadFailed = false;
    _currentWatchRecoveryInterval = watchRecoveryInterval;
    _nextWatchRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
    _snapshot = GalVoiceDumpSnapshot.empty(++_revision);
    final Future<void> future = _initialise(epoch);
    final ({int epoch, Future<void> future}) tracked = (
      epoch: epoch,
      future: future,
    );
    _initialiseInFlight = tracked;
    return future.whenComplete(() {
      if (identical(_initialiseInFlight?.future, future)) {
        _initialiseInFlight = null;
      }
    });
  }

  /// Requests bounded asynchronous recovery only when the watcher or last
  /// scan failed. A stopped session stays stopped; only [startSession] may
  /// arm it again. The caller performs no file-system I/O.
  void requestFreshness() {
    if (!_started) return;
    if (_initialiseInFlight != null || (_watchHealthy && !_loadFailed)) {
      return;
    }
    final ({int epoch, Future<void> future})? recovery = _recoveryInFlight;
    if (recovery != null && recovery.epoch == _sessionEpoch) return;
    final DateTime now = _now();
    if (now.isBefore(_nextWatchRecoveryAt)) return;
    _nextWatchRecoveryAt = now.add(_currentWatchRecoveryInterval);
    _dirty = true;
    final int epoch = _sessionEpoch;
    final Future<void> future = _recoverAndSynchronize(epoch);
    _recoveryInFlight = (epoch: epoch, future: future);
    unawaited(
      future.whenComplete(() {
        if (identical(_recoveryInFlight?.future, future)) {
          _recoveryInFlight = null;
        }
      }),
    );
  }

  /// Waits only for already-required work. A healthy, unchanged directory is
  /// a pure memory fast path even when this is called every 80 ms. It never
  /// starts a stopped session, so a late async consumer cannot resurrect a
  /// watcher after the owning audio source has stopped.
  Future<void> synchronize() async {
    if (!_started) return;
    final int epoch = _sessionEpoch;
    if (!_isCurrent(epoch)) return;
    requestFreshness();
    final ({int epoch, Future<void> future})? initial = _initialiseInFlight;
    if (initial != null && initial.epoch == epoch) {
      await initial.future;
      if (!_isCurrent(epoch)) return;
    }
    final ({int epoch, Future<void> future})? recovery = _recoveryInFlight;
    if (recovery != null && recovery.epoch == epoch) {
      await recovery.future;
      if (!_isCurrent(epoch)) return;
    }
    if (!_isCurrent(epoch)) return;
    if (_dirty) {
      await _synchronizeEpoch(epoch);
    } else {
      final ({int epoch, Future<bool> future})? scan = _scanInFlight;
      if (scan != null && scan.epoch == epoch) await scan.future;
    }
  }

  /// Marks an app-originated mutation (for example pruning) so watcher event
  /// loss cannot leave deleted entries in the published snapshot.
  void invalidate() {
    if (!_started) return;
    _changeGeneration++;
    _dirty = true;
    _fullRescanRequired = true;
    _pendingMutations.clear();
    _scheduleSynchronize(_sessionEpoch);
  }

  Future<void> stopSession() async {
    _started = false;
    _sessionEpoch++;
    _dirty = false;
    _fullRescanRequired = false;
    _pendingMutations.clear();
    _loadFailed = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _watchHealthy = false;
    _watchToken = null;
    final StreamSubscription<FileSystemEvent>? subscription =
        _watchSubscription;
    _watchSubscription = null;
    await subscription?.cancel();
    _clearEntries();
    _snapshot = GalVoiceDumpSnapshot.empty(++_revision);
  }

  Future<void> _initialise(int epoch) async {
    try {
      await directory.create(recursive: true);
    } on FileSystemException {
      // The asynchronous scan below records the failure and requestFreshness
      // performs bounded recovery. Capture itself remains fail-open.
    }
    if (!_isCurrent(epoch)) return;
    await _attachWatcher(epoch);
    if (!_isCurrent(epoch)) return;
    await _synchronizeEpoch(epoch);
    if (_isCurrent(epoch) && _watchHealthy && !_loadFailed) {
      _resetRecoveryBackoff();
    }
  }

  Future<void> _recoverAndSynchronize(int epoch) async {
    if (!_isCurrent(epoch)) return;
    try {
      await directory.create(recursive: true);
    } on FileSystemException {
      if (_isCurrent(epoch)) _backOffRecovery();
      return;
    }
    if (!_isCurrent(epoch)) return;
    if (!_watchHealthy) await _attachWatcher(epoch);
    if (!_isCurrent(epoch)) return;
    await _synchronizeEpoch(epoch);
    if (_isCurrent(epoch) && _watchHealthy && !_loadFailed) {
      _resetRecoveryBackoff();
    }
  }

  Future<void> _attachWatcher(int epoch) async {
    if (!_isCurrent(epoch)) return;
    final StreamSubscription<FileSystemEvent>? previous = _watchSubscription;
    _watchSubscription = null;
    _watchToken = null;
    _watchHealthy = false;
    await previous?.cancel();
    if (!_isCurrent(epoch)) return;

    final Object token = Object();
    try {
      final Stream<FileSystemEvent> changes = _watcher(directory);
      final StreamSubscription<FileSystemEvent> subscription = changes.listen(
        (FileSystemEvent event) => _onFileSystemChange(epoch, token, event),
        onError: (Object _, StackTrace __) =>
            _onWatcherUnavailable(epoch, token),
        onDone: () => _onWatcherUnavailable(epoch, token),
        cancelOnError: true,
      );
      if (!_isCurrent(epoch)) {
        await subscription.cancel();
        return;
      }
      _watchToken = token;
      _watchSubscription = subscription;
      _watchHealthy = true;
    } on FileSystemException {
      _onWatcherUnavailable(epoch, token, requireToken: false);
    } on UnsupportedError {
      _onWatcherUnavailable(epoch, token, requireToken: false);
    }
  }

  void _onFileSystemChange(
    int epoch,
    Object token,
    FileSystemEvent event,
  ) {
    if (!_isCurrent(epoch) || !identical(_watchToken, token)) return;
    if (event is FileSystemMoveEvent) {
      _queueMutation(event.path, _GalVoiceDumpMutation.delete);
      final String? destination = event.destination;
      if (destination != null && destination.isNotEmpty) {
        _queueMutation(destination, _GalVoiceDumpMutation.upsert);
      }
    } else if (event is FileSystemDeleteEvent) {
      _queueMutation(event.path, _GalVoiceDumpMutation.delete);
    } else if (event is FileSystemCreateEvent ||
        event is FileSystemModifyEvent) {
      _queueMutation(event.path, _GalVoiceDumpMutation.upsert);
    } else {
      _fullRescanRequired = true;
      _pendingMutations.clear();
    }
    _changeGeneration++;
    _dirty = true;
    _scheduleSynchronize(epoch);
  }

  void _onWatcherUnavailable(
    int epoch,
    Object token, {
    bool requireToken = true,
  }) {
    if (!_isCurrent(epoch) ||
        (requireToken && !identical(_watchToken, token))) {
      return;
    }
    final bool wasHealthy = _watchHealthy;
    _watchHealthy = false;
    _watchToken = null;
    _watchSubscription = null;
    _fullRescanRequired = true;
    _pendingMutations.clear();
    if (wasHealthy) {
      _currentWatchRecoveryInterval = watchRecoveryInterval;
      _nextWatchRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      _backOffRecovery();
    }
  }

  void _backOffRecovery() {
    _nextWatchRecoveryAt = _now().add(_currentWatchRecoveryInterval);
    final int doubled = _currentWatchRecoveryInterval.inMicroseconds * 2;
    final int maximum = watchRecoveryMaxInterval.inMicroseconds;
    _currentWatchRecoveryInterval = Duration(
      microseconds: doubled < maximum ? doubled : maximum,
    );
  }

  void _resetRecoveryBackoff() {
    _currentWatchRecoveryInterval = watchRecoveryInterval;
    _nextWatchRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _queueMutation(String path, _GalVoiceDumpMutation mutation) {
    final String absolutePath = _absoluteWatchPath(path);
    _pendingMutations[_pathKey(absolutePath)] = (
      path: absolutePath,
      mutation: mutation,
    );
  }

  void _scheduleSynchronize(int epoch) {
    if (!_isCurrent(epoch)) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(eventDebounce, () {
      _debounceTimer = null;
      if (_isCurrent(epoch)) unawaited(_synchronizeEpoch(epoch));
    });
  }

  Future<void> _synchronizeEpoch(int epoch) {
    if (!_isCurrent(epoch)) return Future<void>.value();
    final ({int epoch, Future<void> future})? current = _synchronizeInFlight;
    if (current != null && current.epoch == epoch) return current.future;
    final Future<void> future = _runSynchronizeEpoch(epoch);
    _synchronizeInFlight = (epoch: epoch, future: future);
    return future.whenComplete(() {
      if (identical(_synchronizeInFlight?.future, future)) {
        _synchronizeInFlight = null;
      }
    });
  }

  Future<void> _runSynchronizeEpoch(int epoch) async {
    // A second pass closes the subscribe-before-scan race: if an event arrives
    // during a full scan or one-file stat, the next generation is applied
    // before this synchronization completes. Continuous writes remain
    // coalesced instead of trapping the caller in an endless loop.
    for (int pass = 0; pass < 2 && _isCurrent(epoch) && _dirty; pass++) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _dirty = false;
      final int scannedGeneration = _changeGeneration;
      final bool fullRescan = _fullRescanRequired;
      final List<
          ({
            String path,
            _GalVoiceDumpMutation mutation,
          })> mutations = List<
          ({
            String path,
            _GalVoiceDumpMutation mutation,
          })>.of(_pendingMutations.values);
      _fullRescanRequired = false;
      _pendingMutations.clear();
      final bool loaded = fullRescan
          ? await _scanOnce(epoch)
          : await _applyMutations(epoch, mutations);
      if (!_isCurrent(epoch)) return;
      if (_changeGeneration != scannedGeneration) _dirty = true;
      if (!loaded) {
        _fullRescanRequired = true;
        break;
      }
    }
    if (_isCurrent(epoch) && _dirty && !_loadFailed) {
      _scheduleSynchronize(epoch);
    }
  }

  Future<bool> _applyMutations(
    int epoch,
    List<
            ({
              String path,
              _GalVoiceDumpMutation mutation,
            })>
        mutations,
  ) async {
    if (mutations.isEmpty) return true;
    final Map<String, GalVoiceDumpEntry?> loaded =
        <String, GalVoiceDumpEntry?>{};
    try {
      for (final ({
        String path,
        _GalVoiceDumpMutation mutation,
      }) mutation in mutations) {
        if (mutation.mutation == _GalVoiceDumpMutation.upsert) {
          loaded[_pathKey(mutation.path)] = await _entryLoader(mutation.path);
        }
      }
    } on FileSystemException {
      if (_isCurrent(epoch)) {
        _loadFailed = true;
        _backOffRecovery();
      }
      return false;
    } on UnsupportedError {
      if (_isCurrent(epoch)) {
        _loadFailed = true;
        _backOffRecovery();
      }
      return false;
    }
    if (!_isCurrent(epoch)) return false;
    for (final ({
      String path,
      _GalVoiceDumpMutation mutation,
    }) mutation in mutations) {
      final String key = _pathKey(mutation.path);
      if (mutation.mutation == _GalVoiceDumpMutation.delete) {
        _removeEntry(key);
      } else {
        final GalVoiceDumpEntry? entry = loaded[key];
        final int? ordinal = _removeEntry(key);
        if (entry != null) _addEntry(entry, ordinal: ordinal);
      }
    }
    _loadFailed = false;
    _publishSnapshot();
    return true;
  }

  Future<bool> _scanOnce(int epoch) async {
    final ({int epoch, Future<bool> future})? current = _scanInFlight;
    if (current != null && current.epoch == epoch) return current.future;

    final Future<bool> future = _loadAndPublish(epoch);
    final ({int epoch, Future<bool> future}) tracked = (
      epoch: epoch,
      future: future,
    );
    _scanInFlight = tracked;
    return future.whenComplete(() {
      if (identical(_scanInFlight?.future, future)) _scanInFlight = null;
    });
  }

  Future<bool> _loadAndPublish(int epoch) async {
    final List<GalVoiceDumpEntry> entries;
    try {
      entries = await _loader(directory);
    } on FileSystemException {
      if (_isCurrent(epoch)) {
        _loadFailed = true;
        _backOffRecovery();
      }
      return false;
    } on UnsupportedError {
      if (_isCurrent(epoch)) {
        _loadFailed = true;
        _backOffRecovery();
      }
      return false;
    }
    if (!_isCurrent(epoch)) return false;
    _loadFailed = false;
    _replaceEntries(entries);
    _publishSnapshot();
    return true;
  }

  bool _isCurrent(int epoch) => _started && epoch == _sessionEpoch;

  /// O(log N + K) pairing over the incrementally maintained filename index.
  /// This is the 80 ms poll path; it does not enumerate, stat, or parse the
  /// whole dump directory as a session grows.
  List<String> findPairedResourceNames({
    required int textTsMs,
    int? textEventId,
  }) {
    if (!_started || textTsMs <= 0) return const <String>[];

    final List<String> wavEventHits = _rankedEventHits(
      _wavByEvent[textEventId],
      textTsMs,
    );
    if (wavEventHits.isNotEmpty) return wavEventHits;
    final _IndexedVoice? wav = _bestInRange(
      _wavByTick,
      low: textTsMs - 1000,
      high: textTsMs + 500,
      target: textTsMs,
    );
    if (wav != null) return <String>[wav.entry.name];

    final List<String> oggEventHits = _rankedEventHits(
      _oggByEvent[textEventId],
      textTsMs,
    );
    if (oggEventHits.isNotEmpty) return oggEventHits;
    final List<_IndexedVoice>? exact = _oggUnmarkedByTick[textTsMs];
    if (exact != null && exact.isNotEmpty) {
      final List<String> names = <String>[
        for (final _IndexedVoice voice in exact) voice.entry.name,
      ]..sort();
      return names;
    }
    final _IndexedVoice? ogg = _bestInRange(
      _oggUnmarkedByTick,
      low: textTsMs - 330,
      high: textTsMs - 130,
      target: textTsMs - 220,
    );
    return ogg == null ? const <String>[] : <String>[ogg.entry.name];
  }

  GalVoiceDumpEntry? latestPairableVoice({required DateTime notBefore}) {
    if (!_started || _voicesByModified.isEmpty) return null;
    final int modified = _voicesByModified.lastKey()!;
    final List<_IndexedVoice> candidates = _voicesByModified[modified]!;
    _IndexedVoice latest = candidates.first;
    for (final _IndexedVoice candidate in candidates.skip(1)) {
      if (candidate.ordinal < latest.ordinal) latest = candidate;
    }
    return latest.entry.modified.isBefore(notBefore) ? null : latest.entry;
  }

  List<String> _rankedEventHits(
    List<_IndexedVoice>? candidates,
    int textTsMs,
  ) {
    if (candidates == null) return const <String>[];
    final List<_IndexedVoice> hits = <_IndexedVoice>[
      for (final _IndexedVoice candidate in candidates)
        if ((candidate.parsed.tick - textTsMs).abs() <=
            kGalVoiceResourcePairingWindowMs)
          candidate,
    ]..sort((_IndexedVoice a, _IndexedVoice b) {
        final int aDistance = (a.parsed.tick - textTsMs).abs();
        final int bDistance = (b.parsed.tick - textTsMs).abs();
        return aDistance != bDistance
            ? aDistance.compareTo(bDistance)
            : a.entry.name.compareTo(b.entry.name);
      });
    return <String>[
      for (final _IndexedVoice candidate in hits) candidate.entry.name,
    ];
  }

  _IndexedVoice? _bestInRange(
    SplayTreeMap<int, List<_IndexedVoice>> candidates, {
    required int low,
    required int high,
    required int target,
  }) {
    int? tick = candidates.firstKeyAfter(low - 1);
    _IndexedVoice? best;
    int bestDistance = 1 << 62;
    while (tick != null && tick <= high) {
      for (final _IndexedVoice candidate in candidates[tick]!) {
        final int distance = (tick - target).abs();
        if (distance < bestDistance ||
            (distance == bestDistance &&
                (best == null || candidate.ordinal < best.ordinal))) {
          best = candidate;
          bestDistance = distance;
        }
      }
      tick = candidates.firstKeyAfter(tick);
    }
    return best;
  }

  void _replaceEntries(List<GalVoiceDumpEntry> entries) {
    _clearEntries();
    for (final GalVoiceDumpEntry entry in entries) {
      _addEntry(entry);
    }
  }

  void _clearEntries() {
    _entriesByPath.clear();
    _voicesByPath.clear();
    _wavByTick.clear();
    _oggUnmarkedByTick.clear();
    _voicesByModified.clear();
    _wavByEvent.clear();
    _oggByEvent.clear();
    _nextOrdinal = 0;
  }

  void _addEntry(GalVoiceDumpEntry entry, {int? ordinal}) {
    final String key = _pathKey(entry.path);
    _entriesByPath[key] = entry;
    final GalVoiceResourceName? parsed = parseGalVoiceResourceName(entry.name);
    if (entry.kind == null ||
        parsed == null ||
        isGalNonVoiceBasename(parsed.basename)) {
      return;
    }
    final _IndexedVoice voice = _IndexedVoice(
      entry: entry,
      parsed: parsed,
      ordinal: ordinal ?? _nextOrdinal++,
    );
    _voicesByPath[key] = voice;
    _voicesByModified
        .putIfAbsent(
          entry.modified.microsecondsSinceEpoch,
          () => <_IndexedVoice>[],
        )
        .add(voice);
    if (entry.kind == GalVoiceDumpKind.wav) {
      _addToTickIndex(_wavByTick, voice);
      if (parsed.textEventId != null) {
        _wavByEvent
            .putIfAbsent(
              parsed.textEventId!,
              () => <_IndexedVoice>[],
            )
            .add(voice);
      }
    } else if (parsed.textEventId != null) {
      _oggByEvent
          .putIfAbsent(
            parsed.textEventId!,
            () => <_IndexedVoice>[],
          )
          .add(voice);
    } else {
      _addToTickIndex(_oggUnmarkedByTick, voice);
    }
  }

  int? _removeEntry(String key) {
    _entriesByPath.remove(key);
    final _IndexedVoice? voice = _voicesByPath.remove(key);
    if (voice == null) return null;
    final int modified = voice.entry.modified.microsecondsSinceEpoch;
    final List<_IndexedVoice>? modifiedValues = _voicesByModified[modified];
    modifiedValues?.remove(voice);
    if (modifiedValues != null && modifiedValues.isEmpty) {
      _voicesByModified.remove(modified);
    }
    if (voice.entry.kind == GalVoiceDumpKind.wav) {
      _removeFromTickIndex(_wavByTick, voice);
      final int? eventId = voice.parsed.textEventId;
      if (eventId != null) _removeFromEventIndex(_wavByEvent, eventId, voice);
    } else {
      final int? eventId = voice.parsed.textEventId;
      if (eventId != null) {
        _removeFromEventIndex(_oggByEvent, eventId, voice);
      } else {
        _removeFromTickIndex(_oggUnmarkedByTick, voice);
      }
    }
    return voice.ordinal;
  }

  void _addToTickIndex(
    SplayTreeMap<int, List<_IndexedVoice>> index,
    _IndexedVoice voice,
  ) {
    index
        .putIfAbsent(
          voice.parsed.tick,
          () => <_IndexedVoice>[],
        )
        .add(voice);
  }

  void _removeFromTickIndex(
    SplayTreeMap<int, List<_IndexedVoice>> index,
    _IndexedVoice voice,
  ) {
    final List<_IndexedVoice>? values = index[voice.parsed.tick];
    values?.remove(voice);
    if (values != null && values.isEmpty) index.remove(voice.parsed.tick);
  }

  void _removeFromEventIndex(
    Map<int, List<_IndexedVoice>> index,
    int eventId,
    _IndexedVoice voice,
  ) {
    final List<_IndexedVoice>? values = index[eventId];
    values?.remove(voice);
    if (values != null && values.isEmpty) index.remove(eventId);
  }

  void _publishSnapshot() {
    _snapshot = GalVoiceDumpSnapshot.fromEntries(
      revision: ++_revision,
      entries: _entriesByPath.values.toList(growable: false),
    );
  }

  String _absoluteWatchPath(String path) {
    final File file = File(path);
    if (file.isAbsolute) return file.path;
    return '${directory.path}${Platform.pathSeparator}$path';
  }

  static String _pathKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  static Future<List<GalVoiceDumpEntry>> _loadDirectory(
    Directory directory,
  ) async {
    if (!await directory.exists()) return const <GalVoiceDumpEntry>[];
    final List<GalVoiceDumpEntry> entries = <GalVoiceDumpEntry>[];
    await for (final FileSystemEntity entity in directory.list(
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final GalVoiceDumpEntry? entry = await _loadFile(entity.path);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  static Future<GalVoiceDumpEntry?> _loadFile(String path) async {
    final File file = File(path);
    final FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;
    final String name = _fileBaseName(file.path);
    final String lower = name.toLowerCase();
    final GalVoiceDumpKind? kind =
        lower.endsWith('.ogg') || lower.endsWith('.xwma')
            ? GalVoiceDumpKind.oggLike
            : lower.endsWith('.wav')
                ? GalVoiceDumpKind.wav
                : null;
    return GalVoiceDumpEntry(
      name: name,
      path: file.path,
      modified: stat.modified,
      kind: kind,
    );
  }

  static Stream<FileSystemEvent> _watchDirectory(Directory directory) =>
      directory.watch(events: FileSystemEvent.all);

  static String _fileBaseName(String path) {
    final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
