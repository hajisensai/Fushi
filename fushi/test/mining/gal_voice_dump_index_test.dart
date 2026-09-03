import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_voice_dump_index.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart'
    show pickPairedGameResources;

import '../helpers/source_guard.dart';

void main() {
  late Directory tempDirectory;
  late StreamController<FileSystemEvent> changes;
  late List<GalVoiceDumpEntry> nextEntries;
  late Map<String, GalVoiceDumpEntry> incrementalEntries;
  late List<Completer<List<GalVoiceDumpEntry>>> blockedScans;
  late GalVoiceDumpIndex index;
  late GalVoiceDumpEntry Function(String name) entry;
  int scanCalls = 0;
  int watcherCalls = 0;
  int entryLoadCalls = 0;

  setUp(() async {
    scanCalls = 0;
    watcherCalls = 0;
    entryLoadCalls = 0;
    tempDirectory = await Directory.systemTemp.createTemp(
      'fushi-voice-dump-index-test-',
    );
    entry = (String name) => _entry(
          name,
          path: '${tempDirectory.path}${Platform.pathSeparator}$name',
        );
    changes = StreamController<FileSystemEvent>.broadcast(sync: true);
    nextEntries = <GalVoiceDumpEntry>[];
    incrementalEntries = <String, GalVoiceDumpEntry>{};
    blockedScans = <Completer<List<GalVoiceDumpEntry>>>[];
    index = GalVoiceDumpIndex(
      directory: tempDirectory,
      loader: (_) {
        scanCalls++;
        if (blockedScans.isNotEmpty) return blockedScans.removeAt(0).future;
        return Future<List<GalVoiceDumpEntry>>.value(nextEntries);
      },
      entryLoader: (String path) {
        entryLoadCalls++;
        final GalVoiceDumpEntry? template =
            incrementalEntries[_fileBaseName(path)];
        return Future<GalVoiceDumpEntry?>.value(
          template == null
              ? null
              : GalVoiceDumpEntry(
                  name: template.name,
                  path: path,
                  modified: template.modified,
                  kind: template.kind,
                ),
        );
      },
      watcher: (_) {
        watcherCalls++;
        return changes.stream;
      },
      eventDebounce: Duration.zero,
    );
  });

  tearDown(() async {
    await index.stopSession();
    await changes.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'stable session shares one scan across concurrent and repeated polls',
    () async {
      final Completer<List<GalVoiceDumpEntry>> initial =
          Completer<List<GalVoiceDumpEntry>>();
      blockedScans.add(initial);

      final List<Future<void>> starts = <Future<void>>[
        for (int i = 0; i < 64; i++) index.startSession(),
      ];
      await _waitUntil(() => scanCalls == 1);
      initial.complete(const <GalVoiceDumpEntry>[]);
      await Future.wait(starts);

      for (int i = 0; i < 1000; i++) {
        index.requestFreshness();
        expect(index.snapshot.voiceEntries, isEmpty);
      }
      await index.synchronize();

      expect(scanCalls, 1);
    },
  );

  test('same-count replacement invalidates a cached snapshot', () async {
    nextEntries = <GalVoiceDumpEntry>[entry('100_old.xwma')];
    await index.startSession();
    expect(index.snapshot.byName, contains('100_old.xwma'));
    expect(scanCalls, 1);

    incrementalEntries['200_new.xwma'] = entry('200_new.xwma');
    changes.add(
      FileSystemMoveEvent(
        entry('100_old.xwma').path,
        false,
        entry('200_new.xwma').path,
      ),
    );
    await index.synchronize();

    expect(index.snapshot.byName, isNot(contains('100_old.xwma')));
    expect(index.snapshot.byName, contains('200_new.xwma'));
    expect(scanCalls, 1);
    expect(entryLoadCalls, 1);
  });

  test('change observed during a scan forces a second generation', () async {
    final Completer<List<GalVoiceDumpEntry>> first =
        Completer<List<GalVoiceDumpEntry>>();
    blockedScans.add(first);
    final Future<void> starting = index.startSession();
    await _waitUntil(() => scanCalls == 1);

    incrementalEntries['300_after_event.wav'] = entry('300_after_event.wav');
    changes.add(
      FileSystemMoveEvent(
        entry('100_before_event.wav').path,
        false,
        entry('300_after_event.wav').path,
      ),
    );
    first.complete(<GalVoiceDumpEntry>[entry('100_before_event.wav')]);
    await starting;

    expect(scanCalls, 1);
    expect(entryLoadCalls, 1);
    expect(index.snapshot.byName, contains('300_after_event.wav'));
    expect(index.snapshot.byName, isNot(contains('100_before_event.wav')));
  });

  test('stop and restart reject an old scan completion', () async {
    final Completer<List<GalVoiceDumpEntry>> oldScan =
        Completer<List<GalVoiceDumpEntry>>();
    blockedScans.add(oldScan);
    final Future<void> oldStart = index.startSession();
    await _waitUntil(() => scanCalls == 1);

    await index.stopSession();
    nextEntries = <GalVoiceDumpEntry>[entry('400_new_session.ogg')];
    await index.startSession();
    expect(scanCalls, 2);
    expect(index.snapshot.byName, contains('400_new_session.ogg'));

    oldScan.complete(<GalVoiceDumpEntry>[entry('100_old_session.ogg')]);
    await oldStart;

    expect(index.snapshot.byName, contains('400_new_session.ogg'));
    expect(index.snapshot.byName, isNot(contains('100_old_session.ogg')));
  });

  test('old synchronize cannot interfere with a restarted session', () async {
    final Completer<List<GalVoiceDumpEntry>> oldScan =
        Completer<List<GalVoiceDumpEntry>>();
    final Completer<List<GalVoiceDumpEntry>> newScan =
        Completer<List<GalVoiceDumpEntry>>();
    blockedScans.addAll(<Completer<List<GalVoiceDumpEntry>>>[
      oldScan,
      newScan,
    ]);

    final Future<void> oldStart = index.startSession();
    await _waitUntil(() => scanCalls == 1);
    final Future<void> oldSynchronize = index.synchronize();

    await index.stopSession();
    final Future<void> newStart = index.startSession();
    await _waitUntil(() => scanCalls == 2);

    final GalVoiceDumpEntry eventEntry = entry('500_new_event.xwma');
    incrementalEntries[eventEntry.name] = eventEntry;
    changes.add(FileSystemCreateEvent(eventEntry.path, false));

    oldScan.complete(<GalVoiceDumpEntry>[entry('100_old_session.xwma')]);
    await Future.wait(<Future<void>>[oldStart, oldSynchronize]);

    newScan.complete(<GalVoiceDumpEntry>[entry('400_new_session.xwma')]);
    await newStart;
    await index.synchronize();

    expect(scanCalls, 2);
    expect(entryLoadCalls, 1);
    expect(index.snapshot.byName, contains('400_new_session.xwma'));
    expect(index.snapshot.byName, contains(eventEntry.name));
    expect(index.snapshot.byName, isNot(contains('100_old_session.xwma')));
  });

  test('late synchronization cannot resurrect a stopped session', () async {
    nextEntries = <GalVoiceDumpEntry>[entry('100_active_session.ogg')];
    await index.startSession();
    expect(scanCalls, 1);
    expect(watcherCalls, 1);

    await index.stopSession();
    nextEntries = <GalVoiceDumpEntry>[entry('200_after_stop.ogg')];
    index
      ..requestFreshness()
      ..invalidate();
    await index.synchronize();

    expect(scanCalls, 1);
    expect(watcherCalls, 1);
    expect(index.snapshot.entries, isEmpty);
  });

  test('watch failure recovers with an asynchronous full rebuild', () async {
    nextEntries = <GalVoiceDumpEntry>[entry('100_before_error.xwma')];
    await index.startSession();
    expect(scanCalls, 1);

    nextEntries = <GalVoiceDumpEntry>[entry('200_after_error.xwma')];
    changes.addError(FileSystemException('synthetic watch failure'));
    index.requestFreshness();
    await index.synchronize();

    expect(scanCalls, 2);
    expect(index.snapshot.byName, contains('200_after_error.xwma'));
  });

  test('one file event does not rescan a 1000-entry directory', () async {
    nextEntries = <GalVoiceDumpEntry>[
      for (int i = 0; i < 1000; i++) entry('${100000 + i}_voice_$i.xwma'),
    ];
    await index.startSession();
    expect(scanCalls, 1);

    final GalVoiceDumpEntry added = entry('200000_new_voice.xwma');
    incrementalEntries[added.name] = added;
    changes.add(FileSystemCreateEvent(added.path, false));
    await index.synchronize();

    expect(scanCalls, 1,
        reason: 'normal file events must not list/stat all N files');
    expect(entryLoadCalls, 1, reason: 'only the changed path may be statted');
    expect(index.snapshot.entries, hasLength(1001));
    expect(index.snapshot.byName, contains(added.name));
  });

  test('incremental matcher preserves the established pairing rules', () async {
    const List<String> oggNames = <String>[
      '9780_legacy.ogg',
      '10000_same_tick_b.ogg',
      '10000_same_tick_a.ogg',
      '9987_fushi_textseq16_onna.ogg',
      '9950_fushi_textseq16_otoko.ogg',
      '9990_bgm_theme.ogg',
    ];
    const List<String> wavNames = <String>[
      '10040_unity.wav',
      '9900_fushi_textseq7_a.wav',
      '10100_fushi_textseq7_b.wav',
    ];
    nextEntries = <GalVoiceDumpEntry>[
      for (final String name in oggNames) entry(name),
      for (final String name in wavNames) entry(name),
    ];
    await index.startSession();

    for (final ({int timestampMs, int? eventId}) query
        in <({int timestampMs, int? eventId})>[
      (timestampMs: 10000, eventId: 7),
      (timestampMs: 10000, eventId: null),
      (timestampMs: 12000, eventId: null),
    ]) {
      expect(
        index.findPairedResourceNames(
          textTsMs: query.timestampMs,
          textEventId: query.eventId,
        ),
        pickPairedGameResources(
          oggFileNames: oggNames,
          wavFileNames: wavNames,
          textTsMs: query.timestampMs,
          textEventId: query.eventId,
        ),
      );
    }

    for (final String name in wavNames) {
      changes.add(FileSystemDeleteEvent(entry(name).path, false));
    }
    await index.synchronize();
    for (final ({int timestampMs, int? eventId}) query
        in <({int timestampMs, int? eventId})>[
      (timestampMs: 10000, eventId: 16),
      (timestampMs: 10000, eventId: null),
    ]) {
      expect(
        index.findPairedResourceNames(
          textTsMs: query.timestampMs,
          textEventId: query.eventId,
        ),
        pickPairedGameResources(
          oggFileNames: oggNames,
          wavFileNames: const <String>[],
          textTsMs: query.timestampMs,
          textEventId: query.eventId,
        ),
      );
    }
  });

  test('pairing hot path only reads the in-memory snapshot', () {
    final String source = _packageFile(
      'lib/src/mining/galgame_audio_source.dart',
    );
    final String body = methodBody(source, 'List<File> _findPairedVoiceFiles(');

    expect(body, contains('_voiceDumpIndex.findPairedResourceNames'));
    expect(body, contains('_voicePairingCache[query]'));
    expect(body, isNot(contains('listSync')));
    expect(body, isNot(contains('statSync')));
  });
}

String _packageFile(String relativePath) {
  final List<Directory> starts = <Directory>[
    File.fromUri(Platform.script).parent,
    Directory.current,
  ];
  for (final Directory start in starts) {
    Directory directory = start;
    for (int depth = 0; depth < 10; depth++) {
      final File candidate = File(
        '${directory.path}${Platform.pathSeparator}$relativePath',
      );
      if (candidate.existsSync() &&
          File(
            '${directory.path}${Platform.pathSeparator}pubspec.yaml',
          ).existsSync()) {
        return candidate.readAsStringSync();
      }
      final Directory parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
  }
  fail('cannot find package source $relativePath from ${Platform.script}');
}

GalVoiceDumpEntry _entry(String name, {required String path}) =>
    GalVoiceDumpEntry(
      name: name,
      path: path,
      modified: DateTime.utc(2026, 8, 23),
      kind: name.endsWith('.wav')
          ? GalVoiceDumpKind.wav
          : GalVoiceDumpKind.oggLike,
    );

String _fileBaseName(String path) {
  final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (int i = 0; i < 100; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition did not become true');
}
