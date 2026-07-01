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

  /// TODO-872：浮动字幕条点字传来的「被查字屏幕矩形」（**物理像素**，原点=物理屏幕顶
  /// 含状态栏）。为 null 即非浮动字幕入口（系统 PROCESS_TEXT / hibiki://lookup）→ 弹窗走
  /// 默认 topCenter。物理→逻辑换算 + 状态栏平移在 [build] 内完成（那里 MediaQuery 才有
  /// 有效 viewPadding），随 [_searchGeneration] 一并喂给 [PopupDictionaryPage]。
  Rect? _anchorPhysical;

  /// TODO-708 P1 ⑥：浮动字幕条「整条字幕窗屏幕矩形」（**物理像素**，同 [_anchorPhysical]
  /// 坐标系）。非空时作为弹窗避让锚（超集，覆盖被查字）；为 null 时回退只避让被查字。
  Rect? _subtitlePhysical;

  @override
  void initState() {
    super.initState();

    PopupChannel.instance.init(
      onNewProcessText:
          (String text, int charIndex, Rect? anchor, Rect? subtitle) async {
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
          _anchorPhysical = anchor;
          _subtitlePhysical = subtitle;
          if (charIndex >= 0 && !appModel.isInitialised) {
            _pendingWordExtraction = true;
            _pendingCharIndex = charIndex;
          }
          _searchGeneration++;
        });
      },
    );
  }

  /// TODO-708 P1 ⑤：把原生侧的物理像素屏幕矩形换算成本查词窗内容坐标系的逻辑像素。
  ///
  /// 原生 [FloatingLyricService.glyphScreenRect] / 整条字幕窗矩形用 getLocationOnScreen，
  /// 原点 = **物理屏幕顶（含状态栏）**；而本 Flutter 查词窗（PopupDictTheme 非 edge-to-edge）
  /// 内容区原点 = **状态栏下沿**。两坐标系相差一个状态栏高度。先在物理像素域把 top/bottom
  /// 减去状态栏物理高度 [FlutterView.viewPadding].top（把物理屏坐标平移到内容坐标系），
  /// 再 ÷ devicePixelRatio 换成逻辑像素。只平移竖直位置，矩形高宽不变。
  ///
  /// physical 为 null 直接返回 null（无被查字/无字幕窗）。
  Rect? _toLogicalRect(Rect? physical) {
    if (physical == null) return null;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final double dpr = views.isNotEmpty ? views.first.devicePixelRatio : 1.0;
    final double ratio = dpr <= 0 ? 1.0 : dpr;
    // 状态栏物理高度（逻辑像素）。glyph/subtitle 屏幕矩形含状态栏，本查词窗内容原点在
    // 状态栏下沿，故平移掉这段，弹窗锚点才与用户看到的字对齐。
    final double statusBarPhysical =
        views.isNotEmpty ? views.first.viewPadding.top : 0.0;
    final double top = (physical.top - statusBarPhysical) / ratio;
    final double bottom = (physical.bottom - statusBarPhysical) / ratio;
    return Rect.fromLTRB(
      physical.left / ratio,
      top,
      physical.right / ratio,
      bottom,
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
          // TODO-872：浮动字幕条点字带屏幕锚点 → 弹窗贴被查字旁；其它入口 null → topCenter。
          // TODO-708 P1 ⑤：物理→逻辑换算含状态栏平移在此处（build，视图 metrics 稳定）完成。
          anchorRect: _toLogicalRect(_anchorPhysical),
          // TODO-708 P1 ⑥：整条字幕窗矩形（同一平移换算）作弹窗避让锚，弹窗不遮任一字。
          subtitleWindowRect: _toLogicalRect(_subtitlePhysical),
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
