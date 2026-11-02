import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show dictionaryPopupWebViewUsesHybridComposition;
import 'package:fushi/src/pages/implementations/game_stream_companion_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Entry point of the game stream's lookup panel on the second display
/// (Android `GameStreamCompanionActivity`, process `:companion`).
///
/// Runs the popup's AppModel (theme, dictionary popup settings, Anki field
/// mapping) for the dictionary WebView; everything the panel shows comes from
/// the stream page through [FushiChannels.gameStreamCompanion].
@pragma('vm:entry-point')
void gameStreamCompanionMain() {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Same as popupMain: the dictionary WebView uses texture-layer hybrid
      // composition, which keeps the raster thread separate.
      dictionaryPopupWebViewUsesHybridComposition = false;

      const MethodChannel channel = FushiChannels.gameStreamCompanion;
      final GameStreamCompanionController controller =
          GameStreamCompanionController(
            send: (String raw) => channel.invokeMethod<void>('send', raw),
          );
      channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'message') {
          controller.link.receive(call.arguments as String);
        }
        return null;
      });

      final PlatformServices platformServices =
          PlatformServices.forCurrentPlatform();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          platformServicesProvider.overrideWithValue(platformServices),
        ],
      );
      runApp(
        UncontrolledProviderScope(
          container: container,
          child: GameStreamCompanionApp(controller: controller),
        ),
      );

      // Messages that reached the activity before this point, then ask the
      // stream page for everything again.
      final List<String> backlog =
          await channel.invokeListMethod<String>('listen') ?? const <String>[];
      for (final String raw in backlog) {
        controller.link.receive(raw);
      }
      await controller.link.send(const GameStreamCompanionReady());

      unawaited(container.read(appProvider).initialiseForDictionaryPopup());
    },
    (Object exception, StackTrace stack) {
      debugPrint('[Fushi-companion] uncaught: $exception\n$stack');
    },
  );
}

class GameStreamCompanionApp extends ConsumerWidget {
  const GameStreamCompanionApp({required this.controller, super.key});

  final GameStreamCompanionController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    final bool ready = appModel.isInitialised;
    // Until the AppModel is up the line already shows (fallback theme); the
    // dictionary needs the user's popup settings and waits.
    final ThemeData fallback = buildFushiFallbackTheme(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
    // The dictionary popup reads its strings through the slang provider.
    return TranslationProvider(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ready ? appModel.theme : fallback,
        darkTheme: ready ? appModel.darkTheme : null,
        themeMode: ready ? appModel.themeMode : ThemeMode.light,
        builder: (BuildContext context, Widget? child) =>
            LegacyDesignCompatibility(
              child: FushiGlassScope(child: child ?? const SizedBox.shrink()),
            ),
        home: GameStreamCompanionPage(
          controller: controller,
          dictionaryReady: ready,
        ),
      ),
    );
  }
}
