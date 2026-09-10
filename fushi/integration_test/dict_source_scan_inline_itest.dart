import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-2428 真机复测：查词页源文本条点字 = Yomitan 式扫描，**换的是下方那份结果**。
///
/// 原始失败路径：在「と言いつつ」上点第 2 个字「言」。此前那会压一张浮在「言」上的
/// 查词卡（`_pushNestedPopup`），页面本体那份结果仍停在上一个词上；条上的高亮与卡片
/// 各说各话。现在必须是：条上整句不动、搜索框整句不动、栈深恒 0、下方结果换成从
/// 「言」起的最长匹配，条上的高亮跨度由**真引擎**回报的匹配长度撑开。
///
/// 高亮长度是本用例的核心证据：它不是页面自己编的，是 `lookupHighlightCharCount`
/// 从真实 `DictionarySearchResult.bestLength` 换算来的。高亮框住「言い」两个字 ⇔
/// 真的用后缀「言いつつ」查到了「言い」这条词。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('源文本条点字换下方结果、不压浮层（BUG-2428）', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));

    final AppModel appModel = await readyAppModel(tester);
    expect(await _seedScanDictionary(tester, appModel), isTrue,
        reason: '本用例需要一本含「と言い/言い/言う/つつ」的真词典');

    expect(HomePage.debugSelectTab, isNotNull,
        reason:
            'HomePage.debugSelectTab hook must be registered (debug build)');
    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await tester.pump(const Duration(seconds: 2));

    final HomeDictionarySearchDebug page = tester
        .state(find.byType(HomeDictionaryPage)) as HomeDictionarySearchDebug;

    // ① 主查词：整句进条、命中段锚在条首。
    await page.debugSearch('と言いつつ');
    for (int i = 0; i < 20 && page.debugIsSearching; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(seconds: 1));

    SourceLookupTextPanel panel = _panel(tester);
    expect(panel.text, 'と言いつつ');
    expect(panel.highlight?.start, 0);
    final int mainLength = panel.highlight?.length ?? 0;
    debugPrint('[scan-probe] 主查词 highlight=${panel.highlight}');
    ObserveShot shot = await captureFlutterFrame(tester, '01-main-search');
    expect(shot.saved, isTrue);

    // ② 源文本条点第 2 个字「言」。焦点驱动纪律禁坐标点击，这里直接驱动本条对外的
    // 生产回调（`onLookup` 就是逐字 GestureDetector 唯一的出口，手势本身由
    // clipboard_lookup_text_panel_test 的 widget 用例覆盖）。
    panel.onLookup('言いつつ', Rect.zero, 1);
    await tester.pump(const Duration(milliseconds: 200));
    for (int i = 0; i < 20 && page.debugIsSearching; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(seconds: 1));

    panel = _panel(tester);
    debugPrint('[scan-probe] 点「言」后 highlight=${panel.highlight} '
        'panel="${panel.text}" box="${_searchBoxText(tester)}" '
        'stack=${page.debugPopupStackShape}');
    shot = await captureFlutterFrame(tester, '02-scan-from-index-1');
    expect(shot.saved, isTrue);

    expect(panel.text, 'と言いつつ', reason: '条上必须留着整句，换成后缀就把被点字左边的上下文丢了');
    expect(_searchBoxText(tester), 'と言いつつ', reason: '搜索框是用户输入的整句，扫描查词不接管它');
    expect(panel.highlight?.start, 1, reason: '高亮锚在被点的那个字素簇上');
    expect(page.debugPopupStackShape.depth, 0,
        reason: '扫描换的是下方那份结果，不再压一张浮在字上的查词卡');
    expect(panel.highlight?.length, 2,
        reason: '真引擎用后缀「言いつつ」查到「言い」，高亮据此撑成两个字'
            '（主查词那次是 $mainLength）');
  });
}

SourceLookupTextPanel _panel(WidgetTester tester) =>
    tester.widget(find.byType(SourceLookupTextPanel));

String _searchBoxText(WidgetTester tester) {
  final FushiSearchField field = tester.widget(find.byType(FushiSearchField));
  return field.controller.text;
}

/// 造一本只为本用例服务的 yomitan 词典（四条词头，覆盖扫描要用到的每个起点），
/// 经真实 [AppModel.importDictionary] FFI 导入隔离根。
Future<bool> _seedScanDictionary(
  WidgetTester tester,
  AppModel appModel,
) async {
  final Directory cacheDir = await getTemporaryDirectory();
  final File dictFile = File('${cacheDir.path}/scan_dict.zip');
  final Map<String, dynamic> index = <String, dynamic>{
    'title': 'FushiScanProbeDict',
    'format': 3,
    'revision': 'scan-probe-1',
    'sequenced': false,
  };
  List<dynamic> term(String word, String reading, String gloss) => <dynamic>[
        word,
        reading,
        '',
        '',
        0,
        <String>[gloss],
        0,
        '',
      ];
  final List<List<dynamic>> termBank = <List<dynamic>>[
    term('と言い', 'といい', 'scan probe: と言い'),
    term('言い', 'いい', 'scan probe: 言い'),
    term('言う', 'いう', 'scan probe: 言う'),
    term('つつ', 'つつ', 'scan probe: つつ'),
  ].cast<List<dynamic>>();

  final Archive archive = Archive()
    ..addFile(_jsonFile('index.json', index))
    ..addFile(_jsonFile('term_bank_1.json', termBank));
  final List<int> zipBytes = ZipEncoder().encode(archive)!;
  dictFile.parent.createSync(recursive: true);
  await dictFile.writeAsBytes(zipBytes, flush: true);

  final ValueNotifier<String> progress = ValueNotifier<String>('');
  bool ok = false;
  try {
    await appModel.importDictionary(
      file: dictFile,
      progressNotifier: progress,
      onImportSuccess: () => ok = true,
    );
  } catch (e, stack) {
    debugPrint('[scan-probe] dictionary import failed: $e\n$stack');
  } finally {
    progress.dispose();
  }
  await tester.pump(const Duration(seconds: 1));
  final bool installed = ok ||
      appModel.dictionaries
          .any((Dictionary d) => d.name == 'FushiScanProbeDict');
  debugPrint('[scan-probe] dictionary seed success=$installed');
  return installed;
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}
