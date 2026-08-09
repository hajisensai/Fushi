import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-867 P2 — guards for the app-OUTSIDE global-lookup popup styling.
///
/// popup.css/js are SHARED by the in-app popup (Flutter-Material card chrome)
/// and the bare Windows global-lookup WebView2 window (no native card). The card
/// chrome (#1) MUST stay scoped to `html.global-lookup` so the in-app popup is
/// untouched. The old sub-box divergence (#2/#3: global-lookup flex-wrap) was
/// REMOVED — first-result equal-height stretch is now killed for ALL surfaces by
/// the base grid `align-items:start` (BUG-683) + the shared masonry, so app-外/
/// 扩展 use the same fixed --dict-columns columns as in-app (用户「左右动」根因修：
/// flex-wrap 按窗口宽重排的漂移已消)。These guards lock the chrome scoping AND that
/// global-lookup no longer re-introduces a flex-wrap override.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('scope marker', () {
    test('the shared builder injects the global-lookup class (gated)', () {
      // TODO-895: the document tag moved into the SINGLE source of truth, gated
      // behind globalLookup so only the app-outside frame applies the scoped
      // popup.css chrome. The render.dart shim requests it via globalLookup:true.
      final String inject =
          read('lib/src/pages/implementations/popup_settings_injection.dart');
      expect(
        inject.contains(
            "document.documentElement.classList.add('global-lookup')"),
        isTrue,
        reason: 'the shared builder must tag the document when globalLookup',
      );
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(
          render.contains('PopupSettingsOptions(globalLookup: true)'), isTrue,
          reason:
              'the app-outside frame must request the global-lookup options');
    });

    test('in-app dictionary_popup_webview NEVER adds the global-lookup class',
        () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(
        src.contains("classList.add('global-lookup')"),
        isFalse,
        reason: 'the in-app popup must NOT tag itself global-lookup — its card '
            'chrome is the Flutter Material card; adding it would double-frame '
            'and switch the tested grid to flex-wrap (regression)',
      );
    });
  });

  group('popup.css scoping (source)', () {
    late String css;
    setUpAll(() => css = read('assets/popup/popup.css'));

    test('card chrome is scoped to html.global-lookup body, not bare body', () {
      expect(css.contains('html.global-lookup body {'), isTrue,
          reason: 'hoshi card chrome must live under the global-lookup scope');
      // The chrome props (radius/border) must not appear in the bare body rule.
      final int bareStart = RegExp(r'(^|\n)body \{').firstMatch(css)!.start;
      final int bareEnd = css.indexOf('}', bareStart);
      final String bareBody = css.substring(bareStart, bareEnd);
      expect(bareBody.contains('border-radius'), isFalse,
          reason: 'bare body{} feeds the in-app popup — no card radius there');
      expect(bareBody.contains('box-shadow'), isFalse);
    });

    test(
        'global-lookup shares the in-app grid — NO flex-wrap divergence (消左右动)',
        () {
      expect(css.contains('.glossary-section > .category-body {'), isTrue);
      // in-app rule keeps the --dict-columns grid.
      final int gridAt = css.indexOf('.glossary-section > .category-body {');
      final String gridRule = css.substring(gridAt, css.indexOf('}', gridAt));
      expect(gridRule.contains('display: grid'), isTrue,
          reason: 'the tested --dict-columns grid must remain for in-app');
      expect(gridRule.contains('align-items: start'), isTrue,
          reason: 'align-items:start 让所有面（含 app 外）取自然高度、免 grid stretch，'
              '这正是删掉 global-lookup flex 覆盖后不回退首卡偏高的根据');

      // 用户「词典方框怎么能左右动，Niratan 不会」根因：app 外/扩展原本把 grid 覆盖成
      // flex-wrap（flex:1 1 auto; min-width:160px），每行卡片数随窗口宽变、卡片随内容宽
      // 伸缩漂移。已删除该覆盖，app 外/扩展与 in-app 共用固定列 grid + masonry，锁死不得回归。
      expect(
        css.contains('html.global-lookup .glossary-section > .category-body {'),
        isFalse,
        reason: 'global-lookup 不得再用独立 flex-wrap 覆盖 .category-body — '
            '那会让 app 外/扩展词典方框按窗口宽左右重排漂移（用户投诉的「左右动」），'
            '与 in-app 固定列 / Niratan 都不一致',
      );
      expect(
        css.contains(
            'html.global-lookup .glossary-section > .category-body > .glossary-group {'),
        isFalse,
        reason: 'global-lookup 的 glossary-group flex 覆盖（flex:1 1 auto; '
            'min-width:160px 让卡片按内容宽伸缩）必须随之删除，回落 base grid 固定列',
      );
    });
  });

  group('P3c F1 — icon glyph fix (route A: monochrome symbol font)', () {
    // TODO-895: the icon-font override moved into the SINGLE source of truth
    // popup_settings_injection.dart, gated behind options.globalLookup so only the
    // app-outside path emits it. The in-app popup still never receives it.
    late String inject;
    setUpAll(() => inject =
        read('lib/src/pages/implementations/popup_settings_injection.dart'));

    test('global-lookup iframe forces the monochrome Segoe UI Symbol font', () {
      // The popup card icons are Unicode chars (audio U+266A, arrows U+25B6/
      // U+25BC), NOT Material codepoints. Route A: give them a Windows font that
      // CARRIES those glyphs and is MONOCHROME, so they don't render as oversized
      // colour emoji.
      expect(inject.contains('"Segoe UI Symbol"'), isTrue,
          reason: 'must pin the monochrome symbol font that carries ♪/▶/▼');
    });

    test('the emoji font is DROPPED (no colour-emoji rendering of ♪/✕)', () {
      // "Segoe UI Emoji" in the stack is exactly what made Windows render ♪/✕ as
      // colour emoji (the reported "icon shows wrong"); it must be gone.
      expect(inject.contains('Segoe UI Emoji'), isFalse,
          reason: 'the emoji font caused the colour-emoji symbol rendering');
    });

    test('the icon font is applied to the audio button + collapse arrow glyph',
        () {
      // .audio-button = ♪ ; .glossary-group>summary::before = ▶/▼ content glyph.
      expect(inject.contains('.audio-button'), isTrue);
      expect(inject.contains('.glossary-group>summary::before'), isTrue,
          reason: 'the arrow glyph lives in the ::before content, so the font '
              'override must target the pseudo-element');
    });

    test(
        'the icon override is gated behind options.globalLookup (in-app never)',
        () {
      // The override is only emitted when options.globalLookup is true; the in-app
      // popup builds the shared body with globalLookup:false, so it never receives
      // the icon font. The render.dart shim still calls buildPopupSettingsJs with
      // globalLookup:true.
      expect(inject.contains('options.globalLookup ? _globalLookupIconFontJs'),
          isTrue,
          reason: 'icon override must be conditional on the globalLookup flag');
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(
          render.contains('PopupSettingsOptions(globalLookup: true)'), isTrue,
          reason:
              'the app-outside frame must request the global-lookup options');
      final String inApp =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(inApp.contains('Segoe UI Symbol'), isFalse,
          reason:
              'in-app popup must not carry the global-lookup icon override');
    });
  });

  group('P3c F2 — outer shell chrome (.global-lookup-frame-shell)', () {
    late String host;
    setUpAll(() => host = read('assets/popup/global_lookup_host.js'));

    test('shell carries ONLY the radius, NO border and NO box-shadow', () {
      // TODO-893 symptom 1 — RESPONSIBILITY SPLIT. The single visible card
      // border belongs to the iframe (popup.css `html.global-lookup body`); the
      // shell must NOT draw a second border (that produced two concentric grey
      // rings with a white gap = the reported "white frame"). The shell keeps
      // the radius so the overflow clip follows the rounded card.
      //
      // BUG-709 — the shell must ALSO cast NO box-shadow. The overlay HWND is a
      // NON-layered, opaque WebView2 window (global_lookup_window.cpp: "No
      // WS_EX_LAYERED"), so a CSS box-shadow has no translucent desktop to blend
      // over: its blur paints onto the window's own hard-dark surface as an
      // ~11px DARK HALO ringing the card corners/edges that the native rounded
      // window region (SetWindowRgn) cannot clip away — exactly the "black
      // border outside the rounded corners" the user reported. A real shadow is
      // impossible on a non-layered WebView2 window, so the shell casts none.
      expect(host.contains('.global-lookup-frame-shell{'), isTrue);
      expect(host.contains('border-radius:10px'), isTrue,
          reason:
              'hoshi 10px card radius (drives the overflow clip silhouette)');
      // Match the CSS DECLARATION form (`box-shadow:`) so the doc comments in
      // host.js that mention the word "box-shadow" do not trip the guard.
      expect(host.contains('box-shadow:'), isFalse,
          reason:
              'no box-shadow declaration: on the non-layered opaque overlay '
              'it is a dark halo outside the card, not a real shadow (lock)');
    });

    test('shell draws NO solid border (single border lives on the iframe body)',
        () {
      // The fix is exactly the removal of the shell border. Lock it so a later
      // edit cannot reintroduce the double-border. The border lives ONLY in
      // popup.css `html.global-lookup body` now.
      expect(host.contains('border:1px solid rgba(120,120,128,0.36)'), isFalse,
          reason: 'shell border was the double-border main cause; it is gone');
      expect(host.contains('border-color:rgba(255,255,255,0.34)'), isFalse,
          reason: 'the dark shell border-color override is gone too');
    });

    test('the SINGLE border lives on the iframe body (popup.css), not doubled',
        () {
      final String css = read('assets/popup/popup.css');
      // popup.css owns the one visible border.
      expect(css.contains('html.global-lookup body {'), isTrue);
      final int bodyAt = css.indexOf('html.global-lookup body {');
      final String bodyRule = css.substring(bodyAt, css.indexOf('}', bodyAt));
      expect(bodyRule.contains('border: 1px solid rgba(120, 120, 128, 0.36)'),
          isTrue,
          reason: 'the iframe body owns the one visible card border');
    });

    test('shell background stays transparent (iframe paints the card fill)',
        () {
      // The iframe (popup.html) already paints the THEME background + the
      // html.global-lookup body border, so the shell must NOT add a second fill.
      // The chrome rule is the .global-lookup-frame-shell block carrying the
      // radius (the first such block is the D1 reveal-gate visibility rule).
      final int chromeAt = host.indexOf('border-radius:10px');
      final int ruleStart =
          host.lastIndexOf('.global-lookup-frame-shell{', chromeAt);
      final String rule =
          host.substring(ruleStart, host.indexOf('}', chromeAt));
      expect(rule.contains('background:transparent'), isTrue,
          reason: 'shell owns only the rounded clip + shadow, not the fill');
    });

    test('shell stamps data-theme from the render payload (no themed shadow)',
        () {
      // BUG-709 — the shell no longer carries a themed box-shadow (the dark
      // `[data-theme="dark"]{box-shadow}` variant was the only shell-LEVEL themed
      // rule, and it is gone — a shadow is a dark halo on the non-layered
      // overlay, see the box-shadow guard above). Assert that shell-level themed
      // rule is gone by matching the `[data-theme="dark"]{` form (the bracket
      // then an IMMEDIATE brace). The close-X descendant rule
      // `[data-theme="dark"] .global-lookup-close{` (a space then the child
      // selector) is a SEPARATE, legitimate themed rule and must stay. The
      // per-layer data-theme STAMP still flows from the render payload onto the
      // shell so a future themed shell rule (or debugging) can read it; assert
      // the plumbing stays wired even though no shell-level rule consumes it now.
      expect(host.contains('.global-lookup-frame-shell[data-theme="dark"]{'),
          isFalse,
          reason: 'the dark box-shadow shell variant is gone (no shell-level '
              'themed rule left)');
      expect(host.contains('descriptor && descriptor.theme'), isTrue,
          reason: 'host.js must still stamp data-theme from the descriptor');
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(render.contains("map['theme'] ="), isTrue,
          reason: 'the render payload must carry the resolved brightness');
    });

    test('the shell chrome stays global-lookup scoped (host.js only)', () {
      // host.js is C++-injected into the global-lookup window ONLY; the in-app
      // popup never loads it, so .global-lookup-frame-shell can never reach it.
      expect(host.contains('window.top !== window.self'), isTrue,
          reason: 'host runs on the top-level global-lookup document only');
    });
  });

  group('native rounded window (C++)', () {
    test('global_lookup_window rounds the opaque window via SetWindowRgn', () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      expect(cpp.contains('ApplyRoundedRegion'), isTrue);
      expect(cpp.contains('CreateRoundRectRgn'), isTrue,
          reason: 'opaque non-layered window needs a region for real round '
              'corners (CSS radius alone leaves square window corners)');
      expect(cpp.contains('SetWindowRgn'), isTrue);
      // Applied on size change so the region tracks the settled window size.
      final int sizeAt = cpp.indexOf('case WM_SIZE:');
      final int applyAt = cpp.indexOf('ApplyRoundedRegion();', sizeAt);
      expect(applyAt, greaterThan(sizeAt),
          reason: 'region must be (re)applied on WM_SIZE');
    });

    test('header declares ApplyRoundedRegion', () {
      final String h = read('windows/runner/global_lookup_window.h');
      expect(h.contains('void ApplyRoundedRegion();'), isTrue);
    });
  });

  group('TODO-895 — settings injection is a single source of truth', () {
    late String inject;
    late String render;
    late String inApp;
    setUpAll(() {
      inject =
          read('lib/src/pages/implementations/popup_settings_injection.dart');
      render = read('lib/src/lookup/global_lookup_render.dart');
      inApp =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    });

    test('both call sites go through the shared settings builders', () {
      // app-outside (buildFrameSettingsJs) and in-app (_pushResults) must both
      // delegate to the shared builders in popup_settings_injection.dart, so the
      // settings body can never drift again. BUG-712 ③: the composed
      // buildPopupSettingsJs stays the single source of truth (byte-identical
      // output) and the app-outside frame still calls it; the in-app hot-slot
      // path splits it into the static half (buildPopupStaticSettingsJs) + the
      // per-lookup entries half (buildPopupEntriesJs) to dedup the persistent
      // WebView's static payload — the SAME shared builders buildPopupSettingsJs
      // composes, so single-source-of-truth still holds.
      expect(inject.contains('String buildPopupSettingsJs('), isTrue,
          reason: 'the single source of truth builder must exist');
      expect(
          inject.contains('PopupStaticSettingsJs buildPopupStaticSettingsJs('),
          isTrue,
          reason: 'the shared static-settings builder must exist');
      expect(inject.contains('String buildPopupEntriesJs('), isTrue,
          reason: 'the shared per-lookup entries builder must exist');
      expect(render.contains('buildPopupSettingsJs('), isTrue,
          reason:
              'the app-outside frame must call the shared composed builder');
      expect(inApp.contains('buildPopupStaticSettingsJs('), isTrue,
          reason:
              'the in-app popup must call the shared static-settings builder');
      expect(inApp.contains('buildPopupEntriesJs('), isTrue,
          reason: 'the in-app popup must call the shared entries builder');
    });

    test('D1 — the dictionary font is injected by the shared builder', () {
      // app-outside used to lack the user dictionary font entirely; it now flows
      // through the shared font helper, so both paths apply the same font.
      expect(inject.contains("id = 'fushi-dict-font'"), isTrue,
          reason: 'the shared builder must inject the dictionary font style');
      expect(inject.contains('DictionaryFontCss.build('), isTrue,
          reason: 'the font CSS must be built from the user dictionary fonts');
      // The app-outside file must NOT carry its own second font injection.
      expect(render.contains('fushi-dict-font'), isFalse,
          reason: 'app-outside must not re-implement the font injection');
    });

    test('D2 — autoExpandRows is in the shared body', () {
      // app-outside previously dropped this flag (folded popups never auto-
      // expanded). It now lives in the one body both paths emit. The value is
      // the auto-expand ROW count; popup.js multiplies it by the effective
      // column count (autoExpandCount) to get the expanded block count.
      expect(inject.contains('window.autoExpandRows ='), isTrue,
          reason: 'the shared body must inject autoExpandRows');
      expect(inject.contains('appModel.popupAutoExpandDictionaries'), isTrue);
      // No second INJECTION of the flag in the app-outside file (a doc-comment
      // mention is fine; the actual `window.autoExpandRows =` must not
      // be duplicated there).
      expect(render.contains('window.autoExpandRows ='), isFalse,
          reason: 'app-outside must not re-inject the flag (single source)');
    });

    test('D3 — content zoom uses the clamped/NaN-guarded helper only', () {
      // app-outside used a bare inline `appUiScale * (...)` with no clamp/NaN
      // guard. The shared body must call popupContentZoom (the clamped helper),
      // and NEITHER builder may compute zoom inline anymore.
      expect(inject.contains('DictionaryPopupWebViewState.popupContentZoom('),
          isTrue,
          reason: 'the shared body must use the clamped zoom helper');
      expect(render.contains('appUiScale * ('), isFalse,
          reason: 'app-outside must not compute zoom inline (drift source)');
      expect(inject.contains('appModel.appUiScale * ('), isFalse,
          reason: 'the shared builder must defer zoom to popupContentZoom');
    });
  });

  group('TODO-893 v2 — three reopened symptoms (source guards)', () {
    test('symptom 1 — controller dispatches BOTH onLinkClick and textSelected',
        () {
      // Tapping plain glossary text emits textSelected (not onLinkClick); the
      // app-external controller used to register only onLinkClick, silently
      // dropping body taps. Lock that both handlers reach the shared nested
      // dispatch so a body tap opens a child card.
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      expect(controller.contains("handler == 'textSelected'"), isTrue,
          reason: 'controller must handle the textSelected (body tap) trigger');
      expect(controller.contains("handler == 'onLinkClick'"), isTrue,
          reason: 'onLinkClick (headword/kanji) must still dispatch');
      expect(controller.contains('_dispatchNestedLookup('), isTrue,
          reason: 'both triggers share one dispatch helper (no special case)');
    });

    test('symptom 1 — host.js re-anchors textSelected like onLinkClick', () {
      // textSelected carries the same iframe-LOCAL rect in args[1]; without the
      // re-anchor the child card anchors at iframe-internal coords.
      final String host = read('assets/popup/global_lookup_host.js');
      expect(
        host.contains(
            "handler === 'onLinkClick' || handler === 'textSelected'"),
        isTrue,
        reason: 'transformFrameMessage must re-anchor both link + text taps',
      );
    });

    test('symptom 2 — popup.css makes html.global-lookup transparent', () {
      // The opaque documentElement fill clipped by the shell radius is the
      // residual "white frame"; transparent <html> leaves only body's rounded
      // card. Scoped so the in-app popup (no global-lookup class) is untouched.
      final String css = read('assets/popup/popup.css');
      expect(
        RegExp(r'html\.global-lookup\s*\{[^}]*background:\s*transparent')
            .hasMatch(css),
        isTrue,
        reason: 'html.global-lookup must be transparent so the clipped corners '
            'show the desktop, not opaque theme colour',
      );
      // The in-app html background rule stays (no global-lookup scope on it).
      expect(css.contains('html.global-lookup body {'), isTrue,
          reason: 'in-app vs global-lookup body scoping must remain intact');
    });

    test('symptom 3 — native reports the cursor work-area offset', () {
      // computeFrameRect screenW/H are work-area dimensions; the host child
      // anchor is window-local. Native must hand the window origin's offset
      // inside the work area so Dart can align the two zero points.
      final String fw = read('windows/runner/flutter_window.cpp');
      expect(fw.contains('cursorWorkX'), isTrue,
          reason: 'showAt reply must carry the work-area X offset');
      expect(fw.contains('cursorWorkY'), isTrue,
          reason: 'showAt reply must carry the work-area Y offset');
      expect(fw.contains('x - mi.rcWork.left'), isTrue,
          reason: 'X offset = window origin minus work-area left');
      expect(fw.contains('y - mi.rcWork.top'), isTrue,
          reason: 'Y offset = window origin minus work-area top');
    });

    test('symptom 3 — channel parses cursorWork offset into the show result',
        () {
      final String
          channel = // spec 2026-07-10: channel 实现在 overlay_window_channel.dart（门面+实现拼接扫描）
          read('lib/src/lookup/global_lookup_channel.dart') +
              read('lib/src/lookup/overlay_window_channel.dart');
      expect(channel.contains("reply['cursorWorkX']"), isTrue);
      expect(channel.contains("reply['cursorWorkY']"), isTrue);
      expect(channel.contains('this.cursorWorkX'), isTrue);
      expect(channel.contains('this.cursorWorkY'), isTrue);
    });

    test('symptom 3 — controller feeds selectionScreenOffset to the builder',
        () {
      // The window-local anchor must be lifted into the work-area-absolute
      // domain before the cascade math (and shifted back after).
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      expect(controller.contains('_cursorWorkX'), isTrue);
      expect(controller.contains('_cursorWorkY'), isTrue);
      expect(
        controller.contains(
            'selectionScreenOffset: Offset(_cursorWorkX, _cursorWorkY)'),
        isTrue,
        reason: 'the cascade builder must receive the work-area offset',
      );
    });

    test('symptom 3 — render builder shifts anchor in then shifts result out',
        () {
      // computeFrameRect stays a pure single-domain function: the builder adds
      // the offset to the anchor before, and subtracts it from left/top after.
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(render.contains('Offset selectionScreenOffset'), isTrue,
          reason: 'builder must accept the offset param');
      expect(render.contains('anchorRect.shift(selectionScreenOffset)'), isTrue,
          reason: 'anchor lifted into work-area-absolute domain before layout');
      expect(render.contains('r.left - selectionScreenOffset.dx'), isTrue,
          reason: 'result shifted back to window-local (X)');
      expect(render.contains('r.top - selectionScreenOffset.dy'), isTrue,
          reason: 'result shifted back to window-local (Y)');
    });
  });

  group('BUG-859 — overlay cascade is ALWAYS horizontal (supersedes TODO-938)',
      () {
    // BUG-453/TODO-938 wired the READER's writingMode into the overlay cascade
    // "for in-app parity" — but the in-app reference had already gated vertical
    // placement to the ROOT layer only (base_source_page._layerVerticalWriting:
    // `index == 0 && …`, 2026-06-08): nested-from-popup layers are ALWAYS
    // horizontal because a popup card's content is always horizontal text. The
    // overlay's only isVertical consumers were exactly those nested cards, so
    // the wiring mis-placed every nested card for vertical-book users (child
    // popped left/right of the word at a fixed maxHeight). These guards lock
    // the corrected truth: no writingMode reaches the overlay cascade.
    test('controller does not read writingMode for the cascade', () {
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      final String controllerFlat = controller.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        controllerFlat.contains('isVerticalFromWritingMode('),
        isFalse,
        reason: 'the writingMode→cascade wiring (BUG-453) must stay removed — '
            'nested overlay cards anchor at words inside a HORIZONTAL popup '
            'card (in-app parity: base_source_page._layerVerticalWriting '
            'forces nested layers horizontal)',
      );
      expect(controller.contains('isVertical:'), isFalse,
          reason: 'the frame payload no longer carries a vertical flag');
    });

    test('render anchors nested cards with isVertical: false', () {
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      final String renderFlat = render.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        renderFlat.contains('isVertical: false,'),
        isTrue,
        reason: 'computeFrameRect must be fed the horizontal cascade '
            '(anchors are words inside a horizontal popup card)',
      );
      expect(render.contains('isVerticalFromWritingMode'), isFalse,
          reason: 'the writingMode helper must stay deleted (dead wiring)');
      expect(render.contains('this.isVertical'), isFalse,
          reason: 'GlobalLookupFramePayload must not re-grow a vertical flag');
    });

    test('controller converts the work-area domain with the MONITOR dpr', () {
      // BUG-859（多显示器混缩放）— native showAt 上报光标显示器的物理 px 工作区
      // + monitorDpr；覆盖窗 WebView2 按它自己所在显示器的缩放光栅化，故换算成
      // CSS px 必须用 monitorDpr（0 = native 查询失败，回退主窗口 dpr）。有人把
      // 除数改回主窗口 dpr（修复前行为）本测试转红。
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      final String flat = controller.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        flat.contains('shown.monitorDpr > 0 ? shown.monitorDpr : dpr'),
        isTrue,
        reason: 'work-area conversion must prefer the anchor monitor dpr',
      );
      expect(flat.contains('shown.workWidth / workDpr'), isTrue,
          reason: 'workWidth must be divided by the monitor dpr');
      expect(flat.contains('shown.cursorWorkX / workDpr'), isTrue,
          reason: 'cursorWorkX must be divided by the monitor dpr');
    });

    test('native showAt reports the anchor monitor dpr', () {
      final String cpp = read('windows/runner/flutter_window.cpp');
      expect(
        cpp.contains('FlutterDesktopGetDpiForMonitor(monitor) / 96.0'),
        isTrue,
        reason: 'showAt must report the cursor monitor dpr for the CSS px '
            'conversion (BUG-859 mixed-scale multi-monitor)',
      );
      expect(cpp.contains('"monitorDpr"'), isTrue,
          reason: 'the reply map must carry the monitorDpr key');
    });

    test('native RevealStack folds the work-area clamp into the layer shift',
        () {
      // BUG-859 — RevealStack 的工作区钳位可能悄悄移动窗口原点；layer shift 若仍按
      // 「意图原点」计算，整条级联（根+嵌套）在屏上平移钳位差量。钳位差量必须折进
      // commitLayerShift 实参。
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      final String flat = cpp.replaceAll(RegExp(r'\s+'), ' ');
      expect(flat.contains('bbox_left + clamp_dx_css'), isTrue,
          reason: 'the X clamp delta must be folded into commitLayerShift');
      expect(flat.contains('bbox_top + clamp_dy_css'), isTrue,
          reason: 'the Y clamp delta must be folded into commitLayerShift');
    });
  });

  group('TODO-1067 — desktop overlay nested popup close wiring (source)', () {
    late String render;
    late String host;
    late String controller;
    setUpAll(() {
      render = read('lib/src/lookup/global_lookup_render.dart');
      host = read('assets/popup/global_lookup_host.js');
      controller = read('lib/src/lookup/global_lookup_controller.dart');
    });

    test('子4/TODO-1231 — __hasChildPopup rides its own channel (BUG-434 kept)',
        () {
      // BUG-434 behaviour preserved: a parent frame still learns it has a child so
      // popup.js's click handler posts tapOutside on a parent-card tap. TODO-1231:
      // the flag is NO LONGER baked into the per-frame settings body (that made the
      // parent body change on every nested open/close -> the host re-eval'd the
      // whole body = renderPopup() card rebuild = 父弹窗闪烁). It now rides a
      // dedicated descriptor field + the host applyHasChildPopup one-liner, so the
      // body stays byte-identical and the host skips the full re-render.
      expect(render.contains("map['hasChildPopup'] = i < payloads.length - 1"),
          isTrue,
          reason: 'a frame has a child iff it is not the last in the stack, '
              'carried as its own descriptor field');
      expect(render.contains('window.__hasChildPopup ='), isFalse,
          reason: 'the settings body must NOT bake __hasChildPopup anymore '
              '(TODO-1231: that forced a full re-render on every nested toggle)');
      expect(host.contains('function applyHasChildPopup('), isTrue,
          reason: 'the host applies __hasChildPopup on its own cheap channel');
      expect(host.contains('window.__hasChildPopup ='), isTrue,
          reason:
              'host applyHasChildPopup evals the boolean in the frame realm');
    });

    test('子2 — buildFrameSettingsJs injects the shared swipe-close JS', () {
      // The top-pull swipe JS was only injected on the in-app popup; the overlay
      // iframe never received it, so desktop swipe-to-close was dead there. It
      // must now be injected from the single shared source of truth.
      expect(
          render.contains(
              "import 'package:fushi/src/reader/popup_swipe_close_script.dart';"),
          isTrue,
          reason: 'must import the shared swipe-close source of truth');
      expect(render.contains(r'$kPopupTopPullReleaseJs'), isTrue,
          reason: 'the overlay frame body must inject the swipe-close JS');
      // The controller still gates the resulting topPullReleased on the pref.
      expect(controller.contains("handler == 'topPullReleased'"), isTrue);
      expect(
          controller.contains('ReaderFushiSource.instance.enableSwipeToClose'),
          isTrue,
          reason: 'swipe close stays preference-gated (close-X is the primary '
              'mouse affordance; swipe preserved to avoid mouse mis-drag)');
    });

    test('子1 — host.js draws a per-shell close-X posting dismissPopupAt[index]',
        () {
      expect(host.contains('function createCloseButton('), isTrue,
          reason: 'the host must build a per-shell close-X');
      expect(host.contains("btn.className = 'global-lookup-close'"), isTrue);
      // Clicking it dismisses EXACTLY this layer (+ its children) by layer index.
      expect(host.contains("postToHost('dismissPopupAt', [index])"), isTrue,
          reason:
              'the X dismisses this layer by its stack index, not the root');
      expect(host.contains('var index = layerIndexOf(frameId);'), isTrue);
      // The close-X CSS is present in the injected gate/shell stylesheet.
      expect(host.contains('.global-lookup-close{'), isTrue,
          reason: 'close-X must carry its own scoped style');
    });

    test('子5 — host DEFERS card clicks to popup.js; only a true gap nukes root',
        () {
      // "Click the first popup, everything closes" came from the host coarse
      // mouse hook nuking the ROOT whenever its hit-test decided a click was
      // outside the cards. The fix: a click that hits a shell DEFERS to popup.js
      // (which owns the per-layer close via __hasChildPopup, 子4); the host must
      // NOT post a competing dismiss (double-fire / stack race). Only a click
      // that hits NO shell dismisses the root.
      expect(host.contains('function frameIdAtPoint('), isTrue,
          reason: 'the host still needs a hit-test for the gap decision');
      expect(host.contains('return true; // Card hit: popup.js owns'), isTrue,
          reason:
              'a card hit defers to popup.js (no host post -> no double-fire)');
      expect(host.contains('function postFrameStampedTapOutside('), isFalse,
          reason:
              'the host must NOT post its own tapOutside (would double-fire '
              'with popup.js and race the stack)');
      // The controller per-layer path (from popup.js tapOutside + __frameId)
      // stays wired: clicking the parent card closes only the child.
      expect(controller.contains("handler == 'tapOutside'"), isTrue);
      expect(controller.contains("message['__frameId'] as String?"), isTrue);
      expect(
          controller.contains(
              'closeChildPopupsAndClearSelection(_stack, layerIndex)'),
          isTrue,
          reason: 'a frame-stamped tapOutside (from popup.js) closes only that '
              'layer children');
    });

    test('子3 — reveal gate driven by popup.js popupRendered, not body height',
        () {
      // The old reveal heuristic accepted any non-zero body height, painting a
      // blank/pre-theme card (white flash) before popup.js finished. The gate
      // must now be driven by popup.js's authoritative popupRendered signal.
      expect(host.contains("message.handler === 'popupRendered'"), isTrue,
          reason: 'the wrapped bridge marks content-ready on popupRendered');
      expect(host.contains('markContentReady(record)'), isTrue);
      // hasContent tightened to a real painted card node (no bare height check).
      expect(host.contains("doc.querySelector('.glossary-content')"), isTrue);
      expect(host.contains("doc.querySelector('.no-results')"), isTrue,
          reason: 'no-results card still counts as painted content');
      expect(
          host.contains(
              'body.scrollHeight || 0, body.offsetHeight || 0);\n      return h > 0;'),
          isFalse,
          reason: 'the bare body-height reveal heuristic must be gone');
    });
  });

  group('JS harness (node)', () {
    test('popup.css scoped-style structure (executes parser via node)',
        () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS structure test');
        return;
      }
      final File jsTest =
          File('test/lookup/global_lookup_popup_style_test.mjs');
      expect(jsTest.existsSync(), isTrue);
      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );
      expect(
        result.exitCode,
        0,
        reason: 'global-lookup popup style JS test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(),
          contains('global_lookup_popup_style_test: PASS'));
    });
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
