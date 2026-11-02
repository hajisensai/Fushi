import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/models/game_stream_lookup_layout.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/utils/app_ui_scale.dart'
    show FushiAppUiScaleNeutralizer;
import 'package:fushi/src/platform/game_stream_companion_display_channel.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// Leaving the stream succeeded locally but the host was not told.
class GameStreamLeaveError implements Exception {
  const GameStreamLeaveError(this.cause);
  final Object cause;

  @override
  String toString() => '$cause';
}

/// Stable receiver id for this app process: one phone rejoining its own
/// session keeps the same id, so the host does not see a second client.
final String gameStreamReceiverClientId =
    '${defaultTargetPlatform.name}-${Platform.localHostname}-'
    '${DateTime.now().microsecondsSinceEpoch}';

/// Joins [session] on [client]'s bound [peer], shows [GameStreamPage] until
/// the user leaves, then disconnects and tells the host to stop.
///
/// Join failures throw; a failed stop after leaving throws
/// [GameStreamLeaveError]. Both the library grid and the session list use
/// this one path so settings, lookup and mining behave identically.
Future<void> openGameStreamSession({
  required BuildContext context,
  required SyncRepository repository,
  required FushiGameStreamClient client,
  required FushiClientUrl peer,
  required GameStreamSession session,
  required GameStreamVideoSettings settings,
  String? clientId,
  ValueChanged<GameStreamVideoSettings>? onSettingsChanged,
  GameStreamLookupLayout lookupLayout = const GameStreamLookupLayout(),
  ValueChanged<GameStreamLookupLayout>? onLookupLayoutChanged,
  GameStreamButtonProfile buttonProfile = const GameStreamButtonProfile(),
  ValueChanged<GameStreamButtonProfile>? onButtonProfileChanged,
  GameStreamSecondScreen secondScreen = GameStreamSecondScreen.auto,
  ValueChanged<GameStreamSecondScreen>? onSecondScreenChanged,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  final String requestedClientId = clientId ?? gameStreamReceiverClientId;
  GameStreamLookupController? lookup;
  FushiGameStreamReceiver? receiver;
  GameStreamInputComposer? input;
  GameStreamCompanionDisplay? companion;
  String? joinedClientId;
  Object? leaveError;
  try {
    final GameStreamSession? joined = await client.join(
      sessionId: session.sessionId,
      clientId: requestedClientId,
      clientName: Platform.localHostname,
      settings: session.supports(GameStreamFeature.videoSettings)
          ? settings
          : null,
    );
    if (joined == null) throw StateError(t.game_stream_join_failed);
    final String activeClientId = client.effectiveClientId(requestedClientId);
    joinedClientId = activeClientId;
    final GameStreamLookupController activeLookup = GameStreamLookupController(
      lookupClient: InterconnectGameStreamDictionaryLookup(
        repo: repository,
        peer: peer,
      ),
      streamClient: client,
      clientId: activeClientId,
    );
    lookup = activeLookup;
    final FushiGameStreamReceiver activeReceiver = FushiGameStreamReceiver(
      client: client,
      onTextEvent: activeLookup.applyTextEvent,
      onInputAck: (GameStreamInputAck ack) => input?.applyAck(ack),
    );
    receiver = activeReceiver;
    final GameStreamInputComposer activeInput = GameStreamInputComposer(
      sessionId: session.sessionId,
      clientId: activeClientId,
      sender: activeReceiver.sendInput,
    );
    input = activeInput;
    await activeReceiver.connect(
      sessionId: session.sessionId,
      clientId: activeClientId,
      settings: settings,
    );
    // One handle for the whole session: the route builder may run again.
    final GameStreamCompanionDisplay? activeCompanion =
        GameStreamCompanionDisplay.forCurrentPlatform();
    companion = activeCompanion;
    await navigator.push<void>(
      MaterialPageRoute<void>(
        // The rail's dictionary is a WebView: it must render at net scale 1
        // (DictionaryPopupWebView asserts it), so the whole page is
        // neutralized from the route like the reader, keeping the popup and
        // its selection rects in one coordinate space.
        builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
          child: GameStreamPage(
            sessionId: session.sessionId,
            clientId: activeClientId,
            inputComposer: activeInput,
            lookupController: activeLookup,
            receiver: activeReceiver,
            session: joined,
            settings: settings,
            onSettingsChanged: onSettingsChanged,
            lookupLayout: lookupLayout,
            onLookupLayoutChanged: onLookupLayoutChanged,
            buttonProfile: buttonProfile,
            onButtonProfileChanged: onButtonProfileChanged,
            companionDisplay: activeCompanion,
            secondScreen: secondScreen,
            onSecondScreenChanged: onSecondScreenChanged,
          ),
        ),
      ),
    );
  } finally {
    try {
      await receiver?.disconnect();
      if (joinedClientId != null) {
        await leaveGameStreamOnHost(client, session.sessionId, joinedClientId);
      }
    } catch (error) {
      leaveError = error;
    } finally {
      companion?.dispose();
      input?.dispose();
      lookup?.dispose();
      receiver?.dispose();
    }
  }
  if (leaveError != null) throw GameStreamLeaveError(leaveError);
}

/// Tells the host this receiver left. A host that no longer knows the session
/// (it ended the stream, or its server restarted) already is where leaving
/// wants it to be, so `session_not_found` is not a failed leave.
Future<void> leaveGameStreamOnHost(
  FushiGameStreamClient client,
  String sessionId,
  String clientId,
) async {
  try {
    await client.stop(
      sessionId: sessionId,
      clientId: clientId,
      reason: 'receiver_left',
    );
  } on GameStreamRequestError catch (error) {
    if (error.code != 'session_not_found') rethrow;
  }
}
