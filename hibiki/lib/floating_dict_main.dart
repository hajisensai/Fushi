import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/floating_dict_page.dart';

const _overlayChannel = MethodChannel('app.hibiki.reader/floating_overlay');

@pragma('vm:entry-point')
void floatingDictMain() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    final container = ProviderContainer();
    final appModel = container.read(appProvider);

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: FloatingDictApp(channel: _overlayChannel),
      ),
    );

    unawaited(appModel.initialiseForDictionaryPopup());
  }, (exception, stack) {
    debugPrint('[Hibiki-floatingDict] uncaught: $exception\n$stack');
  });
}

class FloatingDictApp extends ConsumerStatefulWidget {
  const FloatingDictApp({required this.channel, super.key});
  final MethodChannel channel;

  @override
  ConsumerState<FloatingDictApp> createState() => _FloatingDictAppState();
}

class _FloatingDictAppState extends ConsumerState<FloatingDictApp> {
  String? _pendingSearch;

  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler(_handleCall);
  }

  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'searchTerm':
        final String term = call.arguments as String? ?? '';
        if (term.trim().isNotEmpty) {
          setState(() => _pendingSearch = term.trim());
        }
        return null;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final appModel = ref.watch(appProvider);

    if (!appModel.isInitialised) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const ColoredBox(color: Colors.transparent),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appModel.overrideDictionaryTheme ??
          ThemeData(
            colorSchemeSeed: const Color(0xFF1F4959),
            brightness:
                appModel.isDarkMode ? Brightness.dark : Brightness.light,
          ),
      home: FloatingDictPage(
        channel: widget.channel,
        pendingSearch: _pendingSearch,
        onSearchConsumed: () => setState(() => _pendingSearch = null),
      ),
    );
  }
}
