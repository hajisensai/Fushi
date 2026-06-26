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
import 'package:hibiki/src/lookup/global_lookup_stack.dart';

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

  // TODO-867 P2: tag the document as the app-OUTSIDE global-lookup host so
  // popup.css can apply the hoshi-style card chrome + flex-wrap variable-height
  // sub-boxes ONLY here. In-app popups (dictionary_popup_webview) never add this
  // class, so their Flutter-Material card chrome + tested --dict-columns grid
  // stay untouched (zero regression). The marker lives on documentElement next
  // to data-theme so it is re-applied on every render alongside the theme vars.
  final String themeVarsJs = '''
    document.documentElement.classList.add('global-lookup');
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

/// Builds the per-frame settings JS body for ONE lookup card (TODO-867 P3b
/// nested stack). This is the SAME configuration body buildOverlayRenderScript
/// emits for the single-frame overlay (theme vars, window flags, zoom,
/// lookupEntries/kanjiResults, custom CSS, renderPopup()), but parameterised by
/// [result] so each stacked iframe can be fed its own entries. It deliberately
/// omits the bare-overlay self-measure / top-pull gesture wiring — those belong
/// to the single-frame overlay window, not to an iframe inside the host shell.
///
/// The string is meant to be eval'd INSIDE a frame's contentWindow by
/// global_lookup_host.js injectContent, so every `window.` / `document.`
/// reference targets that frame's own realm.
String buildFrameSettingsJs({
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
    document.documentElement.classList.add('global-lookup');
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
''';
}

/// One stacked lookup card as the host script expects it (TODO-867 P3b). [frame]
/// supplies the stack identity/linkage (id, parentIndex); [result] supplies the
/// per-frame entries; geometry is a deterministic placeholder (固定级联偏移) in
/// P3b — real cascade coordinates / per-frame measurement land in P3c.
class GlobalLookupFramePayload {
  const GlobalLookupFramePayload({
    required this.frame,
    required this.result,
  });

  final GlobalLookupFrame frame;
  final DictionarySearchResult result;
}

/// Deterministic placeholder cascade offset (logical px) per stack depth. P3b
/// just fans the cards out by a fixed step so a multi-frame stack is visibly
/// distinct; P3c replaces this with real anchored cascade coordinates.
const double kGlobalLookupCascadeStep = 28.0;

/// Builds the full stack render script for the host (TODO-867 P3b). Serialises
/// every frame into the `{ popups: [...] }` payload global_lookup_host.js
/// renderStack consumes, then calls window.__globalLookupHost.renderStack(...).
///
/// Each popup carries: id, parentIndex, a placeholder cascade `frame` rect, and
/// a `settingsJs` string (this frame's own buildFrameSettingsJs body, run inside
/// its iframe realm). buildOverlayRenderScript is untouched — the single-frame
/// overlay path stays exactly as it was; this is an additive, global-lookup-only
/// renderer.
String buildStackRenderScript({
  required BuildContext context,
  required AppModel appModel,
  required List<GlobalLookupFramePayload> payloads,
}) {
  final List<Map<String, Object?>> popups = <Map<String, Object?>>[];
  for (int i = 0; i < payloads.length; i++) {
    final GlobalLookupFramePayload p = payloads[i];
    final String settingsJs = buildFrameSettingsJs(
      context: context,
      appModel: appModel,
      result: p.result,
    );
    final Map<String, Object?> map = p.frame.toRenderMap();
    final double offset = kGlobalLookupCascadeStep * i;
    map['frame'] = <String, Object?>{
      'left': offset,
      'top': offset,
    };
    map['settingsJs'] = settingsJs;
    popups.add(map);
  }
  final String payloadJson = jsonEncode(<String, Object?>{'popups': popups});
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.renderStack($payloadJson);';
}
