import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/dictionary/dict_style_preview_sample.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/misc/webview_asset_url.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// 词典样式实时预览：跑**真的** `popup.html` + `popup.js`，喂一条样例词条。
///
/// 不自绘近似渲染——近似的东西在振假名、结构化内容、词典自带 styles.css 上必然
/// 失真，用户照着预览调完，真弹窗里是另一个样子。这里渲染路径与真弹窗同源，
/// 连内联/file:// 的平台分叉都复用 [DictionaryPopupWebViewState] 的判断。
///
/// 点选也在这里：picker JS **只注入预览这一个 WebView**，`popup.js` 一行不改，
/// 因此不牵扯 assets/popup 的三份镜像同步。
class DictStylePreview extends StatefulWidget {
  const DictStylePreview({
    super.key,
    required this.css,
    required this.highlightPart,
    required this.onPickPart,
  });

  /// 当前规则编译出的 CSS，改一次换一次（不重载页面）。
  final String css;

  /// 当前选中的部位，在预览里描边标出。
  final DictStylePart highlightPart;

  /// 用户在预览里点了某个部位。
  final ValueChanged<DictStylePart> onPickPart;

  @override
  State<DictStylePreview> createState() => _DictStylePreviewState();
}

class _DictStylePreviewState extends State<DictStylePreview> {
  InAppWebViewController? _controller;
  final WebViewDeathGuard _deathGuard =
      WebViewDeathGuard(surface: 'dict-style-preview');
  bool _ready = false;

  @override
  void didUpdateWidget(DictStylePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.css != widget.css ||
        oldWidget.highlightPart != widget.highlightPart) {
      unawaited(_pushStyles());
    }
  }

  /// 只换 `<style>` 内容，不重渲染词条——重渲染会把滚动位置和折叠态打回去，
  /// 拖滑块时那是一帧一跳。
  Future<void> _pushStyles() async {
    final InAppWebViewController? controller = _controller;
    if (controller == null || !_ready) return;
    await controller.evaluateJavascript(
      source: '''
        window.__fushiStylePreviewApply(
          ${jsonEncode(widget.css)},
          ${jsonEncode(dictStylePartSelector(widget.highlightPart))}
        );
      ''',
    );
  }

  /// 首次加载完成后的一次性引导。
  ///
  /// `popup.js` 没有任何 DOMContentLoaded 自动渲染钩子，必须手动调
  /// `window.renderPopup()`；`data-theme` 也必须设，否则 `--text-color` /
  /// `--background-color` 在 popup.css 里根本没有定义值，整页透明。
  Future<void> _bootstrap() async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    await controller.evaluateJavascript(
      source: '''
        document.documentElement.setAttribute('data-theme', '${dark ? 'dark' : 'light'}');
        window.lookupEntries = ${jsonEncode(kDictStylePreviewEntries)};
        window.kanjiResults = [];
        // 不开这个就没有 .expr-tag 那一段，对应部位在预览里选不中。
        window.showExpressionTags = true;
        // 预览不该继承用户已存的自定义 CSS：那样调出来的效果里混着旧规则，
        // 分不清哪一条是这次改的。
        window.globalDictCSS = '';
        window.customDictCSS = {};
        $_kPickerJs
        window.renderPopup();
      ''',
    );
    _ready = true;
    await _pushStyles();
  }

  @override
  Widget build(BuildContext context) {
    final bool inline = DictionaryPopupWebViewState.shouldInlinePopupAssets;
    final ThemeData theme = Theme.of(context);
    return KeyedSubtree(
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        initialData: inline
            ? InAppWebViewInitialData(
                data: DictionaryPopupWebViewState.buildInlinePopupHtml(
                  themeAttr:
                      theme.brightness == Brightness.dark ? 'dark' : 'light',
                  bgHex: _hex(theme.colorScheme.surface),
                ),
                mimeType: 'text/html',
                encoding: 'utf-8',
              )
            : null,
        initialUrlRequest: inline
            ? null
            : URLRequest(
                url: WebUri(webViewAssetUrl('assets/popup/popup.html')),
              ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          supportZoom: false,
          disableContextMenu: true,
          horizontalScrollBarEnabled: false,
          transparentBackground: false,
        ),
        onWebViewCreated: (InAppWebViewController controller) {
          _controller = controller;
          for (final String name in kDictStylePreviewNoopHandlers) {
            controller.addJavaScriptHandler(
              handlerName: name,
              callback: (List<dynamic> _) => null,
            );
          }
          controller.addJavaScriptHandler(
            handlerName: 'fushiStylePickPart',
            callback: (List<dynamic> args) {
              final Object? raw = args.isEmpty ? null : args.first;
              if (raw is! String || !mounted) return null;
              for (final DictStylePart part in DictStylePart.values) {
                if (part.name == raw) {
                  widget.onPickPart(part);
                  break;
                }
              }
              return null;
            },
          );
        },
        onLoadStop: (_, __) => unawaited(_bootstrap()),
        // 非 null 本身就是救命动作：Java 侧据此 return true，不再连坐杀 app。
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

  String _hex(Color c) {
    final int argb = c.toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }
}

/// popup.js / selection.js 能发起的**全部** JS 桥调用名，在预览里一律 no-op。
///
/// 两件事各自成立：
/// * 行为上——预览只是调样式，制卡 / 播音 / 跳转 / 上报都不该真发生；
///   `favoriteCheck` / `duplicateCheck` 这类在渲染词条头时**无保护地**被调，
///   没注册就抛 TypeError、被 renderPopup 的 try/catch 吞掉 → 整张卡片白屏。
/// * 存活上——BUG-1918：Dart 侧没注册的 handler 名会让插件回一个 **null**
///   答复（`_handleMethod` 末尾 `return null`），Windows 原生侧把它当非空指针
///   解引用 → 0xC0000005 整个 app 闪退。原生已根治（webview_channel_delegate.cpp
///   的 decodeResult 空守卫），但预览本身也不应该依赖平台兜底：每个桥调用
///   都得有确定的 Dart 侧语义。
///
/// 这份名单必须覆盖 popup.html 加载的所有脚本里的 `callHandler('X')`，
/// 守卫测试：`fushi/test/pages/dict_style_preview_handler_coverage_test.dart`。
const List<String> kDictStylePreviewNoopHandlers = <String>[
  'clearSentenceDraft',
  'duplicateCheck',
  'favoriteCheck',
  'favoriteEntry',
  'findMinedMatches',
  'mineEntry',
  'minedCardAction',
  'onLinkClick',
  'openInAnki',
  'openLink',
  'openMinedNote',
  'openSentenceContextModal',
  'overwriteTargetNoteId',
  'panelSentenceLookup',
  'popupRendered',
  'reportJsError',
  'resolveWordAudio',
  'setSentenceContext',
  'tapOutside',
  'textSelected',
  'updateEntry',
];

/// 注入预览 WebView 的点选逻辑。
///
/// 部位 → 选择器表由 Dart 侧生成，避免两边各维护一份而漂移。
final String _kPickerJs = '''
  window.__fushiStylePreviewParts = ${jsonEncode(<Map<String, String>>[
      for (final DictStylePart part in DictStylePart.values)
        <String, String>{
          'name': part.name,
          'selector': dictStylePartSelector(part),
        },
    ])};

  (function () {
    if (window.__fushiStylePreviewInstalled) return;
    window.__fushiStylePreviewInstalled = true;

    var styleEl = null;
    var hoverEl = null;

    // 命中最内层的可调部位：从事件目标往上找第一个匹配的祖先。反过来（从外往内）
    // 会让点释义永远选中词条卡。
    function partAt(node) {
      var parts = window.__fushiStylePreviewParts || [];
      while (node && node !== document.documentElement) {
        for (var i = 0; i < parts.length; i++) {
          if (node.matches && node.matches(parts[i].selector)) return parts[i];
        }
        node = node.parentElement;
      }
      return null;
    }

    window.__fushiStylePreviewApply = function (css, highlightSelector) {
      if (!styleEl) {
        styleEl = document.createElement('style');
        styleEl.id = 'fushi-style-preview';
        document.body.appendChild(styleEl);
      }
      // 选中部位描边用 outline 而非 border：border 会改变盒子尺寸，选来选去
      // 整个布局跟着抖，用户以为是自己的样式把排版搞坏了。
      var marker = highlightSelector
        ? highlightSelector + '{outline:2px dashed rgba(120,160,255,.9);outline-offset:1px;}'
        : '';
      styleEl.textContent = css + '\\n' + marker;
    };

    document.addEventListener('mousemove', function (e) {
      var hit = partAt(e.target);
      var el = hit ? e.target.closest(hit.selector) : null;
      if (el === hoverEl) return;
      if (hoverEl) hoverEl.style.removeProperty('cursor');
      hoverEl = el;
      if (hoverEl) hoverEl.style.setProperty('cursor', 'pointer');
    }, true);

    // 捕获阶段 + 阻断：popup.js 自己在词头/折叠三角/制卡按钮上都挂了点击，
    // 预览里那些行为（播音频、制卡、展开）都不该发生。
    document.addEventListener('click', function (e) {
      var hit = partAt(e.target);
      if (!hit) return;
      e.preventDefault();
      e.stopPropagation();
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('fushiStylePickPart', hit.name);
      }
    }, true);
  })();
''';
