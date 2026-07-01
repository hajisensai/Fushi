// TODO-895 single source of truth for the dictionary-popup WebView settings
// injection body. Both popup render paths feed the SAME popup assets and end in
// window.renderPopup(). The settings body was previously hand-copied TWICE (in-app
// _pushResults + app-outside buildFrameSettingsJs) and drifted: app-outside lost the
// dictionary font (D1), autoExpandDictionaries (D2), and the clamped/NaN-guarded zoom
// (D3). This builder is the ONE place that emits the shared body; the two call sites
// pass their own PopupSettingsOptions for the legitimate differences (app-outside
// global-lookup class + icon-font override + hidden mine button; in-app sentence i18n
// + instant-scroll + load-more orchestration).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/reader/dictionary_font_css.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:path/path.dart' as p;

/// Call-site-specific knobs for [buildPopupSettingsJs]. Everything that must be
/// IDENTICAL between the in-app popup and the app-outside global-lookup window
/// (theme/font/zoom/flags) is computed inside the builder; only the genuinely
/// different bits are toggled here.
class PopupSettingsOptions {
  const PopupSettingsOptions({
    this.globalLookup = false,
    this.mobileExternal = false,
    this.sentenceDraftEnabled = false,
  });

  /// App-outside (Windows bare-WebView2 global lookup) frame. Adds the
  /// `global-lookup` document class, the monochrome icon-font override, and
  /// hides the `.mine-button` (no card mining outside the app).
  final bool globalLookup;

  /// TODO-1065: the app-OUTSIDE / floating-subtitle popup (popup_main host). Adds
  /// the `mobile-external` document class so popup.css makes the `<html>`
  /// documentElement transparent (`html.mobile-external{background:transparent}`),
  /// killing the opaque full-viewport fill that washed the popup white over its
  /// transparent floating window. Mutually exclusive with [globalLookup] in
  /// practice (desktop bare-WebView2 vs mobile external window); the in-app popup
  /// sets neither.
  final bool mobileExternal;

  /// Whether popup.js should render the sentence-context picker. Currently gated
  /// off in both paths (kSentenceContextPickerEnabled), but the in-app path
  /// computes it from its host callbacks, so it stays a parameter.
  final bool sentenceDraftEnabled;
}

String _cssRgb(Color c) => 'rgb(${(c.r * 255.0).round().clamp(0, 255)}, '
    '${(c.g * 255.0).round().clamp(0, 255)}, '
    '${(c.b * 255.0).round().clamp(0, 255)})';

/// Builds the theme-derived CSS custom properties + `data-theme` (+ the
/// `global-lookup` document class when [globalLookup]). Shared by both paths so
/// the WebView surfaces follow the app ColorScheme identically.
String _themeVariablesJs({
  required AppModel appModel,
  required ThemeData theme,
  required bool globalLookup,
  required bool mobileExternal,
}) {
  final bool isDark = theme.brightness == Brightness.dark;
  final ColorScheme scheme = theme.colorScheme;
  final Color primary = scheme.primary;
  final String primaryRgba =
      'rgba(${(primary.r * 255.0).round().clamp(0, 255)}, '
      '${(primary.g * 255.0).round().clamp(0, 255)}, '
      '${(primary.b * 255.0).round().clamp(0, 255)}, 0.35)';
  final Color bgColor = appModel.overrideDictionaryColor ?? scheme.surface;
  // TODO-1065: mobileExternal tags the doc so popup.css `html.mobile-external`
  // turns the documentElement transparent (external popup washout fix), the
  // mobile analogue of the desktop global-lookup transparent-html rule.
  final String classLine = globalLookup
      ? "document.documentElement.classList.add('global-lookup');\n"
      : (mobileExternal
          ? "document.documentElement.classList.add('mobile-external');\n"
          : '');
  return '''
      $classLine      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
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
}

/// TODO-049 / TODO-895 D1: builds the JS that injects the user's DICTIONARY font
/// as a `<style id="hoshi-dict-font">` element (system family names + inlined
/// `data:` URL `@font-face` for imported files). Returns an empty string when no
/// dictionary font is configured. Shared so the app-outside window applies the
/// SAME font the in-app popup does.
String dictionaryFontStyleJs(AppModel appModel) {
  final ReaderSettings? settings = ReaderHibikiSource.readerSettings;
  if (settings == null) return '';
  final ({String fontFamily, String fontFaces}) css = DictionaryFontCss.build(
    settings.dictionaryFonts,
    allowedDirectories: <String>[
      p.join(appModel.appDirectory.path, 'custom_fonts'),
    ],
  );
  if (css.fontFamily.isEmpty) return '';
  final String styleCss = '${css.fontFaces}\n'
      'html, body { font-family: ${css.fontFamily}, '
      '"Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif !important; }';
  final String styleJson = jsonEncode(styleCss);
  return '''
      (function(){
        var el = document.getElementById('hoshi-dict-font');
        if (!el) {
          el = document.createElement('style');
          el.id = 'hoshi-dict-font';
          document.head.appendChild(el);
        }
        el.textContent = $styleJson;
      })();''';
}

/// TODO-867 P3c F1 / TODO-895 D6: the app-outside icon-font override. Forces the
/// monochrome "Segoe UI Symbol" font (which carries the audio/arrow/close glyphs)
/// and DROPS the colour-emoji font, plus hides the `.mine-button` (no mining in the
/// bare window). In-app popups never call this (they keep popup.css's default stack).
const String _globalLookupIconFontJs = '''
    (function(){
      var s = document.getElementById('hibiki-overlay-style');
      if (!s) {
        s = document.createElement('style');
        s.id = 'hibiki-overlay-style';
        s.textContent =
          '.mine-button{display:none !important;}' +
          '.audio-button,.glossary-group>summary::before{font-family:"Segoe UI Symbol","Segoe UI",sans-serif !important;}';
        document.head.appendChild(s);
      }
    })();''';

/// THE single source of truth for the popup settings injection body. Emits the
/// shared theme vars + dictionary font + content zoom + every `window.*` flag
/// (audio, dedup/harmonic, collapse + autoExpandDictionaries, collapsed/hidden
/// names, lookupEntries/kanjiResults, dictionary styles + custom CSS). Each call
/// site appends its own reset hooks + window.renderPopup() AFTER this body, so the
/// body intentionally does NOT call renderPopup itself.
///
/// [globalLookup] frames also receive the `global-lookup` class (in the theme vars)
/// and the monochrome icon-font override.
String buildPopupSettingsJs({
  required AppModel appModel,
  required ThemeData theme,
  required DictionarySearchResult result,
  required PopupSettingsOptions options,
}) {
  final String themeVarsJs = _themeVariablesJs(
    appModel: appModel,
    theme: theme,
    globalLookup: options.globalLookup,
    mobileExternal: options.mobileExternal,
  );
  final String fontStyleJs = dictionaryFontStyleJs(appModel);
  final double zoom = DictionaryPopupWebViewState.popupContentZoom(
    appUiScale: appModel.appUiScale,
    dictionaryFontSize: appModel.dictionaryFontSize,
  );

  final String entriesJson = result.popupJson ??
      DictionaryPopupWebViewState.buildLookupEntriesJson(result);
  final String kanjiResultsJson = jsonEncode(
    result.kanjiResults.map((HoshiKanjiResult k) => k.toMap()).toList(),
  );
  final String stylesJson = DictionaryPopupWebViewState.dictionaryStylesJson();
  final String collapsedNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isCollapsed(appModel.targetLanguage))
      .map((d) => d.name)
      .toList());
  final String hiddenNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isHidden(appModel.targetLanguage))
      .map((d) => d.name)
      .toList());

  final String iconFontJs = options.globalLookup ? _globalLookupIconFontJs : '';

  return '''
    $themeVarsJs
    $fontStyleJs
    $iconFontJs
    document.documentElement.style.zoom = '${zoom.toStringAsFixed(4)}';
    window.audioSources = ${jsonEncode(appModel.enabledAudioSources)};
    window.needsAudio = true;
    window.sentenceDraftEnabled = ${options.sentenceDraftEnabled};
    window._noResultsMessage = ${jsonEncode(t.no_search_results)};
    window.embedMedia = true;
    window.deduplicatePitchAccents = ${appModel.deduplicatePitchAccents};
    window.harmonicFrequency = ${appModel.harmonicFrequency};
    window.showExpressionTags = ${appModel.showExpressionTags};
    window.collapseDictionaries = ${appModel.collapseDictionaries};
    window.autoExpandDictionaries = ${appModel.popupAutoExpandDictionaries};
    window.collapsedDictionaryNames = $collapsedNames;
    window.hiddenDictionaryNames = $hiddenNames;
    try { window.lookupEntries = $entriesJson; } catch(e) { window.lookupEntries = []; }
    try { window.kanjiResults = $kanjiResultsJson; } catch(e) { window.kanjiResults = []; }
    window.dictionaryStyles = $stylesJson;
    window.globalDictCSS = ${jsonEncode(appModel.globalDictCSS)};
    window.customDictCSS = ${jsonEncode(appModel.customDictCSS)};
''';
}
