import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:spaces/spaces.dart';

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

    await HoshiDicts.preloadTransforms();

    final container = ProviderContainer();
    final appModel = container.read(appProvider);

    final initialData = await PopupChannel.instance.getInitialProcessText();
    final String rawText = initialData.text ?? '';
    final int charIndex = initialData.charIndex;

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: PopupDictApp(
          initialText: rawText,
          initialCharIndex: charIndex,
        ),
      ),
    );

    unawaited(appModel.initialiseForDictionaryPopup());
  }, (exception, stack) {
    debugPrint('[Hibiki-popup] uncaught: $exception\n$stack');
  });
}

class PopupDictApp extends ConsumerStatefulWidget {
  const PopupDictApp({
    required this.initialText,
    this.initialCharIndex = -1,
    super.key,
  });
  final String initialText;
  final int initialCharIndex;

  @override
  ConsumerState<PopupDictApp> createState() => _PopupDictAppState();
}

class _PopupDictAppState extends ConsumerState<PopupDictApp> {
  late String _searchTerm;
  int _searchGeneration = 0;
  bool _pendingWordExtraction = false;
  int _pendingCharIndex = -1;

  @override
  void initState() {
    super.initState();
    _searchTerm = widget.initialText;
    if (widget.initialCharIndex >= 0) {
      _pendingWordExtraction = true;
      _pendingCharIndex = widget.initialCharIndex;
    }

    PopupChannel.instance.init(
      initialText: widget.initialText,
      onNewProcessText: (String text, int charIndex) async {
        final appModel = ref.read(appProvider);
        await appModel.refreshPrefCache();
        if (!mounted) return;
        final String resolved = _extractWord(appModel, text, charIndex);
        setState(() {
          _searchTerm = resolved;
          _searchGeneration++;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appModel = ref.watch(appProvider);

    if (appModel.initError != null) {
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
        home: PopupDictionaryPage(
          key: ValueKey('$_searchTerm:$_searchGeneration'),
          searchTerm: _searchTerm,
        ),
      ),
    );
  }

  Widget _buildWithSpacing(BuildContext context, Widget? child) {
    return Spacing(
      dataBuilder: (context) {
        return SpacingData.generate(10);
      },
      child: child ?? const SizedBox.shrink(),
    );
  }
}
