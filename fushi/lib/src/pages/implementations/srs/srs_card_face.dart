/// 复习页的卡面视图：渲染好的 Anki 风格 HTML（卡片 CSS + 正面 / 背面）放进 WebView。
///
/// 视图经 [srsCardFaceBuilderProvider] 注入：widget 测试里没有 WebView，覆写成纯
/// 文本实现即可（复习页的状态机与评分逻辑不依赖卡面怎么画）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show wrapAnkiCardHtmlWithLang;

import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/utils.dart';

/// 一面卡（问题面或答案面）。
@immutable
class SrsCardFace {
  const SrsCardFace({
    required this.cardId,
    required this.showingAnswer,
    required this.bodyHtml,
    required this.css,
    required this.languageCode,
    required this.onBridgeKey,
  });

  final String cardId;
  final bool showingAnswer;

  /// 渲染器给出的正文 HTML（问题面 = question，答案面 = answer）。
  final String bodyHtml;
  final String css;

  /// 卡面 `lang`（字形 / 断行按学习语言走）；空 = 不标。
  final String? languageCode;

  /// WebView 持有键盘焦点时，页内截获的按键 token（见 [kSrsReviewBridgeKeys]）。
  final void Function(String token) onBridgeKey;
}

/// 卡面视图构造器。
typedef SrsCardFaceBuilder =
    Widget Function(BuildContext context, SrsCardFace face);

/// 生产实现：WebView 卡面。测试覆写成纯文本。
final Provider<SrsCardFaceBuilder> srsCardFaceBuilderProvider =
    Provider<SrsCardFaceBuilder>(
      (Ref ref) =>
          (BuildContext context, SrsCardFace face) => SrsWebCardFace(
            key: const ValueKey<String>('srs-card-face-webview'),
            face: face,
          ),
    );

/// WebView 持焦时要交回 Dart 的键（token 名与 `KeyboardEvent.code` 同名）。
const List<String> kSrsReviewBridgeKeys = <String>[
  'Space',
  'Enter',
  'NumpadEnter',
  'Digit1',
  'Digit2',
  'Digit3',
  'Digit4',
  'Numpad1',
  'Numpad2',
  'Numpad3',
  'Numpad4',
  'Ctrl+KeyZ',
  'Meta+KeyZ',
];

const String _kSrsBridgeHandler = 'onSrsReviewKey';

/// 卡面键盘桥脚本（每次换内容后注入；生成器自带幂等守卫）。
final String srsReviewKeyBridgeScript = webViewKeyBridgeScript(
  handlerName: _kSrsBridgeHandler,
  keys: kSrsReviewBridgeKeys,
  forwardRepeats: false,
  stopPropagation: true,
);

String _cssColor(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// 拼出整页 HTML：卡片 CSS + `<div class="card">` 包裹的正文（Anki 的卡面约定）。
///
/// 深色主题下同时挂 Anki 的两种夜间类名（`nightMode` / `night_mode`），卡片 CSS
/// 里写的夜间样式照常生效。
String srsCardHtml({
  required SrsCardFace face,
  required bool dark,
  required Color background,
  required Color foreground,
}) {
  final String night = dark ? ' nightMode night_mode' : '';
  final String body = wrapAnkiCardHtmlWithLang(
    face.bodyHtml,
    face.languageCode,
  );
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;padding:0;background:${_cssColor(background)};'
      'color:${_cssColor(foreground)};}'
      'body{padding:16px;box-sizing:border-box;}</style>'
      '<style>${face.css}</style></head>'
      '<body class="card$night"><div class="card$night">$body</div></body></html>';
}

/// WebView 卡面。保留同一个平台视图，换卡 / 翻面时 `loadData` 换内容（不重建
/// 平台视图，避免每翻一次面闪白）。
class SrsWebCardFace extends StatefulWidget {
  const SrsWebCardFace({super.key, required this.face});

  final SrsCardFace face;

  @override
  State<SrsWebCardFace> createState() => _SrsWebCardFaceState();
}

class _SrsWebCardFaceState extends State<SrsWebCardFace> {
  InAppWebViewController? _controller;
  String? _loadedHtml;

  /// renderer 死亡处置：卡面是纯只读渲染，内容全在 [widget.face] 里，重建零损失；
  /// flush 只需丢掉报废的 controller，重建后 initialData 就是当前这一面。
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'srs_card_face',
    flushBeforeRebuild: () async {
      _controller = null;
      _loadedHtml = null;
    },
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );

  String _html(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return srsCardHtml(
      face: widget.face,
      dark: theme.brightness == Brightness.dark,
      background: theme.colorScheme.surface,
      foreground: theme.colorScheme.onSurface,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncContent();
  }

  @override
  void didUpdateWidget(SrsWebCardFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncContent();
  }

  void _syncContent() {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    final String html = _html(context);
    if (html == _loadedHtml) return;
    _loadedHtml = html;
    unawaited(
      controller
          .loadData(data: html, mimeType: 'text/html', encoding: 'utf-8')
          .catchError((Object e, StackTrace stack) {
            ErrorLogService.instance.log('SrsWebCardFace.loadData', e, stack);
          }),
    );
  }

  Future<void> _injectBridge(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: srsReviewKeyBridgeScript);
    } catch (_) {
      // 页面正在换内容 / 平台视图重建：下一次 onLoadStop 会再注入。
    }
  }

  @override
  Widget build(BuildContext context) {
    final String html = _html(context);
    return KeyedSubtree(
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        initialData: InAppWebViewInitialData(
          data: html,
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          supportZoom: false,
          disableContextMenu: true,
          transparentBackground: false,
        ),
        onWebViewCreated: (InAppWebViewController controller) {
          _controller = controller;
          _loadedHtml = html;
          controller.addJavaScriptHandler(
            handlerName: _kSrsBridgeHandler,
            callback: (List<dynamic> arguments) {
              final Object? token = arguments.isEmpty ? null : arguments.first;
              if (token is String && mounted) widget.face.onBridgeKey(token);
              return null;
            },
          );
        },
        onLoadStop: (InAppWebViewController controller, _) =>
            _injectBridge(controller),
        // 非 null 本身就是救命动作：Java 侧据此 `return true`，不再连坐杀 app。
        onWebContentProcessDidTerminate: (InAppWebViewController _) =>
            unawaited(_deathGuard.handleWebContentTerminated()),
        onRenderProcessGone:
            (InAppWebViewController _, RenderProcessGoneDetail detail) =>
                unawaited(
                  _deathGuard.handleDeath(
                    didCrash: detail.didCrash,
                    rendererPriorityAtExit: detail.rendererPriorityAtExit,
                  ),
                ),
      ),
    );
  }
}

/// 纯文本卡面（测试 / 无 WebView 环境用）：把 HTML 去标签后直接显示。
class SrsPlainCardFace extends StatelessWidget {
  const SrsPlainCardFace({super.key, required this.face});

  final SrsCardFace face;

  @override
  Widget build(BuildContext context) {
    final String text = face.bodyHtml
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .trim();
    return SingleChildScrollView(
      padding: EdgeInsets.all(FushiDesignTokens.of(context).spacing.card),
      child: Text(
        text,
        key: ValueKey<String>(
          face.showingAnswer ? 'srs-face-answer' : 'srs-face-question',
        ),
        style: context.fushiType.titleLarge,
      ),
    );
  }
}
