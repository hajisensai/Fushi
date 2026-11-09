// 服务器托管词典 UI 的真像素验收（Windows 离屏 runner）。
//
// 配对一台正在运行的测试 fushi_server（配对链接从 dart-define
// FUSHI_PROBE_PAIR_LINK 读，缺省用本机测试服务器的链接），等服务器词典目录对账进
// `remote_dictionary_metadata`，然后依次留证：
//   1. 词典管理页列表里的服务器行与来源标签；
//   2. 来源筛选条选中「Server · <名字>」；
//   3. 宽屏右侧详情侧板里一条服务器词典；
//   4. 焦点 + Enter 关掉一条服务器词典的开关，读回 hidden 已翻转；
//   5. 互联设置里该 host 的「用这台服务器查词典」与「可用词典」行；
//   6. 查词「猫舌」走远端优先，结果里的词典名来自服务器。
// 一律焦点驱动（Tab 遍历 + Enter），不用 tester.tap / 坐标。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart'
    show RemoteDictionary;
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart'
    show FushiChoiceChip;
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show DictionaryEntry, DictionarySearchResult;
import 'package:fushi_engine/sync/interconnect_device_name.dart'
    show resolveInterconnectDeviceName;
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kTag = '[server-dict-probe]';

const String _kPairLink = String.fromEnvironment(
  'FUSHI_PROBE_PAIR_LINK',
  defaultValue:
      'fushi://pair?v=1&h=wwy-YRTzQ8BNlmMbZ2FpUqPBrsVQZSNB-6zps4Xrbb0%3D'
      '&n=TestServer&fp=45%3A92%3A75%3Acc%3Ae5%3A1e%3Afe%3A15%3Ad7%3A03%3A7a'
      '%3A5c%3Aac%3A34%3A79%3A28%3A68%3A98%3Aca%3Ae6%3A0f%3A1f%3A23%3Af9%3A38'
      '%3A10%3A44%3Ace%3Acc%3A96%3A27%3A5e&a=lan~https%3A%2F%2F192.0.2.10'
      '%3A38865',
);

/// [scope] 子树里所有 Text / RichText 的文字（去重、保序），作可 diff 的证据。
List<String> _textsIn(WidgetTester tester, Finder scope) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  void add(String? s) {
    final String v = (s ?? '').trim();
    if (v.isEmpty || !seen.add(v)) return;
    out.add(v);
  }

  for (final Element e
      in find.descendant(of: scope, matching: find.byType(Text)).evaluate()) {
    final Text w = e.widget as Text;
    add(w.data ?? w.textSpan?.toPlainText());
  }
  for (final Element e
      in find
          .descendant(of: scope, matching: find.byType(RichText))
          .evaluate()) {
    add((e.widget as RichText).text.toPlainText());
  }
  return out;
}

/// 当前焦点节点是否在 [target] 子树内（或就是它）——只做正向判定。
bool _focusInside(FocusDriver driver, Finder target) {
  final BuildContext? ctx = driver.focused?.context;
  final List<Element> els = target.evaluate().toList();
  if (ctx == null || els.isEmpty) return false;
  final Element el = els.first;
  if (ctx == el) return true;
  bool inside = false;
  ctx.visitAncestorElements((Element a) {
    if (a == el) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

void _printTexts(String step, List<String> texts) {
  debugPrint('$_kTag $step: ${texts.length} texts');
  for (final String t in texts) {
    if (t.trim().isEmpty) continue;
    debugPrint('$_kTag $step | $t');
  }
}

String _remoteSummary(List<RemoteDictionary> rows) => rows
    .map(
      (RemoteDictionary r) =>
          '${r.name}(type=${r.type.name},order=${r.order},hidden=${r.hidden},'
          'lang=${r.sourceLanguage},missing=${r.isMissing})',
    )
    .join('; ');

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final int steps = total.inMilliseconds ~/ 250;
  for (int i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<ObserveShot> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 600));
  final ObserveShot shot = await captureFlutterFrame(tester, name);
  debugPrint(
    '$_kTag shot $name -> ${shot.path} saved=${shot.saved} '
    'nonBlank=${shot.nonBlank} bytes=${shot.bytes}',
  );
  expect(shot.saved, isTrue, reason: '$name 截图应落盘');
  expect(shot.nonBlank, isTrue, reason: '$name 不应是空白帧');
  return shot;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('服务器托管词典：管理页来源标签 / 筛选 / 详情 / 开关 / 互联设置 / 远端查词', (
    WidgetTester tester,
  ) async {
    await runFushiItest(
      label: 'server-dict-probe',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        await tester.pump(const Duration(seconds: 2));

        // ── 1. AppModel + 焦点导航前置 ────────────────────────────────────
        final AppModel appModel = await enableFocusNavigation(tester);
        expect(appModel.isInitialised, isTrue);
        final FocusDriver driver = FocusDriver(tester);
        await _shot(tester, 'server-dict-01-home');

        final bool originalRemoteLookup = appModel.remoteLookupEnabled;
        RemoteDictionary? toggled;
        try {
          // ── 2. 配对 + 打开远端查词 + 等目录对账 ─────────────────────────
          final FushiPairLink? link = FushiPairLink.tryParse(_kPairLink);
          expect(link, isNotNull, reason: '配对链接应能解析');
          final SyncRepository repo = SyncRepository(appModel.database);
          final InterconnectLinkPairingResult pairing =
              await pairWithInterconnectLink(
                repo: repo,
                link: link!,
                localDeviceName: await resolveInterconnectDeviceName(
                  appModel.platformServices.deviceInfo,
                ),
                pinProvider: () async => null,
              );
          debugPrint('$_kTag pairing result: $pairing');
          expect(
            pairing,
            isA<InterconnectLinkPaired>(),
            reason: '无 PIN 的局域网配对应成功：$pairing',
          );
          final String pairedName =
              (pairing as InterconnectLinkPaired).deviceName ??
              link.deviceName ??
              '';
          debugPrint(
            '$_kTag paired baseUrl=${pairing.baseUrl} deviceName=$pairedName',
          );

          await appModel.setRemoteLookupEnabled(true);
          expect(appModel.remoteLookupEnabled, isTrue);

          bool reconciled() => appModel.dictRepo.remoteDictionaries.length >= 5;
          int waitedMs = 0;
          while (!reconciled() && waitedMs < 30000) {
            await tester.pump(const Duration(milliseconds: 500));
            waitedMs += 500;
          }
          final bool autoReconciled = reconciled();
          debugPrint(
            '$_kTag catalog auto-reconciled=$autoReconciled after ${waitedMs}ms '
            'catalogService=${appModel.remoteDictionaryCatalog != null}',
          );
          if (!autoReconciled) {
            debugPrint(
              '$_kTag FINDING: automatic catalog trigger did not fill '
              'remoteDictionaries within 30s; calling refresh() explicitly',
            );
            final Map<String, Object?>? diffs = await appModel
                .remoteDictionaryCatalog
                ?.refresh();
            debugPrint('$_kTag explicit refresh diffs: $diffs');
            for (int i = 0; i < 20 && !reconciled(); i++) {
              await tester.pump(const Duration(milliseconds: 500));
            }
          }
          final List<RemoteDictionary> remote =
              appModel.dictRepo.remoteDictionaries;
          debugPrint(
            '$_kTag remoteDictionaries(${remote.length}): '
            '${_remoteSummary(remote)}',
          );
          expect(remote.length, greaterThanOrEqualTo(5));
          final String hostId = remote.first.hostId;
          debugPrint('$_kTag hostId=$hostId');
          await _shot(tester, 'server-dict-02-paired');

          // ── 3. 词典管理页 ────────────────────────────────────────────────
          HomePage.debugSelectTab?.call(HomeTab.books);
          await tester.pump(const Duration(seconds: 1));
          unawaited(appModel.showDictionaryMenu());
          final Finder page = find.byType(DictionaryDialogPage);
          for (int i = 0; i < 40 && page.evaluate().isEmpty; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(page, findsOneWidget, reason: '词典管理页应已打开');
          await _pumpFor(tester, const Duration(seconds: 2));
          _printTexts('03-list', _textsIn(tester, page));
          final Finder chips = find.descendant(
            of: page,
            matching: find.text('Server · $pairedName'),
          );
          debugPrint(
            '$_kTag source-chip "Server · $pairedName" count='
            '${chips.evaluate().length}',
          );
          expect(
            chips,
            findsWidgets,
            reason: '服务器行应带来源标签 Server · $pairedName',
          );
          await _shot(tester, 'server-dict-03-list');

          // 3b. 来源筛选：焦点移到「Server · <名字>」chip，Enter 选中。
          final Finder serverFilter = find.byKey(
            ValueKey<String>('dict-source-filter-server-$hostId'),
          );
          expect(serverFilter, findsOneWidget, reason: '应有这台服务器的筛选 chip');
          final bool filterFocused = await driver.focusWidget(
            serverFilter,
            maxSteps: 120,
          );
          debugPrint('$_kTag filter chip focused=$filterFocused');
          expect(filterFocused, isTrue, reason: '服务器筛选 chip 应可经 Tab 到达');
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          final bool filterSelected = tester
              .widget<FushiChoiceChip>(serverFilter)
              .selected;
          debugPrint('$_kTag filter chip selected=$filterSelected');
          expect(filterSelected, isTrue, reason: 'Enter 后服务器筛选应被选中');
          _printTexts('03b-filter', _textsIn(tester, page));
          await _shot(tester, 'server-dict-04-filter-server');

          // 3c. 详情侧板：焦点到 Test General JA 这一行，Enter 打开。
          final Finder rowTitle = find.descendant(
            of: page,
            matching: find.text('Test General JA'),
          );
          expect(rowTitle, findsWidgets, reason: '筛选后应可见 Test General JA 行');
          final bool rowFocused = await driver.focusWidget(
            rowTitle.first,
            maxSteps: 120,
          );
          debugPrint('$_kTag row focused=$rowFocused');
          expect(rowFocused, isTrue, reason: 'Test General JA 行应可经 Tab 到达');
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          final Finder detailSwitch = find.byKey(
            ValueKey<String>(
              'dict-detail-enabled-server:$hostId/Test General JA',
            ),
          );
          debugPrint(
            '$_kTag detail panel switch present='
            '${detailSwitch.evaluate().isNotEmpty}',
          );
          _printTexts('03c-detail', _textsIn(tester, page));
          expect(detailSwitch, findsOneWidget, reason: '详情侧板应显示该服务器词典');
          await _shot(tester, 'server-dict-05-detail');

          // ── 4. 焦点 + Enter 关掉 Test Games JA 的行内开关 ───────────────
          RemoteDictionary find1(String name) => appModel
              .dictRepo
              .remoteDictionaries
              .firstWhere((RemoteDictionary r) => r.name == name);
          final RemoteDictionary before = find1('Test Games JA');
          debugPrint('$_kTag before toggle: hidden=${before.hidden}');
          final Finder rowSwitch = find.byKey(
            ValueKey<String>('dict-row-switch-server:$hostId/Test Games JA'),
          );
          expect(rowSwitch, findsOneWidget, reason: 'Test Games JA 行开关应在树里');
          // 只认焦点真落在开关子树内：FocusDriver.focusWidget 的「反向」判定会把
          // 整行点击面（其子树含开关）也算命中，Enter 就成了打开行详情。
          final bool switchFocused = await driver.focusUntil(
            () => _focusInside(driver, rowSwitch),
            maxSteps: 120,
          );
          debugPrint('$_kTag row switch focused=$switchFocused');
          expect(switchFocused, isTrue, reason: '行内开关应可经 Tab 到达');
          await driver.activate();
          toggled = before;
          RemoteDictionary after = find1('Test Games JA');
          for (int i = 0; i < 20 && after.hidden == before.hidden; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            after = find1('Test Games JA');
          }
          debugPrint(
            '$_kTag after toggle: hidden=${after.hidden} '
            'all=${_remoteSummary(appModel.dictRepo.remoteDictionaries)}',
          );
          expect(after.hidden, !before.hidden, reason: 'Enter 应翻转 hidden');
          await _pumpFor(tester, const Duration(seconds: 1));
          _printTexts('04-toggled', _textsIn(tester, page));
          await _shot(tester, 'server-dict-06-toggled');

          // 关掉管理页（经 NavigatorState，非坐标点击）。
          Navigator.of(tester.element(page)).pop();
          await _pumpFor(tester, const Duration(seconds: 1));

          // ── 5. 互联设置里的 host 分组 ───────────────────────────────────
          final NavigatorState nav = Navigator.of(
            tester.element(find.byType(Scaffold).first),
          );
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsDetailPage(
                  destination: buildInterconnectDestination(),
                ),
              ),
            ),
          );
          await _pumpFor(tester, const Duration(seconds: 3));
          // 已配对设备列表住在「Pairing & devices」子页里：焦点移过去，Enter 进入。
          final Finder pairingRow = find.text('Pairing & devices');
          expect(
            pairingRow,
            findsWidgets,
            reason: '互联页应有「Pairing & devices」入口',
          );
          final bool pairingFocused = await driver.focusWidget(
            pairingRow.first,
            maxSteps: 150,
          );
          debugPrint('$_kTag pairing & devices row focused=$pairingFocused');
          expect(pairingFocused, isTrue);
          await _shot(tester, 'server-dict-07a-interconnect-root');
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 3));
          final Finder lookupSwitch = find.byKey(
            ValueKey<String>('interconnect-lookup-switch-$hostId'),
          );
          final bool lookupFocused = await driver.focusWidget(
            lookupSwitch,
            maxSteps: 150,
          );
          debugPrint(
            '$_kTag interconnect lookup switch present='
            '${lookupSwitch.evaluate().isNotEmpty} focused=$lookupFocused',
          );
          await _pumpFor(tester, const Duration(seconds: 1));
          final Finder hostSection = find.byKey(
            ValueKey<String>('interconnect-lookup-host-$hostId'),
          );
          final Finder settingsPage = find.byType(SettingsDetailPage).last;
          // 子页不一定是 SettingsDetailPage：有 host 分组就以它的所在页（最近的
          // Scaffold）为取文案范围。
          final Finder textScope = hostSection.evaluate().isNotEmpty
              ? find
                    .ancestor(of: hostSection, matching: find.byType(Scaffold))
                    .first
              : settingsPage;
          final List<String> settingsTexts = _textsIn(tester, textScope);
          _printTexts('05-interconnect', settingsTexts);
          expect(
            find.byKey(ValueKey<String>('interconnect-lookup-host-$hostId')),
            findsOneWidget,
            reason: '互联设置应有该 host 的查词分组',
          );
          expect(
            settingsTexts.any(
              (String s) =>
                  s.contains('Use this server for dictionary lookups'),
            ),
            isTrue,
          );
          expect(
            settingsTexts.any(
              (String s) => s.contains('Dictionaries available'),
            ),
            isTrue,
          );
          await _shot(tester, 'server-dict-07b-interconnect-host');
          nav.popUntil((Route<dynamic> r) => r.isFirst);
          await _pumpFor(tester, const Duration(seconds: 1));

          // ── 6. 远端优先查词 ──────────────────────────────────────────────
          final DictionarySearchResult result = await appModel.searchDictionary(
            searchTerm: '猫舌',
            searchWithWildcards: false,
            useCache: false,
          );
          final List<String> dictNames = <String>[
            for (final DictionaryEntry e in result.entries) e.dictionaryName,
          ];
          debugPrint(
            '$_kTag search 猫舌: entries=${result.entries.length} '
            'dictionaries=${dictNames.toSet().toList()} '
            'words=${result.entries.map((DictionaryEntry e) => e.word).toSet().toList()} '
            'appliedByHost=${appModel.remoteDictionaryConfigAppliedByHost}',
          );
          expect(
            dictNames,
            contains('Test General JA'),
            reason: '远端优先：结果应来自服务器的 Test General JA',
          );
          expect(
            dictNames,
            isNot(contains('Test Games JA')),
            reason: 'Test Games JA 已被本配置关掉，不应出现在结果里',
          );
        } finally {
          final RemoteDictionary? t0 = toggled;
          if (t0 != null) {
            final List<RemoteDictionary> now = appModel
                .dictRepo
                .remoteDictionaries
                .where((RemoteDictionary r) => r.name == t0.name)
                .toList();
            if (now.isNotEmpty && now.first.hidden != t0.hidden) {
              await appModel.setRemoteDictionaryHidden(now.first, t0.hidden);
            }
          }
          await appModel.setRemoteLookupEnabled(originalRemoteLookup);
          await appModel.setExperimentalFocusNavigationEnabled(false);
          debugPrint(
            '$_kTag restored: remoteLookup=${appModel.remoteLookupEnabled} '
            'focusNav=${appModel.experimentalFocusNavigationEnabled}',
          );
        }
      },
    );
  });
}
