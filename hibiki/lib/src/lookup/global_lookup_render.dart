// TODO-617 global lookup overlay — render-script builder.
//
// Mirrors dictionary_popup_webview._pushResults so the bare-WebView2 overlay
// applies the SAME configuration the in-app popup does: theme/ColorScheme
// colours, content zoom (appUiScale + dictionary font size), pitch/frequency
// dedup, collapse/hidden dictionary filtering, custom CSS, gaiji embedding, the
// no-results message, plus lookupEntries/kanjiResults. Produces one JS string
// the native side ExecuteScripts, ending in renderPopup().
//
// Theme is read from the global navigator context (AppModel.navigatorKey), so
// no BuildContext needs to be threaded from the (UI-less) controller.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/reader/popup_swipe_close_script.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

String _cssRgb(Color c) => 'rgb(${(c.r * 255.0).round().clamp(0, 255)}, '
    '${(c.g * 255.0).round().clamp(0, 255)}, '
    '${(c.b * 255.0).round().clamp(0, 255)})';

/// Builds the full JS injection (settings + entries + renderPopup) for the
/// overlay. [result] may have no entries — popup.js then shows the no-results
/// state, so the caller should always render (never early-return on empty).
String buildOverlayRenderScript({
  required BuildContext context,
  required AppModel appModel,
  required DictionarySearchResult result,
}) {
  final ThemeData theme = Theme.of(context);
  final bool isDark = theme.brightness == Brightness.dark;
  final ColorScheme scheme = theme.colorScheme;

  final Color primary = scheme.primary;
  final String primaryRgba =
      'rgba(${(primary.r * 255.0).round().clamp(0, 255)}, '
      '${(primary.g * 255.0).round().clamp(0, 255)}, '
      '${(primary.b * 255.0).round().clamp(0, 255)}, 0.35)';
  final Color bgColor = appModel.overrideDictionaryColor ?? scheme.surface;

  final String themeVarsJs = '''
    document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
    document.documentElement.style.setProperty('--hoshi-primary-highlight', '$primaryRgba');
    document.documentElement.style.setProperty('--text-color', '${_cssRgb(scheme.onSurface)}');
    document.documentElement.style.setProperty('--background-color', '${_cssRgb(bgColor)}');
    document.documentElement.style.setProperty('--md-surface-container', '${_cssRgb(scheme.surfaceContainer)}');
    document.documentElement.style.setProperty('--md-surface-container-high', '${_cssRgb(scheme.surfaceContainerHigh)}');
    document.documentElement.style.setProperty('--md-outline-variant', '${_cssRgb(scheme.outlineVariant)}');
    document.documentElement.style.setProperty('--md-on-surface-variant', '${_cssRgb(scheme.onSurfaceVariant)}');
    document.documentElement.style.setProperty('--md-primary', '${_cssRgb(scheme.primary)}');
    document.documentElement.style.setProperty('--dict-columns', '${appModel.popupDictionaryColumns}');
''';

  final String entriesJson = result.popupJson ?? '[]';
  final String kanjiResultsJson = jsonEncode(
    result.kanjiResults.map((HoshiKanjiResult k) => k.toMap()).toList(),
  );
  final String stylesJson = jsonEncode(HoshiDicts.dictionaryStyles);
  final double zoom =
      appModel.appUiScale * (appModel.dictionaryFontSize / 16.0);
  final String collapsedNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isCollapsed(appModel.targetLanguage))
      .map((d) => d.name)
      .toList());
  final String hiddenNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isHidden(appModel.targetLanguage))
      .map((d) => d.name)
      .toList());

  return '''
    $themeVarsJs
    (function(){
      var s = document.getElementById('hibiki-overlay-style');
      if (!s) {
        s = document.createElement('style');
        s.id = 'hibiki-overlay-style';
        // Read-only out-of-app lookup: hide the mining (+) button. Also give the
        // symbol glyphs (audio music-note, collapse arrows) a Windows symbol
        // font so they don't render as tofu under popup.css's forced macOS font.
        s.textContent =
          '.mine-button{display:none !important;}' +
          '.audio-button,.glossary-group>summary{font-family:"Segoe UI Symbol","Segoe UI Emoji","Segoe UI",sans-serif !important;}';
        document.head.appendChild(s);
      }
    })();
    document.documentElement.style.zoom = '${zoom.toStringAsFixed(4)}';
    window.audioSources = ${jsonEncode(appModel.enabledAudioSources)};
    window.needsAudio = true;
    window.sentenceDraftEnabled = false;
    window._noResultsMessage = ${jsonEncode(t.no_search_results)};
    window.embedMedia = true;
    window.deduplicatePitchAccents = ${appModel.deduplicatePitchAccents};
    window.harmonicFrequency = ${appModel.harmonicFrequency};
    window.showExpressionTags = ${appModel.showExpressionTags};
    window.collapseDictionaries = ${appModel.collapseDictionaries};
    window.collapsedDictionaryNames = $collapsedNames;
    window.hiddenDictionaryNames = $hiddenNames;
    try { window.lookupEntries = $entriesJson; } catch(e) { window.lookupEntries = []; }
    try { window.kanjiResults = $kanjiResultsJson; } catch(e) { window.kanjiResults = []; }
    window.dictionaryStyles = $stylesJson;
    window.globalDictCSS = ${jsonEncode(appModel.globalDictCSS)};
    window.customDictCSS = ${jsonEncode(appModel.customDictCSS)};
    if (window.resetSentenceContextMirror) window.resetSentenceContextMirror();
    if (window.resetSelectedDictionaries) window.resetSelectedDictionaries();
    window.renderPopup && window.renderPopup();
    // Self-measure for the bare overlay window. The card has no intrinsic
    // width (body fills the viewport), so Dart sizes the window's WIDTH from
    // the known logical box (popupMaxWidth * appUiScale) * devicePixelRatio —
    // devicePixelRatio is only knowable here (= monitor DPI scale). HEIGHT is
    // the physical scrollHeight (scrollHeight already includes the CSS zoom
    // magnification; * dpr converts CSS px -> physical px). Re-posts on resize
    // so the height re-measures once Dart has applied the correct width.
    (function(){
      if (window.__hibikiOverlaySizeWired) { window.__hibikiPostOverlaySize(); return; }
      window.__hibikiOverlaySizeWired = true;
      window.__hibikiPostOverlaySize = function(){
        try {
          var dpr = window.devicePixelRatio || 1;
          // Measure CONTENT height (body), NOT documentElement.scrollHeight:
          // the root element's scrollHeight is clamped to the viewport, so a
          // short card in the tall off-screen render window would report the
          // window height (max) instead of the content. body height is the
          // true content height -> short cards fit snugly, tall cards cap+scroll.
          var b = document.body;
          var contentH = b ? Math.max(b.scrollHeight, b.getBoundingClientRect().height) : 0;
          var h = Math.ceil(contentH * dpr);
          window.chrome.webview.postMessage({handler: 'overlaySize', args: [dpr, h]});
        } catch (e) {}
      };
      window.addEventListener('resize', function(){
        requestAnimationFrame(window.__hibikiPostOverlaySize);
      });
      requestAnimationFrame(function(){
        requestAnimationFrame(window.__hibikiPostOverlaySize);
      });
    })();
    // TODO-854 M1a-2：给覆盖窗也挂下滑关闭手势识别（pointer/mouse，桌面
    // WebView2 不触发 touch）。回调 topPullReleased 经原生 callHandler shim
    // 桥到 chrome.webview.postMessage，由 GlobalLookupController 据用户
    // enableSwipeToClose 偏好决定是否真正 hide。
    $kPopupTopPullReleaseJs
''';
}
