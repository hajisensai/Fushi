import 'package:test/test.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';

CompanionHostMessage _host(CompanionHostMessage message) =>
    CompanionHostMessage.decode(message.encode());

CompanionPanelMessage _panel(CompanionPanelMessage message) =>
    CompanionPanelMessage.decode(message.encode());

const CompanionDailySummary _fullSummary = CompanionDailySummary(
  dayKey: '2026-11-07',
  readingMs: 52 * 60000,
  watchingMs: 24 * 60000,
  listeningMs: 18 * 60000,
  gamesMs: 5000,
  srsDue: CompanionSrsDue(newCount: 12, learnCount: 4, reviewCount: 47),
  continueItem: CompanionContinueItem(
    kind: CompanionContinueKind.book,
    title: 'こころ',
    subtitle: '夏目漱石',
    progress: 0.34,
    coverPath: '/covers/kokoro.jpg',
    link: 'fushi://widget/continue?kind=book&id=abc',
  ),
);

void main() {
  group('main -> panel round trips', () {
    test('context with library and title', () {
      const CompanionContext context = CompanionContext(
        CompanionContextKind.library,
        library: CompanionLibraryKind.manga,
        title: 'x',
      );
      final CompanionHostMessage back = _host(
        const CompanionContextMessage(context),
      );
      expect(back, isA<CompanionContextMessage>());
      expect((back as CompanionContextMessage).context, context);
    });

    test('snapshot keeps its kind and data', () {
      final CompanionHostMessage back = _host(
        const CompanionSnapshotMessage(
          kind: CompanionContextKind.reader,
          data: <String, Object?>{
            'page': 3,
            'title': '猫',
            'nested': <String, Object?>{'a': true},
          },
        ),
      );
      final CompanionSnapshotMessage snap = back as CompanionSnapshotMessage;
      expect(snap.kind, CompanionContextKind.reader);
      expect(snap.data['page'], 3);
      expect(snap.data['title'], '猫');
      expect(snap.data['nested'], <String, Object?>{'a': true});
    });

    test('a full summary and a failed (null) one', () {
      final CompanionSummaryMessage full =
          _host(const CompanionSummaryMessage(_fullSummary))
              as CompanionSummaryMessage;
      expect(full.summary, _fullSummary);

      final CompanionSummaryMessage failed =
          _host(const CompanionSummaryMessage(null)) as CompanionSummaryMessage;
      expect(failed.summary, isNull);
    });

    test('a summary without review or continue keeps them absent', () {
      const CompanionDailySummary bare = CompanionDailySummary(
        dayKey: '2026-11-07',
      );
      final CompanionSummaryMessage back =
          _host(const CompanionSummaryMessage(bare)) as CompanionSummaryMessage;
      expect(back.summary, bare);
      expect(back.summary!.srsDue, isNull);
      expect(back.summary!.continueItem, isNull);
      expect(back.summary!.continueItem?.progress, isNull);
    });

    test('now playing and nothing playing', () {
      const CompanionNowPlaying now = CompanionNowPlaying(
        kind: CompanionNowPlayingKind.audiobook,
        title: '吾輩は猫である',
        subtitle: '夏目漱石',
        playing: true,
      );
      expect(
        (_host(const CompanionNowPlayingMessage(now))
                as CompanionNowPlayingMessage)
            .nowPlaying,
        now,
      );
      expect(
        (_host(const CompanionNowPlayingMessage(null))
                as CompanionNowPlayingMessage)
            .nowPlaying,
        isNull,
      );
    });

    test('lookup, pings and replies', () {
      final CompanionLookupMessage lookup =
          _host(
                const CompanionLookupMessage(
                  text: '猫がいる',
                  charIndex: 1,
                  sentence: '庭に猫がいる。',
                ),
              )
              as CompanionLookupMessage;
      expect(lookup.text, '猫がいる');
      expect(lookup.charIndex, 1);
      expect(lookup.sentence, '庭に猫がいる。');
      expect(
        _host(const CompanionPrefsChangedMessage()),
        isA<CompanionPrefsChangedMessage>(),
      );
      expect(
        _host(const CompanionLibraryChangedMessage()),
        isA<CompanionLibraryChangedMessage>(),
      );
      final CompanionReplyMessage ok =
          _host(
                const CompanionReplyMessage(
                  id: 7,
                  value: <String, Object?>{
                    'rows': <Object?>[1, 2],
                  },
                ),
              )
              as CompanionReplyMessage;
      expect(ok.id, 7);
      expect(ok.value, <String, Object?>{
        'rows': <Object?>[1, 2],
      });
      expect(ok.error, isNull);
      final CompanionReplyMessage failed =
          _host(const CompanionReplyMessage(id: 8, error: 'nope'))
              as CompanionReplyMessage;
      expect(failed.error, 'nope');
    });

    test('S7j: lookup routing keeps where lookups open', () {
      for (final bool onCompanion in <bool>[true, false]) {
        final CompanionLookupRoutingMessage m =
            _host(CompanionLookupRoutingMessage(onCompanion: onCompanion))
                as CompanionLookupRoutingMessage;
        expect(m.onCompanion, onCompanion);
      }
    });
  });

  group('panel -> main round trips', () {
    test('ready, command, playback, open, request, lookup state', () {
      expect(
        _panel(const CompanionReadyMessage()),
        isA<CompanionReadyMessage>(),
      );
      final CompanionCommandMessage command =
          _panel(
                const CompanionCommandMessage(
                  kind: CompanionContextKind.video,
                  action: 'seek',
                  args: <String, Object?>{'deltaMs': -5000},
                ),
              )
              as CompanionCommandMessage;
      expect(command.kind, CompanionContextKind.video);
      expect(command.action, 'seek');
      expect(command.args, <String, Object?>{'deltaMs': -5000});
      expect(
        (_panel(const CompanionPlaybackMessage(CompanionPlaybackAction.toggle))
                as CompanionPlaybackMessage)
            .action,
        CompanionPlaybackAction.toggle,
      );
      expect(
        (_panel(const CompanionOpenOnMainMessage('fushi://widget/srs'))
                as CompanionOpenOnMainMessage)
            .link,
        'fushi://widget/srs',
      );
      final CompanionRequestMessage request =
          _panel(
                const CompanionRequestMessage(
                  id: 3,
                  method: CompanionRequestMethods.refreshSummary,
                  args: <String, Object?>{'q': 'x'},
                ),
              )
              as CompanionRequestMessage;
      expect(request.id, 3);
      expect(request.method, CompanionRequestMethods.refreshSummary);
      expect(request.args, <String, Object?>{'q': 'x'});
      final CompanionLookupStateMessage state =
          _panel(
                const CompanionLookupStateMessage(
                  open: true,
                  term: '猫',
                  mined: true,
                ),
              )
              as CompanionLookupStateMessage;
      expect(state.open, isTrue);
      expect(state.term, '猫');
      expect(state.mined, isTrue);
    });
  });

  group('robustness', () {
    test('malformed or unknown messages throw FormatException', () {
      expect(() => CompanionHostMessage.decode('[1]'), throwsFormatException);
      expect(
        () => CompanionHostMessage.decode('{"type":"bogus"}'),
        throwsFormatException,
      );
      expect(
        () => CompanionPanelMessage.decode('{"type":"request","id":"x"}'),
        throwsFormatException,
      );
      expect(
        () => CompanionPanelMessage.decode(
          '{"type":"playback","action":"rewind"}',
        ),
        throwsFormatException,
      );
    });

    test('an unknown context kind reads as none; an unknown library as '
        'null', () {
      final CompanionContextMessage back =
          CompanionHostMessage.decode(
                '{"type":"context","context":{"kind":"spaceship",'
                '"library":"comics"}}',
              )
              as CompanionContextMessage;
      expect(back.context.kind, CompanionContextKind.none);
      expect(back.context.library, isNull);
    });

    test('a continue item without a link is dropped, not invented', () {
      final CompanionSummaryMessage back =
          CompanionHostMessage.decode(
                '{"type":"summary","summary":{"day":"d","continue":'
                '{"kind":"book","title":"t"}}}',
              )
              as CompanionSummaryMessage;
      expect(back.summary!.continueItem, isNull);
    });

    test('media kinds are the ones that replace the summary', () {
      expect(
        <CompanionContextKind>[
          for (final CompanionContextKind k in CompanionContextKind.values)
            if (k.isMedia) k,
        ],
        <CompanionContextKind>[
          CompanionContextKind.reader,
          CompanionContextKind.video,
          CompanionContextKind.manga,
          CompanionContextKind.audiobook,
          CompanionContextKind.music,
          CompanionContextKind.srs,
          CompanionContextKind.gameStream,
        ],
      );
    });
  });
}
