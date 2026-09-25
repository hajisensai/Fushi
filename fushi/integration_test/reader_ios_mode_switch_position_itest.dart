import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi_engine/epub/epub_importer.dart' show EpubImporter;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// BUG-2652 回归：iOS 上以分页开书、翻到章中，再在书内切到「滚动」，落点每次都被
/// 钉回章首（修复前 iOS 模拟器 8/8 次复现，横竖排都是）；退出重进（全新 WebView）
/// 则正常。根因是同一个 WKWebView 原地重载后视口头几帧瞬时读成 0，两次重锚恰好在
/// 这时采样：`setChromeInsets` 重发未变化的 inset、TODO-718 恢复重锚现场采样。
///
/// 这条测试走设置页的真实顺序（先 await 持久化 view mode，再
/// `onLayoutReloadLive` 让同一个 WebView 重载本章），横竖排各做 4 轮
/// 分页 → 滚动 → 分页，断言每次切换后的首个可见字符就是切换前那一个。
///
/// Run (from repo root, iOS):
///   .\tool\run_mac_itest.ps1 integration_test/reader_ios_mode_switch_position_itest.dart -Ios
bool _webViewShown() =>
    find.byKey(const ValueKey<String>('fushi_webview')).evaluate().isNotEmpty;

bool _contentReady() => find
    .byKey(const ValueKey<String>('fushi_content_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _pumpFor(WidgetTester tester, int quarterSeconds) async {
  for (int i = 0; i < quarterSeconds; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (ready()) return;
  }
  fail('$label did not become ready');
}

const String _para =
    '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。';

String _chapter(String title) {
  final StringBuffer b = StringBuffer();
  for (int i = 1; i <= 80; i++) {
    b.writeln('<p>$i $_para</p>');
  }
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title></head>'
      '<body>\n<h1>$title</h1>\n$b</body></html>';
}

Uint8List _buildEpub(String id) {
  final String opf =
      '<?xml version="1.0" encoding="utf-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">$id</dc:identifier>'
      '<dc:title>$id</dc:title><dc:language>ja</dc:language></metadata>'
      '<manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>'
      '<spine><itemref idref="c1"/></spine></package>';
  const String nav =
      '<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>nav</title></head><body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">一</a></li></ol></nav></body></html>';
  const String container =
      '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>';
  final Archive a = Archive();
  void add(String name, String content, {bool store = false}) {
    final List<int> bytes = utf8.encode(content);
    final ArchiveFile f = ArchiveFile(name, bytes.length, bytes);
    if (store) f.compress = false;
    a.addFile(f);
  }

  add('mimetype', 'application/epub+zip', store: true);
  add('META-INF/container.xml', container);
  add('OEBPS/content.opf', opf);
  add('OEBPS/nav.xhtml', nav);
  add('OEBPS/ch1.xhtml', _chapter('第一章'));
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

Future<int> _firstVisibleChar() async {
  final Object? raw = await ReaderFushiPage.debugEvaluateJavascript!(
    'window.fushiReader.getFirstVisibleCharOffset()',
  );
  return (raw as num).toInt();
}

/// 设置页的切换顺序（settings_schema_reading.dart）：先 await 持久化，再整章重载。
Future<void> _switchViewMode(WidgetTester tester, String mode) async {
  await ReaderFushiSource.instance.setReaderViewMode(mode);
  ReaderFushiSource.onLayoutReloadLive?.call();
  await _pumpFor(tester, 2);
  await _waitFor(tester, _contentReady, '$mode content');
  await _pumpFor(tester, 6);
}

Future<void> _runWritingMode(
  WidgetTester tester,
  AppModel appModel,
  String writingMode,
) async {
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: _buildEpub('mode-switch-$writingMode'),
    fileName: 'mode_switch_$writingMode.epub',
  );
  await _pumpFor(tester, 6);
  await ReaderFushiSource.instance.setReaderWritingMode(writingMode);
  await ReaderFushiSource.instance.setReaderViewMode('paginated');

  await openBookViaProductionPath(tester, bookKey);
  await _pumpFor(tester, 8);
  await _waitFor(tester, _webViewShown, 'reader WebView');
  await _waitFor(tester, _contentReady, 'content');
  await _pumpFor(tester, 8);

  for (int cycle = 0; cycle < 4; cycle++) {
    for (int i = 0; i < 3; i++) {
      await ReaderFushiPage.debugEvaluateJavascript!(
        "window.fushiReader.paginate('forward')",
      );
      await _pumpFor(tester, 2);
    }
    final int paged = await _firstVisibleChar();
    expect(paged, greaterThan(0), reason: 'must be reading mid-chapter');

    await _switchViewMode(tester, 'continuous');
    final int continuous = await _firstVisibleChar();
    debugPrint('[modeswitch] $writingMode #$cycle paged=$paged '
        'continuous=$continuous');
    expect(
      continuous,
      paged,
      reason: '$writingMode cycle $cycle: switching to scroll mode must keep '
          'the reading position (was pinned to the chapter start)',
    );

    await _switchViewMode(tester, 'paginated');
    expect(
      await _firstVisibleChar(),
      paged,
      reason: '$writingMode cycle $cycle: switching back to paged mode must '
          'keep the reading position',
    );
  }

  final NavigatorState nav = tester.state<NavigatorState>(
    find.byType(Navigator).first,
  );
  nav.pop();
  await _pumpFor(tester, 12);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'in-book paged <-> scroll switch keeps the reading position',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'modeswitch',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await tester.pump(const Duration(seconds: 2));

          final AppModel appModel = await readyAppModel(tester);
          await showBooksTab(tester);
          await _runWritingMode(tester, appModel, 'vertical-rl');
          await showBooksTab(tester);
          await _runWritingMode(tester, appModel, 'horizontal-tb');
        },
      );
    },
  );
}
