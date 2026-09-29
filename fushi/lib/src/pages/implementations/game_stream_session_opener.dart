import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
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
    'android-${Platform.localHostname}-${DateTime.now().microsecondsSinceEpoch}';

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
}) async {
  final NavigatorState navigator = Navigator.of(context);
  final String requestedClientId = clientId ?? gameStreamReceiverClientId;
  GameStreamLookupController? lookup;
  FushiGameStreamReceiver? receiver;
  GameStreamInputComposer? input;
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
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => GameStreamPage(
          sessionId: session.sessionId,
          clientId: activeClientId,
          inputComposer: activeInput,
          lookupController: activeLookup,
          receiver: activeReceiver,
          session: joined,
          settings: settings,
          onSettingsChanged: onSettingsChanged,
        ),
      ),
    );
  } finally {
    try {
      await receiver?.disconnect();
      if (joinedClientId != null) {
        await client.stop(
          sessionId: session.sessionId,
          clientId: joinedClientId,
          reason: 'receiver_left',
        );
      }
    } catch (error) {
      leaveError = error;
    } finally {
      input?.dispose();
      lookup?.dispose();
      receiver?.dispose();
    }
  }
  if (leaveError != null) throw GameStreamLeaveError(leaveError);
}
