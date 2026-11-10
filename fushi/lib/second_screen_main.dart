import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show dictionaryPopupWebViewUsesHybridComposition;
import 'package:fushi/src/second_screen/panel/companion_panel_app.dart';
import 'package:fushi/src/second_screen/panel/game_stream_panel_app.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Entry point of the panel on the second display (Android
/// `SecondScreenActivity`, process `:second_screen`).
///
/// The panel's mode is fixed per launch (a new mode is a new panel): the game
/// stream's lookup panel, or the companion.
@pragma('vm:entry-point')
void secondScreenMain() {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Same as popupMain: the dictionary WebView uses texture-layer hybrid
      // composition, which keeps the raster thread separate.
      dictionaryPopupWebViewUsesHybridComposition = false;

      const MethodChannel channel = FushiChannels.secondScreen;
      final SecondScreenPanelMode mode = secondScreenPanelModeOf(
        await channel.invokeMapMethod<String, Object?>('launchInfo'),
      );
      switch (mode) {
        case SecondScreenPanelMode.gameStream:
          await runGameStreamPanel(channel);
        case SecondScreenPanelMode.companion:
          await runCompanionPanel(channel);
      }
    },
    (Object exception, StackTrace stack) {
      debugPrint('[Fushi-second-screen] uncaught: $exception\n$stack');
    },
  );
}

/// The mode in the panel's `launchInfo`. The main process only launches
/// modes it knows, so anything else is a broken launch and throws.
SecondScreenPanelMode secondScreenPanelModeOf(Map<String, Object?>? info) {
  final Object? raw = info?['mode'];
  final SecondScreenPanelMode? mode = SecondScreenPanelMode.fromWire(raw);
  if (mode == null) {
    throw StateError('second screen panel launched without a mode: $raw');
  }
  return mode;
}
