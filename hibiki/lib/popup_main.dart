import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';

@pragma('vm:entry-point')
void popupMain() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    final container = ProviderContainer();
    final appModel = container.read(appProvider);

    final initialText = await PopupChannel.instance.getInitialProcessText();

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: PopupDictApp(initialText: initialText ?? ''),
      ),
    );

    appModel.initialiseForDictionaryPopup();
  }, (exception, stack) {
    debugPrint('[Hibiki-popup] uncaught: $exception\n$stack');
  });
}

class PopupDictApp extends ConsumerStatefulWidget {
  const PopupDictApp({required this.initialText, super.key});
  final String initialText;

  @override
  ConsumerState<PopupDictApp> createState() => _PopupDictAppState();
}

class _PopupDictAppState extends ConsumerState<PopupDictApp> {
  late String _searchTerm;

  @override
  void initState() {
    super.initState();
    _searchTerm = widget.initialText;

    PopupChannel.instance.init(
      onNewProcessText: (text) {
        setState(() {
          _searchTerm = text;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appModel = ref.watch(appProvider);

    if (!appModel.isInitialised) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final isDark = brightness == Brightness.dark;
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: isDark ? ThemeData.dark() : null,
        home: Scaffold(
          backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
          body: Center(
            child: CircularProgressIndicator(
              color: isDark ? Colors.white70 : null,
            ),
          ),
        ),
      );
    }

    if (appModel.initError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: Text('Init error: ${appModel.initError}')),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appModel.overrideDictionaryTheme ??
          ThemeData(
            colorSchemeSeed: const Color(0xFF1F4959),
            brightness: appModel.isDarkMode ? Brightness.dark : Brightness.light,
          ),
      home: PopupDictionaryPage(
        key: ValueKey(_searchTerm),
        searchTerm: _searchTerm,
      ),
    );
  }
}
