import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:spaces/spaces.dart';

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

    unawaited(appModel.initialiseForDictionaryPopup());
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
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _searchTerm = widget.initialText;

    PopupChannel.instance.init(
      initialText: widget.initialText,
      onNewProcessText: (text) {
        setState(() {
          _searchTerm = text;
          _searchGeneration++;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appModel = ref.watch(appProvider);

    if (appModel.initError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: _buildWithSpacing,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(child: Text('Init error: ${appModel.initError}')),
        ),
      );
    }

    if (!appModel.isInitialised) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final isDark = brightness == Brightness.dark;
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: isDark ? ThemeData.dark() : null,
        builder: _buildWithSpacing,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: CircularProgressIndicator(
              color: isDark ? Colors.white70 : null,
            ),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: _buildWithSpacing,
      theme: appModel.overrideDictionaryTheme ?? appModel.theme,
      darkTheme: appModel.overrideDictionaryTheme != null
          ? null
          : appModel.darkTheme,
      themeMode: appModel.overrideDictionaryTheme != null
          ? ThemeMode.light
          : (appModel.isDarkMode ? ThemeMode.dark : ThemeMode.light),
      home: PopupDictionaryPage(
        key: ValueKey('$_searchTerm:$_searchGeneration'),
        searchTerm: _searchTerm,
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
