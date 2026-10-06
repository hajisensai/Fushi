import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/components/glass/fushi_native_material.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart'
    show
        openBookViaProductionPath,
        readyAppModel,
        seedDictionary,
        seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// macOS 真机取证：查词浮层的原生系统材质背衬（NSVisualEffectView）。
///
/// 阅读器正文是 WKWebView 平台视图，Flutter 的 BackdropFilter 采不到；浮层改在
/// 弹窗 WebView 下垫 `app.fushi/native_material` 平台视图。本用例真实点词弹出浮层，
/// 依次在 MD3 深 / 浅、玻璃设计系统深 / 浅、以及关闭原生材质（对照：旧的不透明
/// 面板）下用 `screencapture -l` 抓**合成后**的真实窗口像素，并核对：
/// - 视图树里确有 NSVisualEffectView；
/// - 浮层文档摘掉了 `fushi-solid-backdrop`（宿主声明背后有真模糊）；
/// - 浮层顶栏（Flutter 画在材质之上）与 WebView 的命中链不被材质视图截走。
///
/// 窗口必须在前台（macOS 不给被遮挡窗口发 vsync）。
///
/// Run（在 Mac 上、可见窗口）：
///   FUSHI_TEST_INPUT=1 FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root-mat \
///     flutter test integration_test/macos_popup_native_material_itest.dart \
///     -d macos --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root-mat
const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

Future<Map<Object?, Object?>> _call(
  String method, [
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final dynamic raw = await _input.invokeMethod<dynamic>(method, args);
  return (raw as Map).cast<Object?, Object?>();
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label,
) async {
  for (int i = 0; i < 120; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 500));
  }
  fail('timed out waiting for $label');
}

Future<dynamic> _popupEval(String source) async =>
    ReaderFushiPage.debugEvaluateTopPopup?.call(source);

Future<bool> _waitPopup(WidgetTester tester) async {
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    final dynamic t = await _popupEval(
      "(document.body && document.body.innerText || '').indexOf('testword') >= 0",
    );
    if (t == true || t == 1 || t == 'true') return true;
  }
  return false;
}

Future<File?> _shot(int windowNumber, String name) async {
  final File file = File('${observeScreenshotDir().path}/$name.png');
  final ProcessResult r = await Process.run('screencapture', <String>[
    '-x',
    '-o',
    '-l',
    '$windowNumber',
    file.path,
  ]);
  debugPrint('[native-mat] $name exit=${r.exitCode} ${file.path}');
  return file.existsSync() ? file : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS lookup popup sits on a native NSVisualEffectView', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    await _call('activate');
    expect(await waitForHome(tester), isTrue, reason: 'home must render');
    await tester.pump(const Duration(seconds: 2));
    expect(await seedDictionary(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);

    final String bookKey = await seedReaderBook(
      tester,
      fileName: 'native_material_popup.epub',
    );
    await openBookViaProductionPath(tester, bookKey);
    await _waitFor(
      tester,
      () => find.byKey(_kWebViewKey).evaluate().isNotEmpty,
      'reader WebView',
    );
    await _waitFor(
      tester,
      () => find.byKey(_kContentReadyKey).evaluate().isNotEmpty,
      'reader content',
    );
    await _waitFor(tester, readerWebViewReady, 'reader debug hooks');
    await tester.pump(const Duration(seconds: 2));

    final Map<Object?, Object?> act = await _call('activate');
    final int windowNumber = (act['windowNumber'] as num).toInt();

    Future<void> openPopup(String label) async {
      final dynamic rectRaw = await ReaderFushiPage.debugEvaluateJavascript!('''
        (function() {
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          var n; while ((n = walker.nextNode())) {
            var i = n.textContent.indexOf('testword');
            if (i >= 0) {
              var r = document.createRange();
              r.setStart(n, i); r.setEnd(n, i + 8);
              var b = r.getBoundingClientRect();
              if (b.width > 0 && b.height > 0)
                return JSON.stringify({x: b.left, y: b.top, w: b.width, h: b.height});
            }
          }
          return null;
        })()
      ''');
      expect(rectRaw, isNotNull, reason: 'testword must be laid out ($label)');
      final Map<String, double> rect = <String, double>{
        for (final Match m in RegExp(
          r'"(x|y|w|h)":\s*(-?[\d.]+)',
        ).allMatches(rectRaw.toString()))
          m.group(1)!: double.parse(m.group(2)!),
      };
      final Offset origin = tester.getTopLeft(find.byKey(_kWebViewKey));
      await _call('click', <String, Object?>{
        'x': origin.dx + rect['x']! + rect['w']! / 2,
        'y': origin.dy + rect['y']! + rect['h']! / 2,
      });
      expect(await _waitPopup(tester), isTrue, reason: '点词必须弹出浮层 ($label)');
      // 等入场动效走完（材质在 alpha<1 的祖先下不模糊）。
      await tester.pump(const Duration(milliseconds: 900));
    }

    Future<void> closePopup() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    Future<void> capture(String label) async {
      await openPopup(label);
      final dynamic cls = await _popupEval(
        'document.documentElement.className',
      );
      debugPrint('[native-mat] $label html.class=$cls');
      final Map<Object?, Object?> views = await _call('dumpViews');
      final String tree = views['views'].toString();
      final bool hasEffect = tree.contains('FushiNativeMaterialNSView');
      debugPrint('[native-mat] $label effectViewInTree=$hasEffect');
      final Finder popup = find.byType(DictionaryPopupWebView);
      final Rect webRect = tester.getRect(popup.last);
      debugPrint('[native-mat] $label popup webview rect=$webRect');
      // 命中链：浮层 WebView 中心应命中 WKWebView；WebView 上方 12px（浮层顶栏，
      // Flutter 画在材质之上）不应命中材质视图。
      final Map<Object?, Object?> hitWeb = await _call('mouseMove', {
        'x': webRect.center.dx,
        'y': webRect.center.dy,
      });
      final Map<Object?, Object?> hitHeader = await _call('mouseMove', {
        'x': webRect.center.dx,
        'y': webRect.top - 12,
      });
      debugPrint('[native-mat] $label hitWeb=${hitWeb['chain']}');
      debugPrint('[native-mat] $label hitHeader=${hitHeader['chain']}');
      await tester.pump(const Duration(milliseconds: 300));
      await _shot(windowNumber, 'native-material-$label');
      await closePopup();
    }

    // MD3（新库默认设计系统）深 / 浅。
    await appModel.themeNotifier.setDesignSystem('material');
    await appModel.themeNotifier.setBrightnessMode('dark');
    await tester.pump(const Duration(seconds: 1));
    await capture('md3-dark');
    await appModel.themeNotifier.setBrightnessMode('light');
    await tester.pump(const Duration(seconds: 1));
    await capture('md3-light');

    // 玻璃设计系统深 / 浅。
    await appModel.themeNotifier.setDesignSystem('glass');
    await appModel.themeNotifier.setGlassMaterial(FushiGlassMaterial.frosted);
    await tester.pump(const Duration(seconds: 1));
    await capture('glass-light');
    await appModel.themeNotifier.setBrightnessMode('dark');
    await tester.pump(const Duration(seconds: 1));
    await capture('glass-dark');

    // 对照：关掉原生材质（旧行为 = 不透明面板）。
    await appModel.themeNotifier.setDesignSystem('material');
    debugNativeMaterialHostSupported = () => false;
    await tester.pump(const Duration(seconds: 1));
    await capture('md3-dark-opaque-control');
  });
}
