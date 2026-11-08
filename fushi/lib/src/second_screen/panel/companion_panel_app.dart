import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/profile/profile_view_model.dart'
    show invalidateAnkiStateAfterPrefsChange;
import 'package:fushi/src/second_screen/panel/companion/companion_context_panels.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_shell.dart';
import 'package:fushi/src/second_screen/second_screen_pipe.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// The second-screen panel in companion mode.
///
/// Runs the popup's AppModel (theme, locale, dictionary popup settings) like
/// the game stream panel; everything else it shows comes from the main
/// engine through the panel's [channel] ([CompanionPanelSession]).
Future<void> runCompanionPanel(MethodChannel channel) async {
  // The relay answers whether it took each message: a lost one fails its
  // request instead of leaving it waiting forever.
  final SecondScreenPipe pipe = SecondScreenPipe(
    post: (String raw) => channel.invokeMethod<bool>('send', raw),
    spillDirectory: Directory(
      '${secondScreenSpillRoot('second_screen_companion').path}'
      '${Platform.pathSeparator}panel',
    ),
  );
  final CompanionPanelSession session = CompanionPanelSession(send: pipe.send);
  void receive(String raw) => pipe.receive(
    raw,
    session.receive,
    (Object error, StackTrace stack) =>
        debugPrint('[Fushi-second-screen] bad message: $error $stack'),
  );
  channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'message') receive(call.arguments as String);
    return null;
  });

  final PlatformServices platformServices =
      PlatformServices.forCurrentPlatform();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      platformServicesProvider.overrideWithValue(platformServices),
      companionPanelSessionProvider.overrideWith((Ref ref) => session),
    ],
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CompanionPanelApp(),
    ),
  );

  // Messages that reached the activity before this point, then ask the main
  // engine for everything again.
  final List<String> backlog =
      await channel.invokeListMethod<String>('listen') ?? const <String>[];
  backlog.forEach(receive);
  await session.start();

  unawaited(container.read(appProvider).initialiseForDictionaryPopup());
}

/// Companion panel root: the user's theme and language once the AppModel is
/// up (the fallback theme until then), reloaded whenever the main process
/// changes preferences.
class CompanionPanelApp extends ConsumerStatefulWidget {
  const CompanionPanelApp({this.home, super.key});

  /// The shell (tests pass their own); defaults to [CompanionShell] with
  /// the module panels.
  final Widget? home;

  @override
  ConsumerState<CompanionPanelApp> createState() => _CompanionPanelAppState();
}

class _CompanionPanelAppState extends ConsumerState<CompanionPanelApp> {
  StreamSubscription<void>? _prefsChanges;
  bool _reloading = false;
  bool _reloadAgain = false;

  @override
  void initState() {
    super.initState();
    _prefsChanges = ref
        .read(companionPanelSessionProvider)
        .prefsChanges
        .listen((_) => unawaited(_reloadPrefs()));
  }

  @override
  void dispose() {
    unawaited(_prefsChanges?.cancel());
    super.dispose();
  }

  /// The main process changed preferences: reload them the way the warm
  /// `:popup` does (one version read, a full reload only when something
  /// changed), then drop state derived from them. One reload at a time; a
  /// ping during one runs it once more.
  Future<void> _reloadPrefs() async {
    final AppModel appModel = ref.read(appProvider);
    // Not up yet: the initialisation reads the current preferences.
    if (!appModel.isInitialised) return;
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        try {
          final bool changed = await appModel.refreshForWarmDictionaryPopup();
          if (!changed || !mounted) continue;
          invalidateAnkiStateAfterPrefsChange(ref);
          final String tag = appModel.appLocale.toLanguageTag();
          if (tag != LocaleSettings.currentLocale.languageTag) {
            LocaleSettings.setLocaleRaw(tag);
          }
          setState(() {});
        } catch (error, stack) {
          ErrorLogService.instance.log(
            'CompanionPanelApp.reloadPrefs',
            error,
            stack,
          );
        }
      } while (_reloadAgain && mounted);
    } finally {
      _reloading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    final bool ready = appModel.isInitialised;
    final ThemeData fallback = buildFushiFallbackTheme(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
    final Locale? locale = ready ? appModel.appLocale : null;
    // Most strings read the global `t`, which does not rebuild on a language
    // change: remount the app on one (like the main app's root).
    return KeyedSubtree(
      key: ValueKey<String>(
        'companion-locale-${locale?.toLanguageTag() ?? ''}',
      ),
      child: TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ready ? appModel.theme : fallback,
          darkTheme: ready ? appModel.darkTheme : null,
          themeMode: ready ? appModel.themeMode : ThemeMode.light,
          locale: locale,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: ready
              ? appModel.locales.values
              : const <Locale>[Locale('en')],
          builder: (BuildContext context, Widget? child) =>
              LegacyDesignCompatibility(
                child: FushiGlassScope(child: child ?? const SizedBox.shrink()),
              ),
          home:
              widget.home ??
              CompanionShell(contextPanels: companionContextPanels),
        ),
      ),
    );
  }
}
