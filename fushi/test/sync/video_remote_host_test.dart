import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

void main() {
  late FushiDatabase db;
  late FavoriteSentenceRepository favorites;
  late VideoRemoteHost host;
  late _Player player;
  late DateTime now;
  late Map<String, Object?> snapshot;
  int serial = 0;

  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) => host.handle(operation, <String, dynamic>{
    'sessionId': snapshot['sessionId'],
    'subtitleVersion': snapshot['subtitleVersion'],
    'requestId': 'request_${++serial}',
    ...data,
  }, 'phone');

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    favorites = _BlockingFavorites(db);
    now = DateTime(2026, 10, 12);
    player = _Player();
    host = VideoRemoteHost(favorites: () => favorites, now: () => now);
    host.register(player.binding);
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
  });

  test('lookup pauses and only resumes playback it owns', () async {
    final Map<String, Object?> lookup = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    expect(player.playing, false);
    expect(player.commands, <String>['pause']);
    await call('lookupEnd', <String, dynamic>{
      'contextId': lookup['contextId'],
    });
    expect(player.playing, true);
    expect(player.commands, <String>['pause', 'play']);

    player.playing = false;
    player.notify();
    final Map<String, Object?> paused = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    await call('lookupEnd', <String, dynamic>{
      'contextId': paused['contextId'],
    });
    expect(player.playing, false);
    expect(player.commands, <String>['pause', 'play']);
  });

  test(
    'switching rows with replaceContextId hands the pause over without resuming',
    () async {
      final Map<String, Object?> first = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'primary'},
      );
      expect(player.commands, <String>['pause']);
      final Map<String, Object?> second = await call(
        'lookupBegin',
        <String, dynamic>{
          'cueId': 'secondary',
          'replaceContextId': first['contextId'],
        },
      );
      // No resume-then-pause: the desktop never plays between the two lookups.
      expect(player.commands, <String>['pause']);
      expect(player.playing, isFalse);
      // The old context is gone; ending it is a no-op.
      await call('lookupEnd', <String, dynamic>{
        'contextId': first['contextId'],
      });
      expect(player.commands, <String>['pause']);
      // The new lookup owns the pause and resumes it on close.
      await call('lookupEnd', <String, dynamic>{
        'contextId': second['contextId'],
      });
      expect(player.commands, <String>['pause', 'play']);
      expect(player.playing, isTrue);
    },
  );

  test(
    'an audition before the row switch is rewound, not resumed, on handover',
    () async {
      player.seekMs = 1500;
      final Map<String, Object?> first = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'primary'},
      );
      await call('lookupContext', <String, dynamic>{
        'contextId': first['contextId'],
        'action': 'previewAudio',
      });
      player.playing = true; // audition still running
      player.commands.clear();
      final Map<String, Object?> second = await call(
        'lookupBegin',
        <String, dynamic>{
          'cueId': 'secondary',
          'replaceContextId': first['contextId'],
        },
      );
      expect(player.previews.last, 'stop');
      expect(player.commands, <String>['seek']);
      expect(player.seekMs, 1500);
      expect(player.playing, isFalse);
      await call('lookupEnd', <String, dynamic>{
        'contextId': second['contextId'],
      });
      expect(player.commands, <String>['seek', 'play']);
      expect(player.playing, isTrue);
    },
  );

  test(
    'without replaceContextId (older phones) the previous lookup ends first',
    () async {
      await call('lookupBegin', <String, dynamic>{'cueId': 'primary'});
      await call('lookupBegin', <String, dynamic>{'cueId': 'secondary'});
      expect(player.commands, <String>['pause', 'play', 'pause']);
      expect(player.playing, isFalse);
    },
  );

  test(
    'a local intent before the row switch is not handed over as owned pause',
    () async {
      final Map<String, Object?> first = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'primary'},
      );
      // Someone at the desktop paused explicitly: that pause is theirs.
      await player.command('pause', <String, dynamic>{});
      final Map<String, Object?> second = await call(
        'lookupBegin',
        <String, dynamic>{
          'cueId': 'secondary',
          'replaceContextId': first['contextId'],
        },
      );
      await call('lookupEnd', <String, dynamic>{
        'contextId': second['contextId'],
      });
      expect(player.commands, <String>['pause', 'pause']);
      expect(player.playing, isFalse);
    },
  );

  test(
    'reported error clears after the next successful operation or session',
    () async {
      host.reportError('favorite_source_unavailable');
      Map<String, Object?> state = await host.handle(
        'snapshot',
        <String, dynamic>{},
        'phone',
      );
      expect(state['error'], 'favorite_source_unavailable');
      // A rejected operation does not acknowledge the failure.
      await expectLater(
        call('command', <String, dynamic>{'action': 'bogus'}),
        throwsA(isA<VideoRemoteException>()),
      );
      state = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      expect(state['error'], 'favorite_source_unavailable');
      await call('command', <String, dynamic>{'action': 'pause'});
      state = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      expect(state.containsKey('error'), isFalse);
      final Map<String, Object?> events = await call(
        'events',
        <String, dynamic>{'afterRevision': 0, 'waitMs': 0},
      );
      final Map<String, Object?> last =
          ((events['events']! as List).last as Map)['payload']!
              as Map<String, Object?>;
      expect(last.containsKey('error'), isFalse);

      host.reportError('favorite_subtitle_ambiguous');
      player.identity = 'episode-two';
      player.notify();
      state = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      expect(state.containsKey('error'), isFalse);
    },
  );

  group('lookupContext (adjust sentence context)', () {
    // Four primary rows around one secondary row: the context must stay on
    // the anchor's own track, in time order.
    Future<String> begin(String cueId) async {
      player.cues = const <VideoRemoteCue>[
        VideoRemoteCue(
          id: 'p0',
          text: '零',
          startMs: 0,
          endMs: 900,
          delayMs: 0,
          track: 'primary',
        ),
        VideoRemoteCue(
          id: 'p1',
          text: '一',
          startMs: 1000,
          endMs: 1900,
          delayMs: 0,
          track: 'primary',
        ),
        VideoRemoteCue(
          id: 's1',
          text: 'one',
          startMs: 1000,
          endMs: 1900,
          delayMs: 0,
          track: 'secondary',
        ),
        VideoRemoteCue(
          id: 'p2',
          text: '二',
          startMs: 2000,
          endMs: 2900,
          delayMs: 0,
          track: 'primary',
        ),
        VideoRemoteCue(
          id: 'p3',
          text: '三',
          startMs: 3000,
          endMs: 3900,
          delayMs: 0,
          track: 'primary',
        ),
      ];
      player.notify();
      snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': cueId},
      );
      return lookup['contextId']! as String;
    }

    Future<Map<String, Object?>> context(
      String contextId,
      String action, [
      Map<String, dynamic> args = const <String, dynamic>{},
    ]) => call('lookupContext', <String, dynamic>{
      'contextId': contextId,
      'action': action,
      ...args,
    });

    test(
      'set / edit / remove drive the draft and the card follows it',
      () async {
        final String id = await begin('p1');
        Map<String, Object?> preview = await context(id, 'preview');
        expect(preview['current'], '一');
        expect(preview['prev'], isEmpty);
        expect(preview['total'], 0);

        preview = await context(id, 'set', <String, dynamic>{
          'prev': 5,
          'next': 2,
        });
        // Clamped at the track edges; the secondary row never joins.
        expect(preview['prev'], <String>['零']);
        expect(preview['next'], <String>['二', '三']);
        expect(preview['total'], 3);

        preview = await context(id, 'edit', <String, dynamic>{
          'slot': 'next',
          'index': 0,
          'text': '二（改）',
        });
        expect(preview['next'], <String>['二（改）', '三']);
        preview = await context(id, 'remove', <String, dynamic>{
          'slot': 'next',
          'index': 1,
          'removed': true,
        });
        expect(preview['nextRemoved'], <bool>[false, true]);
        expect(preview['total'], 2);

        await call('mine', <String, dynamic>{
          'contextId': id,
          'fields': <String, dynamic>{
            'rawFields': <String, dynamic>{'expression': '一'},
          },
        });
        final VideoRemoteMineSelection selection = player.minedSelection!;
        expect(player.minedCue!.id, 'p1');
        expect(selection.adjusted, isTrue);
        expect(selection.sentence, '零\n一\n二（改）');
        expect(selection.cueSentence, selection.sentence);
        // First kept row start -> last kept row end; the removed row is out.
        expect(selection.startMs, 0);
        expect(selection.endMs, 2900);

        // Later edits do not reach an accepted card; success consumes the draft.
        await context(id, 'set', <String, dynamic>{'prev': 0, 'next': 0});
        expect(player.minedSelection!.sentence, '零\n一\n二（改）');
        await context(id, 'set', <String, dynamic>{'prev': 1, 'next': 0});
        player.mining.complete(<String, Object?>{'success': true});
        await Future<void>.delayed(Duration.zero);
        preview = await context(id, 'preview');
        expect(preview['total'], 0);
        expect(preview['prev'], isEmpty);
      },
    );

    test('without context the card is the looked-up row', () async {
      final String id = await begin('p2');
      await call('mine', <String, dynamic>{
        'contextId': id,
        'fields': <String, dynamic>{
          'rawFields': <String, dynamic>{'expression': '二'},
        },
      });
      final VideoRemoteMineSelection selection = player.minedSelection!;
      expect(selection.adjusted, isFalse);
      expect(selection.sentence, '二');
      expect(selection.startMs, 2000);
      expect(selection.endMs, 2900);
    });

    test('audio preview plays the composed span on the desktop', () async {
      final String id = await begin('p1');
      await context(id, 'set', <String, dynamic>{'prev': 0, 'next': 1});
      final Map<String, Object?> played = await context(id, 'previewAudio');
      expect(played['played'], isTrue);
      final Map<String, Object?> stopped = await context(id, 'stopAudio');
      expect(stopped['played'], isFalse);
      expect(player.previews, <String>['p1:1000-2900', 'stop']);
      // Previewing is not an explicit playback command: the lookup survives.
      expect((await context(id, 'preview'))['total'], 1);
    });

    test(
      'closing after an audition restores the paused playhead and resumes',
      () async {
        player.seekMs = 1500;
        final String id = await begin('p1');
        expect(player.playing, isFalse);
        await context(id, 'set', <String, dynamic>{'prev': 1, 'next': 0});
        await context(id, 'previewAudio');
        // The audition stops by itself at the span end. That automatic stop
        // does not move the revision (the real controller is checked below).
        player.playing = false;
        player.seekMs = 1900;
        player.commands.clear();
        await call('lookupEnd', <String, dynamic>{'contextId': id});
        expect(player.commands, <String>['seek', 'play']);
        expect(player.seekMs, 1500);
        expect(player.playing, isTrue);
      },
    );

    test(
      'closing mid-audition stops it and keeps a paused video paused',
      () async {
        player.playing = false;
        player.seekMs = 1200;
        final String id = await begin('p1');
        await context(id, 'previewAudio');
        player.playing = true; // audition still running
        player.commands.clear();
        await call('lookupEnd', <String, dynamic>{'contextId': id});
        expect(player.previews.last, 'stop');
        expect(player.commands, <String>['seek']);
        expect(player.seekMs, 1200);
      },
    );

    test(
      'a local drag or play after an audition is never overridden on close',
      () async {
        player.seekMs = 1500;
        final String id = await begin('p1');
        await context(id, 'previewAudio');
        player.playing = false; // the audition stopped at the span end
        player.seekMs = 1900;
        // Someone at the desktop drags the progress bar and plays on.
        await player.command('seek', <String, dynamic>{'positionMs': 5000});
        await player.command('play', <String, dynamic>{});
        player.commands.clear();
        player.previews.clear();
        await call('lookupEnd', <String, dynamic>{'contextId': id});
        expect(player.commands, isEmpty);
        expect(player.previews, isEmpty);
        expect(player.seekMs, 5000);
        expect(player.playing, isTrue);
      },
    );

    test('lease expiry after an audition keeps a local drag as well', () async {
      player.seekMs = 1500;
      final String id = await begin('p1');
      await context(id, 'previewAudio');
      player.playing = false;
      await player.command('seek', <String, dynamic>{'positionMs': 5000});
      player.commands.clear();
      now = now.add(const Duration(seconds: 36));
      await host.handle('snapshot', <String, dynamic>{}, 'second-phone');
      expect(player.commands, isEmpty);
      expect(player.seekMs, 5000);
      expect(player.playing, isFalse);
    });

    test('stale or malformed requests are refused, never crash', () async {
      final String id = await begin('p1');
      Future<void> refused(Future<Map<String, Object?>> request, String code) =>
          expectLater(
            request,
            throwsA(
              isA<VideoRemoteException>().having(
                (VideoRemoteException e) => e.code,
                'code',
                code,
              ),
            ),
          );
      await refused(context('lookup_bogus', 'preview'), 'lookup_expired');
      await refused(context(id, 'bogus'), 'invalid_action');
      await refused(
        context(id, 'edit', <String, dynamic>{
          'slot': 'nowhere',
          'index': 0,
          'text': 'x',
        }),
        'invalid_argument',
      );
      await refused(
        context(id, 'remove', <String, dynamic>{
          'slot': 'current',
          'index': 0,
          'removed': true,
        }),
        'invalid_argument',
      );
      await refused(
        context(id, 'remove', <String, dynamic>{
          'slot': 'prev',
          'index': 3,
          'removed': true,
        }),
        'invalid_argument',
      );
      await refused(
        context(id, 'set', <String, dynamic>{'prev': '1'}),
        'invalid_number',
      );
      // Subtitles changed under the lookup: the draft is gone with it.
      player.cues = <VideoRemoteCue>[...player.cues.take(2)];
      player.notify();
      await refused(context(id, 'preview'), 'lookup_expired');
      // An ended lookup is expired as well.
      final String next = await begin('p2');
      await call('lookupEnd', <String, dynamic>{'contextId': next});
      await refused(context(next, 'set'), 'lookup_expired');
    });
  });

  test('adapter failure codes reach the mining task', () async {
    final Map<String, Object?> lookup = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    final Map<String, Object?> accepted = await call('mine', <String, dynamic>{
      'contextId': lookup['contextId'],
      'fields': <String, dynamic>{'term': '言葉'},
    });
    player.mining.completeError(
      const VideoRemoteException(409, 'video_extraction_unavailable'),
    );
    await Future<void>.delayed(Duration.zero);
    final Map<String, Object?> status = await call(
      'mineStatus',
      <String, dynamic>{'taskId': accepted['taskId']},
    );
    expect(status['status'], 'failed');
    expect(status['error'], 'video_extraction_unavailable');
  });

  test(
    'desktop toggle on the real player controller cancels lookup resume',
    () async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      player.revisionSource = () => controller.remoteControlRevision;
      player.onCommand = (String action) async {
        if (action == 'pause') await controller.pause();
        if (action == 'play') await controller.play();
      };
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'primary'},
      );
      expect(player.playing, false);
      // The desktop shortcut / subtitle-list paths use togglePlayPause().
      // Toggling twice returns to paused without any state the phone owns.
      await controller.togglePlayPause();
      player.playing = true;
      await controller.togglePlayPause();
      player.playing = false;
      await call('lookupEnd', <String, dynamic>{
        'contextId': lookup['contextId'],
      });
      expect(player.playing, false);
      expect(player.commands, <String>['pause']);

      // Every other public transport entry is an explicit intent as well.
      for (final Future<void> Function() intent in <Future<void> Function()>[
        controller.play,
        controller.pause,
        controller.playOrPause,
        controller.togglePlayPause,
        () => controller.seekMs(1000),
        () => controller.seekRelative(1000),
        () async => controller.notifyExternalSeek(500),
      ]) {
        final int before = controller.remoteControlRevision;
        await intent();
        expect(controller.remoteControlRevision, greaterThan(before));
      }
    },
  );

  test(
    'the automatic span-end stop of a replay does not count as a local intent',
    () async {
      AudioCue cue(int index, int start, int end) => AudioCue()
        ..bookKey = 'video/1'
        ..chapterHref = 'video://default'
        ..sentenceIndex = index
        ..textFragmentId = ''
        ..text = 'line$index'
        ..startMs = start
        ..endMs = end
        ..audioFileIndex = 0;
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[cue(0, 0, 1000), cue(1, 1001, 2000)]);
      // The phone's audition is a replay: its seek and play are intents.
      final int beforeReplay = controller.remoteControlRevision;
      await controller.replayCue(controller.cues[0]);
      final int afterReplay = controller.remoteControlRevision;
      expect(afterReplay, greaterThan(beforeReplay));
      // Crossing the span end pauses and parks on the cue end by itself.
      controller.debugUpdateCueForPosition(900);
      controller.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.debugOneShotHoldCueIndex, isNull);
      expect(controller.remoteControlRevision, afterReplay);
      // A pause or seek from the desktop afterwards still counts.
      await controller.seekMs(5000);
      expect(controller.remoteControlRevision, greaterThan(afterReplay));
    },
  );

  test('snapshot includes the selected episode identity', () {
    expect(snapshot['identity'], 'book-one');
    expect(snapshot['sectionIndex'], 0);
  });

  test('favorite read cannot attach an old cue to a changed session', () async {
    final _BlockingFavorites repo = favorites as _BlockingFavorites;
    repo.readStarted = Completer<void>();
    repo.readGate = Completer<void>();
    final Completer<void> gate = repo.readGate!;
    final Future<Map<String, Object?>> pending = call(
      'favoriteSet',
      <String, dynamic>{'cueId': 'primary', 'favorited': true},
    );
    final Future<void> rejected = expectLater(
      pending,
      throwsA(
        isA<VideoRemoteException>().having(
          (VideoRemoteException error) => error.code,
          'code',
          'session_changed',
        ),
      ),
    );
    await repo.readStarted!.future;
    player.identity = 'episode-two';
    player.sectionIndex = 1;
    player.notify();
    gate.complete();
    await rejected;
    expect(await FavoriteSentenceRepository(db).getAll(), isEmpty);
  });

  test(
    'favorite read cannot write after the controller lease is released',
    () async {
      final _BlockingFavorites repo = favorites as _BlockingFavorites;
      repo.readStarted = Completer<void>();
      repo.readGate = Completer<void>();
      final Completer<void> gate = repo.readGate!;
      final Future<void> rejected = expectLater(
        call('favoriteSet', <String, dynamic>{
          'cueId': 'primary',
          'favorited': true,
        }),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'controller_lease_lost',
          ),
        ),
      );
      await repo.readStarted!.future;
      await host.releaseController();
      gate.complete();
      await rejected;
      expect(await FavoriteSentenceRepository(db).getAll(), isEmpty);
    },
  );

  test(
    'expiry during an in-flight lookup pause restores only that pause',
    () async {
      player.pauseStarted = Completer<void>();
      player.pauseGate = Completer<void>();
      final Future<void> rejected = expectLater(
        call('lookupBegin', <String, dynamic>{'cueId': 'primary'}),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'controller_lease_lost',
          ),
        ),
      );
      await player.pauseStarted!.future;
      now = now.add(const Duration(seconds: 36));
      await host.handle('snapshot', <String, dynamic>{}, 'second-phone');
      player.pauseGate!.complete();
      await rejected;
      expect(player.playing, true);
      expect(player.commands, <String>['pause', 'play']);
    },
  );

  test(
    'release and reacquire by the same peer invalidates an in-flight pause',
    () async {
      player.pauseStarted = Completer<void>();
      player.pauseGate = Completer<void>();
      final Future<void> rejected = expectLater(
        call('lookupBegin', <String, dynamic>{'cueId': 'primary'}),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'controller_lease_lost',
          ),
        ),
      );
      await player.pauseStarted!.future;
      await host.releaseController();
      await host.handle('snapshot', <String, dynamic>{}, 'phone');
      player.pauseGate!.complete();
      await rejected;
      expect(player.playing, true);
    },
  );

  test(
    'a local pause during pending lookup prevents expiry recovery play',
    () async {
      player.pauseStarted = Completer<void>();
      player.pauseGate = Completer<void>();
      final Future<void> rejected = expectLater(
        call('lookupBegin', <String, dynamic>{'cueId': 'primary'}),
        throwsA(isA<VideoRemoteException>()),
      );
      await player.pauseStarted!.future;
      final Future<void> localPause = player.command(
        'pause',
        <String, dynamic>{},
      );
      now = now.add(const Duration(seconds: 36));
      await host.handle('snapshot', <String, dynamic>{}, 'second-phone');
      player.pauseGate!.complete();
      await localPause;
      await rejected;
      expect(player.playing, false);
      expect(player.commands, <String>['pause', 'pause']);
    },
  );

  test('manual playback intent cancels automatic resume', () async {
    final Map<String, Object?> lookup = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    await player.command('pause', <String, dynamic>{});
    await call('lookupEnd', <String, dynamic>{
      'contextId': lookup['contextId'],
    });
    expect(player.playing, false);
    expect(player.commands, <String>['pause', 'pause']);
  });

  test('old session and changed subtitle clock reject stale cues', () async {
    player.identity = 'episode-two';
    player.notify();
    await expectLater(
      call('command', <String, dynamic>{
        'action': 'seekCue',
        'cueId': 'primary',
      }),
      throwsA(
        isA<VideoRemoteException>().having(
          (VideoRemoteException e) => e.code,
          'code',
          'session_changed',
        ),
      ),
    );
    expect(player.seekMs, isNull);
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
    player.cues = List<VideoRemoteCue>.of(player.cues);
    player.notify();
    await expectLater(
      call('command', <String, dynamic>{
        'action': 'seekCue',
        'cueId': 'primary',
      }),
      throwsA(
        isA<VideoRemoteException>().having(
          (VideoRemoteException e) => e.code,
          'code',
          'subtitles_changed',
        ),
      ),
    );
  });

  test('secondary cue seeks with its own delay', () async {
    await call('command', <String, dynamic>{
      'action': 'seekCue',
      'cueId': 'secondary',
    });
    expect(player.seekMs, 4500);
    expect(player.playing, true);
  });

  test(
    '35 second lease expiry restores owned pause before handing over',
    () async {
      await call('lookupBegin', <String, dynamic>{'cueId': 'primary'});
      now = now.add(const Duration(seconds: 36));
      await host.handle('snapshot', <String, dynamic>{}, 'second-phone');
      expect(player.playing, true);
      await expectLater(
        call('favorites'),
        throwsA(isA<VideoRemoteException>()),
      );
    },
  );

  test(
    'mining retry invokes extraction/write once and task remains queryable',
    () async {
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'secondary'},
      );
      final Map<String, dynamic> request = <String, dynamic>{
        'requestId': 'one-mine',
        'contextId': lookup['contextId'],
        'fields': <String, dynamic>{'term': '言葉'},
      };
      final Map<String, Object?> first = await call('mine', request);
      final Map<String, Object?> retry = await call('mine', request);
      expect(first['taskId'], retry['taskId']);
      expect(player.mineCalls, 1);
      expect(player.minedCue!.id, 'secondary');
      expect(player.minedCue!.delayMs, 1500);
      await call('lookupEnd', <String, dynamic>{
        'contextId': lookup['contextId'],
      });
      player.mining.complete(<String, Object?>{'success': true, 'noteId': 123});
      await Future<void>.delayed(Duration.zero);
      final Map<String, Object?> result = await call(
        'mineStatus',
        <String, dynamic>{'taskId': first['taskId']},
      );
      expect(result['status'], 'succeeded');
      expect((result['result']! as Map)['noteId'], 123);
    },
  );

  test(
    'favorites persist in real DB, repeated set is idempotent and bulk remove deletes',
    () async {
      await call('favoriteSet', <String, dynamic>{
        'cueId': 'primary',
        'favorited': true,
      });
      await call('favoriteSet', <String, dynamic>{
        'cueId': 'primary',
        'favorited': true,
      });
      final List<FavoriteSentence> stored = await FavoriteSentenceRepository(
        db,
      ).getAll();
      expect(stored, hasLength(1));
      expect(stored.single.bookKey, 'book-one');
      expect(stored.single.source, kFavoriteSentenceSourceVideo);
      expect(stored.single.normCharOffset, 1000);
      expect(stored.single.dateKey, FushiDatabase.statDateKeyOf(now));
      final Map<String, Object?> list = await call(
        'favorites',
        <String, dynamic>{'query': '一番'},
      );
      expect(list['total'], 1);
      await call('favoritesRemove', <String, dynamic>{
        'ids': <String>[stored.single.id],
      });
      expect(await FavoriteSentenceRepository(db).getAll(), isEmpty);
    },
  );

  test(
    'retained mining task deduplicates after generic request eviction',
    () async {
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'primary'},
      );
      final Map<String, dynamic> request = <String, dynamic>{
        'requestId': 'retained-mine',
        'contextId': lookup['contextId'],
        'fields': <String, dynamic>{'term': '言葉'},
      };
      final Map<String, Object?> accepted = await call('mine', request);
      player.mining.complete(<String, Object?>{'success': true, 'noteId': 123});
      await Future<void>.delayed(Duration.zero);
      for (int index = 0; index < 128; index++) {
        await call('lookupEnd', <String, dynamic>{
          'contextId': 'other-context',
        });
      }
      await expectLater(
        call('mine', <String, dynamic>{
          ...request,
          'fields': <String, dynamic>{'term': '別の言葉'},
        }),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'request_id_conflict',
          ),
        ),
      );
      final Map<String, Object?> retry = await call('mine', request);
      expect(retry['taskId'], accepted['taskId']);
      expect(retry['status'], 'succeeded');
      expect(player.mineCalls, 1);
    },
  );
}

final class _BlockingFavorites extends FavoriteSentenceRepository {
  _BlockingFavorites(FushiDatabase db) : super(db);
  Completer<void>? readStarted;
  Completer<void>? readGate;

  @override
  Future<List<FavoriteSentence>> getAll() async {
    final Completer<void>? gate = readGate;
    if (gate != null) {
      readGate = null;
      readStarted!.complete();
      await gate.future;
    }
    return super.getAll();
  }
}

final class _Player {
  String identity = 'episode-one';
  int sectionIndex = 0;
  bool playing = true;
  int controlRevision = 0;
  int Function()? revisionSource;
  Future<void> Function(String action)? onCommand;
  int? seekMs;
  int mineCalls = 0;
  VideoRemoteCue? minedCue;
  VideoRemoteMineSelection? minedSelection;
  final List<String> previews = <String>[];
  final List<String> commands = <String>[];
  final List<VoidCallback> listeners = <VoidCallback>[];
  final Completer<Map<String, Object?>> mining =
      Completer<Map<String, Object?>>();
  Completer<void>? pauseStarted;
  Completer<void>? pauseGate;
  List<VideoRemoteCue> cues = const <VideoRemoteCue>[
    VideoRemoteCue(
      id: 'primary',
      text: '一番の言葉',
      startMs: 1000,
      endMs: 2000,
      delayMs: 0,
      track: 'primary',
    ),
    VideoRemoteCue(
      id: 'secondary',
      text: '第二の言葉',
      startMs: 3000,
      endMs: 4000,
      delayMs: 1500,
      track: 'secondary',
    ),
  ];

  late final VideoRemotePlaybackBinding binding = VideoRemotePlaybackBinding(
    identity: () => identity,
    title: () => 'Test video',
    bookUid: () => 'book-one',
    sectionIndex: () => sectionIndex,
    cues: () => cues,
    state: () => <String, Object?>{
      'playing': playing,
      'positionMs': seekMs ?? 0,
      'speed': 1.0,
      'controlRevision': revisionSource?.call() ?? controlRevision,
    },
    command: command,
    mine:
        (
          VideoRemoteCue cue,
          Map<String, dynamic> fields,
          VideoRemoteMineSelection selection,
        ) {
          mineCalls++;
          minedCue = cue;
          minedSelection = selection;
          return mining.future;
        },
    previewAudio: (VideoRemoteCue anchor, int startMs, int endMs) async {
      previews.add('${anchor.id}:$startMs-$endMs');
      // Like the real replay: seek to the span and play (two intents).
      controlRevision += 2;
      playing = true;
      return true;
    },
    stopAudio: () async {
      previews.add('stop');
      // Like the real stop (`controller.pause`): an intent that pauses.
      controlRevision++;
      playing = false;
    },
    openFavorite: (FavoriteSentence favorite) async {
      seekMs = favorite.normCharOffset;
      notify();
    },
    addListener: listeners.add,
    removeListener: listeners.remove,
  );

  Future<void> command(String action, Map<String, dynamic> data) async {
    commands.add(action);
    controlRevision++;
    await onCommand?.call(action);
    if (action == 'pause') {
      playing = false;
      if (pauseStarted != null && !pauseStarted!.isCompleted) {
        pauseStarted!.complete();
      }
      await pauseGate?.future;
    }
    if (action == 'play' || action == 'seekCue') playing = true;
    if (data['positionMs'] is int) seekMs = data['positionMs'] as int;
    notify();
  }

  void notify() {
    for (final VoidCallback listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }
}
