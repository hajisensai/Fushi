import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/floating_dict_page.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

const _overlayChannel = MethodChannel('app.fushi.reader/floating_overlay');

@pragma('vm:entry-point')
void floatingDictMain() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    final platformServices = PlatformServices.forCurrentPlatform();
    final container = ProviderContainer(
      overrides: [
        platformServicesProvider.overrideWithValue(platformServices),
      ],
    );
    final appModel = container.read(appProvider);

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const FloatingDictApp(channel: _overlayChannel),
      ),
    );

    unawaited(appModel.initialiseForDictionaryPopup());
  }, (exception, stack) {
    debugPrint('[Fushi-floatingDict] uncaught: $exception\n$stack');
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
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(color: Colors.transparent),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 与 popup_main 同一口径：有书内覆盖主题用它，否则用用户真实主题
      // （主题色 / 自定义主题 / 墨水屏 / 组件主题都跟着走）。以前这里写死默认
      // 种子色现造一份裸 ThemeData，悬浮词典因此无视用户的主题设置。
      theme: appModel.overrideDictionaryTheme ?? appModel.theme,
      darkTheme:
          appModel.overrideDictionaryTheme != null ? null : appModel.darkTheme,
      themeMode: appModel.overrideDictionaryTheme != null
          ? ThemeMode.light
          : appModel.themeMode,
      // 独立 entry point 不经主 app 的根作用域：玻璃设计系统的组件配色 / 渲染
      // 档位在这里自己挂（结构恒定，MD3 下也挂，见 [FushiGlassScope]）。
      builder: (BuildContext context, Widget? child) =>
          FushiGlassScope(child: child ?? const SizedBox.shrink()),
      home: FloatingDictPage(
        channel: widget.channel,
        pendingSearch: _pendingSearch,
        onSearchConsumed: () => setState(() => _pendingSearch = null),
      ),
    );
  }
}
