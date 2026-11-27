import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 真机取证（用户 2026-11-27）：查词浮层词典卡的紧凑行高 + Apple 半透卡 / 面板光感。
///
/// 导入 6 本生成词典，在阅读器里点 `testword` 弹出真浮层，第 2 本起折叠，依次在
/// Apple 浅 / 深、M3E 浅下截图，并量出词典名行高（桌面期望 Apple 24px、M3E 28px）。
///
/// Windows（离屏）：`tool/run_windows_itest.ps1 integration_test/popup_compact_glass_visual_itest.dart`
///   —— WebView2 以纹理合成进 Flutter 场景，captureFlutterFrame 抓得到。
/// macOS（可见窗口、前台）：
///   FUSHI_TEST_INPUT=1 FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root-compact \
///     flutter test integration_test/popup_compact_glass_visual_itest.dart \
///     -d macos --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root-compact
///   —— 弹窗 WKWebView 是原生平台视图，用 `screencapture -l` 抓合成后的窗口像素。
const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

const List<String> _dictTitles = <String>[
  '明鏡国語辞典 第三版',
  '旺文社漢字典 第四版',
  '新明解国語辞典 第八版',
  '三省堂国語辞典 第八版',
  '現代新国語辞典 第七版',
  '日本語シソーラス 類語検索辞典',
];

Future<File> _writeDict(File file, String title, int i) async {
  final List<List<dynamic>> termBank = <List<dynamic>>[
    <dynamic>[
      'testword',
      'testword',
      '',
      '',
      0,
      <String>['①客を家などに呼び、食事などを出してもてなすこと。($title)', '②興行・もよおし物に客として呼ぶこと。'],
      0,
      '',
    ],
  ];
  final Map<String, dynamic> index = <String, dynamic>{
    'title': title,
    'format': 3,
    'revision': 'compact-visual-$i',
    'sequenced': false,
  };
  List<int> bytesOf(Object json) => utf8.encode(jsonEncode(json));
  final List<int> a = bytesOf(index);
  final List<int> b = bytesOf(termBank);
  final Archive archive = Archive()
    ..addFile(ArchiveFile('index.json', a.length, a))
    ..addFile(ArchiveFile('term_bank_1.json', b.length, b));
  file.parent.createSync(recursive: true);
  await file.writeAsBytes(ZipEncoder().encode(archive)!, flush: true);
  return file;
}

Future<void> _seedDictionaries(AppModel appModel) async {
  final Directory dir = await getTemporaryDirectory();
  for (int i = 0; i < _dictTitles.length; i++) {
    final String title = _dictTitles[i];
    if (appModel.dictionaries.any((d) => d.name == title)) continue;
    final File f = await _writeDict(
      File('${dir.path}/compact_visual_$i.zip'),
      title,
      i,
    );
    final ValueNotifier<String> progress = ValueNotifier<String>('');
    try {
      await appModel.importDictionary(
        file: f,
        progressNotifier: progress,
        onImportSuccess: () {},
      );
    } finally {
      progress.dispose();
    }
  }
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
    final dynamic n = await _popupEval(
      "document.querySelectorAll('.glossary-group').length",
    );
    if (n is num && n >= _dictTitles.length) return true;
  }
  return false;
}

String _clickWordJs() => r'''
(function() {
  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  var n; while ((n = walker.nextNode())) {
    var i = n.textContent.indexOf('testword');
    if (i < 0) continue;
    var r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + 8);
    var b = r.getBoundingClientRect();
    if (b.width <= 0 || b.height <= 0) continue;
    var px = b.left + b.width / 2, py = b.top + b.height / 2;
    var t = document.elementFromPoint(px, py) || document.body;
    var init = {bubbles: true, cancelable: true, view: window, clientX: px, clientY: py, button: 0};
    try { t.dispatchEvent(new PointerEvent('pointerdown', Object.assign({pointerType: 'mouse', pointerId: 7, isPrimary: true, buttons: 1}, init))); } catch (e) {}
    try { t.dispatchEvent(new PointerEvent('pointerup', Object.assign({pointerType: 'mouse', pointerId: 7, isPrimary: true, buttons: 0}, init))); } catch (e) {}
    t.dispatchEvent(new MouseEvent('click', Object.assign({detail: 1}, init)));
    return 'clicked';
  }
  return 'missing';
})()
''';

/// 第 2 本起折叠、第 1 本展开，重排 masonry，量行高。
const String _collapseAndMeasureJs = r'''
(function() {
  var groups = Array.prototype.slice.call(document.querySelectorAll('.glossary-group'));
  groups.forEach(function(g, i) { g.open = (i === 0); });
  if (window.__fushiRelayoutPopupColumns) window.__fushiRelayoutPopupColumns();
  var rows = groups.map(function(g) {
    var l = g.querySelector('.dict-label');
    return l ? Math.round(l.getBoundingClientRect().height * 10) / 10 : -1;
  });
  var cell = groups[1] ? getComputedStyle(groups[1]).backgroundColor : '';
  return JSON.stringify({
    cls: document.documentElement.className,
    theme: document.documentElement.getAttribute('data-theme'),
    rows: rows, cell: cell
  });
})()
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('popup dictionary rows are compact; Apple cards are glass', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    int? windowNumber;
    if (Platform.isMacOS) {
      final dynamic act = await _input.invokeMethod<dynamic>('activate');
      windowNumber = ((act as Map)['windowNumber'] as num).toInt();
    }
    expect(await waitForHome(tester), isTrue, reason: 'home must render');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await _seedDictionaries(appModel);
    expect(
      _dictTitles.every((t) => appModel.dictionaries.any((d) => d.name == t)),
      isTrue,
      reason: '6 本生成词典都要导入成功',
    );

    final String bookKey = await seedReaderBook(
      tester,
      fileName: 'compact_visual_popup.epub',
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

    Future<void> capture(String label) async {
      final dynamic clicked = await ReaderFushiPage.debugEvaluateJavascript!(
        _clickWordJs(),
      );
      expect(clicked.toString(), contains('clicked'), reason: label);
      expect(await _waitPopup(tester), isTrue, reason: '浮层要出 6 本词典 ($label)');
      final dynamic measured = await _popupEval(_collapseAndMeasureJs);
      debugPrint('[compact-visual] $label $measured');
      await tester.pump(const Duration(milliseconds: 900));
      if (Platform.isMacOS && windowNumber != null) {
        final File file = File(
          '${observeScreenshotDir().path}/compact-$label.png',
        );
        final ProcessResult r = await Process.run('screencapture', <String>[
          '-x',
          '-o',
          '-l',
          '$windowNumber',
          file.path,
        ]);
        debugPrint(
          '[compact-visual] $label shot exit=${r.exitCode} ${file.path}',
        );
      } else {
        final ObserveShot shot = await captureFlutterFrame(
          tester,
          'compact-$label',
        );
        debugPrint('[compact-visual] $label shot saved=${shot.saved}');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    final String oldDesign = appModel.themeNotifier.designSystem;
    final String oldBrightness = appModel.themeNotifier.brightnessMode;
    try {
      await appModel.themeNotifier.setDesignSystem('glass');
      await appModel.themeNotifier.setGlassMaterial(FushiGlassMaterial.minimal);
      await appModel.themeNotifier.setBrightnessMode('light');
      await tester.pump(const Duration(seconds: 1));
      await capture('apple-light');
      await appModel.themeNotifier.setBrightnessMode('dark');
      await tester.pump(const Duration(seconds: 1));
      await capture('apple-dark');
      await appModel.themeNotifier.setDesignSystem('material');
      await appModel.themeNotifier.setBrightnessMode('light');
      await tester.pump(const Duration(seconds: 1));
      await capture('m3e-light');
    } finally {
      await appModel.themeNotifier.setDesignSystem(oldDesign);
      await appModel.themeNotifier.setBrightnessMode(oldBrightness);
    }
  });
}
