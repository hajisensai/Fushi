import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// The second-screen panel in companion mode.
///
/// Runs the popup's AppModel (theme, dictionary popup settings) like the
/// game stream panel. The main engine does not send companion messages yet;
/// the pipe is drained so nothing piles up on the platform side.
Future<void> runCompanionPanel(MethodChannel channel) async {
  channel.setMethodCallHandler((MethodCall call) async => null);

  final PlatformServices platformServices =
      PlatformServices.forCurrentPlatform();
  final ProviderContainer container = ProviderContainer(
    overrides: [platformServicesProvider.overrideWithValue(platformServices)],
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CompanionPanelApp(),
    ),
  );

  await channel.invokeListMethod<String>('listen');
  unawaited(container.read(appProvider).initialiseForDictionaryPopup());
}

/// Companion panel root: the user's theme once the AppModel is up, the
/// fallback theme until then.
class CompanionPanelApp extends ConsumerWidget {
  const CompanionPanelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    final bool ready = appModel.isInitialised;
    final ThemeData fallback = buildFushiFallbackTheme(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
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
        home: const CompanionIdlePage(),
      ),
    );
  }
}

/// What the companion shows while nothing drives it: the screen is in use
/// and what the user opens on the main screen will appear here.
class CompanionIdlePage extends StatelessWidget {
  const CompanionIdlePage({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: FushiEntranceScope(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiStaggeredEntrance(
                    index: 0,
                    child: Icon(
                      FushiIcons.devices,
                      size: 48,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FushiStaggeredEntrance(
                    index: 1,
                    child: Text(
                      t.second_screen_idle_title,
                      style: text.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FushiStaggeredEntrance(
                    index: 2,
                    child: Text(
                      t.second_screen_idle_hint,
                      style: text.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
