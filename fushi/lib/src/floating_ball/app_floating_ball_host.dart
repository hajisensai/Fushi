/// 全局悬浮球宿主：挂在 `main.dart` 根 builder 的 Stack 上（导航之上、查词弹窗
/// 宿主之下），任何页面都在。设计见 `docs/specs/2026-09-28-floating-ball.md`。
///
/// 三件事：
///  1. 应用内球：复用阅读器的 [ReaderFloatingBall]（同一套停靠 / 拖动 / 展开几何），
///     活动范围是整窗扣掉系统 inset；按钮 = 当前路由的场景按钮 + 全局按钮。
///  2. Android 系统常驻：按偏好起停原生 `FloatingBallService`，并把前后台状态告诉它
///     （前台时原生球隐藏、由本球接管）。
///  3. 外部查词入口（iOS App Intent / `fushi://lookup` 深链）：排队到 app 初始化
///     完成，再交给应用内查词弹窗。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/floating_ball_mode.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';
import 'package:fushi/utils.dart';

/// 截屏识字送给系统 OCR 的语言。Fushi 的查词对象是日语；ML Kit / Vision 的日文
/// 识别器同时认拉丁字母与汉字。
const String kFloatingBallOcrLanguage = 'ja';

/// 外部查词请求（App Intent / 深链）。app 未初始化时先存着，宿主就绪后取走。
final ValueNotifier<String?> pendingExternalLookup = ValueNotifier<String?>(
  null,
);

/// 从应用外交来一个要查的词（iOS App Intent、`fushi://lookup?word=`）。
void deliverExternalLookup(String word) {
  final String trimmed = word.trim();
  if (trimmed.isEmpty) return;
  pendingExternalLookup.value = trimmed;
}

/// 原生系统球的按钮文案（原生侧不维护多语言）。
Map<String, String> floatingBallNativeLabels() => <String, String>{
  FloatingBallGlobalAction.lookup.storageValue: t.floating_ball_action_lookup,
  FloatingBallGlobalAction.clipboard.storageValue:
      t.floating_ball_action_clipboard,
  FloatingBallGlobalAction.screenOcr.storageValue:
      t.floating_ball_action_screen_ocr,
  'open_app': t.floating_ball_action_open_app,
  'close': t.floating_ball_action_close,
  'notification': t.floating_ball_notification,
  'ocr_notification': t.floating_ball_ocr_notification,
  'ocr_hint': t.floating_ball_ocr_pick_hint,
  'ocr_no_text': t.floating_ball_ocr_empty,
  'ocr_model_unavailable': t.floating_ball_ocr_model_unavailable,
  'ocr_failed': t.floating_ball_ocr_failed,
};

/// 本平台可用、且用户开着的全局按钮。
List<FloatingBallGlobalAction> enabledFloatingBallActions(
  PreferencesRepository prefs,
) => <FloatingBallGlobalAction>[
  for (final FloatingBallGlobalAction action in prefs.floatingBallActions)
    if (action.availableOn(
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
    ))
      action,
];

class AppFloatingBallHost extends ConsumerStatefulWidget {
  const AppFloatingBallHost({super.key});

  @override
  ConsumerState<AppFloatingBallHost> createState() =>
      _AppFloatingBallHostState();
}

class _AppFloatingBallHostState extends ConsumerState<AppFloatingBallHost>
    with WidgetsBindingObserver {
  final FloatingBallSceneRegistry _registry =
      FloatingBallSceneRegistry.instance;

  PreferencesRepository? _prefs;

  /// 上一次下发给原生系统球的配置（模式 + 按钮 + 语言）；相同就不重复下发。
  String? _systemSignature;

  /// 截屏期间把球藏起来，别把自己拍进去。
  bool _capturing = false;

  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _registry.addListener(_onChanged);
    pendingExternalLookup.addListener(_onChanged);
    if (Platform.isIOS || Platform.isAndroid) {
      unawaited(
        FloatingBallChannel.installHandler(
          onLookup: deliverExternalLookup,
          onScreenOcrFinished: _onScreenOcrFinished,
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _registry.removeListener(_onChanged);
    pendingExternalLookup.removeListener(_onChanged);
    _prefs?.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onPrefsChanged() {
    _syncSystemBall();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool foreground = switch (state) {
      AppLifecycleState.resumed => true,
      AppLifecycleState.paused || AppLifecycleState.hidden => false,
      // inactive（下拉通知栏、系统对话框）与 detached 不改变谁该露面。
      _ => _foreground,
    };
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (_systemSignature != null) {
      unawaited(FloatingBallChannel.setAppForeground(foreground));
    }
    // 从「显示在其他应用上层」授权页回来：再试一次起系统球。
    if (foreground) _syncSystemBall(force: true);
  }

  FloatingBallMode _mode(PreferencesRepository prefs) =>
      prefs.floatingBallMode.effectiveOn(isAndroid: Platform.isAndroid);

  /// 按偏好起停 Android 原生系统球。
  void _syncSystemBall({bool force = false}) {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null || !Platform.isAndroid) return;
    final bool wanted = _mode(prefs) == FloatingBallMode.system;
    if (!wanted) {
      if (_systemSignature != null) {
        _systemSignature = null;
        unawaited(FloatingBallChannel.stopSystemBall());
      }
      return;
    }
    final List<String> actions = <String>[
      for (final FloatingBallGlobalAction a in enabledFloatingBallActions(
        prefs,
      ))
        a.storageValue,
    ];
    final Map<String, String> labels = floatingBallNativeLabels();
    // 文案进签名：切换界面语言后原生球的按钮也要换。
    final String signature = '${actions.join(',')}|${labels.values.join('|')}';
    if (!force && signature == _systemSignature) return;
    unawaited(() async {
      final bool started = await FloatingBallChannel.startSystemBall(
        actions: actions,
        labels: labels,
        ocrLanguage: kFloatingBallOcrLanguage,
      );
      // 没权限起不来：不记签名，回到前台时再试。
      _systemSignature = started ? signature : null;
      if (started) {
        await FloatingBallChannel.setAppForeground(_foreground);
      }
    }());
  }

  void _attachPrefs(PreferencesRepository prefs) {
    if (identical(prefs, _prefs)) return;
    _prefs?.removeListener(_onPrefsChanged);
    _prefs = prefs;
    prefs.addListener(_onPrefsChanged);
    _syncSystemBall(force: true);
  }

  /// 外部查词：app 就绪后才交给查词弹窗（弹窗要用已初始化的词典）。
  void _flushExternalLookup() {
    final String? word = pendingExternalLookup.value;
    if (word == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String? current = pendingExternalLookup.value;
      if (current == null) return;
      pendingExternalLookup.value = null;
      FloatingLyricLookupNotifier.instance.requestLookup(current, 0);
    });
  }

  // ── 全局按钮 ────────────────────────────────────────────────────────

  BuildContext? get _navigatorContext =>
      ref.read(appProvider).navigatorKey.currentContext;

  void _toast(String message) {
    final BuildContext? ctx = _navigatorContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(
      ctx,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _manualLookup() async {
    final BuildContext? ctx = _navigatorContext;
    if (ctx == null) return;
    final String? word = await showDialog<String>(
      context: ctx,
      builder: (BuildContext context) => const _ManualLookupDialog(),
    );
    if (word == null || word.trim().isEmpty) return;
    FloatingLyricLookupNotifier.instance.requestLookup(word.trim(), 0);
  }

  Future<void> _clipboardLookup() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _toast(t.floating_ball_clipboard_empty);
      return;
    }
    FloatingLyricLookupNotifier.instance.requestLookup(text, 0);
  }

  /// Android 截屏 OCR 截到帧（或放弃）：把藏起来的球放回来。
  void _onScreenOcrFinished() {
    if (mounted && _capturing) setState(() => _capturing = false);
  }

  Future<void> _screenOcr() async {
    if (Platform.isAndroid) {
      // 原生只藏得了原生球：Flutter 球要自己藏，等 screenOcrFinished 再放回来。
      setState(() => _capturing = true);
      final bool started = await FloatingBallChannel.startScreenOcr(
        language: kFloatingBallOcrLanguage,
        labels: floatingBallNativeLabels(),
      );
      if (started) return;
      _onScreenOcrFinished();
      if (!await FloatingBallChannel.canDrawOverlays()) {
        _toast(t.floating_ball_overlay_permission_needed);
        await FloatingBallChannel.requestOverlayPermission();
      } else {
        _toast(t.floating_ball_ocr_failed);
      }
      return;
    }
    if (Platform.isIOS) await _screenOcrInApp();
  }

  /// iOS：截自己的窗口 → Vision → 选取页。
  Future<void> _screenOcrInApp() async {
    setState(() => _capturing = true);
    // 等球从画面上消失再截。
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    final Uint8List? bytes;
    try {
      bytes = await FloatingBallChannel.captureScreen();
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
    if (bytes == null) {
      _toast(t.floating_ball_ocr_failed);
      return;
    }
    final SystemOcrPageResult result;
    try {
      result = await const MethodChannelSystemOcr().recognize(
        bytes,
        language: kFloatingBallOcrLanguage,
      );
    } on SystemOcrUnavailableException {
      _toast(t.floating_ball_ocr_model_unavailable);
      return;
    } catch (error, stack) {
      ErrorLogService.instance.log('floating_ball.screen_ocr', error, stack);
      _toast(t.floating_ball_ocr_failed);
      return;
    }
    if (result.isEmpty) {
      _toast(t.floating_ball_ocr_empty);
      return;
    }
    final NavigatorState? navigator = ref
        .read(appProvider)
        .navigatorKey
        .currentState;
    if (navigator == null) return;
    // 无过渡：截图与当前画面同形，淡入 / 滑入只会让人以为画面跳了。
    unawaited(
      navigator.push(
        PageRouteBuilder<void>(
          opaque: true,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder:
              (
                BuildContext context,
                Animation<double> animation,
                Animation<double> secondaryAnimation,
              ) => ScreenOcrPickerPage(imageBytes: bytes!, result: result),
        ),
      ),
    );
  }

  ReaderHeaderAction _globalAction(FloatingBallGlobalAction action) =>
      switch (action) {
        FloatingBallGlobalAction.lookup => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_lookup'),
          icon: Icons.search,
          label: t.floating_ball_action_lookup,
          onPressed: () => unawaited(_manualLookup()),
        ),
        FloatingBallGlobalAction.clipboard => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_clipboard'),
          icon: Icons.content_paste_search,
          label: t.floating_ball_action_clipboard,
          onPressed: () => unawaited(_clipboardLookup()),
        ),
        FloatingBallGlobalAction.screenOcr => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_screen_ocr'),
          icon: Icons.document_scanner_outlined,
          label: t.floating_ball_action_screen_ocr,
          onPressed: () => unawaited(_screenOcr()),
        ),
      };

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    if (!appModel.isInitialised) return const SizedBox.shrink();
    final PreferencesRepository prefs = appModel.prefsRepo;
    _attachPrefs(prefs);
    _flushExternalLookup();

    final FloatingBallMode mode = _mode(prefs);
    final FloatingBallSceneSnapshot scene = _registry.current;
    if (!mode.showsInAppBall || scene.hidesBall || _capturing) {
      return const SizedBox.shrink();
    }
    final List<ReaderHeaderAction> actions = <ReaderHeaderAction>[
      ...scene.actions,
      for (final FloatingBallGlobalAction action in enabledFloatingBallActions(
        prefs,
      ))
        _globalAction(action),
    ];
    if (actions.isEmpty) return const SizedBox.shrink();
    final Size window = MediaQuery.sizeOf(context);
    final EdgeInsets padding = MediaQuery.viewPaddingOf(context);
    final Rect viewport = Rect.fromLTRB(
      padding.left,
      padding.top,
      window.width - padding.right,
      window.height - padding.bottom,
    );
    // ReaderFloatingBall 返回 Positioned，必须是 Stack 的直接子节点。本宿主挂在
    // 导航之上，没有 Overlay 祖先，球与按钮的 Tooltip 要自带一层；Stack 只在
    // 球 / 按钮上命中，空白处照常穿透到底下页面。
    return Overlay.wrap(
      child: Stack(
        children: <Widget>[
          ReaderFloatingBall(
            key: const ValueKey<String>('fushi_app_floating_ball'),
            viewport: viewport,
            actions: actions,
            dock: ReaderFloatingBallDock.decode(prefs.floatingBallDock),
            verticalFraction: prefs.floatingBallVerticalFraction,
            onDockChanged: (ReaderFloatingBallDock dock, double fraction) {
              unawaited(prefs.setFloatingBallPosition(dock.id, fraction));
            },
          ),
        ],
      ),
    );
  }
}

class _ManualLookupDialog extends StatefulWidget {
  const _ManualLookupDialog();

  @override
  State<_ManualLookupDialog> createState() => _ManualLookupDialogState();
}

class _ManualLookupDialogState extends State<_ManualLookupDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(t.floating_ball_action_lookup),
      content: TextField(
        key: const ValueKey<String>('floating_ball_lookup_field'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(hintText: t.floating_ball_lookup_hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButtonLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.searchFieldLabel)),
      ],
    );
  }
}
