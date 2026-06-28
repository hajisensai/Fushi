import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';

String _extractWord(AppModel appModel, String text, int charIndex) {
  if (charIndex < 0 || !appModel.isInitialised) return text;
  final String word = appModel.targetLanguage.wordFromIndex(
    text: text,
    index: charIndex,
  );
  return word.isNotEmpty ? word : text;
}

@pragma('vm:entry-point')
void popupMain() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    final platformServices = PlatformServices.forCurrentPlatform();
    final container = ProviderContainer(
      overrides: [
        platformServicesProvider.overrideWithValue(platformServices),
      ],
    );

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const PopupDictApp(),
      ),
    );

    await HoshiDicts.preloadTransforms();
    final appModel = container.read(appProvider);
    unawaited(appModel.initialiseForDictionaryPopup());
  }, (exception, stack) {
    debugPrint('[Hibiki-popup] uncaught: $exception\n$stack');
  });
}

class PopupDictApp extends ConsumerStatefulWidget {
  const PopupDictApp({super.key});

  @override
  ConsumerState<PopupDictApp> createState() => _PopupDictAppState();
}

class _PopupDictAppState extends ConsumerState<PopupDictApp> {
  String _searchTerm = '';
  int _searchGeneration = 0;
  bool _pendingWordExtraction = false;
  int _pendingCharIndex = -1;

  @override
  void initState() {
    super.initState();

    PopupChannel.instance.init(
      onNewProcessText: (String text, int charIndex) async {
        final appModel = ref.read(appProvider);
        // TODO-855: warm-reuse hot path. Don't unconditionally re-scan the whole
        // preferences table on every external ProcessText (the v0.4.1 path was a
        // pure setState). refreshPrefCacheIfChanged does one cheap indexed DB
        // version read and only does the full reload when the main app actually
        // mutated a preference / switched profile since the last lookup, so the
        // warm-reuse popup still sees a new profile's prefs without paying the
        // reload cost on every word.
        if (appModel.isInitialised) {
          await appModel.refreshPrefCacheIfChanged();
        }
        if (!mounted) return;
        final String resolved = _extractWord(appModel, text, charIndex);
        setState(() {
          _searchTerm = resolved;
          if (charIndex >= 0 && !appModel.isInitialised) {
            _pendingWordExtraction = true;
            _pendingCharIndex = charIndex;
          }
          _searchGeneration++;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appModel = ref.watch(appProvider);

    if (appModel.initError != null) {
      _pendingWordExtraction = false;
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: _buildWithSpacing,
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: Text(t.init_error_message(error: appModel.initError!)),
            ),
          ),
        ),
      );
    }

    if (!appModel.isInitialised) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final cs = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: brightness,
      );
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorScheme: cs),
          builder: _buildWithSpacing,
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: CircularProgressIndicator(color: cs.primary),
            ),
          ),
        ),
      );
    }

    if (_pendingWordExtraction) {
      _pendingWordExtraction = false;
      final String resolved =
          _extractWord(appModel, _searchTerm, _pendingCharIndex);
      if (resolved != _searchTerm) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _searchTerm = resolved;
            _searchGeneration++;
          });
        });
      }
    }

    return TranslationProvider(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: _buildWithSpacing,
        theme: appModel.overrideDictionaryTheme ?? appModel.theme,
        darkTheme: appModel.overrideDictionaryTheme != null
            ? null
            : appModel.darkTheme,
        themeMode: appModel.overrideDictionaryTheme != null
            ? ThemeMode.light
            : appModel.themeMode,
        // TODO-951 症状C：不再用 ValueKey 强制重建整页——那会每次新 ProcessText 都丢弃
        // 并重建 PopupDictionaryPage（含其 DictionaryPopupController + 弹窗 WebView），
        // 冷加载一次 popup.html/JS/CSS 露白屏一瞬（用户报「每次查词已有弹窗会闪」）。
        // 改为页面常驻、把新词经 searchTerm + searchGeneration 透传，
        // PopupDictionaryPage.didUpdateWidget 复用常驻热槽原地查新词。searchGeneration
        // 让相同词的连续 ProcessText 也能触发 didUpdateWidget（否则同词不变 widget 配置）。
        home: PopupDictionaryPage(
          searchTerm: _searchTerm,
          searchGeneration: _searchGeneration,
        ),
      ),
    );
  }

  Widget _buildWithSpacing(BuildContext context, Widget? child) {
    final AppModel appModel = ref.watch(appProvider);
    return HibikiAppUiScale(
      scale: appModel.isInitialised
          ? appModel.appUiScale
          : HibikiAppUiScale.defaultScale,
      child: child ?? const SizedBox.shrink(),
    );
  }
}
