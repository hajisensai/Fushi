// 服务器托管词典 UI 的真像素验收（Windows 离屏 runner）。
//
// 配对一台正在运行的测试 fushi_server，等服务器词典目录对账进
// `remote_dictionary_metadata`，然后依次留证：
//   1. 词典管理页列表里的服务器行与来源标签；
//   2. 来源筛选条选中「Server · <名字>」；
//   3. 宽屏右侧详情侧板里一条服务器词典；
//   4. 焦点 + Enter 关掉一条服务器词典的开关，读回 hidden 已翻转；
//   5. 互联设置里该 host 的「用这台服务器查词典」与「可用词典」行；
//   6. 查词「猫舌」走远端优先，结果里的词典名来自服务器。
// 一律焦点驱动（Tab 遍历 + Enter），不用 tester.tap / 坐标。
//
// 环境相关的值一律由 dart-define 给，没有本机缺省值；缺任何一个测试立即失败并点名：
//   FUSHI_PROBE_PAIR_LINK      测试服务器的配对链接（fushi://pair?...）
//   FUSHI_PROBE_PAIR_LINK_FILE 或：存着配对链接的文本文件（runner 经 cmd.exe 转发命令行，
//                           链接里的 & 会被截断，走文件绕开）
//   FUSHI_PROBE_LOCAL_DICT_DIR 放测试词典 zip 的文件夹
// 示例（fushi/ 下）：
//   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 `
//     -Target integration_test\server_dictionaries_probe_test.dart `
//     -DartDefine 'FUSHI_PROBE_PAIR_LINK=<pair-link>',`
//                 'FUSHI_PROBE_LOCAL_DICT_DIR=<dir-with-test-zips>'
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart'
    show RemoteDictionary, RemoteDictionaryHostSource;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show FushiAdjustableSegmented;
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart'
    show buildLookupDestination;
import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiDialogFrame;
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart'
    show FushiChoiceChip;
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show Dictionary, DictionaryEntry, DictionarySearchResult, DictionaryType;
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

const String _kPairLink = String.fromEnvironment('FUSHI_PROBE_PAIR_LINK');
const String _kPairLinkFile = String.fromEnvironment(
  'FUSHI_PROBE_PAIR_LINK_FILE',
);

/// 配对链接：直接给的 dart-define 优先，否则从 [_kPairLinkFile] 读。两个都没给为空串。
String _pairLink() => _kPairLink.isNotEmpty
    ? _kPairLink
    : _kPairLinkFile.isEmpty
    ? ''
    : File(_kPairLinkFile).readAsStringSync().trim();

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

/// 焦点节点的可读描述：debugLabel、所在 widget 及其 key、最近的 String ValueKey 祖先。
String _describeFocus(FocusNode? node) {
  if (node == null) return 'null';
  final BuildContext? ctx = node.context;
  final Widget? w = ctx?.widget;
  String? keyed;
  bool inDialog = false;
  ctx?.visitAncestorElements((Element a) {
    final Key? k = a.widget.key;
    if (keyed == null && k is ValueKey<String>) {
      keyed = '${a.widget.runtimeType}<${k.value}>';
    }
    if (a.widget is FushiDialogFrame) inDialog = true;
    return true;
  });
  return 'label=${node.debugLabel} widget=${w?.runtimeType} '
      'key=${w?.key} keyedAncestor=$keyed inDialog=$inDialog '
      'hash=${identityHashCode(node)}';
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

const String _kLocalDictDir = String.fromEnvironment(
  'FUSHI_PROBE_LOCAL_DICT_DIR',
);

/// 缺必需的 dart-define 就在启动 app 前失败，消息点名缺哪个。
void _requireProbeDefines() {
  final List<String> missing = <String>[
    if (_pairLink().isEmpty)
      'FUSHI_PROBE_PAIR_LINK / FUSHI_PROBE_PAIR_LINK_FILE',
    if (_kLocalDictDir.isEmpty) 'FUSHI_PROBE_LOCAL_DICT_DIR',
  ];
  if (missing.isNotEmpty) {
    fail('缺少必需的 --dart-define（探针没有本机缺省值）：${missing.join(', ')}');
  }
}

List<String> _keyedTexts(WidgetTester tester, Finder scope, String prefix) {
  final List<String> out = <String>[];
  final Finder found = find.descendant(
    of: scope,
    matching: find.byWidgetPredicate((Widget w) {
      final Key? k = w.key;
      return k is ValueKey<String> && k.value.startsWith(prefix);
    }),
  );
  for (final Element e in found.evaluate()) {
    final String key = (e.widget.key! as ValueKey<String>).value.substring(
      prefix.length,
    );
    final List<String> texts = _textsIn(tester, find.byWidget(e.widget));
    out.add('$key => ${texts.join(' / ')}');
  }
  return out;
}

void _printManagerEvidence(WidgetTester tester, String step, Finder page) {
  _printTexts(step, _textsIn(tester, page));
  for (final String h in _keyedTexts(tester, page, 'dict-language-group-')) {
    debugPrint('$_kTag $step group-header | $h');
  }
  for (final String c in _keyedTexts(tester, page, 'dict-row-source-')) {
    debugPrint('$_kTag $step row-chip | $c');
  }
  final int glyphs = find
      .descendant(
        of: page,
        matching: find.byKey(const ValueKey<String>('dict-row-server-glyph')),
      )
      .evaluate()
      .length;
  debugPrint(
    '$_kTag $step server-glyphs=$glyphs summary=${_summaryText(tester, page)}',
  );
}

String _summaryText(WidgetTester tester, Finder page) => _textsIn(
  tester,
  find.descendant(
    of: page,
    matching: find.byKey(const ValueKey<String>('dict-list-summary')),
  ),
).join(' / ');

Future<void> _importLocalDict(
  WidgetTester tester,
  AppModel appModel,
  String fileName,
  String title,
) async {
  final File file = File('$_kLocalDictDir${Platform.pathSeparator}$fileName');
  expect(file.existsSync(), isTrue, reason: '本地词典包应存在：${file.path}');
  final ValueNotifier<String> progress = ValueNotifier<String>('');
  bool ok = false;
  try {
    final Future<void> job = appModel.importDictionary(
      file: file,
      progressNotifier: progress,
      onImportSuccess: () => ok = true,
    );
    bool done = false;
    unawaited(job.whenComplete(() => done = true));
    for (int i = 0; i < 240 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await job;
  } finally {
    progress.dispose();
  }
  bool present() =>
      appModel.dictRepo.dictionaries.any((Dictionary d) => d.name == title);
  for (int i = 0; i < 40 && !present(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  final List<String> local = <String>[
    for (final Dictionary d in appModel.dictRepo.dictionaries)
      '${d.name}(type=${d.type.name},lang=${d.sourceLanguage})',
  ];
  debugPrint(
    '$_kTag import $fileName ok=$ok present=${present()} local=$local',
  );
  expect(present(), isTrue, reason: '$title 应已导入 dictRepo.dictionaries');
}

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

/// 焦点驱动打开改名对话框（BUG-4273 回归闸）：焦点移到 [renameBtn] → Enter，逐帧记
/// primaryFocus 与每次焦点变化的调用栈，并**断言**对话框输入框（autofocus）在几帧内
/// 直接拿到主焦点——不再用 Tab 兜底，bug 回来这里就红。
Future<EditableTextState> _openRenameByKeyboard(
  WidgetTester tester,
  FocusDriver driver,
  Finder renameBtn,
  String label, {
  required String shotName,
}) async {
  final bool renameFocused = await driver.focusUntil(
    () => _focusInside(driver, renameBtn),
    maxSteps: 150,
  );
  debugPrint('$_kTag [$label] rename button focused=$renameFocused');
  expect(renameFocused, isTrue, reason: '[$label] Rename 按钮应可经 Tab 到达');
  debugPrint(
    '$_kTag [$label] focus-trace pre-enter: ${_describeFocus(driver.focused)}',
  );
  final Finder dialogFrame = find.byType(FushiDialogFrame);
  final Finder editable = find.descendant(
    of: dialogFrame,
    matching: find.byType(EditableText),
  );
  bool fieldHasPrimary() {
    final FocusNode? now = FocusManager.instance.primaryFocus;
    if (now == null) return false;
    for (final Element e in editable.evaluate()) {
      if (identical((e.widget as EditableText).focusNode, now)) return true;
    }
    return false;
  }

  final List<String> focusChanges = <String>[];
  FocusNode? lastSeen = driver.focused;
  void onFocusChange() {
    final FocusNode? now = FocusManager.instance.primaryFocus;
    if (identical(now, lastSeen)) return;
    lastSeen = now;
    final List<String> frames = StackTrace.current
        .toString()
        .split('\n')
        .where(
          (String l) =>
              l.contains('package:fushi/') ||
              l.contains('focus_') ||
              l.contains('editable_text') ||
              l.contains('text_field') ||
              l.contains('dialog') ||
              l.contains('routes.dart') ||
              l.contains('navigator.dart'),
        )
        .take(16)
        .map((String l) => l.trim())
        .toList();
    focusChanges.add(
      '${_describeFocus(now)} fieldPrimary=${fieldHasPrimary()}\n'
      '      ${frames.join('\n      ')}',
    );
  }

  FocusManager.instance.addListener(onFocusChange);
  final List<String> focusFrames = <String>[];
  int? firstFieldFrame;
  try {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    focusFrames.add(
      'f00 ${_describeFocus(driver.focused)} fieldPrimary=${fieldHasPrimary()}',
    );
    if (fieldHasPrimary()) firstFieldFrame = 0;
    for (int i = 1; i <= 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final bool onField = fieldHasPrimary();
      if (onField && firstFieldFrame == null) firstFieldFrame = i;
      focusFrames.add(
        'f${i.toString().padLeft(2, '0')} '
        '${_describeFocus(driver.focused)} fieldPrimary=$onField',
      );
    }
  } finally {
    FocusManager.instance.removeListener(onFocusChange);
  }
  for (final String f in focusFrames) {
    debugPrint('$_kTag [$label] focus-trace $f');
  }
  for (int i = 0; i < focusChanges.length; i++) {
    debugPrint('$_kTag [$label] focus-change #$i ${focusChanges[i]}');
  }
  debugPrint(
    '$_kTag [$label] rename dialog open=${dialogFrame.evaluate().isNotEmpty} '
    'fields=${editable.evaluate().length} firstFieldFrame=$firstFieldFrame '
    'focusChanges=${focusChanges.length}',
  );
  expect(dialogFrame, findsOneWidget, reason: '[$label] Enter 应打开改名对话框');
  expect(editable, findsWidgets, reason: '[$label] 改名对话框应有输入框');
  expect(
    firstFieldFrame,
    isNotNull,
    reason: '[$label] BUG-4273：键盘打开改名框后输入框应在 30 帧内直接获焦（无 Tab）',
  );
  expect(
    firstFieldFrame!,
    lessThanOrEqualTo(10),
    reason: '[$label] 输入框应在几帧内获焦，实际第 $firstFieldFrame 帧',
  );
  await _pumpFor(tester, const Duration(seconds: 1));
  final bool stillOnField = fieldHasPrimary();
  debugPrint(
    '$_kTag [$label] after 1s: fieldPrimary=$stillOnField '
    'primary=${_describeFocus(driver.focused)}',
  );
  expect(stillOnField, isTrue, reason: '[$label] 1 s 后焦点仍应在输入框上');
  await _shot(tester, shotName);
  return tester.state<EditableTextState>(editable.last);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('服务器托管词典：管理页来源标签 / 筛选 / 详情 / 开关 / 互联设置 / 远端查词', (
    WidgetTester tester,
  ) async {
    _requireProbeDefines();
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

        RemoteDictionary? toggled;
        try {
          // ── 2. 配对 + 打开远端查词 + 等目录对账 ─────────────────────────
          final FushiPairLink? link = FushiPairLink.tryParse(_pairLink());
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

          // 新配对的 host 默认开着「用这台服务器查词典」：远端查词总闸（派生值）
          // 随词典仓库跟上配对列表变为开，不需要（也没有）全局开关。
          for (int i = 0; i < 40 && !appModel.remoteLookupEnabled; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
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

          // ── 2b. 导入两本本机词典：一本与服务器同名（→「Both」），一本只在本机 ──
          await _importLocalDict(
            tester,
            appModel,
            'TestGeneralJA.zip',
            'Test General JA',
          );
          await _importLocalDict(
            tester,
            appModel,
            'TestLocalJA.zip',
            'Test Local JA',
          );

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
          _printManagerEvidence(tester, '03-list-all', page);
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
          // 顶栏副标题「Profile · <名字>」。
          final Finder subtitle = find.byKey(
            const ValueKey<String>('dict-profile-subtitle'),
          );
          for (int i = 0; i < 20 && subtitle.evaluate().isEmpty; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          final List<String> subtitleTexts = subtitle.evaluate().isEmpty
              ? const <String>[]
              : _textsIn(tester, subtitle);
          debugPrint('$_kTag profile subtitle=$subtitleTexts');
          expect(
            subtitleTexts.any((String s) => s.startsWith('Profile · ')),
            isTrue,
            reason: '顶栏应有「Profile · <名字>」副标题',
          );
          final int hostCount =
              (await appModel.remoteDictionaryHostSources()).length;
          final int filterRefresh = find
              .byKey(const ValueKey<String>('dict-server-refresh'))
              .evaluate()
              .length;
          debugPrint(
            '$_kTag hosts=$hostCount filter-bar refresh count=$filterRefresh',
          );
          expect(
            filterRefresh,
            hostCount >= 2 ? 1 : 0,
            reason: '筛选栏刷新钮只在 ≥2 台 host 时出现',
          );
          await _shot(tester, 'server-dict-03-list');

          // 03b. 来源条：这台 host 的卡片（状态 / 本数 / 用于查词 / 刷新）。
          final Finder strip = find.byKey(
            const ValueKey<String>('dict-server-sources'),
          );
          final Finder hostCard = find.byKey(
            ValueKey<String>('dict-server-source-$hostId'),
          );
          expect(strip, findsOneWidget, reason: '列表上方应有来源条');
          expect(hostCard, findsOneWidget, reason: '来源条应有该 host 的卡片');
          await tester.ensureVisible(hostCard);
          await _pumpFor(tester, const Duration(seconds: 1));
          final List<String> cardTexts = _textsIn(tester, hostCard);
          _printTexts('03b-sources-strip', _textsIn(tester, strip));
          expect(cardTexts, contains(pairedName), reason: '卡片标题应是设备名');
          expect(
            cardTexts.any((String s) => s.contains('Use for lookups')),
            isTrue,
          );
          expect(
            cardTexts.any(
              (String s) => RegExp(r'^\d+ of \d+ enabled$').hasMatch(s),
            ),
            isTrue,
            reason: '卡片应有「m of n enabled」',
          );
          final Size cardSize = tester.getSize(hostCard);
          final Finder cardSwitch = find.byKey(
            ValueKey<String>('dict-server-source-lookup-$hostId'),
          );
          final Finder cardStatus = find.byKey(
            ValueKey<String>('dict-server-source-status-$hostId'),
          );
          final double nameY = tester
              .getCenter(
                find.descendant(of: hostCard, matching: find.text(pairedName)),
              )
              .dy;
          final double switchY = tester.getCenter(cardSwitch).dy;
          final double statusY = tester.getCenter(cardStatus).dy;
          final bool singleRow =
              (nameY - switchY).abs() < 8 && (nameY - statusY).abs() < 8;
          final int perHostRefresh = find
              .byKey(ValueKey<String>('dict-server-source-refresh-$hostId'))
              .evaluate()
              .length;
          final int lookupOffLine = find
              .byKey(ValueKey<String>('dict-server-source-lookup-off-$hostId'))
              .evaluate()
              .length;
          debugPrint(
            '$_kTag host card size=$cardSize nameY=$nameY statusY=$statusY '
            'switchY=$switchY singleRow=$singleRow '
            'perHostRefresh=$perHostRefresh lookupOffLine=$lookupOffLine',
          );
          if (cardSize.width >= 560) {
            expect(singleRow, isTrue, reason: '宽 ≥560 时来源卡片应是单行');
          }
          await _shot(tester, 'server-dict-03b-sources-strip');

          // 3a. 「This device」筛选。
          final Finder localFilter = find.byKey(
            const ValueKey<String>('dict-source-filter-thisDevice'),
          );
          expect(localFilter, findsOneWidget, reason: '应有 This device 筛选 chip');
          final bool localFocused = await driver.focusWidget(
            localFilter,
            maxSteps: 120,
          );
          debugPrint('$_kTag this-device chip focused=$localFocused');
          expect(localFocused, isTrue);
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          debugPrint(
            '$_kTag this-device chip selected='
            '${tester.widget<FushiChoiceChip>(localFilter).selected}',
          );
          _printManagerEvidence(tester, '03a-filter-local', page);
          debugPrint(
            '$_kTag this-device strip count=${strip.evaluate().length}',
          );
          expect(strip, findsNothing, reason: '「This device」筛选下不应有来源条');
          await _shot(tester, 'server-dict-03a-filter-local');

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
          _printManagerEvidence(tester, '03b-filter-server', page);
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
          // 本机也装了 Test General JA：这一行是「Both」，详情走本机词典详情。
          final Finder bothDetail = find.byKey(
            const ValueKey<String>('dict-detail-Test General JA'),
          );
          debugPrint(
            '$_kTag both-row detail present=${bothDetail.evaluate().isNotEmpty}',
          );
          _printTexts(
            '03c-detail-both',
            bothDetail.evaluate().isNotEmpty
                ? _textsIn(tester, bothDetail)
                : _textsIn(tester, page),
          );
          expect(bothDetail, findsOneWidget, reason: '详情侧板应显示 Both 行');
          final Finder serverCopy = find.byKey(
            const ValueKey<String>('dict-detail-server-copy-Test General JA'),
          );
          if (serverCopy.evaluate().isNotEmpty) {
            await tester.ensureVisible(serverCopy);
            await _pumpFor(tester, const Duration(milliseconds: 750));
          }
          final List<String> copyTexts = serverCopy.evaluate().isEmpty
              ? const <String>[]
              : _textsIn(tester, serverCopy);
          _printTexts('03c-server-copy', copyTexts);
          expect(
            serverCopy,
            findsOneWidget,
            reason: 'Both 详情应有 Server copy 分组',
          );
          expect(copyTexts, contains('Version on server'));
          expect(copyTexts, contains('Version on this device'));
          await _shot(tester, 'server-dict-05-detail-both');

          // 3d. 只在服务器上的一行（Test Games JA）的详情。
          final Finder gamesTitle = find.descendant(
            of: page,
            matching: find.text('Test Games JA'),
          );
          expect(gamesTitle, findsWidgets);
          final bool gamesFocused = await driver.focusWidget(
            gamesTitle.first,
            maxSteps: 120,
          );
          debugPrint('$_kTag games row focused=$gamesFocused');
          expect(gamesFocused, isTrue);
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          final Finder serverDetail = find.byKey(
            ValueKey<String>('dict-detail-server:$hostId/Test Games JA'),
          );
          debugPrint(
            '$_kTag server-row detail present='
            '${serverDetail.evaluate().isNotEmpty}',
          );
          _printTexts(
            '03d-detail-server',
            serverDetail.evaluate().isNotEmpty
                ? _textsIn(tester, serverDetail)
                : _textsIn(tester, page),
          );
          expect(serverDetail, findsOneWidget, reason: '详情侧板应显示服务器行');
          final List<String> serverDetailTexts = _textsIn(tester, serverDetail);
          expect(
            serverDetailTexts,
            contains('Source'),
            reason: '服务器行详情应有「Source」标签',
          );
          await _shot(tester, 'server-dict-05b-detail-server');

          // 3e. 改名：Test KO（只在服务器上）→「My KO」，走详情的 Rename 对话框。
          final Finder koTitle = find.descendant(
            of: page,
            matching: find.text('Test KO'),
          );
          expect(koTitle, findsWidgets);
          final bool koFocused = await driver.focusWidget(
            koTitle.first,
            maxSteps: 120,
          );
          debugPrint('$_kTag KO row focused=$koFocused');
          expect(koFocused, isTrue);
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          final Finder renameBtn = find.byKey(
            ValueKey<String>('dict-detail-rename-server:$hostId/Test KO'),
          );
          expect(renameBtn, findsOneWidget, reason: '服务器行详情应有 Rename');
          final EditableTextState fieldState = await _openRenameByKeyboard(
            tester,
            driver,
            renameBtn,
            'server-row',
            shotName: 'server-dict-05c0-rename-dialog-server',
          );
          fieldState.updateEditingValue(
            const TextEditingValue(
              text: 'My KO',
              selection: TextSelection.collapsed(offset: 5),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          fieldState.performAction(TextInputAction.done);
          String koName() => appModel.dictRepo.remoteDictionaries
              .firstWhere((RemoteDictionary r) => r.name == 'Test KO')
              .effectiveDisplayName;
          for (int i = 0; i < 20 && koName() != 'My KO'; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _pumpFor(tester, const Duration(seconds: 1));
          debugPrint('$_kTag KO effectiveDisplayName=${koName()}');
          expect(koName(), 'My KO', reason: '改名应写入 local_display_name');
          final Finder koDetail = find.byKey(
            ValueKey<String>('dict-detail-server:$hostId/Test KO'),
          );
          _printTexts(
            '03e-detail-renamed',
            koDetail.evaluate().isNotEmpty
                ? _textsIn(tester, koDetail)
                : _textsIn(tester, page),
          );
          expect(
            find.descendant(of: page, matching: find.text('My KO')),
            findsWidgets,
            reason: '列表 / 详情应显示新名字',
          );
          await _shot(tester, 'server-dict-05c-detail-server-renamed');

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

          // 4b. 回到「All」，切到「Frequency」段（焦点进分段外壳 + 方向键）。
          final Finder allFilter = find.byKey(
            const ValueKey<String>('dict-source-filter-all'),
          );
          final bool allFocused = await driver.focusWidget(
            allFilter,
            maxSteps: 120,
          );
          debugPrint('$_kTag all chip focused=$allFocused');
          expect(allFocused, isTrue);
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          final Finder typeSegmented = find.byWidgetPredicate(
            (Widget w) => w is FushiAdjustableSegmented<DictionaryType>,
          );
          expect(typeSegmented, findsOneWidget, reason: '应有词典类型分段');
          final bool segFocused = await driver.focusWidget(
            typeSegmented,
            maxSteps: 120,
          );
          debugPrint('$_kTag type segmented focused=$segFocused');
          expect(segFocused, isTrue);
          await driver.adjust(steps: 2);
          await _pumpFor(tester, const Duration(seconds: 1));
          final DictionaryType segNow = tester
              .widget<FushiAdjustableSegmented<DictionaryType>>(typeSegmented)
              .selected;
          debugPrint('$_kTag type segment now=$segNow');
          expect(segNow, DictionaryType.frequency);
          _printManagerEvidence(tester, '04b-frequency', page);
          expect(
            find.descendant(of: page, matching: find.text('Test Freq JA')),
            findsWidgets,
            reason: '频率段应列出服务器的 Test Freq JA',
          );
          await _shot(tester, 'server-dict-06b-frequency');

          // 4c. 「Kanji」分区（Frequency 往左一段）与服务器汉字词典提示。
          expect(
            await driver.focusWidget(typeSegmented, maxSteps: 120),
            isTrue,
          );
          await driver.adjust(steps: -1);
          await _pumpFor(tester, const Duration(seconds: 1));
          final DictionaryType segKanji = tester
              .widget<FushiAdjustableSegmented<DictionaryType>>(typeSegmented)
              .selected;
          debugPrint('$_kTag type segment now=$segKanji');
          expect(segKanji, DictionaryType.kanji);
          _printManagerEvidence(tester, '04c-kanji', page);
          final Finder kanjiNote = find.byKey(
            ValueKey<String>('dict-kanji-server-note-$hostId'),
          );
          final List<RemoteDictionaryHostSource> srcs = await appModel
              .remoteDictionaryHostSources();
          final int catalogKanji = srcs
              .expand((RemoteDictionaryHostSource h) => h.catalog)
              .where((RemoteDictionary r) => r.type == DictionaryType.kanji)
              .length;
          final String noteTexts = kanjiNote.evaluate().isEmpty
              ? '-'
              : _textsIn(tester, kanjiNote).join(' / ');
          debugPrint(
            '$_kTag kanji note present=${kanjiNote.evaluate().isNotEmpty} '
            'catalogKanji=$catalogKanji texts=$noteTexts',
          );
          if (catalogKanji > 0) {
            expect(kanjiNote, findsOneWidget, reason: '服务器有汉字词典时应有提示');
          } else {
            debugPrint(
              '$_kTag FINDING: test server catalog has no kanji dictionary; '
              'the kanji note is (by design) not rendered',
            );
            expect(kanjiNote, findsNothing);
          }
          await _shot(tester, 'server-dict-06c-kanji-note');

          // 4d. 回 Term，选「This device」：分组头「N of M shown」。
          expect(
            await driver.focusWidget(typeSegmented, maxSteps: 120),
            isTrue,
          );
          await driver.adjust(steps: -1);
          await _pumpFor(tester, const Duration(seconds: 1));
          expect(
            tester
                .widget<FushiAdjustableSegmented<DictionaryType>>(typeSegmented)
                .selected,
            DictionaryType.term,
          );
          expect(await driver.focusWidget(localFilter, maxSteps: 120), isTrue);
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          final String filteredSummary = _summaryText(tester, page);
          _printManagerEvidence(tester, '04d-filtered-header', page);
          debugPrint('$_kTag filtered summary="$filteredSummary"');
          expect(
            RegExp(r'^\d+ of \d+ shown').hasMatch(filteredSummary),
            isTrue,
            reason: '筛选时分组头应为「N of M shown」',
          );
          await _shot(tester, 'server-dict-06d-filtered-header');

          // 4d2. 本机词典行（Test Local JA）详情里同样键盘改名：证明 BUG-4273 的修复
          // 不限于服务器行。
          final Finder localTitle = find.descendant(
            of: page,
            matching: find.text('Test Local JA'),
          );
          expect(localTitle, findsWidgets, reason: '本机筛选下应可见 Test Local JA');
          expect(
            await driver.focusWidget(localTitle.first, maxSteps: 120),
            isTrue,
            reason: 'Test Local JA 行应可经 Tab 到达',
          );
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          final Finder localRenameBtn = find.byKey(
            const ValueKey<String>('dict-detail-rename-Test Local JA'),
          );
          expect(localRenameBtn, findsOneWidget, reason: '本机行详情应有 Rename');
          final EditableTextState localField = await _openRenameByKeyboard(
            tester,
            driver,
            localRenameBtn,
            'local-row',
            shotName: 'server-dict-06d1-rename-dialog-local',
          );
          localField.updateEditingValue(
            const TextEditingValue(
              text: 'My Local JA',
              selection: TextSelection.collapsed(offset: 11),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          localField.performAction(TextInputAction.done);
          String localName() => appModel.dictRepo.dictionaries
              .firstWhere((Dictionary d) => d.name == 'Test Local JA')
              .effectiveDisplayName;
          for (int i = 0; i < 20 && localName() != 'My Local JA'; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _pumpFor(tester, const Duration(seconds: 1));
          debugPrint('$_kTag local effectiveDisplayName=${localName()}');
          expect(localName(), 'My Local JA', reason: '本机改名应写入显示名');
          expect(
            find.descendant(of: page, matching: find.text('My Local JA')),
            findsWidgets,
            reason: '列表 / 详情应显示本机词典新名字',
          );
          await _shot(tester, 'server-dict-06d2-detail-local-renamed');

          // 4e. 来源条「Use for lookups」：先把唯一一台 host 的查词关掉（总闸随之派生
          // 为关），再焦点 + Enter 打开卡片开关，读回总闸 remoteLookupEnabled 变为开。
          expect(await driver.focusWidget(allFilter, maxSteps: 120), isTrue);
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 1));
          await appModel.setRemoteDictionaryHostLookupEnabled(hostId, false);
          await _pumpFor(tester, const Duration(seconds: 2));
          final Finder lookupCardSwitch = find.byKey(
            ValueKey<String>('dict-server-source-lookup-$hostId'),
          );
          Future<bool> hostLookup() async =>
              (await appModel.remoteDictionaryHostSources())
                  .firstWhere(
                    (RemoteDictionaryHostSource h) => h.hostId == hostId,
                  )
                  .lookupEnabled;
          final bool offNotice =
              find
                  .byKey(const ValueKey<String>('dict-remote-lookup-off'))
                  .evaluate()
                  .isNotEmpty ||
              find.text('Remote lookup is off').evaluate().isNotEmpty;
          debugPrint(
            '$_kTag before strip toggle: '
            'remoteLookup=${appModel.remoteLookupEnabled} '
            'hostLookup=${await hostLookup()} '
            'switchPresent=${lookupCardSwitch.evaluate().isNotEmpty} '
            'offNotice=$offNotice',
          );
          _printTexts('04e-sources-off', _textsIn(tester, strip));
          final Finder offLine = find.byKey(
            ValueKey<String>('dict-server-source-lookup-off-$hostId'),
          );
          final Finder offTurnOn = find.byKey(
            ValueKey<String>('dict-server-source-lookup-turn-on-$hostId'),
          );
          final List<String> offLineTexts = offLine.evaluate().isEmpty
              ? const <String>[]
              : _textsIn(tester, offLine);
          debugPrint(
            '$_kTag host-off card line count=${offLine.evaluate().length} '
            'turnOn=${offTurnOn.evaluate().length} texts=$offLineTexts',
          );
          expect(appModel.remoteLookupEnabled, isFalse);
          expect(await hostLookup(), isFalse);
          expect(lookupCardSwitch, findsOneWidget, reason: '关掉后卡片开关仍应在');
          expect(
            offNotice,
            isFalse,
            reason: '全局「Remote lookup is off」提示已删除，不应出现',
          );
          expect(offLine, findsOneWidget, reason: 'host 关查词时卡片应有说明行');
          expect(
            offLineTexts.any(
              (String s) => s.startsWith('Not used for lookups'),
            ),
            isTrue,
          );
          expect(offTurnOn, findsOneWidget, reason: '说明行应带 Turn on');
          await _shot(tester, 'server-dict-06e-sources-lookup-off');
          final bool cardSwitchFocused = await driver.focusUntil(
            () => _focusInside(driver, lookupCardSwitch),
            maxSteps: 150,
          );
          debugPrint('$_kTag strip lookup switch focused=$cardSwitchFocused');
          expect(cardSwitchFocused, isTrue);
          await driver.activate();
          for (int i = 0; i < 20 && !appModel.remoteLookupEnabled; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _pumpFor(tester, const Duration(seconds: 2));
          final bool hostAfter = await hostLookup();
          debugPrint(
            '$_kTag after strip toggle: '
            'remoteLookup=${appModel.remoteLookupEnabled} hostLookup=$hostAfter',
          );
          expect(hostAfter, isTrue, reason: 'Enter 应打开这台 host 的查词');
          expect(
            appModel.remoteLookupEnabled,
            isTrue,
            reason: '打开唯一一台 host 的查词后总闸（派生值）应为开',
          );
          _printTexts('04f-sources-on', _textsIn(tester, strip));
          final int offLineAfter = find
              .byKey(ValueKey<String>('dict-server-source-lookup-off-$hostId'))
              .evaluate()
              .length;
          final bool offNoticeAfter =
              find
                  .byKey(const ValueKey<String>('dict-remote-lookup-off'))
                  .evaluate()
                  .isNotEmpty ||
              find.text('Remote lookup is off').evaluate().isNotEmpty;
          debugPrint(
            '$_kTag after strip toggle: cardLine=$offLineAfter '
            'offNotice=$offNoticeAfter',
          );
          expect(offLineAfter, 0, reason: '打开后卡片说明行应消失');
          expect(offNoticeAfter, isFalse);
          await _shot(tester, 'server-dict-06f-sources-lookup-on');

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

          // ── 5b. 查词 › 外部集成：全局「远程查词」开关已删，换成「Dictionary
          // servers · <摘要>」导航行，Enter 打开「Pairing & devices」。
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    SettingsDetailPage(destination: buildLookupDestination()),
              ),
            ),
          );
          await _pumpFor(tester, const Duration(seconds: 3));
          final Finder serversRow = find.byKey(
            const ValueKey<String>('lookup.remote_lookup'),
          );
          final bool serversFocused = await driver.focusUntil(
            () => _focusInside(driver, serversRow),
            maxSteps: 250,
          );
          debugPrint('$_kTag dictionary-servers row focused=$serversFocused');
          expect(
            serversFocused,
            isTrue,
            reason: '「Dictionary servers」行应可经 Tab 到达',
          );
          await tester.ensureVisible(serversRow);
          await _pumpFor(tester, const Duration(seconds: 1));
          final List<String> rowTexts = _textsIn(tester, serversRow);
          final int rowSwitches = find
              .descendant(
                of: serversRow,
                matching: find.byWidgetPredicate(
                  (Widget w) => w.runtimeType.toString().contains('Switch'),
                ),
              )
              .evaluate()
              .length;
          final Finder integrationsScope = find
              .ancestor(of: serversRow, matching: find.byType(Scaffold))
              .first;
          _printTexts(
            '09-lookup-settings',
            _textsIn(tester, integrationsScope),
          );
          debugPrint(
            '$_kTag dictionary-servers row texts=$rowTexts switches=$rowSwitches '
            'oldSwitchText=${find.text('Remote dictionary lookup').evaluate().length}',
          );
          expect(rowTexts, contains('Dictionary servers'));
          expect(
            rowTexts.any((String s) => s.contains(pairedName)),
            isTrue,
            reason: '副标题应报在用的服务器（$pairedName）',
          );
          expect(rowSwitches, 0, reason: '「Dictionary servers」行不应再有开关');
          expect(find.text('Remote dictionary lookup'), findsNothing);
          await _shot(tester, 'server-dict-09-lookup-settings');
          await driver.activate();
          await _pumpFor(tester, const Duration(seconds: 3));
          final Finder pairingTitle = find.text('Pairing & devices');
          final Finder pairingHost = find.byKey(
            ValueKey<String>('interconnect-lookup-host-$hostId'),
          );
          debugPrint(
            '$_kTag after Enter on servers row: '
            'pairingTitle=${pairingTitle.evaluate().length} '
            'hostSection=${pairingHost.evaluate().length}',
          );
          expect(
            pairingTitle,
            findsWidgets,
            reason: 'Enter 应打开 Pairing & devices',
          );
          expect(pairingHost, findsOneWidget, reason: '打开的应是带 host 查词分组的配对页');
          await _shot(tester, 'server-dict-09b-lookup-settings-open');
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

          // ── 7. 还原 Test Games JA 后查「猫」：本机与服务器结果合并 ─────────
          // 第 4 步已把 Test Games JA 的 hidden 翻过来（before 是翻转前的状态）。
          final RemoteDictionary cur = find1(before.name);
          if (cur.hidden != before.hidden) {
            await appModel.setRemoteDictionaryHidden(cur, before.hidden);
          }
          final DictionarySearchResult neko = await appModel.searchDictionary(
            searchTerm: '猫',
            searchWithWildcards: false,
            useCache: false,
          );
          final List<String> nekoDicts = <String>[];
          for (final DictionaryEntry e in neko.entries) {
            if (!nekoDicts.contains(e.dictionaryName)) {
              nekoDicts.add(e.dictionaryName);
            }
          }
          debugPrint(
            '$_kTag search 猫: entries=${neko.entries.length} '
            'dictionaryOrder=$nekoDicts',
          );
          for (final DictionaryEntry e in neko.entries) {
            debugPrint(
              '$_kTag search 猫 | ${e.dictionaryName} | ${e.word} '
              '${e.reading} | ${e.meaning}',
            );
          }

          // ── 8. 查词页的 WebView 结果区（与浮层同一个 popup.js）查「猫」 ──────
          HomePage.debugSelectTab?.call(HomeTab.dictionaries);
          await _pumpFor(tester, const Duration(seconds: 2));
          final Finder dictPage = find.byType(HomeDictionaryPage);
          expect(dictPage, findsOneWidget, reason: '查词页应已打开');
          final HomeDictionarySearchDebug searchDebug =
              tester.state(dictPage) as HomeDictionarySearchDebug;
          await searchDebug.debugSearch('猫', writeHistory: false);
          await _pumpFor(tester, const Duration(seconds: 3));
          final Finder popupWeb = find.byWidgetPredicate(
            (Widget w) =>
                w is DictionaryPopupWebView &&
                w.result.searchTerm == '猫' &&
                w.result.entries.isNotEmpty,
          );
          debugPrint('$_kTag popup webviews=${popupWeb.evaluate().length}');
          expect(popupWeb, findsWidgets, reason: '查词结果区应有 WebView');
          final DictionaryPopupWebViewState webState = tester.state(
            popupWeb.first,
          );
          Object? dom;
          for (int i = 0; i < 60; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            dom = await webState.debugEval(
              'JSON.stringify({glyphs: '
              "document.querySelectorAll('.dict-remote-glyph').length, "
              "text: (document.getElementById('entries-container')"
              '||document.body).innerText.slice(0, 800)})',
            );
            if (dom is String && dom.contains('猫')) break;
          }
          debugPrint('$_kTag popup dom=$dom');
          await _shot(tester, 'server-dict-08-popup-shell');
          final List<int>? px = await webState.debugCaptureWebView();
          if (px == null || px.isEmpty) {
            debugPrint(
              '$_kTag FINDING: popup WebView takeScreenshot returned nothing',
            );
          } else {
            final File f = File(
              '${observeScreenshotDir().path}/server-dict-08-popup.png',
            );
            await f.writeAsBytes(px, flush: true);
            debugPrint(
              '$_kTag shot server-dict-08-popup -> ${f.path} bytes=${px.length}',
            );
          }
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
