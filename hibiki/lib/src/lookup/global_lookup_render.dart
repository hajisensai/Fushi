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
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/lookup/global_lookup_stack.dart';

String _cssRgb(Color c) => 'rgb(${(c.r * 255.0).round().clamp(0, 255)}, '
    '${(c.g * 255.0).round().clamp(0, 255)}, '
    '${(c.b * 255.0).round().clamp(0, 255)})';

// TODO-867 P3c — buildOverlayRenderScript (the single-frame TOP-LEVEL direct
// renderPopup path) is RETIRED. The top-level WebView2 document is now
// global_lookup_host.html (a bare iframe host with zero popup.js instance), so
// nothing can call window.renderPopup() at the top level. The single-frame
// lookup is stack depth 1: it renders through buildStackRenderScript ->
// window.__globalLookupHost.renderStack, exactly like a nested card, using
// buildFrameSettingsJs below for its per-frame settings body. The off-screen
// self-measure / top-pull gesture wiring that used to live here moves to the
// host (P3c阶段 D/E); per-frame settings keep their own theme/zoom/entries.

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
