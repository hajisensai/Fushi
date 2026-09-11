import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 真 app 复测：查词弹窗内点交叉引用链接 = **原地跳转**（对齐 Hoshi Reader），
/// 顶栏 ← → 在历史页间来回，回来时滚动位恢复。
///
/// 路径：首页查词 tab → 生产 `_pushNestedPopup` 开「足」的弹窗（真 WebView）→ 把弹窗
/// 滚到 300px → DOM `.click()` 词典正文里的 `?query=揚げ足` 链接（走真实 popup.js
/// onclick → `onLinkClick` 桥 → mixin `navigatePopupInPlace`）→ 断言：栈深仍是 1、
/// 同一个 WebView State、词头换成「揚げ足」、顶栏出现 ← →（← 可用 / → 置灰）→ 触发
/// ← 的生产回调 → 词头回到「足」、scrollTop 回到 ≈300、→ 变可用。每一步抓真帧。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('弹窗内链接原地跳转 + ← → 历史 + 滚动位恢复', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));

    final AppModel appModel = await readyAppModel(tester);
    expect(await _seedLinkDictionary(tester, appModel), isTrue,
        reason: '本用例需要一本「足」的释义里带 ?query=揚げ足 链接的真词典');

    expect(HomePage.debugSelectTab, isNotNull);
    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await tester.pump(const Duration(seconds: 2));

    final HomeDictionarySearchDebug page = tester
        .state(find.byType(HomeDictionaryPage)) as HomeDictionarySearchDebug;

    // ① 开「足」的弹窗（真 WebView），等链接渲染出来。
    final int matches = await page.debugOpenPopup('足');
    expect(matches, greaterThan(0));
    expect(await _waitForExpression(tester, page, '足'), isTrue,
        reason: '弹窗必须渲染出「足」的词头');
    final Object? webViewBefore = page.debugTopPopupWebViewState;
    expect(webViewBefore, isNotNull);
    final int links = await _evalInt(
        page, "document.querySelectorAll('a.gloss-sc-a').length");
    expect(links, greaterThan(0), reason: '释义里必须渲染出交叉引用链接');
    expect(
        find.byKey(const ValueKey<String>('popup_history_back')), findsNothing,
        reason: '还没跳过：顶栏不画 ← →');

    // 把弹窗滚到 300px（释义故意造得很长，滚得动）。
    final int scrollable = await _evalInt(page,
        '(document.scrollingElement.scrollHeight - document.scrollingElement.clientHeight)');
    expect(scrollable, greaterThan(300), reason: '内容必须比视口高 300px 以上');
    await page.debugEvaluateTopPopup(
        'document.scrollingElement.scrollTop = 300; true');
    await tester.pump(const Duration(milliseconds: 300));
    final int scrollBefore =
        await _evalInt(page, 'document.scrollingElement.scrollTop');
    debugPrint('[inplace-probe] scrollTop before link click = $scrollBefore');
    expect(scrollBefore, greaterThanOrEqualTo(290));
    ObserveShot shot = await captureFlutterFrame(tester, '01-root-popup');
    expect(shot.saved, isTrue);

    // ② DOM 点链接：真实 popup.js onclick → onLinkClick 桥 → 原地跳转。
    await page.debugEvaluateTopPopup(
        "document.querySelector('a.gloss-sc-a').click(); true");
    expect(await _waitForExpression(tester, page, '揚げ足'), isTrue,
        reason: '同一弹窗必须换成「揚げ足」');
    expect(page.debugPopupStackShape.depth, 1, reason: '原地跳转不叠子层，栈深仍是 1');
    expect(identical(page.debugTopPopupWebViewState, webViewBefore), isTrue,
        reason: '还是同一个 WebView（不是新建一层）');
    final Finder backFinder =
        find.byKey(const ValueKey<String>('popup_history_back'));
    final Finder forwardFinder =
        find.byKey(const ValueKey<String>('popup_history_forward'));
    expect(backFinder, findsOneWidget, reason: '跳过之后顶栏出现 ←');
    expect(forwardFinder, findsOneWidget);
    expect(tester.widget<FushiIconButton>(backFinder).enabled, isTrue);
    expect(tester.widget<FushiIconButton>(forwardFinder).enabled, isFalse,
        reason: '没有前进页：→ 置灰');
    final int scrollAfterNav =
        await _evalInt(page, 'document.scrollingElement.scrollTop');
    debugPrint('[inplace-probe] scrollTop on 揚げ足 = $scrollAfterNav');
    expect(scrollAfterNav, 0, reason: '新词从顶部开始');
    shot = await captureFlutterFrame(tester, '02-after-link-navigate');
    expect(shot.saved, isTrue);

    // ③ ←：回到「足」，滚动位恢复到 300，→ 变可用。焦点驱动纪律禁坐标点击，这里
    // 直接驱动按钮对外的生产回调（onTap 就是 ← 唯一出口）。
    await tester.widget<FushiIconButton>(backFinder).onTap!();
    expect(await _waitForExpression(tester, page, '足'), isTrue,
        reason: '← 必须回到「足」');
    expect(page.debugPopupStackShape.depth, 1);
    int restored = -1;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      restored = await _evalInt(page, 'document.scrollingElement.scrollTop');
      if (restored >= 290) break;
    }
    debugPrint('[inplace-probe] scrollTop after back = $restored');
    expect(restored, greaterThanOrEqualTo(290),
        reason: '回到历史页必须恢复离开时的滚动位（≈300）');
    expect(tester.widget<FushiIconButton>(backFinder).enabled, isFalse,
        reason: '回到栈底：← 置灰');
    expect(tester.widget<FushiIconButton>(forwardFinder).enabled, isTrue,
        reason: '有前进页：→ 可用');
    shot = await captureFlutterFrame(tester, '03-after-back');
    expect(shot.saved, isTrue);

    // ④ →：再到「揚げ足」。
    await tester.widget<FushiIconButton>(forwardFinder).onTap!();
    expect(await _waitForExpression(tester, page, '揚げ足'), isTrue);
    expect(tester.widget<FushiIconButton>(forwardFinder).enabled, isFalse);
    expect(tester.widget<FushiIconButton>(backFinder).enabled, isTrue);
    shot = await captureFlutterFrame(tester, '04-after-forward');
    expect(shot.saved, isTrue);

    page.debugClosePopup();
    await tester.pump(const Duration(seconds: 1));
  });
}

/// 轮询顶层弹窗 WebView 的首个词头文本，直到等于 [expression]。
Future<bool> _waitForExpression(
  WidgetTester tester,
  HomeDictionarySearchDebug page,
  String expression,
) async {
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    final dynamic raw = await page.debugEvaluateTopPopup(
        "(document.querySelector('.entry .expression') || {}).textContent || ''");
    if (raw is String && raw.trim() == expression) return true;
  }
  return false;
}

Future<int> _evalInt(HomeDictionarySearchDebug page, String source) async {
  final dynamic raw = await page.debugEvaluateTopPopup(source);
  if (raw is num) return raw.round();
  if (raw is String) return int.tryParse(raw) ?? -1;
  return -1;
}

/// 造一本只为本用例服务的 yomitan 词典：「足」的释义先铺 60 行占位（让弹窗滚得动），
/// 末尾一条结构化内容带 `?query=揚げ足` 链接；「揚げ足」是跳转目标。
Future<bool> _seedLinkDictionary(
  WidgetTester tester,
  AppModel appModel,
) async {
  final Directory cacheDir = await getTemporaryDirectory();
  final File dictFile = File('${cacheDir.path}/inplace_nav_dict.zip');
  final Map<String, dynamic> index = <String, dynamic>{
    'title': 'FushiInplaceNavProbeDict',
    'format': 3,
    'revision': 'inplace-nav-probe-1',
    'sequenced': false,
  };
  final List<dynamic> ashiGloss = <dynamic>[
    for (int i = 0; i < 60; i++) 'inplace probe filler line $i',
    <String, dynamic>{
      'type': 'structured-content',
      'content': <String, dynamic>{
        'tag': 'a',
        'href': '?query=揚げ足',
        'content': '揚げ足',
      },
    },
  ];
  List<dynamic> term(String word, String reading, List<dynamic> gloss) =>
      <dynamic>[word, reading, '', '', 0, gloss, 0, ''];
  final List<List<dynamic>> termBank = <List<dynamic>>[
    term('足', 'あし', ashiGloss),
    term('揚げ足', 'あげあし', <dynamic>['inplace probe: 揚げ足']),
  ];

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
    debugPrint('[inplace-probe] dictionary import failed: $e\n$stack');
  } finally {
    progress.dispose();
  }
  await tester.pump(const Duration(seconds: 1));
  final bool installed = ok ||
      appModel.dictionaries
          .any((Dictionary d) => d.name == 'FushiInplaceNavProbeDict');
  debugPrint('[inplace-probe] dictionary seed success=$installed');
  return installed;
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}
