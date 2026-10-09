import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart';
import 'package:media_kit/media_kit.dart';

String snapshot([Map<String, Object> changes = const <String, Object>{}]) =>
    jsonEncode(<String, Object>{
      'version': 1,
      'nav-active': true,
      'menu-active': false,
      'menu-domain': false,
      'title': 3,
      'playlist': 42,
      'position': 12.345,
      'generation': 7,
      'stable': true,
      'bdj-detected': false,
      'bdj-handled': false,
      'angle': 0,
      'menu-call-allowed': true,
      ...changes,
    });

class _Native {
  _Native(this.mpv);
  final _Mpv mpv;
  Pointer<Void> get ctx => nullptr;
}

class _Mpv {
  _Mpv(this.result);
  final int result;
  List<String> received = <String>[];

  // Match libmpv's generated FFI member, including its spelling.
  // ignore: non_constant_identifier_names
  int mpv_command(Pointer<Void> context, Pointer<Pointer<Char>> arguments) {
    received = <String>[];
    for (int i = 0; arguments[i] != nullptr; i++) {
      received.add(arguments[i].cast<Utf8>().toDartString());
    }
    return result;
  }
}

void main() {
  group('resolved disc tracks', () {
    test('auto mode still resolves physical audio 2 and PGS subtitle 1', () {
      final Track logical = Track(
        audio: AudioTrack.auto(),
        subtitle: SubtitleTrack.auto(),
      );
      final List<AudioTrack> audio = <AudioTrack>[
        AudioTrack.auto(),
        AudioTrack.no(),
        const AudioTrack('1', 'Commentary', 'eng'),
        const AudioTrack('2', 'Original', 'jpn'),
      ];
      final VideoDiscResolvedTracks physical = VideoDiscResolvedTracks.fromMpv(
        audioId: '2',
        subtitleId: '1',
        subtitleCodec: 'hdmv_pgs_subtitle',
        stable: true,
      );
      expect(logical.audio.id, 'auto');
      expect(logical.subtitle.codec, isNull);
      expect(physical.audioId, '2');
      expect(physical.subtitleId, '1');
      expect(physical.subtitleCodec, 'hdmv_pgs_subtitle');
      expect(
        videoDiscResolvedTrackOrdinal(
          physical.audioId,
          audio.map((AudioTrack track) => track.id),
        ),
        1,
      );
    });

    test(
      'unknown physical selection never silently chooses the first track',
      () {
        for (final String? id in <String?>[null, 'auto', 'no', '99']) {
          expect(
            videoDiscResolvedTrackOrdinal(id, <String>['auto', 'no', '1', '2']),
            isNull,
          );
        }
        expect(resolvedVideoDiscTrackId('', stable: false), isNull);
        expect(resolvedVideoDiscTrackId('', stable: true), 'no');
        expect(resolvedVideoDiscTrackId('auto', stable: true), isNull);
      },
    );

    test(
      'title switch or replay invalidates an in-flight physical track read',
      () {
        final VideoDiscNavigationState initial = VideoDiscNavigationState.parse(
          snapshot(),
        )!;
        expect(videoDiscTitleIdentityMatches(initial, initial), isTrue);
        for (final Map<String, Object> change in <Map<String, Object>>[
          <String, Object>{'generation': 8},
          <String, Object>{'playlist': 43},
          <String, Object>{'title': 4},
          <String, Object>{'angle': 1},
          <String, Object>{'stable': false},
        ]) {
          expect(
            videoDiscTitleIdentityMatches(
              initial,
              VideoDiscNavigationState.parse(snapshot(change)),
            ),
            isFalse,
          );
        }
      },
    );
  });
  group('atomic Blu-ray navigation identity', () {
    test('uses native MPLS ID rather than edition/title index', () {
      final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
        snapshot(),
      )!;
      expect(state.playlistFileName, '00042.mpls');
      expect(state.title, 3);
      expect(state.generation, 7);
      expect(state.positionSeconds, 12.345);
      expect(state.angle, 0);
      expect(state.allowsStudy, isTrue);
    });

    test('top menu and first play never become study titles', () {
      for (final int title in <int>[0, 65535]) {
        final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
          snapshot(<String, Object>{'title': title, 'menu-domain': true}),
        )!;
        expect(state.playlistFileName, isNull);
        expect(state.allowsStudy, isFalse);
      }
    });

    test('IG popup and demux drain suspend title eligibility', () {
      for (final Map<String, Object> change in <Map<String, Object>>[
        <String, Object>{'menu-active': true, 'menu-domain': true},
        <String, Object>{'stable': false},
        <String, Object>{'playlist': -1},
        <String, Object>{'nav-active': false},
        <String, Object>{'title': -1},
        <String, Object>{'title': 0},
        <String, Object>{'title': 65535},
        <String, Object>{'bdj-detected': true, 'bdj-handled': false},
      ]) {
        final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
          snapshot(change),
        )!;
        expect(state.allowsStudy, isFalse);
      }
    });

    test('rejects unknown versions, malformed data and invalid positions', () {
      expect(VideoDiscNavigationState.parse(''), isNull);
      expect(VideoDiscNavigationState.parse('[]'), isNull);
      for (final Map<String, Object> change in <Map<String, Object>>[
        <String, Object>{'version': 2},
        <String, Object>{'playlist': '../secret'},
        <String, Object>{'playlist': 100000},
        <String, Object>{'generation': -1},
        <String, Object>{'position': -1},
        <String, Object>{'menu-domain': 'no'},
      ]) {
        expect(VideoDiscNavigationState.parse(snapshot(change)), isNull);
      }
    });
  });

  group('disc input commands', () {
    test('checked FFI preserves command args and reports native rejection', () {
      final _Mpv success = _Mpv(0);
      runCheckedVideoDiscCommand(_Native(success), <String>[
        'discnav',
        'popup',
      ]);
      expect(success.received, <String>['discnav', 'popup']);
      expect(
        () => runCheckedVideoDiscCommand(_Native(_Mpv(-12)), <String>[
          'discnav',
          'select',
        ]),
        throwsA(
          isA<VideoDiscMenuException>().having(
            (VideoDiscMenuException error) => error.code,
            'code',
            'command-failed:-12',
          ),
        ),
      );
    });
    test('keyboard and top/popup actions retain upstream semantics', () {
      for (final String action in <String>[
        'up',
        'down',
        'left',
        'right',
        'select',
        'menu',
        'title-menu',
        'popup',
        'prev',
      ]) {
        expect(videoDiscNavigationCommand(action), <String>['discnav', action]);
      }
    });

    test('pointer uses normalized video coordinates including edge pixels', () {
      expect(videoDiscNavigationCommand('mouse-click', x: 0, y: 1), <String>[
        'discnav',
        'mouse-click',
        '0.0',
        '1.0',
      ]);
      expect(videoDiscNavigationCommand('mouse-move', x: .25, y: .75), <String>[
        'discnav',
        'mouse-move',
        '0.25',
        '0.75',
      ]);
    });

    test(
      'rejects unknown commands and letterbox/outside pointer positions',
      () {
        expect(() => videoDiscNavigationCommand('shell'), throwsArgumentError);
        expect(
          () => videoDiscNavigationCommand('mouse-click'),
          throwsArgumentError,
        );
        for (final double invalid in <double>[
          -.1,
          1.1,
          double.nan,
          double.infinity,
        ]) {
          expect(
            () => videoDiscNavigationCommand('mouse-click', x: invalid, y: .5),
            throwsArgumentError,
          );
        }
      },
    );
  });

  group('enter actual top menu', () {
    test(
      'pure BD-J top menu is interactive without MPLS or presentation time',
      () {
        final VideoDiscNavigationState top = VideoDiscNavigationState.parse(
          snapshot(<String, Object>{
            'title': 0,
            'playlist': -1,
            'position': -9223372036854775808.0,
            'stable': false,
            'menu-domain': true,
            'menu-active': true,
            'bdj-detected': true,
            'bdj-handled': true,
            'menu-call-allowed': false,
          }),
        )!;
        expect(top.playlist, isNull);
        expect(top.positionSeconds, isNegative);
        expect(
          videoDiscMenuEntryAction(top, requested: false),
          VideoDiscMenuEntryAction.complete,
        );
        expect(top.isTitle, isFalse);
        expect(top.allowsStudy, isFalse);
        expect(top.playlistFileName, isNull);
        expect(videoDiscTitleIdentityMatches(top, top), isFalse);
      },
    );

    test(
      'missing Java, background, non-top and unstable MPLS cannot complete BD-J entry',
      () {
        final Map<String, Object> pureTop = <String, Object>{
          'title': 0,
          'playlist': -1,
          'position': -1,
          'stable': false,
          'menu-domain': true,
          'menu-active': true,
          'bdj-detected': true,
          'bdj-handled': true,
        };
        for (final Map<String, Object> change in <Map<String, Object>>[
          <String, Object>{'bdj-handled': false},
          <String, Object>{'menu-active': false},
          <String, Object>{'menu-domain': false},
          <String, Object>{'nav-active': false},
          <String, Object>{'title': 1},
          <String, Object>{'playlist': 42},
        ]) {
          final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
            snapshot(<String, Object>{...pureTop, ...change}),
          )!;
          expect(
            videoDiscMenuEntryAction(state, requested: false),
            VideoDiscMenuEntryAction.wait,
            reason: '$change',
          );
          expect(state.isTitle, isFalse);
          expect(state.allowsStudy, isFalse);
        }
      },
    );

    test(
      'negative presentation time stays invalid for stable movie playback',
      () {
        expect(
          VideoDiscNavigationState.parse(
            snapshot(<String, Object>{'position': -1, 'stable': true}),
          ),
          isNull,
        );
        final VideoDiscNavigationState draining =
            VideoDiscNavigationState.parse(
              snapshot(<String, Object>{'position': -1, 'stable': false}),
            )!;
        expect(draining.isTitle, isFalse);
        expect(draining.allowsStudy, isFalse);
        expect(
          videoDiscMenuEntryAction(draining, requested: false),
          VideoDiscMenuEntryAction.wait,
        );
      },
    );

    test(
      'first-play with UOP waits for permission instead of failing or retrying',
      () {
        final VideoDiscNavigationState blocked = VideoDiscNavigationState.parse(
          snapshot(<String, Object>{
            'title': 65535,
            'menu-domain': true,
            'menu-call-allowed': false,
          }),
        )!;
        expect(
          videoDiscMenuEntryAction(blocked, requested: false),
          VideoDiscMenuEntryAction.wait,
        );
        final VideoDiscNavigationState allowed = VideoDiscNavigationState.parse(
          snapshot(<String, Object>{'title': 65535, 'menu-domain': true}),
        )!;
        expect(
          videoDiscMenuEntryAction(allowed, requested: false),
          VideoDiscMenuEntryAction.requestTopMenu,
        );
        expect(
          videoDiscMenuEntryAction(allowed, requested: true),
          VideoDiscMenuEntryAction.wait,
        );
      },
    );

    test(
      'author auto-started movie still requests menu and never completes intent',
      () {
        final VideoDiscNavigationState movie = VideoDiscNavigationState.parse(
          snapshot(),
        )!;
        expect(
          videoDiscMenuEntryAction(movie, requested: false),
          VideoDiscMenuEntryAction.requestTopMenu,
        );
        expect(
          videoDiscMenuEntryAction(movie, requested: true),
          VideoDiscMenuEntryAction.wait,
        );
      },
    );

    test(
      'top background or popup is not proof of the requested interactive top menu',
      () {
        for (final Map<String, Object> change in <Map<String, Object>>[
          <String, Object>{'title': 0, 'menu-domain': true},
          <String, Object>{
            'title': 1,
            'menu-domain': true,
            'menu-active': true,
          },
          <String, Object>{
            'title': 0,
            'menu-domain': true,
            'menu-active': true,
            'stable': false,
          },
        ]) {
          final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
            snapshot(change),
          )!;
          expect(
            videoDiscMenuEntryAction(state, requested: true),
            VideoDiscMenuEntryAction.wait,
          );
        }
      },
    );

    test(
      'interactive stable top menu completes without a redundant command',
      () {
        final VideoDiscNavigationState top = VideoDiscNavigationState.parse(
          snapshot(<String, Object>{
            'title': 0,
            'menu-domain': true,
            'menu-active': true,
          }),
        )!;
        expect(
          videoDiscMenuEntryAction(top, requested: false),
          VideoDiscMenuEntryAction.complete,
        );
        expect(
          videoDiscMenuEntryAction(top, requested: true),
          VideoDiscMenuEntryAction.complete,
        );
      },
    );
  });

  group('disc versus Fushi track ownership', () {
    test(
      'Fushi override returns ownership on interactive menu, including same MPLS',
      () {
        final VideoDiscNavigationState movie = VideoDiscNavigationState.parse(
          snapshot(),
        )!;
        final VideoDiscNavigationState menu = VideoDiscNavigationState.parse(
          snapshot(<String, Object>{
            'title': 0,
            'menu-domain': true,
            'menu-active': true,
          }),
        )!;
        expect(
          menu.playlist,
          movie.playlist,
        ); // This must not depend on MPLS change.
        expect(
          shouldReturnDiscTrackOwnership(
            owner: VideoDiscTrackOwner.fushi,
            previous: movie,
            next: menu,
          ),
          isTrue,
        );
        // After returning, rebinding the same movie cannot claim ownership again
        // or overwrite what the disc just selected with a stored Off/external cue.
        expect(
          shouldReturnDiscTrackOwnership(
            owner: VideoDiscTrackOwner.disc,
            previous: menu,
            next: movie,
          ),
          isFalse,
        );
      },
    );

    test(
      'an explicit Fushi selection inside an already visible menu remains explicit',
      () {
        final VideoDiscNavigationState menu = VideoDiscNavigationState.parse(
          snapshot(<String, Object>{
            'title': 0,
            'menu-domain': true,
            'menu-active': true,
          }),
        )!;
        expect(
          shouldReturnDiscTrackOwnership(
            owner: VideoDiscTrackOwner.fushi,
            previous: menu,
            next: menu,
          ),
          isFalse,
        );
      },
    );

    test(
      'background-only menu and ordinary subtitles do not reclaim ownership',
      () {
        final VideoDiscNavigationState movie = VideoDiscNavigationState.parse(
          snapshot(),
        )!;
        final VideoDiscNavigationState background =
            VideoDiscNavigationState.parse(
              snapshot(<String, Object>{'title': 0, 'menu-domain': true}),
            )!;
        for (final VideoDiscNavigationState next in <VideoDiscNavigationState>[
          movie,
          background,
        ]) {
          expect(
            shouldReturnDiscTrackOwnership(
              owner: VideoDiscTrackOwner.fushi,
              previous: movie,
              next: next,
            ),
            isFalse,
          );
        }
      },
    );
  });
}
