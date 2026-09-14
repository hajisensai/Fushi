import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// macOS app-external global lookup — REAL app, real Runner overlay
/// (macos/Runner/GlobalLookupOverlay.swift: NSPanel + WKWebView on the same
/// `global_lookup` channel contract as the Windows WebView2 window).
///
/// Drives the programmatic [GlobalLookupController.lookupText] entry (the
/// same overlay pipeline the hotkey takes after the selection capture) and
/// asserts, against the live native surface:
///   1. the prewarmed overlay WKWebView loads the host document;
///   2. a lookup reveals the panel (native isShowing);
///   3. the root popup iframe really rendered the seeded entry (DOM text read
///      through the env-gated debugEvaluateJs hook) — a real WebKit render,
///      not a Dart-side state flag;
///   4. hide() takes the panel down again.
/// A WKWebView snapshot PNG is written next to the test root as evidence.
///
/// Run on the Mac (from fushi/, hidden runner + test hooks):
///   FUSHI_TEST_HIDDEN=1 FUSHI_TEST_INPUT=1 FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root \
///     flutter test integration_test/macos_global_lookup_itest.dart -d macos \
///     --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS overlay renders an app-external lookup card', (
    WidgetTester tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'macOS-only overlay test');
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[mac-glookup] FlutterError: ${details.exceptionAsString()}');
    };
    try {
      await launchFushiTestApp();
      expect(
        await waitForHome(tester),
        isTrue,
        reason: 'Home must render within 90s',
      );
      expect(
        await seedDictionary(tester),
        isTrue,
        reason: 'generated test dictionary must import',
      );
      final AppModel appModel = await readyAppModel(tester);

      // main.dart starts the controller after the first frame when the lookup
      // module is enabled; start() is idempotent so this is safe either way.
      await GlobalLookupController.instance.start(appModel: appModel);
      expect(GlobalLookupController.isSupported, isTrue);
      expect(GlobalLookupController.instance.isAvailable, isTrue);

      // 1) prewarmed overlay: the host document loads in the WKWebView.
      bool ready = false;
      for (int i = 0; i < 80 && !ready; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        ready = await GlobalLookupChannel.isWebViewReady();
      }
      expect(
        ready,
        isTrue,
        reason: 'overlay WKWebView never loaded global_lookup_host.html',
      );

      // 2) programmatic lookup of the seeded entry (猫 / ねこ).
      final bool taken = await GlobalLookupController.instance.lookupText('猫');
      expect(taken, isTrue, reason: 'lookupText must take the lookup');
      bool showing = false;
      for (int i = 0; i < 80 && !showing; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        showing = await GlobalLookupChannel.isShowing();
      }
      expect(showing, isTrue, reason: 'overlay panel never revealed');

      // 3) the ROOT popup iframe really rendered the entry (WebKit DOM).
      const MethodChannel channel = FushiChannels.globalLookup;
      const String readRootText = '''
(function () {
  var frames = document.querySelectorAll('iframe');
  var out = [];
  for (var i = 0; i < frames.length; i++) {
    try {
      var d = frames[i].contentDocument;
      if (d && d.body) { out.push(d.body.innerText); }
    } catch (e) { out.push('ERR:' + e); }
  }
  return out.join('\\n---\\n');
})()''';
      // Per-frame diagnostics printed on failure: where each iframe actually
      // navigated (the host must resolve popup.html against ITS OWN origin —
      // fushi-popup://assets on macOS, not the Windows https://hibiki.popup).
      const String describeFrames = '''
(function () {
  var frames = document.querySelectorAll('iframe');
  var out = ['host=' + location.href + ' frames=' + frames.length];
  for (var i = 0; i < frames.length; i++) {
    var f = frames[i];
    try {
      var d = f.contentDocument;
      out.push('#' + i + ' src=' + f.getAttribute('src') +
        ' href=' + (d ? d.location.href : 'null') +
        ' ready=' + (d ? d.readyState : '-') +
        ' bodyChildren=' + (d && d.body ? d.body.children.length : -1) +
        ' html=' + (d && d.body ? d.body.innerHTML.length : -1));
    } catch (e) { out.push('#' + i + ' ERR:' + e); }
  }
  return out.join('\\n');
})()''';
      String text = '';
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        text =
            await channel.invokeMethod<String>(
              'debugEvaluateJs',
              <String, Object?>{'script': readRootText},
            ) ??
            '';
        if (text.contains('猫')) break;
      }
      debugPrint(
        '[mac-glookup] root iframe text: '
        '${text.length > 400 ? text.substring(0, 400) : text}',
      );
      final String frames =
          await channel.invokeMethod<String>('debugEvaluateJs', <String, Object?>{
            'script': describeFrames,
          }) ??
          '';
      debugPrint('[mac-glookup] frames:\n$frames');

      // Snapshot BEFORE the text assertions so a failing run still leaves
      // pixel evidence behind.
      final String snapshot =
          '${Directory.systemTemp.path}/'
          'fushi_mac_global_lookup.png';
      final bool saved =
          await channel.invokeMethod<bool>('debugSnapshot', <String, Object?>{
            'path': snapshot,
          }) ??
          false;
      debugPrint('[mac-glookup] snapshot saved=$saved path=$snapshot');

      expect(
        text,
        contains('猫'),
        reason: 'popup.js must render the seeded headword',
      );
      expect(
        text,
        contains('ねこ'),
        reason: 'popup.js must render the seeded reading',
      );
      expect(saved, isTrue, reason: 'WKWebView snapshot must be written');

      // Liveness probes for the host's rAF-driven pipeline (measure →
      // overlaySize → revealStack; content-ready paint gate). WebKit suspends
      // requestAnimationFrame for pages it considers not visible, which would
      // leave the card blank + un-measured even though the DOM has text.
      const String armRafProbe = '''
(function () {
  window.__fushiRafCount = 0;
  (function tick() { window.__fushiRafCount++; requestAnimationFrame(tick); })();
  return document.visibilityState + ' hidden=' + document.hidden;
})()''';
      const String readProbe = '''
(function () {
  var layer = document.getElementById('global-lookup-host-layer');
  var out = ['raf=' + window.__fushiRafCount +
    ' vis=' + document.visibilityState +
    ' win=' + window.innerWidth + 'x' + window.innerHeight +
    ' dpr=' + window.devicePixelRatio +
    ' layerTransform=' + (layer ? layer.style.transform : 'nolayer')];
  var frames = document.querySelectorAll('iframe');
  for (var i = 0; i < frames.length; i++) {
    var f = frames[i];
    var shell = f.parentElement;
    var r = f.getBoundingClientRect();
    var cs = shell ? getComputedStyle(shell) : null;
    out.push('#' + i + ' rect=' + Math.round(r.left) + ',' + Math.round(r.top) +
      ' ' + Math.round(r.width) + 'x' + Math.round(r.height) +
      (cs ? ' shellVis=' + cs.visibility + ' op=' + cs.opacity +
        ' disp=' + cs.display + ' pe=' + cs.pointerEvents : ''));
  }
  return out.join('\\n');
})()''';
      final String vis =
          await channel.invokeMethod<String>('debugEvaluateJs', <String, Object?>{
            'script': armRafProbe,
          }) ??
          '';
      debugPrint('[mac-glookup] visibility before settle: $vis');
      debugPrint(
        '[mac-glookup] native window state: '
        '${await channel.invokeMethod<String>('debugWindowState')}',
      );
      // Let the host's measure → overlaySize → revealStack round trip settle
      // (the glog dump at the end of the run shows whether the cascade
      // geometry path ran or only the READY-SAFETY legacy reveal).
      await tester.pump(const Duration(seconds: 3));
      final String probe =
          await channel.invokeMethod<String>('debugEvaluateJs', <String, Object?>{
            'script': readProbe,
          }) ??
          '';
      debugPrint('[mac-glookup] probe after settle:\n$probe');
      final String snapshot2 =
          '${Directory.systemTemp.path}/fushi_mac_global_lookup_settled.png';
      final bool saved2 =
          await channel.invokeMethod<bool>('debugSnapshot', <String, Object?>{
            'path': snapshot2,
          }) ??
          false;
      debugPrint('[mac-glookup] settled snapshot saved=$saved2 path=$snapshot2');

      // 4) dismissal takes the panel down.
      await GlobalLookupChannel.hide();
      await tester.pump(const Duration(milliseconds: 250));
      expect(await GlobalLookupChannel.isShowing(), isFalse);

      expect(
        errors,
        isEmpty,
        reason: errors.map((e) => e.exceptionAsString()).join('\n'),
      );
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
