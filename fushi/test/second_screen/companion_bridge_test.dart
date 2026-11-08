import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_second_screen_platform.dart';

class _FakeNowPlaying extends ChangeNotifier
    implements CompanionNowPlayingSource {
  CompanionNowPlaying? value;
  int toggles = 0;

  void set(CompanionNowPlaying? next) {
    value = next;
    notifyListeners();
  }

  @override
  CompanionNowPlaying? get current => value;

  @override
  Future<void> toggle() async => toggles++;
}

void main() {
  late Map<String, Object?> prefs;
  late FakeSecondScreenPlatform platform;
  late SecondScreenHost host;
  late SecondScreenController controller;
  late ValueNotifier<HomeTab> tab;
  late CompanionContextRegistry contexts;
  late _FakeNowPlaying nowPlaying;
  late Directory spill;
  late CompanionBridge bridge;
  late int collected;
  late StateError? summaryError;
  late List<String> opened;
  late int unclaimedCounts;
  late List<String?> mined;

  CompanionDailySummary summaryFor(int n) =>
      CompanionDailySummary(dayKey: 'd', readingMs: n);

  setUp(() async {
    prefs = <String, Object?>{
      kSecondScreenModePrefKey: SecondScreenMode.always.name,
    };
    platform = FakeSecondScreenPlatform(
      displays: <SecondScreenDisplayInfo>[thorBottomScreen],
    );
    host = SecondScreenHost(platform);
    controller = SecondScreenController(
      readPref: (String k) => prefs[k],
      writePref: (String k, Object? v) async => prefs[k] = v,
      host: host,
    );
    tab = ValueNotifier<HomeTab>(HomeTab.home);
    contexts = CompanionContextRegistry(homeTab: tab);
    nowPlaying = _FakeNowPlaying();
    spill = await Directory.systemTemp.createTemp('companion_bridge');
    collected = 0;
    summaryError = null;
    opened = <String>[];
    unclaimedCounts = 0;
    mined = <String?>[];
    bridge = CompanionBridge(
      host: host,
      controller: controller,
      contexts: contexts,
      collectSummary: () async {
        collected++;
        final StateError? error = summaryError;
        if (error != null) throw error;
        return summaryFor(collected);
      },
      nowPlaying: nowPlaying,
      countUnclaimedLookup: () => unclaimedCounts++,
      onMined: mined.add,
      spillRoot: spill,
    )..bindOpenLink((String link) async => opened.add(link));
    bridge.start();
    await controller.start();
  });

  tearDown(() async {
    bridge.dispose();
    controller.dispose();
    host.dispose();
    contexts.dispose();
    tab.dispose();
    nowPlaying.dispose();
    if (spill.existsSync()) await spill.delete(recursive: true);
  });

  /// Messages the bridge sent to the panel since the last call.
  List<CompanionHostMessage> drain() {
    final List<CompanionHostMessage> out = <CompanionHostMessage>[
      for (final String raw in platform.sent) CompanionHostMessage.decode(raw),
    ];
    platform.sent.clear();
    return out;
  }

  Future<void> fromPanel(CompanionPanelMessage message) async {
    platform.emit(SecondScreenPanelMessageReceived(message.encode()));
    await pumpEventQueue();
  }

  Future<void> ready() async {
    await fromPanel(const CompanionReadyMessage());
  }

  test('the companion is active; nothing is sent before the panel is '
      'ready', () async {
    expect(bridge.isActive, isTrue);
    contexts.claim(
      Object(),
      const CompanionContext(CompanionContextKind.video),
    );
    bridge.notifyPrefsChanged();
    await pumpEventQueue();
    expect(platform.sent, isEmpty);
    expect(await bridge.sendLookup(text: '猫'), isFalse);
    expect(collected, 0);
  });

  test('ready: context, what plays and the summary', () async {
    nowPlaying.value = const CompanionNowPlaying(
      kind: CompanionNowPlayingKind.music,
      title: 'song',
      playing: true,
    );
    await ready();
    final List<CompanionHostMessage> sent = drain();
    expect(
      (sent[0] as CompanionUiRestoreMessage).state,
      const CompanionPanelUiState(),
    );
    expect(sent[1], isA<CompanionContextMessage>());
    expect(
      (sent[1] as CompanionContextMessage).context.kind,
      CompanionContextKind.home,
    );
    expect((sent[2] as CompanionNowPlayingMessage).nowPlaying?.title, 'song');
    expect((sent[3] as CompanionSummaryMessage).summary, summaryFor(1));
    expect(sent, hasLength(4));

    // A second "ready" (a new panel) gets everything again.
    await ready();
    expect(drain().map((CompanionHostMessage m) => m.runtimeType), <Type>[
      CompanionUiRestoreMessage,
      CompanionContextMessage,
      CompanionNowPlayingMessage,
      CompanionSummaryMessage,
    ]);
  });

  test('the panel UI state outlives the panel: kept from its reports, '
      'handed to the next panel first on ready', () async {
    await ready();
    drain();
    const CompanionPanelUiState state = CompanionPanelUiState(
      tab: 'library',
      libraryMode: 'browse',
      librarySection: 'manga',
      libraryQuery: 'ナルト',
      settingsCategory: 'reading',
      settingsQuery: 'font',
    );
    await fromPanel(
      const CompanionUiStateMessage(CompanionPanelUiState(tab: 'settings')),
    );
    await fromPanel(const CompanionUiStateMessage(state));
    expect(bridge.panelUiState, state);
    expect(drain(), isEmpty, reason: 'nothing is echoed back');

    // The top activity stopped: the panel finished; a new one starts.
    await controller.setMode(SecondScreenMode.off);
    await controller.setMode(SecondScreenMode.always);
    await pumpEventQueue();
    drain();
    await ready();
    final List<CompanionHostMessage> sent = drain();
    expect((sent.first as CompanionUiRestoreMessage).state, state);
    expect(sent[1], isA<CompanionContextMessage>());
  });

  test('context changes and the owner\'s snapshots follow', () async {
    await ready();
    drain();
    final Object page = Object();
    contexts.claim(page, const CompanionContext(CompanionContextKind.reader));
    contexts.publishSnapshot(page, <String, Object?>{'page': 4});
    await pumpEventQueue();
    final List<CompanionHostMessage> sent = drain();
    expect(
      (sent[0] as CompanionContextMessage).context.kind,
      CompanionContextKind.reader,
    );
    final CompanionSnapshotMessage snap = sent[1] as CompanionSnapshotMessage;
    expect(snap.kind, CompanionContextKind.reader);
    expect(snap.data, <String, Object?>{'page': 4});

    // A new panel gets the context and the last snapshot.
    await ready();
    final List<CompanionHostMessage> again = drain();
    expect(again[0], isA<CompanionUiRestoreMessage>());
    expect(again[1], isA<CompanionContextMessage>());
    expect(again[2], isA<CompanionSnapshotMessage>());

    tab.value = HomeTab.video;
    contexts.release(page);
    await pumpEventQueue();
    final CompanionContextMessage back =
        drain().single as CompanionContextMessage;
    expect(back.context.library, CompanionLibraryKind.video);
  });

  test('inactive (setting off): nothing is sent, even on ready', () async {
    await controller.setMode(SecondScreenMode.off);
    expect(bridge.isActive, isFalse);
    await ready();
    expect(platform.sent, isEmpty);
    expect(collected, 0);
  });

  test('commands go to the owner of the matching context', () async {
    final List<String> got = <String>[];
    contexts.claim(
      Object(),
      const CompanionContext(CompanionContextKind.video),
      onCommand: (String action, Map<String, Object?> args) => got.add(action),
    );
    await ready();
    await fromPanel(
      const CompanionCommandMessage(
        kind: CompanionContextKind.video,
        action: 'playPause',
      ),
    );
    await fromPanel(
      const CompanionCommandMessage(
        kind: CompanionContextKind.reader,
        action: 'turnPage',
      ),
    );
    expect(got, <String>['playPause']);
  });

  test('open on main: only widget deep links are followed', () async {
    await ready();
    await fromPanel(const CompanionOpenOnMainMessage('fushi://widget/srs'));
    await fromPanel(const CompanionOpenOnMainMessage('https://example.com'));
    await fromPanel(const CompanionOpenOnMainMessage('fushi://auth/x'));
    expect(opened, <String>['fushi://widget/srs']);
  });

  test('playback toggles what plays; changes of it are pushed', () async {
    await ready();
    drain();
    await fromPanel(
      const CompanionPlaybackMessage(CompanionPlaybackAction.toggle),
    );
    expect(nowPlaying.toggles, 1);
    nowPlaying.set(
      const CompanionNowPlaying(
        kind: CompanionNowPlayingKind.audiobook,
        title: 'book',
        playing: false,
      ),
    );
    // The same value again is not resent.
    nowPlaying.set(
      const CompanionNowPlaying(
        kind: CompanionNowPlayingKind.audiobook,
        title: 'book',
        playing: false,
      ),
    );
    await pumpEventQueue();
    final List<CompanionHostMessage> sent = drain();
    expect(sent, hasLength(1));
    expect(
      (sent.single as CompanionNowPlayingMessage).nowPlaying?.title,
      'book',
    );
  });

  test('requests: registered handler, unknown method, failing handler, '
      'summary refresh', () async {
    bridge.registerRequestHandler(
      'echo',
      (Map<String, Object?> args) async => <String, Object?>{'got': args['x']},
    );
    bridge.registerRequestHandler(
      'boom',
      (Map<String, Object?> args) async => throw StateError('bad'),
    );
    await ready();
    drain();
    await fromPanel(
      const CompanionRequestMessage(
        id: 1,
        method: 'echo',
        args: <String, Object?>{'x': 5},
      ),
    );
    await fromPanel(const CompanionRequestMessage(id: 2, method: 'nope'));
    await fromPanel(const CompanionRequestMessage(id: 3, method: 'boom'));
    await fromPanel(
      const CompanionRequestMessage(
        id: 4,
        method: CompanionRequestMethods.refreshSummary,
      ),
    );
    final List<CompanionHostMessage> sent = drain();
    final Map<int, CompanionReplyMessage> replies =
        <int, CompanionReplyMessage>{
          for (final CompanionReplyMessage r
              in sent.whereType<CompanionReplyMessage>())
            r.id: r,
        };
    expect(replies[1]!.value, <String, Object?>{'got': 5});
    expect(replies[1]!.error, isNull);
    expect(replies[2]!.error, contains('unknown method'));
    expect(replies[3]!.error, contains('bad'));
    expect(replies[4]!.error, isNull);
    expect(
      sent.whereType<CompanionSummaryMessage>().single.summary,
      summaryFor(2),
    );
  });

  test('a summary that cannot be collected is sent as failed', () async {
    summaryError = StateError('db closed');
    await ready();
    final CompanionSummaryMessage failed = drain()
        .whereType<CompanionSummaryMessage>()
        .single;
    expect(failed.summary, isNull);
  });

  test('pings: several pref changes send one; library changes refresh the '
      'summary now, or after media closes', () async {
    await ready();
    drain();
    bridge
      ..notifyPrefsChanged()
      ..notifyPrefsChanged()
      ..notifyPrefsChanged();
    await pumpEventQueue();
    expect(drain().single, isA<CompanionPrefsChangedMessage>());

    bridge.notifyLibraryChanged();
    await pumpEventQueue();
    List<CompanionHostMessage> sent = drain();
    expect(sent[0], isA<CompanionLibraryChangedMessage>());
    expect((sent[1] as CompanionSummaryMessage).summary, summaryFor(2));

    // Media on top: the summary is not shown, so it is only marked stale.
    final Object reader = Object();
    contexts.claim(reader, const CompanionContext(CompanionContextKind.reader));
    bridge
      ..notifyLibraryChanged()
      ..notifyReviewsChanged();
    await pumpEventQueue();
    sent = drain();
    expect(sent.whereType<CompanionSummaryMessage>(), isEmpty);
    expect(collected, 2);

    contexts.release(reader);
    await pumpEventQueue();
    sent = drain();
    expect(sent[0], isA<CompanionContextMessage>());
    expect((sent[1] as CompanionSummaryMessage).summary, summaryFor(3));
  });

  test('lookups go to the panel only while it is up and ready', () async {
    await ready();
    drain();
    expect(await bridge.sendLookup(text: '  '), isFalse);
    expect(
      await bridge.sendLookup(text: '猫がいる', charIndex: 0, sentence: '猫がいる。'),
      isTrue,
    );
    final CompanionLookupMessage lookup =
        drain().single as CompanionLookupMessage;
    expect(lookup.text, '猫がいる');
    expect(lookup.sentence, '猫がいる。');

    await fromPanel(const CompanionLookupStateMessage(open: true, term: '猫'));
    expect(bridge.lookupOpen, isTrue);

    // The panel goes away: lookups fall back to the page, state resets.
    platform.detach();
    expect(bridge.isActive, isFalse);
    expect(bridge.lookupOpen, isFalse);
    expect(await bridge.sendLookup(text: '猫'), isFalse);
  });

  test('S6: companion lookups are counted by the page on top, else '
      'unattributed; a mined card is reported once', () async {
    await ready();
    drain();
    int pageCounts = 0;
    final Object reader = Object();
    contexts.claim(
      reader,
      const CompanionContext(CompanionContextKind.reader),
      onLookupCounted: () => pageCounts++,
    );
    await fromPanel(const CompanionLookupCountedMessage());
    expect(pageCounts, 1);
    expect(unclaimedCounts, 0);

    contexts.release(reader);
    await fromPanel(const CompanionLookupCountedMessage());
    expect(pageCounts, 1);
    expect(unclaimedCounts, 1);

    await fromPanel(const CompanionLookupStateMessage(open: true, term: '猫'));
    await fromPanel(
      const CompanionLookupStateMessage(open: true, term: '猫', mined: true),
    );
    expect(mined, <String?>['猫']);
  });

  test(
    'S6: the controller sink reaches the panel only while it is up',
    () async {
      await ready();
      drain();
      expect(contexts.controller, same(bridge));
      expect(bridge.sendPanelNav(CompanionPanelNav.begin), isTrue);
      expect(
        bridge.sendLookupAction(
          CompanionLookupActions.scroll,
          <String, Object?>{CompanionLookupActions.dy: 12.0},
        ),
        isTrue,
      );
      await pumpEventQueue();
      final List<CompanionHostMessage> sent = drain();
      expect(
        (sent[0] as CompanionPanelNavMessage).action,
        CompanionPanelNav.begin,
      );
      final CompanionLookupActionMessage action =
          sent[1] as CompanionLookupActionMessage;
      expect(action.action, CompanionLookupActions.scroll);
      expect(action.args[CompanionLookupActions.dy], 12.0);

      platform.detach();
      expect(contexts.controller, isNull);
      expect(bridge.sendPanelNav(CompanionPanelNav.up), isFalse);
    },
  );

  test('pages route lookups through the registry: active mirrors the '
      'controller, the sink is the bridge', () async {
    await ready();
    drain();
    expect(contexts.active.value, isTrue);
    expect(await contexts.routeLookup(text: '猫がいる', charIndex: 0), isTrue);
    expect((drain().single as CompanionLookupMessage).text, '猫がいる');
    platform.detach();
    expect(contexts.active.value, isFalse);
    expect(await contexts.routeLookup(text: '猫'), isFalse);
    expect(drain(), isEmpty);
  });
}
