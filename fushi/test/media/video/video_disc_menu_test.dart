import 'dart:convert';

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

/// Stands in for media_kit's patched `NativePlayer.commandWithResult`
/// (BUG-3507: async `mpv_command_async`, returns libmpv's result code).
class _Native {
  _Native(this.mpv);
  final _Mpv mpv;

  Future<int> commandWithResult(List<String> args) async {
    mpv.received = List<String>.of(args);
    return mpv.result;
  }
}

class _Mpv {
  _Mpv(this.result);
  final int result;
  List<String> received = <String>[];
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
        <String, Object>{'version': 3},
        // v2 must say which navigation library produced it.
        <String, Object>{'version': 2},
        <String, Object>{'version': 2, 'disc-type': 'hddvd'},
        // A DVD snapshot without its dvd-state branch is not a DVD snapshot.
        <String, Object>{'version': 2, 'disc-type': 'dvd'},
        <String, Object>{'playlist': '../secret'},
        <String, Object>{'playlist': 100000},
        <String, Object>{'generation': -1},
        <String, Object>{'position': -1},
        <String, Object>{'menu-domain': 'no'},
      ]) {
        expect(VideoDiscNavigationState.parse(snapshot(change)), isNull);
      }
    });

    test('a v2 Blu-ray snapshot keeps every v1 meaning', () {
      final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
        snapshot(<String, Object>{'version': 2, 'disc-type': 'bluray'}),
      )!;
      expect(state.discType, VideoDiscType.bluray);
      expect(state.dvd, isNull);
      expect(state.playlistFileName, '00042.mpls');
      expect(state.dvdTitleNumber, isNull);
      expect(state.allowsStudy, isTrue);
    });
  });

  group('atomic DVD navigation identity (snapshot v2)', () {
    Map<String, Object> dvdState([
      Map<String, Object> changes = const <String, Object>{},
    ]) => <String, Object>{
      'domain': 'VTS',
      'vts': 2,
      'title': 4,
      'part': 3,
      'pgc': 1,
      'pg': 3,
      'cell': 5,
      'still': false,
      'button': 0,
      'button-count': 0,
      'title-menu-allowed': true,
      'root-menu-allowed': true,
      ...changes,
    };

    String dvd({
      Map<String, Object> top = const <String, Object>{},
      Map<String, Object> branch = const <String, Object>{},
    }) => snapshot(<String, Object>{
      'version': 2,
      'disc-type': 'dvd',
      'title': 4,
      'playlist': -1,
      'dvd-state': dvdState(branch),
      ...top,
    });

    const Map<String, Object> menu = <String, Object>{
      'domain': 'VMGM',
      'vts': 0,
      'title': 0,
      'part': 0,
      'pgc': 2,
      'pg': 1,
      'cell': 1,
      'still': true,
      'button': 2,
      'button-count': 3,
      'highlight': <String, Object>{
        'x0': 100,
        'y0': 320,
        'x1': 260,
        'y1': 352,
        'palette': <int>[0x00000000, 0xFFFFFFFF, 0xFF1020F0, 0x80FF0000],
      },
    };

    test('title domain binds the VM title, never a playlist', () {
      final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
        dvd(),
      )!;
      expect(state.discType, VideoDiscType.dvd);
      expect(state.dvd!.domain, VideoDvdDomain.title);
      expect(state.dvd!.titleSet, 2);
      expect(state.dvd!.part, 3);
      expect(state.dvd!.programChain, 1);
      expect(state.dvd!.cell, 5);
      expect(state.playlist, isNull);
      expect(state.playlistFileName, isNull);
      expect(state.dvdTitleNumber, 4);
      expect(state.isTitle, isTrue);
      expect(state.allowsStudy, isTrue);
    });

    test('menus parse the live highlight but never become study titles', () {
      final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
        dvd(
          top: <String, Object>{
            'title': 0,
            'menu-active': true,
            'menu-domain': true,
          },
          branch: menu,
        ),
      )!;
      final VideoDvdNavigationState branch = state.dvd!;
      expect(branch.domain, VideoDvdDomain.videoManagerMenu);
      expect(branch.inMenu, isTrue);
      expect(branch.still, isTrue);
      expect(branch.button, 2);
      expect(branch.buttonCount, 3);
      expect(branch.highlight!.x0, 100);
      expect(branch.highlight!.width, 160);
      expect(branch.highlight!.height, 32);
      expect(branch.highlight!.palette, <int>[
        0x00000000,
        0xFFFFFFFF,
        0xFF1020F0,
        0x80FF0000,
      ]);
      expect(state.isTitle, isFalse);
      expect(state.dvdTitleNumber, isNull);
      expect(state.allowsStudy, isFalse);
      // The disc's menu shows: entering the menu is complete without a call.
      expect(
        videoDiscMenuEntryAction(state, requested: false),
        VideoDiscMenuEntryAction.complete,
      );
    });

    test('drain, instability and identity mismatches suspend the title', () {
      for (final String raw in <String>[
        dvd(top: <String, Object>{'stable': false}),
        dvd(top: <String, Object>{'menu-domain': true}),
        dvd(top: <String, Object>{'nav-active': false}),
      ]) {
        final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
          raw,
        )!;
        expect(state.allowsStudy, isFalse, reason: raw);
      }
    });

    test('malformed DVD branches are rejected, not guessed', () {
      for (final String raw in <String>[
        // The top-level title must be the VM title.
        dvd(top: <String, Object>{'title': 5}),
        // A DVD has no MPLS playlist.
        dvd(top: <String, Object>{'playlist': 1}),
        dvd(branch: <String, Object>{'domain': 'BDMV'}),
        // A title number outside the title domain (or none inside it).
        dvd(branch: <String, Object>{'domain': 'VTSM'}),
        dvd(
          top: <String, Object>{'title': 0},
          branch: <String, Object>{'title': 0},
        ),
        dvd(branch: <String, Object>{'title': 100}),
        dvd(branch: <String, Object>{'still': 'yes'}),
        // A focused button needs its rectangle and four colours, and vice versa.
        dvd(branch: <String, Object>{'button': 1, 'button-count': 2}),
        dvd(
          top: <String, Object>{'title': 0},
          branch: <String, Object>{
            ...menu,
            'highlight': <String, Object>{
              'x0': 10,
              'y0': 10,
              'x1': 5,
              'y1': 20,
              'palette': <int>[0, 0, 0, 0],
            },
          },
        ),
        dvd(
          top: <String, Object>{'title': 0},
          branch: <String, Object>{
            ...menu,
            'highlight': <String, Object>{
              'x0': 0,
              'y0': 0,
              'x1': 5,
              'y1': 5,
              'palette': <int>[0, 0, 0],
            },
          },
        ),
        dvd(
          top: <String, Object>{'title': 0},
          branch: <String, Object>{...menu, 'button': 0},
        ),
        dvd(branch: <String, Object>{'button': 4, 'button-count': 3}),
      ]) {
        expect(VideoDiscNavigationState.parse(raw), isNull, reason: raw);
      }
    });

    test('parses the wire libmpv emits on the authored test disc', () {
      // Captured from the Windows libmpv built with this patch on the disc
      // tool/dvd/make_test_dvd.py authors (VMGM title menu, 3 buttons,
      // opaque yellow select colour 255/224/0).
      const String wire =
          '{"version":2,"disc-type":"dvd","nav-active":true,'
          '"menu-active":true,"menu-domain":true,"menu-call-allowed":true,'
          '"title":0,"playlist":-1,"generation":1,"angle":0,'
          '"position":0.339,"stable":true,"bdj-detected":false,'
          '"bdj-handled":false,"src-width":720,"src-height":480,'
          '"dvd-state":{"domain":"VMGM","vts":0,"title":0,"part":0,"pgc":0,'
          '"pg":0,"cell":1,"still":true,"button":1,"button-count":3,'
          '"title-menu-allowed":true,"root-menu-allowed":true,'
          '"highlight":{"x0":80,"y0":360,"x1":240,"y1":400,'
          '"palette":[16777215,4294958848,4294958848,16777215]}}}';
      final VideoDiscNavigationState state = VideoDiscNavigationState.parse(
        wire,
      )!;
      expect(state.discType, VideoDiscType.dvd);
      expect(state.dvd!.domain, VideoDvdDomain.videoManagerMenu);
      expect(state.dvd!.still, isTrue);
      // 255/224/0 through the disc's YCbCr CLUT comes back as 255/223/0.
      expect(state.dvd!.highlight!.palette[1], 0xFFFFDF00);
      expect(state.allowsStudy, isFalse);
      expect(
        videoDiscMenuEntryAction(state, requested: false),
        VideoDiscMenuEntryAction.complete,
      );
    });

    test('title identity follows the PGC, not only the title number', () {
      final VideoDiscNavigationState expected = VideoDiscNavigationState.parse(
        dvd(),
      )!;
      final VideoDiscNavigationState otherPgc = VideoDiscNavigationState.parse(
        dvd(branch: <String, Object>{'pgc': 2}),
      )!;
      final VideoDiscNavigationState bluray = VideoDiscNavigationState.parse(
        snapshot(<String, Object>{'title': 4}),
      )!;
      expect(videoDiscTitleIdentityMatches(expected, expected), isTrue);
      expect(videoDiscTitleIdentityMatches(expected, otherPgc), isFalse);
      expect(videoDiscTitleIdentityMatches(expected, bluray), isFalse);
    });
  });

  group('disc menu key table', () {
    test('every key maps to a discnav action for both disc types', () {
      for (final VideoDiscType type in VideoDiscType.values) {
        for (final VideoDiscMenuKey key in VideoDiscMenuKey.values) {
          final List<String> command = videoDiscMenuKeyCommand(type, key);
          expect(command.first, 'discnav', reason: '$type $key');
        }
      }
      expect(
        videoDiscMenuKeyCommand(VideoDiscType.dvd, VideoDiscMenuKey.topMenu),
        <String>['discnav', 'menu'],
      );
      expect(
        videoDiscMenuKeyCommand(VideoDiscType.dvd, VideoDiscMenuKey.titleMenu),
        <String>['discnav', 'title-menu'],
      );
      expect(
        videoDiscMenuKeyCommand(VideoDiscType.dvd, VideoDiscMenuKey.back),
        <String>['discnav', 'prev'],
      );
      expect(
        videoDiscMenuKeyCommand(VideoDiscType.dvd, VideoDiscMenuKey.popupMenu),
        <String>['discnav', 'popup'],
      );
    });

    test('UI action strings map back to remote keys for dispatch', () {
      for (final VideoDiscMenuKey key in VideoDiscMenuKey.values) {
        final String action =
            videoDiscMenuKeyActions[VideoDiscType.bluray]![key]!;
        expect(videoDiscMenuKeyForAction(action), key, reason: action);
      }
      expect(videoDiscMenuKeyForAction('mouse-click'), isNull);
      expect(videoDiscMenuKeyForAction('nonsense'), isNull);
    });

    test('remote keys stay unchecked inputs; menu calls stay checked', () {
      for (final VideoDiscMenuKey key in <VideoDiscMenuKey>[
        VideoDiscMenuKey.up,
        VideoDiscMenuKey.down,
        VideoDiscMenuKey.left,
        VideoDiscMenuKey.right,
        VideoDiscMenuKey.select,
        VideoDiscMenuKey.back,
        VideoDiscMenuKey.popupMenu,
      ]) {
        expect(
          isVideoDiscInputCommand(
            videoDiscMenuKeyCommand(VideoDiscType.dvd, key),
          ),
          isTrue,
          reason: '$key',
        );
      }
      for (final VideoDiscMenuKey key in <VideoDiscMenuKey>[
        VideoDiscMenuKey.topMenu,
        VideoDiscMenuKey.titleMenu,
      ]) {
        expect(
          isVideoDiscInputCommand(
            videoDiscMenuKeyCommand(VideoDiscType.dvd, key),
          ),
          isFalse,
          reason: '$key',
        );
      }
    });

    test('DVD menu calls follow their own user-operation bits', () {
      final VideoDiscNavigationState dvd = VideoDiscNavigationState.parse(
        snapshot(<String, Object>{
          'version': 2,
          'disc-type': 'dvd',
          'title': 1,
          'playlist': -1,
          'menu-call-allowed': true,
          'dvd-state': <String, Object>{
            'domain': 'VTS',
            'vts': 1,
            'title': 1,
            'part': 1,
            'pgc': 1,
            'pg': 1,
            'cell': 1,
            'still': false,
            'button': 0,
            'button-count': 0,
            'title-menu-allowed': false,
            'root-menu-allowed': true,
          },
        }),
      )!;
      expect(videoDiscMenuKeyAllowed(dvd, VideoDiscMenuKey.topMenu), isTrue);
      expect(videoDiscMenuKeyAllowed(dvd, VideoDiscMenuKey.titleMenu), isFalse);
      expect(videoDiscMenuKeyAllowed(dvd, VideoDiscMenuKey.select), isTrue);
      final VideoDiscNavigationState bluray = VideoDiscNavigationState.parse(
        snapshot(<String, Object>{'menu-call-allowed': false}),
      )!;
      expect(
        videoDiscMenuKeyAllowed(bluray, VideoDiscMenuKey.topMenu),
        isFalse,
      );
      expect(
        videoDiscMenuKeyAllowed(bluray, VideoDiscMenuKey.titleMenu),
        isFalse,
      );
    });
  });

  group('disc input commands', () {
    test(
      'checked command preserves args and reports native rejection',
      () async {
        final _Mpv success = _Mpv(0);
        await runCheckedVideoDiscCommand(_Native(success), <String>[
          'discnav',
          'popup',
        ]);
        expect(success.received, <String>['discnav', 'popup']);
        await expectLater(
          runCheckedVideoDiscCommand(_Native(_Mpv(-12)), <String>[
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
      },
    );
    // BUG-3290: libbluray answers an unconsumed key/click with -1 (popup closed,
    // click outside enabled buttons, BD-J listener returned false); the shipped
    // patch surfaces that as MPV_ERROR_COMMAND. It is a no-op, not an error.
    test(
      'unconsumed remote input is a false result, never an exception',
      () async {
        for (final String action in <String>[
          'up',
          'down',
          'left',
          'right',
          'select',
          'popup',
          'prev',
        ]) {
          final List<String> command = videoDiscNavigationCommand(action);
          expect(isVideoDiscInputCommand(command), isTrue, reason: action);
          expect(
            await runVideoDiscInputCommand(_Native(_Mpv(-12)), command),
            isFalse,
          );
          expect(
            await runVideoDiscInputCommand(_Native(_Mpv(0)), command),
            isTrue,
          );
        }
        final List<String> click = videoDiscNavigationCommand(
          'mouse-click',
          x: .5,
          y: .9,
        );
        expect(isVideoDiscInputCommand(click), isTrue);
        final _Mpv mpv = _Mpv(-12);
        expect(await runVideoDiscInputCommand(_Native(mpv), click), isFalse);
        expect(mpv.received, click);
      },
    );

    test(
      'menu calls stay checked: a refused top menu is still an error',
      () async {
        for (final String action in <String>['menu', 'title-menu']) {
          final List<String> command = videoDiscNavigationCommand(action);
          expect(isVideoDiscInputCommand(command), isFalse);
          expect(
            () => runVideoDiscInputCommand(_Native(_Mpv(0)), command),
            throwsArgumentError,
          );
          await expectLater(
            runCheckedVideoDiscCommand(_Native(_Mpv(-12)), command),
            throwsA(isA<VideoDiscMenuException>()),
          );
        }
        expect(
          isVideoDiscInputCommand(<String>['set', 'disc-menu', 'yes']),
          isFalse,
        );
      },
    );

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
    });

    test('pointer hover never reaches the disc (it selects buttons)', () {
      // libbluray's mouse move selects the button under the pointer and
      // auto-action buttons fire on selection: hovering off an expanded
      // submenu collapsed it. Only clicks are a disc command.
      expect(
        () => videoDiscNavigationCommand('mouse-move', x: .25, y: .75),
        throwsArgumentError,
      );
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
