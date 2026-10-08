import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/utils.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_loading_view.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/misc/popup_channel.dart';
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart';

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

    await FushiDicts.preloadTransforms();
    final appModel = container.read(appProvider);
    unawaited(appModel.initialiseForDictionaryPopup());
  }, (exception, stack) {
    debugPrint('[Fushi-popup] uncaught: $exception\n$stack');
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

  /// 被点字在 [_searchTerm]（整行原文）里的 UTF-16 下标；-1 = 整串查词入口
  /// （系统 PROCESS_TEXT / fushi://lookup）。BUG-2899：整行原样交给查词页，由它在
  /// 源文本条上做扫描查词，不再在这里切成单词把整行丢掉。
  int _sourceCharIndex = -1;

  /// TODO-872：浮动字幕条点字传来的「被查字屏幕矩形」（**物理像素**，原点=物理屏幕顶
  /// 含状态栏）。为 null 即非浮动字幕入口（系统 PROCESS_TEXT / fushi://lookup）→ 弹窗走
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
          // TODO-1336：warm-reuse 热路径。偏好版本读取 / 重载（DB 访问）失败绝不能吞掉
          // 紧随其后投递新词的 setState——否则常驻热页收不到新词、didUpdateWidget 不触发，
          // 弹窗卡在旧词甚至配合 _isClosing 残留一并关不掉。记日志后带旧偏好缓存继续。
          try {
            await appModel.refreshPrefCacheIfChanged();
          } on Object catch (e, stack) {
            ErrorLogService.instance
                .log('popupMain.refreshPrefCacheIfChanged', e, stack);
          }
        }
        if (!mounted) return;
        setState(() {
          _searchTerm = text;
          _sourceCharIndex = charIndex;
          _anchorPhysical = anchor;
          _subtitlePhysical = subtitle;
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
      // 初始化失败同样没有用户主题可用：走与冷启动占位同一份兜底主题，错误态
      // 是贴顶的 M3E 面板（错误色块图标 + 原因 + 关闭），点外面也能关窗。
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final ThemeData fallbackTheme = buildFushiFallbackTheme(brightness);
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fallbackTheme,
          builder: _buildWithSpacing,
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: PopupDictionaryErrorView(
              colorScheme: fallbackTheme.colorScheme,
              message: t.init_error_message(error: appModel.initError!),
              onDismiss: () => unawaited(PopupChannel.instance.finishPopup()),
            ),
          ),
        ),
      );
    }

    if (!appModel.isInitialised) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final ThemeData fallbackTheme = buildFushiFallbackTheme(brightness);
      final ColorScheme cs = fallbackTheme.colorScheme;
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fallbackTheme,
          builder: _buildWithSpacing,
          home: Scaffold(
            backgroundColor: Colors.transparent,
            // 冷启动占位：不再在别的 app 画面正中裸转圈；慢了才在词卡将出现的位置淡入
            // 小加载胶囊，且加载期间点外面同样能关窗。
            body: PopupDictionaryLoadingView(
              colorScheme: cs,
              // 与 PopupDictionaryPage 同一避让优先级：整条字幕窗 > 被查字。
              anchorRect: _toLogicalRect(_subtitlePhysical ?? _anchorPhysical),
              onDismiss: () => unawaited(PopupChannel.instance.finishPopup()),
            ),
          ),
        ),
      );
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
          sourceCharIndex: _sourceCharIndex,
          // TODO-872：浮动字幕条点字带屏幕锚点 → 弹窗贴被查字旁；其它入口 null → topCenter。
          // TODO-708 P1 ⑤：物理→逻辑换算含状态栏平移在此处（build，视图 metrics 稳定）完成。
          anchorRect: _toLogicalRect(_anchorPhysical),
          // TODO-708 P1 ⑥：整条字幕窗矩形（同一平移换算）作弹窗避让锚，弹窗不遮任一字。
          subtitleWindowRect: _toLogicalRect(_subtitlePhysical),
          // TODO-708 P3 ③：悬浮字幕「点字查词」入口（_anchorPhysical != null）回旧「4.1」轻形态：
          // 无搜索输入框、点字直接出词卡。其它入口（系统 PROCESS_TEXT / fushi://lookup）
          // _anchorPhysical == null → showSearchBar 保持 true，仍带搜索栏重查。
          showSearchBar: _anchorPhysical == null,
        ),
      ),
    );
  }

  Widget _buildWithSpacing(BuildContext context, Widget? child) {
    final AppModel appModel = ref.watch(appProvider);
    return FushiAppUiScale(
      scale: appModel.isInitialised
          ? appModel.appUiScale
          : FushiAppUiScale.defaultScale,
      // 查词窗是独立 entry point，不经主 app 的根作用域：玻璃设计系统的组件
      // 配色 / 渲染档位（GlassTheme）要在这里自己挂一层，否则弹窗里的玻璃
      // 按钮 / 浮层吃库默认参数，与主 app 不一致。结构恒定（MD3 下也挂，见
      // [FushiGlassScope] 类注释）。
      child: LegacyDesignCompatibility(
        child: FushiGlassScope(
          child:
              SmoothWheelScrollScope(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}
