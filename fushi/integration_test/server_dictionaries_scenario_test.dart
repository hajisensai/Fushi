// 服务器托管词典的端到端场景验收（Windows 离屏 runner，真 app + 真测试服务器）。
//
// 像用户一样用多台设备、多个配置、多本词典走七个场景，每一步留截图
// （`scenario-NN-<slug>`）与可 diff 的 `[scenario]` 证据行：
//   1. 瘦设备：新装、配对、本机零词典——管理页只有服务器行、汉字分区提示、查词全来自服务器；
//   2. 配置：两个配置各自选服务器词典（隐藏 / 置顶），切换后列表与查词跟着变、请求带选择；
//      语言 / 媒体绑定解析；作品级配置视图查词；
//   3. 混合设备：本机导入同名 / 独有词典，「推送到服务器」与「下载到本机」；
//   4. 服务器端变化（默认开关、语言、删除、重新导入）经目录刷新传到本机；
//   5. 离线：停服务器后目录行保留、查词只给本机结果且不卡；恢复后合并；
//   6. 解除配对（保留 / 忘掉词典设置）与重新配对；
//   7. 第二台设备并发查词，各按各的词典选择。
// 产品检查一律记成 CHECK OK / CHECK FAIL（不中途抛），最后统一断言；一个场景抛异常
// 只记 SCENARIO ERROR，后面的场景照跑。一律焦点驱动（Tab + Enter），不用 tester.tap。
//
// 环境相关的值一律由 dart-define 给，没有本机缺省值；缺任何一个测试立即失败并点名：
//   FUSHI_PROBE_PAIR_LINK   测试服务器的配对链接（fushi://pair?...）
//   FUSHI_PROBE_SCRATCH     工作目录，需含 dicts/（测试词典 zip）、srv/fushi_server.yaml
//                           （读 admin_token）、gen/stop_server.ps1、gen/restart_server.cmd
//   FUSHI_PROBE_SERVER_HOST 测试服务器的主机（用于探测端口是否开）
//   FUSHI_PROBE_SERVER_PORT 测试服务器的互联端口
//   FUSHI_PROBE_ADMIN_BASE  admin API 根地址（如 https://127.0.0.1:<admin-port>）
// 示例（fushi/ 下）：
//   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 `
//     -Target integration_test\server_dictionaries_scenario_test.dart `
//     -DartDefine 'FUSHI_PROBE_PAIR_LINK=<pair-link>',`
//                 'FUSHI_PROBE_SCRATCH=<scratch-dir>',`
//                 'FUSHI_PROBE_SERVER_HOST=<server-host>',`
//                 'FUSHI_PROBE_SERVER_PORT=<port>',`
//                 'FUSHI_PROBE_ADMIN_BASE=https://127.0.0.1:<admin-port>'
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show ProviderContainer, ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart'
    show DictionaryDownloadPhase;
import 'package:fushi/src/models/dictionary_repository.dart'
    show RemoteDictionary;
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_manager_panels.dart'
    show DictionarySourceChip, DictionarySourceKind;
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart'
    show ProfileViewModel, profileViewModelProvider;
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show withoutInterconnectHost;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show FushiAdjustableSegmented;
import 'package:fushi_core/fushi_core.dart'
    show ProfileMediaKind, ProfileRow, RemoteDictionaryMetaRow;
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show Dictionary, DictionaryEntry, DictionarySearchResult, DictionaryType;
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteLookupDictionaryConfig;
import 'package:fushi_engine/sync/interconnect_device_name.dart'
    show resolveInterconnectDeviceName;
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kTag = '[scenario]';

const String _kPairLink = String.fromEnvironment('FUSHI_PROBE_PAIR_LINK');

/// 本机测试素材与服务器配置所在的目录（布局见文件头）。
const String _kScratch = String.fromEnvironment('FUSHI_PROBE_SCRATCH');

const String _kAdminBase = String.fromEnvironment('FUSHI_PROBE_ADMIN_BASE');
const String _kServerHost = String.fromEnvironment('FUSHI_PROBE_SERVER_HOST');
const int _kServerPort = int.fromEnvironment(
  'FUSHI_PROBE_SERVER_PORT',
  defaultValue: -1,
);

/// 缺必需的 dart-define 就在启动 app 前失败，消息点名缺哪个。
void _requireProbeDefines() {
  final List<String> missing = <String>[
    if (_kPairLink.isEmpty) 'FUSHI_PROBE_PAIR_LINK',
    if (_kScratch.isEmpty) 'FUSHI_PROBE_SCRATCH',
    if (_kAdminBase.isEmpty) 'FUSHI_PROBE_ADMIN_BASE',
    if (_kServerHost.isEmpty) 'FUSHI_PROBE_SERVER_HOST',
    if (_kServerPort < 0) 'FUSHI_PROBE_SERVER_PORT',
  ];
  if (missing.isNotEmpty) {
    fail('缺少必需的 --dart-define（探针没有本机缺省值）：${missing.join(', ')}');
  }
}

const String _kGeneral = 'Test General JA';
const String _kGames = 'Test Games JA';
const String _kZh = 'Test ZH';
const String _kFreq = 'Test Freq JA';
const String _kKo = 'Test KO';
const String _kKanji = 'KANJIDIC [2026-313]';
const String _kLocalJa = 'Test Local JA';
const String _kPush = 'Test Push JA';

const String _kGamesProfile = 'Japanese – Games';
const String _kChineseProfile = 'Chinese';

// ── 证据记录 ──────────────────────────────────────────────────────────────

final List<String> _fails = <String>[];
final List<String> _scenarioErrors = <String>[];

void _log(String s) => debugPrint('$_kTag $s');

bool _check(bool ok, String label, [Object? detail]) {
  _log(
    'CHECK ${ok ? 'OK  ' : 'FAIL'} $label'
    '${detail == null ? '' : ' :: $detail'}',
  );
  if (!ok) _fails.add(label);
  return ok;
}

Future<void> _scenario(String name, Future<void> Function() body) async {
  _log('════ SCENARIO $name ════');
  final Stopwatch sw = Stopwatch()..start();
  try {
    await body();
  } catch (e, st) {
    _scenarioErrors.add('$name: $e');
    _log('SCENARIO ERROR $name: $e');
    for (final String l in st.toString().split('\n').take(14)) {
      _log('  $l');
    }
  }
  _log('════ END $name (${sw.elapsedMilliseconds} ms) ════');
}

// ── 通用 UI 小工具 ────────────────────────────────────────────────────────

List<String> _textsIn(WidgetTester tester, Finder scope) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  void add(String? s) {
    final String v = (s ?? '').trim();
    if (v.isEmpty || !seen.add(v)) return;
    out.add(v);
  }

  if (scope.evaluate().isEmpty) return out;
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

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final int steps = total.inMilliseconds ~/ 250;
  for (int i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) return false;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return true;
}

/// 边 pump 边等 [future]（真时间的异步工作需要帧继续走）。
Future<T> _awaitPumping<T>(
  WidgetTester tester,
  Future<T> future, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  bool done = false;
  T? value;
  Object? error;
  StackTrace? stack;
  unawaited(
    future.then<void>(
      (T v) {
        value = v;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  final bool ok = await _pumpUntil(tester, () => done, timeout: timeout);
  if (!ok) throw TimeoutException('awaitPumping timed out', timeout);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value as T;
}

Future<ObserveShot> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 600));
  final ObserveShot shot = await captureFlutterFrame(tester, 'scenario-$name');
  _log(
    'shot scenario-$name -> ${shot.path} saved=${shot.saved} '
    'nonBlank=${shot.nonBlank}',
  );
  _check(shot.saved && shot.nonBlank, 'shot scenario-$name saved & non-blank');
  return shot;
}

/// 最近一次 [_focus] 是否真由 Tab 走到（false = 走不到、用了 requestFocusInside 兜底）。
bool _lastFocusByTab = false;

/// 焦点移进 [target]（Tab 遍历，走不到时用 requestFocusInside 兜底并记一笔），返回是否成功。
Future<bool> _focus(
  WidgetTester tester,
  FocusDriver driver,
  Finder target,
  String label, {
  int maxSteps = 160,
}) async {
  _lastFocusByTab = false;
  if (target.evaluate().isEmpty) {
    _log('focus $label: target not in tree');
    return false;
  }
  try {
    await tester.ensureVisible(target.first);
    await tester.pump(const Duration(milliseconds: 300));
  } catch (_) {}
  bool ok = await driver.focusUntil(
    () => _focusInside(driver, target),
    maxSteps: maxSteps,
  );
  _lastFocusByTab = ok;
  if (!ok) {
    ok = await driver.requestFocusInside(target.first);
    await tester.pump(const Duration(milliseconds: 200));
    ok = ok && _focusInside(driver, target);
    _log('focus $label: Tab walk failed, requestFocusInside=$ok');
  } else {
    _log('focus $label: reached by Tab');
  }
  return ok;
}

Future<bool> _focusAndEnter(
  WidgetTester tester,
  FocusDriver driver,
  Finder target,
  String label, {
  int maxSteps = 160,
}) async {
  final bool ok = await _focus(
    tester,
    driver,
    target,
    label,
    maxSteps: maxSteps,
  );
  if (ok) {
    await driver.activate();
    await _pumpFor(tester, const Duration(milliseconds: 750));
  }
  return ok;
}

// ── 管理页 ────────────────────────────────────────────────────────────────

Future<Finder> _openManager(WidgetTester tester, AppModel appModel) async {
  final Finder page = find.byType(DictionaryDialogPage);
  if (page.evaluate().isEmpty) {
    unawaited(appModel.showDictionaryMenu());
    await _pumpUntil(
      tester,
      () => page.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 15),
    );
  }
  await _pumpFor(tester, const Duration(seconds: 2));
  return page;
}

Future<void> _closeManager(WidgetTester tester) async {
  final Finder page = find.byType(DictionaryDialogPage);
  if (page.evaluate().isEmpty) return;
  Navigator.of(tester.element(page)).pop();
  await _pumpFor(tester, const Duration(seconds: 1));
}

/// 管理页里按显示顺序的行：`<行 key> => <来源种类>`（读 [DictionarySourceChip.kind]；
/// 服务器行的 chip 不画字，只能读种类）。
List<String> _managerRows(WidgetTester tester, Finder page) {
  final List<String> out = <String>[];
  final Finder chips = find.descendant(
    of: page,
    matching: find.byWidgetPredicate((Widget w) {
      final Key? k = w.key;
      return w is DictionarySourceChip &&
          k is ValueKey<String> &&
          k.value.startsWith('dict-row-source-');
    }),
  );
  for (final Element e in chips.evaluate()) {
    final DictionarySourceChip chip = e.widget as DictionarySourceChip;
    final String key = (chip.key! as ValueKey<String>).value.substring(
      'dict-row-source-'.length,
    );
    final String text = _textsIn(tester, find.byWidget(chip)).join(' / ');
    out.add('$key => ${chip.kind.name}${text.isEmpty ? '' : ' "$text"'}');
  }
  return out;
}

/// [rowKey] 那一行的来源种类；行不在树里为 null。
DictionarySourceKind? _rowKind(
  WidgetTester tester,
  Finder page,
  String rowKey,
) {
  final Finder chip = find.descendant(
    of: page,
    matching: find.byKey(ValueKey<String>('dict-row-source-$rowKey')),
  );
  if (chip.evaluate().isEmpty) return null;
  return (chip.evaluate().first.widget as DictionarySourceChip).kind;
}

void _printManager(WidgetTester tester, String step, Finder page) {
  final List<String> rows = _managerRows(tester, page);
  _log('$step manager rows (${rows.length}):');
  for (final String r in rows) {
    _log('$step   row | $r');
  }
  final Finder strip = find.byKey(
    const ValueKey<String>('dict-server-sources'),
  );
  _log('$step strip: ${_textsIn(tester, strip).join(' / ')}');
  final Finder summary = find.byKey(
    const ValueKey<String>('dict-list-summary'),
  );
  _log('$step summary: ${_textsIn(tester, summary).join(' / ')}');
  final Finder subtitle = find.byKey(
    const ValueKey<String>('dict-profile-subtitle'),
  );
  _log('$step subtitle: ${_textsIn(tester, subtitle).join(' / ')}');
}

/// 来源卡状态行：(文字, 是否完整放下——没被省略号截断)。
(String, bool) _statusLine(WidgetTester tester, String hostId) {
  final Finder f = find.byKey(
    ValueKey<String>('dict-server-source-status-$hostId'),
  );
  if (f.evaluate().isEmpty) return ('(absent)', false);
  final Text text = tester.widget<Text>(f.first);
  final Finder para = find.descendant(
    of: f.first,
    matching: find.byType(RichText),
  );
  final bool fits =
      para.evaluate().isNotEmpty &&
      !tester.renderObject<RenderParagraph>(para.first).didExceedMaxLines;
  return (text.data ?? text.textSpan?.toPlainText() ?? '', fits);
}

/// 行开关当前值（本机行 key = 词典名，服务器行 key = `server:<host>/<名>`）。
bool? _switchValue(WidgetTester tester, String rowKey) {
  final Finder f = find.byKey(ValueKey<String>('dict-row-switch-$rowKey'));
  if (f.evaluate().isEmpty) return null;
  return (f.evaluate().first.widget as dynamic).value as bool;
}

int _rowIndex(List<String> rows, String name) {
  for (int i = 0; i < rows.length; i++) {
    final String key = rows[i].split(' => ').first;
    if (key == name || key.endsWith('/$name')) return i;
  }
  return -1;
}

Future<bool> _setTypeSegment(
  WidgetTester tester,
  FocusDriver driver,
  DictionaryType target,
) async {
  final Finder seg = find.byWidgetPredicate(
    (Widget w) => w is FushiAdjustableSegmented<DictionaryType>,
  );
  if (seg.evaluate().isEmpty) {
    _log('type segmented not in tree');
    return false;
  }
  DictionaryType now() =>
      tester.widget<FushiAdjustableSegmented<DictionaryType>>(seg).selected;
  const List<DictionaryType> order = <DictionaryType>[
    DictionaryType.term,
    DictionaryType.kanji,
    DictionaryType.frequency,
  ];
  if (now() == target) return true;
  if (!await driver.focusWidget(seg, maxSteps: 160)) return false;
  final int delta = order.indexOf(target) - order.indexOf(now());
  await driver.adjust(steps: delta);
  await _pumpFor(tester, const Duration(seconds: 1));
  return now() == target;
}

/// 焦点到 [title] 那一行、Enter 打开详情侧板（行的焦点节点是标题的祖先，用
/// [FocusDriver.focusWidget] 的双向判定）。
Future<bool> _openDetail(
  WidgetTester tester,
  FocusDriver driver,
  Finder page,
  String title,
) async {
  final Finder rowTitle = find.descendant(of: page, matching: find.text(title));
  if (rowTitle.evaluate().isEmpty) {
    _log('detail $title: row title not visible');
    return false;
  }
  try {
    await tester.ensureVisible(rowTitle.first);
    await tester.pump(const Duration(milliseconds: 300));
  } catch (_) {}
  final bool ok = await driver.focusWidget(rowTitle.first, maxSteps: 160);
  _log('detail $title: row focused=$ok');
  if (ok) {
    await driver.activate();
    await _pumpFor(tester, const Duration(milliseconds: 1250));
  }
  return ok;
}

// ── 查词 ──────────────────────────────────────────────────────────────────

class _Lookup {
  _Lookup(this.term, this.result, this.ms);
  final String term;
  final DictionarySearchResult result;
  final int ms;

  List<String> get dicts {
    final List<String> out = <String>[];
    for (final DictionaryEntry e in result.entries) {
      if (!out.contains(e.dictionaryName)) out.add(e.dictionaryName);
    }
    return out;
  }

  List<String> get meanings => <String>[
    for (final DictionaryEntry e in result.entries) e.plainMeaning.trim(),
  ];

  List<String> get kanjiDicts => <String>{
    for (final dynamic k in result.kanjiResults) '${k.dictName}',
  }.toList();

  bool get hasFreqJa =>
      result.entries.any((DictionaryEntry e) => e.extra.contains(_kFreq)) ||
      (result.popupJson ?? '').contains(_kFreq);

  int count(String meaningPart) =>
      meanings.where((String m) => m.contains(meaningPart)).length;
}

Future<_Lookup> _lookup(
  WidgetTester tester,
  AppModel appModel,
  String term,
  String label,
) async {
  final Stopwatch sw = Stopwatch()..start();
  final DictionarySearchResult r = await _awaitPumping(
    tester,
    appModel.searchDictionary(
      searchTerm: term,
      searchWithWildcards: false,
      useCache: false,
    ),
    timeout: const Duration(seconds: 60),
  );
  final _Lookup l = _Lookup(term, r, sw.elapsedMilliseconds);
  _log(
    'lookup[$label] $term ms=${l.ms} entries=${r.entries.length} '
    'dicts=${l.dicts} kanji=${l.kanjiDicts} freqJa=${l.hasFreqJa} '
    'applied=${appModel.remoteDictionaryConfigAppliedByHost}',
  );
  for (final DictionaryEntry e in r.entries) {
    _log(
      'lookup[$label] $term | ${e.dictionaryName} | ${e.word} ${e.reading} '
      '| ${e.plainMeaning.trim().replaceAll('\n', ' ')}',
    );
  }
  return l;
}

String _cfg(RemoteLookupDictionaryConfig? c) => c == null
    ? 'null'
    : 'excluded=${c.excluded.toList()..sort()} order=${c.order}';

String _remoteSummary(Iterable<RemoteDictionary> rows) => rows
    .map(
      (RemoteDictionary r) =>
          '${r.name}(order=${r.order},hidden=${r.hidden},'
          'lang=${r.sourceLanguage},missing=${r.isMissing})',
    )
    .join('; ');

String? _remoteOrderFirst(AppModel appModel, String hostId) {
  final List<String> order =
      appModel.dictRepo.filtersForHost(hostId)?.order ?? const <String>[];
  return order.isEmpty ? null : order.first;
}

RemoteDictionary? _remote(AppModel appModel, String name) {
  for (final RemoteDictionary r in appModel.dictRepo.remoteDictionaries) {
    if (r.name == name) return r;
  }
  return null;
}

Future<List<RemoteDictionaryMetaRow>> _dbRows(AppModel appModel) =>
    appModel.database.getAllRemoteDictionaryMetadata();

String _dbSummary(List<RemoteDictionaryMetaRow> rows) => rows
    .map(
      (RemoteDictionaryMetaRow r) =>
          '${r.name}(order=${r.order},hidden=${r.hidden},'
          'lang=${r.sourceLanguage},missing=${r.missingSince != null})',
    )
    .join('; ');

// ── 管理员 API / 服务器进程 ───────────────────────────────────────────────

String? _adminTokenCache;

String _adminToken() {
  final String? cached = _adminTokenCache;
  if (cached != null) return cached;
  final String yaml = File(
    p.join(_kScratch, 'srv', 'fushi_server.yaml'),
  ).readAsStringSync();
  final RegExpMatch? m = RegExp(
    r'^admin_token:\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(yaml);
  if (m == null) throw StateError('admin_token not found in server config');
  return _adminTokenCache = m.group(1)!;
}

class _Http {
  _Http(this.status, this.body);
  final int status;
  final Object? body;
}

Future<_Http> _request(
  String method,
  Uri uri, {
  required String authorization,
  Object? json,
  List<int>? bytes,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final HttpClient client = HttpClient()
    ..badCertificateCallback = ((X509Certificate _, String _, int _) => true)
    ..connectionTimeout = const Duration(seconds: 5);
  try {
    final HttpClientRequest req = await client.openUrl(method, uri);
    req.headers.set(HttpHeaders.authorizationHeader, authorization);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(json)));
    } else if (bytes != null) {
      req.headers.contentType = ContentType.binary;
      req.add(bytes);
    }
    final HttpClientResponse resp = await req.close().timeout(timeout);
    final String text = await resp.transform(utf8.decoder).join();
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = text;
    }
    return _Http(resp.statusCode, decoded);
  } finally {
    client.close(force: true);
  }
}

Future<_Http> _admin(
  String method,
  String path, {
  Object? json,
  List<int>? bytes,
}) => _request(
  method,
  Uri.parse('$_kAdminBase$path'),
  authorization: 'Bearer ${_adminToken()}',
  json: json,
  bytes: bytes,
);

String _dictPath(String name) =>
    '/api/admin/dictionaries/${Uri.encodeComponent(name)}';

Future<List<Map<String, Object?>>> _adminList() async {
  final _Http r = await _admin('GET', '/api/admin/dictionaries');
  final Object? body = r.body;
  if (r.status != 200 || body is! Map) {
    throw StateError('admin list failed: ${r.status} $body');
  }
  return <Map<String, Object?>>[
    for (final Object? e in (body['dictionaries'] as List<Object?>? ?? []))
      if (e is Map) e.cast<String, Object?>(),
  ];
}

Future<bool> _serverPortOpen() async {
  try {
    final Socket s = await Socket.connect(
      _kServerHost,
      _kServerPort,
      timeout: const Duration(seconds: 2),
    );
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _stopServer(WidgetTester tester) async {
  final ProcessResult r = await _awaitPumping(
    tester,
    Process.run('powershell', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      p.join(_kScratch, 'gen', 'stop_server.ps1'),
    ]),
  );
  _log('stop server: ${'${r.stdout}'.trim()} ${'${r.stderr}'.trim()}');
  final Stopwatch sw = Stopwatch()..start();
  while (await _serverPortOpen() && sw.elapsed < const Duration(seconds: 20)) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  _log('server port open after stop: ${await _serverPortOpen()}');
}

Future<bool> _startServer(WidgetTester tester) async {
  if (await _serverPortOpen()) return true;
  await Process.start('cmd.exe', <String>[
    '/c',
    p.join(_kScratch, 'gen', 'restart_server.cmd'),
  ], mode: ProcessStartMode.detached);
  final Stopwatch sw = Stopwatch()..start();
  bool up = false;
  while (sw.elapsed < const Duration(seconds: 240)) {
    await _pumpFor(tester, const Duration(seconds: 2));
    if (await _serverPortOpen()) {
      up = true;
      break;
    }
  }
  _log('server restart up=$up after ${sw.elapsed.inSeconds}s');
  return up;
}

// ── 配对 ──────────────────────────────────────────────────────────────────

Future<String> _pair(WidgetTester tester, AppModel appModel) async {
  final FushiPairLink link = FushiPairLink.tryParse(_kPairLink)!;
  final InterconnectLinkPairingResult pairing = await _awaitPumping(
    tester,
    (() async => pairWithInterconnectLink(
      repo: SyncRepository(appModel.database),
      link: link,
      localDeviceName: await resolveInterconnectDeviceName(
        appModel.platformServices.deviceInfo,
      ),
      pinProvider: () async => null,
    ))(),
  );
  _log('pairing result: $pairing');
  if (pairing is! InterconnectLinkPaired) {
    throw StateError('pairing failed: $pairing');
  }
  return pairing.deviceName ?? link.deviceName ?? '';
}

Future<void> _unpair(AppModel appModel, String hostId) async {
  await SyncRepository(appModel.database).updateFushiClientUrls((
    List<FushiClientUrl> current,
  ) {
    List<FushiClientUrl> next = current;
    for (final FushiClientUrl u in current) {
      if (remoteDictionaryHostIdOf(u) == hostId) {
        next = withoutInterconnectHost(next, url: u.url, hostId: u.hostId);
      }
    }
    return next;
  });
}

Future<FushiClientUrl?> _pairedUrl(AppModel appModel, String hostId) async {
  for (final FushiClientUrl u in await SyncRepository(
    appModel.database,
  ).getFushiClientUrls()) {
    if (remoteDictionaryHostIdOf(u) == hostId) return u;
  }
  return null;
}

Future<void> _importLocalDict(
  WidgetTester tester,
  AppModel appModel,
  String fileName,
  String title,
) async {
  final File file = File(p.join(_kScratch, 'dicts', fileName));
  final ValueNotifier<String> progress = ValueNotifier<String>('');
  try {
    await _awaitPumping(
      tester,
      appModel.importDictionary(
        file: file,
        progressNotifier: progress,
        onImportSuccess: () {},
      ),
    );
  } finally {
    progress.dispose();
  }
  await _pumpUntil(
    tester,
    () => appModel.dictRepo.dictionaries.any((Dictionary d) => d.name == title),
    timeout: const Duration(seconds: 10),
  );
  _log(
    'imported $fileName: local=${appModel.dictRepo.dictionaries.map((Dictionary d) => d.name).toList()}',
  );
}

Dictionary? _local(AppModel appModel, String name) {
  for (final Dictionary d in appModel.dictRepo.dictionaries) {
    if (d.name == name) return d;
  }
  return null;
}

ProfileViewModel _vm(ProviderContainer c) =>
    c.read(profileViewModelProvider.notifier);

Future<int?> _profileId(ProfileRepository repo, String name) async {
  for (final ProfileRow r in await repo.getAllProfiles()) {
    if (r.name == name) return r.id;
  }
  return null;
}

/// 第二台设备：直接对服务器发互联查词请求（与 app 并发），返回 (applied, 词典顺序, 释义)。
Future<(bool?, List<String>, List<String>)> _peerLookup(
  FushiClientUrl url,
  String token,
  Map<String, Object?> body,
) async {
  final _Http r = await _request(
    'POST',
    Uri.parse('${url.url}/api/lookup/dictionary'),
    authorization: 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    json: body,
  );
  final Object? json = r.body;
  if (r.status != 200 || json is! Map) {
    throw StateError('peer lookup failed: ${r.status} $json');
  }
  final Object? result = json['result'];
  final List<String> order = <String>[];
  final List<String> meanings = <String>[];
  if (result is Map) {
    for (final Object? raw in (result['entries'] as List<Object?>? ?? [])) {
      Object? e = raw;
      if (e is String) e = jsonDecode(e);
      if (e is! Map) continue;
      final String n = '${e['dictionaryName']}';
      if (!order.contains(n)) order.add(n);
      meanings.add('${e['meaning']}');
    }
  }
  return (json['dictionaryConfigApplied'] as bool?, order, meanings);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('服务器托管词典：多设备 / 多配置 / 多词典端到端场景', (WidgetTester tester) async {
    _requireProbeDefines();
    await runFushiItest(
      label: 'scenario',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        await tester.pump(const Duration(seconds: 2));
        final AppModel appModel = await enableFocusNavigation(tester);
        expect(appModel.isInitialised, isTrue);
        final FocusDriver driver = FocusDriver(tester);
        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(HomePage).first),
          listen: false,
        );
        final ProfileRepository profileRepo = appModel
            .interconnectProfileRepository();
        HomePage.debugSelectTab?.call(HomeTab.books);
        await _pumpFor(tester, const Duration(seconds: 1));
        await _shot(tester, '00-home');

        String hostId = '';
        String hostName = '';
        bool serverStopped = false;
        int? defaultProfileId;

        try {
          // ═══ 1. 瘦设备 ═══════════════════════════════════════════════════
          await _scenario('1 thin device', () async {
            _check(
              appModel.dictRepo.dictionaries.isEmpty,
              '1 fresh app has no local dictionaries',
              appModel.dictRepo.dictionaries.map((Dictionary d) => d.name),
            );
            hostName = await _pair(tester, appModel);
            await _pumpUntil(tester, () => appModel.remoteLookupEnabled);
            final bool filled = await _pumpUntil(
              tester,
              () => appModel.dictRepo.remoteDictionaries.length >= 7,
              timeout: const Duration(seconds: 30),
            );
            _check(
              filled,
              '1 catalog auto-reconciled after pairing (>=7 rows in 30s)',
              _remoteSummary(appModel.dictRepo.remoteDictionaries),
            );
            hostId = appModel.dictRepo.remoteDictionaries.first.hostId;
            _log('hostId=$hostId hostName=$hostName');

            final Finder page = await _openManager(tester, appModel);
            _printManager(tester, '1', page);
            final List<String> rows = _managerRows(tester, page);
            _check(
              rows.isNotEmpty &&
                  rows.every((String r) => r.startsWith('server:')),
              '1 manager shows only server rows',
              rows,
            );
            _check(
              rows.every((String r) => r.contains('=> server')),
              '1 every row is a server-source row',
            );
            final (String st1, bool fit1) = _statusLine(tester, hostId);
            _check(
              st1 == 'Online' && fit1,
              '1 source card status "Online" fits (not ellipsized)',
              'text="$st1" fits=$fit1',
            );
            await _shot(tester, '01-thin-manager');

            final bool kanjiSeg = await _setTypeSegment(
              tester,
              driver,
              DictionaryType.kanji,
            );
            _check(kanjiSeg, '1 Kanji segment reachable');
            final Finder kanjiNote = find.byKey(
              ValueKey<String>('dict-kanji-server-note-$hostId'),
            );
            _printManager(tester, '1-kanji', page);
            _log('1 kanji note texts: ${_textsIn(tester, kanjiNote)}');
            _check(
              kanjiNote.evaluate().isNotEmpty,
              '1 kanji section note dict-kanji-server-note-<host> present',
            );
            final Finder kanjiTile = find.byKey(
              const ValueKey<String>('dict-overview-sources-kanji'),
            );
            final String kanjiTileText = kanjiTile.evaluate().isEmpty
                ? '(absent)'
                : (tester.widget<Text>(kanjiTile.first).data ?? '');
            _check(
              kanjiTileText == '0 on this device · 1 on server',
              '1 Kanji overview tile reads "0 on this device · 1 on server"',
              kanjiTileText,
            );
            final bool emptyStateShown = find
                .descendant(
                  of: page,
                  matching: find.text('Import a dictionary for use'),
                )
                .evaluate()
                .isNotEmpty;
            _check(
              kanjiNote.evaluate().isNotEmpty && !emptyStateShown,
              '1 Kanji: no "Import a dictionary" empty state while the server note shows',
              'note=${kanjiNote.evaluate().isNotEmpty} emptyState=$emptyStateShown',
            );
            await _shot(tester, '02-thin-kanji-note');
            final bool freqSeg = await _setTypeSegment(
              tester,
              driver,
              DictionaryType.frequency,
            );
            _printManager(tester, '1-freq', page);
            _check(
              freqSeg &&
                  find
                      .descendant(of: page, matching: find.text(_kFreq))
                      .evaluate()
                      .isNotEmpty,
              '1 Frequency segment lists Test Freq JA',
            );
            await _shot(tester, '03-thin-frequency');
            await _setTypeSegment(tester, driver, DictionaryType.term);
            await _closeManager(tester);

            final _Lookup neko = await _lookup(tester, appModel, '猫', '1');
            _check(
              neko.dicts.isNotEmpty &&
                  neko.dicts.every(
                    (String d) => <String>{
                      _kGeneral,
                      _kGames,
                      _kZh,
                      _kLocalJa,
                    }.contains(d),
                  ),
              '1 猫 results are server-only dictionaries',
              neko.dicts,
            );
            _check(
              neko.kanjiDicts.contains(_kKanji),
              '1 猫 has a kanji card from KANJIDIC',
              neko.kanjiDicts,
            );
            _check(neko.hasFreqJa, '1 猫 carries a Test Freq JA frequency');
            final _Lookup hon = await _lookup(tester, appModel, '本', '1');
            _check(
              hon.dicts.contains(_kLocalJa) && hon.count('LOCAL: book') >= 1,
              '1 本 → Test Local JA (server)',
              hon.dicts,
            );
            final _Lookup neko2 = await _lookup(
              tester,
              appModel,
              '猫',
              '1-warm',
            );
            _log(
              '1 latency remote-only 猫 cold=${neko.ms}ms warm=${neko2.ms}ms',
            );
            _check(
              appModel.remoteDictionaryConfigAppliedByHost[hostId] == true,
              '1 host applied our dictionary config',
            );
          });
          expect(hostId, isNotEmpty, reason: '后续场景都需要已配对的 host');

          // ═══ 2. 配置 ═════════════════════════════════════════════════════
          int? gamesId;
          int? chineseId;
          await _scenario('2 profiles', () async {
            ProfileViewModel vm = _vm(container);
            await vm.loaded;
            defaultProfileId = await profileRepo.getActiveProfileId();
            _log('2 default profile id=$defaultProfileId');

            // 2a. 「Japanese – Games」：新建（成为激活配置），在管理页里关 General、
            // 把 Games 置顶，再关 ZH / KO。
            await _awaitPumping(tester, vm.createProfile(_kGamesProfile));
            gamesId = await _profileId(profileRepo, _kGamesProfile);
            _log('2 created $_kGamesProfile id=$gamesId');
            await appModel.reloadDictionariesFromDb();
            Finder page = await _openManager(tester, appModel);
            final Finder generalSwitch = find.byKey(
              ValueKey<String>('dict-row-switch-server:$hostId/$_kGeneral'),
            );
            final bool genFocused = await _focus(
              tester,
              driver,
              generalSwitch,
              'General switch',
            );
            if (genFocused) {
              await driver.activate();
              await _pumpUntil(
                tester,
                () => _remote(appModel, _kGeneral)?.hidden == true,
                timeout: const Duration(seconds: 5),
              );
            }
            _check(
              _remote(appModel, _kGeneral)?.hidden == true,
              '2 Games: General hidden via row switch (focus+Enter)',
            );
            final bool gamesDetail = await _openDetail(
              tester,
              driver,
              page,
              _kGames,
            );
            final Finder moveTop = find.descendant(
              of: find.byKey(
                ValueKey<String>('dict-detail-server:$hostId/$_kGames'),
              ),
              matching: find.byKey(
                const ValueKey<String>('dict-detail-move-top'),
              ),
            );
            _log(
              '2 Games detail open=$gamesDetail moveTop=${moveTop.evaluate().length}',
            );
            // 详情侧板的「置顶」图标钮 Tab 走不到（焦点只停在整行 Position 上，Enter 打开
            // 「移到第几位」对话框），改用行级键盘 Alt+↑：焦点回到 Games 行，按一次。
            bool moved = await _focusAndEnter(
              tester,
              driver,
              moveTop,
              'move-top Games',
            );
            final bool moveTopByTab = _lastFocusByTab;
            _check(
              moveTopByTab && _remoteOrderFirst(appModel, hostId) == _kGames,
              '2 Priority: Tab reaches move-top on a server row and Enter moves it first',
              'tab=$moveTopByTab first=${_remoteOrderFirst(appModel, hostId)}',
            );
            if (_remoteOrderFirst(appModel, hostId) != _kGames) {
              final Finder gamesTitle = find.descendant(
                of: page,
                matching: find.text(_kGames),
              );
              final bool rowFocused = await driver.focusWidget(
                gamesTitle.first,
                maxSteps: 160,
              );
              _log('2 Alt+Up fallback: Games row focused=$rowFocused');
              if (rowFocused) {
                await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
                await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
                await _pumpFor(tester, const Duration(seconds: 1));
              }
              moved = _remoteOrderFirst(appModel, hostId) == _kGames;
            }
            await _pumpFor(tester, const Duration(seconds: 1));
            final RemoteLookupDictionaryConfig? cfgAfterMove = appModel.dictRepo
                .filtersForHost(hostId);
            _log('2 config after move-top: ${_cfg(cfgAfterMove)}');
            _check(
              moved &&
                  (cfgAfterMove?.order.isNotEmpty ?? false) &&
                  cfgAfterMove!.order.first == _kGames,
              '2 Games: move-top puts Test Games JA first in the request order',
              cfgAfterMove?.order,
            );
            await _shot(tester, '04-games-detail-moved');

            // 「优先级」行的上移按钮：Tab 可达、Enter 上移一位（服务器行 Test Local JA）。
            final List<String> orderBeforeUp =
                appModel.dictRepo.filtersForHost(hostId)?.order ??
                const <String>[];
            final int upBefore = orderBeforeUp.indexOf(_kLocalJa);
            final bool localDetail = await _openDetail(
              tester,
              driver,
              page,
              _kLocalJa,
            );
            final Finder moveUp = find.descendant(
              of: find.byKey(
                ValueKey<String>('dict-detail-server:$hostId/$_kLocalJa'),
              ),
              matching: find.byKey(
                const ValueKey<String>('dict-detail-move-up'),
              ),
            );
            final bool upFocused = await _focus(
              tester,
              driver,
              moveUp,
              'move-up Local JA',
            );
            final bool upByTab = _lastFocusByTab;
            if (upFocused && upByTab) {
              await driver.activate();
              await _pumpFor(tester, const Duration(seconds: 1));
            }
            final List<String> orderAfterUp =
                appModel.dictRepo.filtersForHost(hostId)?.order ??
                const <String>[];
            final int upAfter = orderAfterUp.indexOf(_kLocalJa);
            _log(
              '2 move-up Local JA detail=$localDetail tab=$upByTab '
              'before=$orderBeforeUp after=$orderAfterUp',
            );
            _check(
              upByTab && upBefore > 0 && upAfter == upBefore - 1,
              '2 Priority: Tab reaches move-up on a server row (Test Local JA) and Enter moves it up one',
              'tab=$upByTab index $upBefore → $upAfter',
            );
            await _shot(tester, '04b-local-detail-moved-up');
            for (final String n in <String>[_kZh, _kKo]) {
              final RemoteDictionary? r = _remote(appModel, n);
              if (r != null) await appModel.setRemoteDictionaryHidden(r, true);
            }
            await _pumpFor(tester, const Duration(seconds: 1));
            _printManager(tester, '2-games-edit', page);
            await _shot(tester, '05-games-manager');
            await _closeManager(tester);

            // 2b. 「Chinese」：新建（快照 Games 当前设置后复制），只留 ZH。
            vm = _vm(container);
            await _awaitPumping(tester, vm.createProfile(_kChineseProfile));
            chineseId = await _profileId(profileRepo, _kChineseProfile);
            _log('2 created $_kChineseProfile id=$chineseId');
            await appModel.reloadDictionariesFromDb();
            for (final RemoteDictionary r in List<RemoteDictionary>.of(
              appModel.dictRepo.remoteDictionaries,
            )) {
              final bool hide = r.name != _kZh;
              if (r.hidden != hide) {
                await appModel.setRemoteDictionaryHidden(r, hide);
              }
            }
            _log(
              '2 chinese live rows: ${_remoteSummary(appModel.dictRepo.remoteDictionaries)}',
            );

            Future<void> switchTo(int id, String label) async {
              final ProfileViewModel v = _vm(container);
              await v.loaded;
              final Stopwatch sw = Stopwatch()..start();
              await _awaitPumping(tester, v.switchProfile(id));
              _log('2 switch → $label took ${sw.elapsedMilliseconds}ms');
              await _pumpFor(tester, const Duration(seconds: 1));
            }

            Future<void> verify(
              String label,
              String shotName, {
              required Set<String> hidden,
              String? first,
            }) async {
              _log(
                '2[$label] active=${await profileRepo.getActiveProfileId()} '
                'remote=${_remoteSummary(appModel.dictRepo.remoteDictionaries)}',
              );
              final RemoteLookupDictionaryConfig? cfg = appModel.dictRepo
                  .filtersForHost(hostId);
              _log('2[$label] request config: ${_cfg(cfg)}');
              final Set<String> actualHidden = <String>{
                for (final RemoteDictionary r
                    in appModel.dictRepo.remoteDictionaries)
                  if (r.hidden) r.name,
              };
              _check(
                actualHidden.containsAll(hidden) &&
                    hidden.containsAll(actualHidden),
                '2[$label] hidden server rows match the profile',
                'expected=$hidden actual=$actualHidden',
              );
              _check(
                cfg != null &&
                    cfg.excluded.containsAll(hidden) &&
                    hidden.containsAll(
                      cfg.excluded.where(
                        (String n) => _remote(appModel, n) != null,
                      ),
                    ),
                '2[$label] request excluded == hidden server rows',
                _cfg(cfg),
              );
              if (first != null) {
                _check(
                  cfg != null &&
                      cfg.order.isNotEmpty &&
                      cfg.order.first == first,
                  '2[$label] request order starts with $first',
                  cfg?.order,
                );
              }
              final Finder pg = await _openManager(tester, appModel);
              _printManager(tester, '2[$label]', pg);
              await _shot(tester, shotName);
              await _closeManager(tester);
              final _Lookup neko = await _lookup(tester, appModel, '猫', label);
              final _Lookup cidian = await _lookup(
                tester,
                appModel,
                '词典',
                label,
              );
              for (final String h in hidden) {
                _check(
                  !neko.dicts.contains(h) && !cidian.dicts.contains(h),
                  '2[$label] hidden "$h" absent from 猫 / 词典 results',
                );
              }
              if (first != null) {
                _check(
                  neko.dicts.isNotEmpty && neko.dicts.first == first,
                  '2[$label] 猫 first dictionary is $first',
                  neko.dicts,
                );
              }
              _check(
                appModel.remoteDictionaryConfigAppliedByHost[hostId] == true,
                '2[$label] remoteDictionaryConfigAppliedByHost[host] == true',
                appModel.remoteDictionaryConfigAppliedByHost,
              );
              _log(
                '2[$label] summary 猫=${neko.dicts} kanji=${neko.kanjiDicts} '
                '词典=${cidian.dicts}',
              );
            }

            await switchTo(gamesId!, _kGamesProfile);
            await verify(
              'games',
              '06-profile-games',
              hidden: <String>{_kGeneral, _kZh, _kKo},
              first: _kGames,
            );
            await switchTo(chineseId!, _kChineseProfile);
            final Set<String> chineseHidden = <String>{
              for (final RemoteDictionary r
                  in appModel.dictRepo.remoteDictionaries)
                if (r.name != _kZh) r.name,
            };
            await verify(
              'chinese',
              '07-profile-chinese',
              hidden: chineseHidden,
            );
            final _Lookup cn = await _lookup(
              tester,
              appModel,
              '词典',
              'chinese2',
            );
            _check(
              cn.dicts.contains(_kZh),
              '2[chinese] 词典 → Test ZH',
              cn.dicts,
            );
            await switchTo(gamesId!, '$_kGamesProfile (again)');
            await verify(
              'games-again',
              '08-profile-games-again',
              hidden: <String>{_kGeneral, _kZh, _kKo},
              first: _kGames,
            );

            // 2c. 绑定：zh → Chinese，video → Chinese。
            final ProfileViewModel bv = _vm(container);
            await bv.loaded;
            await bv.setLanguageBinding('zh', chineseId);
            final int zhOnly = await profileRepo.resolveProfileId(
              bookUid: null,
              languageTag: 'zh-Hant',
              mediaType: null,
            );
            _log(
              '2 observation: binding "zh" resolves zh-Hant content to profile '
              '$zhOnly (script kept by design, language_binding.dart)',
            );
            await bv.setLanguageBinding('zh', null);
            await bv.setLanguageBinding('zh-Hant', chineseId);
            await bv.setMediaTypeBinding(ProfileMediaKind.video, chineseId);
            final int r1 = await profileRepo.resolveProfileId(
              bookUid: null,
              languageTag: 'zh-Hant-TW',
              mediaType: ProfileMediaKind.epub,
            );
            final int r2 = await profileRepo.resolveProfileId(
              bookUid: null,
              languageTag: null,
              mediaType: ProfileMediaKind.video,
            );
            final int r3 = await profileRepo.resolveProfileId(
              bookUid: null,
              languageTag: 'ja',
              mediaType: ProfileMediaKind.epub,
            );
            _log(
              '2 bindings: languages=${await profileRepo.getAllLanguageBindings()} '
              'media=${await profileRepo.getAllMediaTypeBindings()} '
              'resolve(zh-Hant-TW,epub)=$r1 resolve(-,video)=$r2 resolve(ja,epub)=$r3',
            );
            _check(
              r1 == chineseId,
              '2 resolveProfileId(zh-Hant-TW, epub) → Chinese (binding zh-Hant)',
            );
            _check(r2 == chineseId, '2 resolveProfileId(video) → Chinese');
            _check(r3 == gamesId, '2 resolveProfileId(ja, epub) → active');

            // 2d. 作品级配置视图（激活 = Games，作品绑定 Chinese）下的本机查词。
            final Object owner = Object();
            final bool entered = await WorkProfileScope.instance.enterProfile(
              owner: owner,
              repository: profileRepo,
              resolveProfileId: () async => chineseId,
            );
            try {
              final RemoteLookupDictionaryConfig? viewCfg = WorkProfileScope
                  .instance
                  .lookupView
                  ?.filtersForHost(hostId);
              _log(
                '2 work-scope entered=$entered view=${WorkProfileScope.instance.lookupView?.profileId} '
                'viewConfig=${_cfg(viewCfg)}',
              );
              final _Lookup v1 = await _lookup(tester, appModel, '猫', 'view');
              final _Lookup v2 = await _lookup(tester, appModel, '词典', 'view');
              _check(
                v1.dicts.every((String d) => d == _kZh) &&
                    v2.dicts.contains(_kZh),
                '2 profileView(Chinese) lookup uses Chinese selection while Games is active',
                '猫=${v1.dicts} 词典=${v2.dicts}',
              );
            } finally {
              WorkProfileScope.instance.leave(owner);
            }
            final _Lookup back = await _lookup(
              tester,
              appModel,
              '猫',
              'games-after-view',
            );
            _check(
              back.dicts.isNotEmpty && back.dicts.first == _kGames,
              '2 after leaving work scope Games selection is back',
              back.dicts,
            );

            // 2e. 回到默认配置：服务器行全部重新可用。
            await switchTo(defaultProfileId!, 'default');
            await verify('default', '09-profile-default', hidden: <String>{});
          });
          // 场景 2 的配置留着到 finally 再删（中途失败也一定清掉）；后续场景用默认配置。

          // ═══ 3. 混合设备 ═════════════════════════════════════════════════
          await _scenario('3 mixed device', () async {
            await _importLocalDict(
              tester,
              appModel,
              'TestGeneralJA.zip',
              _kGeneral,
            );
            await _importLocalDict(tester, appModel, 'TestPushJA.zip', _kPush);
            Finder page = await _openManager(tester, appModel);
            _printManager(tester, '3', page);
            _check(
              _rowKind(tester, page, _kGeneral) == DictionarySourceKind.both,
              '3 Test General JA row = Both',
              _rowKind(tester, page, _kGeneral),
            );
            final List<String> rows3 = _managerRows(tester, page);
            _check(
              _rowIndex(rows3, _kGeneral) == 0 &&
                  rows3.first.startsWith('$_kGeneral => both'),
              '3 imported Test General JA keeps server position #1 (Both, not moved to the end)',
              rows3,
            );
            _log(
              '3 General order: remote=${_remote(appModel, _kGeneral)?.order} '
              'local=${_local(appModel, _kGeneral)?.order} '
              'request=${appModel.dictRepo.filtersForHost(hostId)?.order}',
            );
            _check(
              _rowKind(tester, page, _kPush) == DictionarySourceKind.thisDevice,
              '3 Test Push JA row = This device',
              _rowKind(tester, page, _kPush),
            );
            await _shot(tester, '10-mixed-manager');

            // 推送前先关掉本机 Test Push JA 的开关（焦点 + Enter），推送后服务器行应沿用
            // 本机的位置与开关。
            final bool pushSwitchFocused = await _focus(
              tester,
              driver,
              find.byKey(ValueKey<String>('dict-row-switch-$_kPush')),
              'Push local switch',
            );
            if (pushSwitchFocused) {
              await driver.activate();
              await _pumpFor(tester, const Duration(seconds: 1));
            }
            final bool? pushEnabledBefore = _switchValue(tester, _kPush);
            final List<String> rowsBeforePush = _managerRows(tester, page);
            final int pushIdxBefore = _rowIndex(rowsBeforePush, _kPush);
            _log(
              '3 before push: switch=$pushEnabledBefore index=$pushIdxBefore '
              'rows=$rowsBeforePush',
            );

            // 推送 Test Push JA。
            await _openDetail(tester, driver, page, _kPush);
            final Finder pushRow = find.byKey(
              ValueKey<String>('dict-detail-push-$hostId-$_kPush'),
            );
            _log(
              '3 push detail texts: ${_textsIn(tester, find.byKey(ValueKey<String>('dict-detail-$_kPush')))}',
            );
            _check(
              pushRow.evaluate().isNotEmpty &&
                  _textsIn(tester, pushRow).contains('Push to $hostName'),
              '3 Test Push JA detail offers "Push to $hostName"',
              _textsIn(tester, pushRow),
            );
            await _shot(tester, '11-push-detail');
            final Stopwatch pushSw = Stopwatch()..start();
            final bool pushFocused = await _focusAndEnter(
              tester,
              driver,
              pushRow,
              'push row',
            );
            final ValueNotifier<DictionaryDownloadPhase> phase =
                appModel.dictionaryDownloadController.phase;
            await _pumpUntil(
              tester,
              () => phase.value != DictionaryDownloadPhase.idle,
              timeout: const Duration(seconds: 5),
            );
            await _shot(tester, '12-push-progress');
            await _pumpUntil(
              tester,
              () => phase.value == DictionaryDownloadPhase.idle,
              timeout: const Duration(seconds: 120),
            );
            _log(
              '3 push took ${pushSw.elapsedMilliseconds}ms focused=$pushFocused',
            );
            await _pumpFor(tester, const Duration(seconds: 2));
            final List<Map<String, Object?>> afterPush = await _awaitPumping(
              tester,
              _adminList(),
            );
            _check(
              afterPush.any((Map<String, Object?> d) => d['name'] == _kPush),
              '3 server lists Test Push JA after push (admin GET)',
              afterPush.map((Map<String, Object?> d) => d['name']).toList(),
            );
            await _pumpUntil(
              tester,
              () => _rowKind(tester, page, _kPush) == DictionarySourceKind.both,
              timeout: const Duration(seconds: 10),
            );
            _check(
              _rowKind(tester, page, _kPush) == DictionarySourceKind.both,
              '3 Test Push JA row = Both after push',
              _rowKind(tester, page, _kPush),
            );
            final List<String> rowsAfterPush = _managerRows(tester, page);
            final int pushIdxAfter = _rowIndex(rowsAfterPush, _kPush);
            final RemoteDictionary? pushedRemote = _remote(appModel, _kPush);
            _log(
              '3 after push: index=$pushIdxAfter rows=$rowsAfterPush '
              'remote=${pushedRemote == null ? 'absent' : _remoteSummary(<RemoteDictionary>[pushedRemote])} '
              'request=${appModel.dictRepo.filtersForHost(hostId)?.order}',
            );
            _check(
              pushIdxBefore >= 0 && pushIdxAfter == pushIdxBefore,
              '3 pushed Test Push JA keeps the local row position',
              '$pushIdxBefore → $pushIdxAfter',
            );
            _check(
              pushEnabledBefore == false && pushedRemote?.hidden == true,
              '3 pushed server row takes the local switch state (off → hidden)',
              'localEnabled=$pushEnabledBefore remoteHidden=${pushedRemote?.hidden}',
            );
            await _shot(tester, '13-push-done');
            // 恢复开关（焦点 + Enter），服务器那份若仍关着也打开。
            if (await _focus(
              tester,
              driver,
              find.byKey(ValueKey<String>('dict-row-switch-$_kPush')),
              'Push switch restore',
            )) {
              await driver.activate();
              await _pumpFor(tester, const Duration(seconds: 1));
            }
            final RemoteDictionary? pr = _remote(appModel, _kPush);
            _log(
              '3 after re-enable: switch=${_switchValue(tester, _kPush)} '
              'remoteHidden=${pr?.hidden}',
            );
            if (pr != null && pr.hidden) {
              await appModel.setRemoteDictionaryHidden(pr, false);
              await _pumpFor(tester, const Duration(seconds: 1));
            }

            // 下载 Test KO。
            page = find.byType(DictionaryDialogPage);
            await _openDetail(tester, driver, page, _kKo);
            final Finder dl = find.byKey(
              ValueKey<String>('dict-detail-download-server:$hostId/$_kKo'),
            );
            _check(
              dl.evaluate().isNotEmpty &&
                  _textsIn(tester, dl).contains('Download to this device'),
              '3 Test KO detail offers "Download to this device"',
              _textsIn(tester, dl),
            );
            await _shot(tester, '14-download-detail');
            final Stopwatch dlSw = Stopwatch()..start();
            await _focusAndEnter(tester, driver, dl, 'download KO');
            await _pumpUntil(
              tester,
              () => phase.value != DictionaryDownloadPhase.idle,
              timeout: const Duration(seconds: 5),
            );
            await _pumpUntil(
              tester,
              () => phase.value == DictionaryDownloadPhase.idle,
              timeout: const Duration(seconds: 120),
            );
            await _pumpUntil(
              tester,
              () => _local(appModel, _kKo) != null,
              timeout: const Duration(seconds: 15),
            );
            _log('3 download took ${dlSw.elapsedMilliseconds}ms');
            final bool koDir = Directory(
              p.join(appModel.dictionaryResourceDirectory.path, _kKo),
            ).existsSync();
            _check(
              _local(appModel, _kKo) != null && koDir,
              '3 Test KO downloaded (dictRepo + directory)',
              'inRepo=${_local(appModel, _kKo) != null} dir=$koDir',
            );
            await _pumpUntil(
              tester,
              () => _rowKind(tester, page, _kKo) == DictionarySourceKind.both,
              timeout: const Duration(seconds: 10),
            );
            _printManager(tester, '3-after-transfers', page);
            _check(
              _rowKind(tester, page, _kKo) == DictionarySourceKind.both,
              '3 Test KO row = Both after download',
              _rowKind(tester, page, _kKo),
            );
            await _shot(tester, '15-download-done');
            await _closeManager(tester);

            final _Lookup neko = await _lookup(tester, appModel, '猫', '3');
            _check(
              neko.count('PUSH: cat') == 1,
              '3 猫 shows PUSH: cat exactly once (local + server copy deduped)',
              neko.count('PUSH: cat'),
            );
            _check(
              neko.count('GENERAL: cat') == 1,
              '3 猫 shows GENERAL: cat exactly once',
              neko.count('GENERAL: cat'),
            );
            final _Lookup neko2 = await _lookup(
              tester,
              appModel,
              '猫',
              '3-warm',
            );
            _log('3 latency merged 猫 cold=${neko.ms}ms warm=${neko2.ms}ms');
          });

          // ═══ 4. 服务器端变化 ═════════════════════════════════════════════
          await _scenario('4 server changes propagate', () async {
            final _Http a = await _awaitPumping(
              tester,
              _admin(
                'PUT',
                _dictPath(_kGames),
                json: <String, Object?>{'defaultEnabled': false},
              ),
            );
            final _Http b = await _awaitPumping(
              tester,
              _admin(
                'PUT',
                _dictPath(_kKo),
                json: <String, Object?>{'languageOverride': 'ko-KR'},
              ),
            );
            final _Http c = await _awaitPumping(
              tester,
              _admin('DELETE', _dictPath(_kPush)),
            );
            _log(
              '4 admin PUT games=${a.status} PUT ko=${b.status} DELETE push=${c.status}',
            );
            final Object? diffs = await _awaitPumping(
              tester,
              appModel.remoteDictionaryCatalog!.refresh(),
            );
            _log('4 refresh diffs: $diffs');
            await _pumpFor(tester, const Duration(seconds: 1));
            final List<RemoteDictionaryMetaRow> rows = await _dbRows(appModel);
            _log('4 db rows: ${_dbSummary(rows)}');
            _check(
              _remote(appModel, _kGames)?.hidden == false,
              '4 Test Games JA stays enabled (host default only affects new rows)',
            );
            final RemoteDictionaryMetaRow? koRow = rows
                .where((RemoteDictionaryMetaRow r) => r.name == _kKo)
                .firstOrNull;
            _check(
              koRow?.sourceLanguage == 'ko-KR',
              '4 Test KO catalog language follows server override (ko-KR)',
              koRow?.sourceLanguage,
            );
            final RemoteDictionaryMetaRow? pushRow = rows
                .where((RemoteDictionaryMetaRow r) => r.name == _kPush)
                .firstOrNull;
            _check(
              pushRow?.missingSince != null,
              '4 Test Push JA catalog row marked missing',
              pushRow == null ? 'row gone' : 'missing=${pushRow.missingSince}',
            );
            Finder page = await _openManager(tester, appModel);
            _printManager(tester, '4', page);
            _check(
              _rowKind(tester, page, _kPush) == DictionarySourceKind.thisDevice,
              '4 Test Push JA row = This device (local copy, server copy gone)',
              _rowKind(tester, page, _kPush),
            );
            await _openDetail(tester, driver, page, _kPush);
            final Finder pushAgain = find.byKey(
              ValueKey<String>('dict-detail-push-$hostId-$_kPush'),
            );
            _check(
              pushAgain.evaluate().isNotEmpty,
              '4 local-only Test Push JA (server copy deleted) offers Push again',
              _textsIn(tester, pushAgain),
            );
            final Finder koTitle = find.descendant(
              of: page,
              matching: find.text(_kKo),
            );
            if (koTitle.evaluate().isNotEmpty) {
              try {
                await tester.ensureVisible(koTitle.first);
                await tester.pump(const Duration(milliseconds: 300));
              } catch (_) {}
            }
            final List<String> pageTexts = _textsIn(tester, page);
            final List<String> koHeaders = pageTexts
                .where((String s) => s.contains('ko'))
                .toList();
            // KO 此刻是「两者」行，按本机那份的语言（ko）分组；服务器覆盖只管服务器那份。
            _log('4 texts mentioning ko (KO is a Both row here): $koHeaders');
            await _openDetail(tester, driver, page, _kKo);
            _log(
              '4 KO detail texts: ${_textsIn(tester, find.byKey(ValueKey<String>('dict-detail-$_kKo')))}',
            );
            _log('4 KO row chip: ${_rowKind(tester, page, _kKo)}');
            await _shot(tester, '16-server-changes');
            await _closeManager(tester);

            // 删本机 Test Push JA：不应留下幽灵行。
            final Dictionary? localPush = _local(appModel, _kPush);
            if (localPush != null) {
              await _awaitPumping(tester, appModel.deleteDictionary(localPush));
            }
            // 也删本机 Test KO：只剩服务器那份（语言被管理员覆盖成 ko-KR）。
            final Dictionary? localKo = _local(appModel, _kKo);
            if (localKo != null) {
              await _awaitPumping(tester, appModel.deleteDictionary(localKo));
            }
            await _pumpFor(tester, const Duration(seconds: 1));
            page = await _openManager(tester, appModel);
            _printManager(tester, '4-after-local-delete', page);
            final List<String> pushRows = _managerRows(
              tester,
              page,
            ).where((String r) => r.contains(_kPush)).toList();
            _log('4 Test Push JA rows after local delete: $pushRows');
            _check(
              pushRows.isEmpty,
              '4 no ghost Test Push JA row after deleting the local copy',
              pushRows,
            );
            final List<RemoteDictionaryMetaRow> afterDel = await _dbRows(
              appModel,
            );
            _check(
              afterDel.every((RemoteDictionaryMetaRow r) => r.name != _kPush),
              '4 missing Test Push JA catalog row forgotten (DB) after deleting the local copy',
              _dbSummary(afterDel),
            );
            final Finder koTitle2 = find.descendant(
              of: page,
              matching: find.text(_kKo),
            );
            if (koTitle2.evaluate().isNotEmpty) {
              try {
                await tester.ensureVisible(koTitle2.first);
                await tester.pump(const Duration(milliseconds: 300));
              } catch (_) {}
            }
            final List<String> pageTexts2 = _textsIn(tester, page);
            final List<String> koHeaders2 = pageTexts2
                .where((String s) => s.contains('ko'))
                .toList();
            _log(
              '4 KO server-only row kind=${_rowKind(tester, page, 'server:$hostId/$_kKo')} '
              'texts mentioning ko: $koHeaders2',
            );
            _check(
              _rowKind(tester, page, 'server:$hostId/$_kKo') ==
                      DictionarySourceKind.server &&
                  pageTexts2.any((String s) => s.contains('한국어 (ko-KR)')) &&
                  !pageTexts2.any((String s) => s.startsWith('ko-KR')),
              '4 server-only KO group header reads "한국어 (ko-KR)" after admin override (not raw)',
              koHeaders2,
            );
            await _shot(tester, '17-after-local-delete');
            await _closeManager(tester);

            // 经 WebUI 导入端点重新放回服务器。
            final List<int> bytes = File(
              p.join(_kScratch, 'dicts', 'TestPushJA.zip'),
            ).readAsBytesSync();
            final _Http imp = await _awaitPumping(
              tester,
              _admin(
                'POST',
                '/api/admin/dictionaries/import?filename=TestPushJA.zip',
                bytes: bytes,
              ),
            );
            _log('4 admin import status=${imp.status} body=${imp.body}');
            final Object? diffs2 = await _awaitPumping(
              tester,
              appModel.remoteDictionaryCatalog!.refresh(),
            );
            _log('4 refresh after re-import: $diffs2');
            await _pumpFor(tester, const Duration(seconds: 1));
            final RemoteDictionary? back = _remote(appModel, _kPush);
            _check(
              back != null && !back.isMissing && !back.hidden,
              '4 re-imported Test Push JA is back as an enabled server row',
              back == null
                  ? 'absent'
                  : _remoteSummary(<RemoteDictionary>[back]),
            );
            page = await _openManager(tester, appModel);
            _check(
              _rowKind(tester, page, 'server:$hostId/$_kPush') ==
                  DictionarySourceKind.server,
              '4 Test Push JA row chip is Server again',
              _rowKind(tester, page, 'server:$hostId/$_kPush'),
            );
            _printManager(tester, '4-reimported', page);
            await _shot(tester, '18-reimported');
            await _closeManager(tester);
          });

          // ═══ 5. 离线 ═════════════════════════════════════════════════════
          await _scenario('5 offline', () async {
            final List<FushiClientUrl> paired = await SyncRepository(
              appModel.database,
            ).getFushiClientUrls();
            _log(
              '5 paired addresses for the host: ${paired.where((FushiClientUrl u) => remoteDictionaryHostIdOf(u) == hostId).map((FushiClientUrl u) => '${u.url}(enabled=${u.enabled},lookup=${u.lookupEnabled},learned=${u.learned})').toList()}',
            );
            bool? reachable() =>
                appModel.remoteDictionaryHostReachability[hostId]?.reachable;

            // 5a. 停服务器 → 目录刷新（判死）→ 首次查词应直接跳过远端。
            await _stopServer(tester);
            serverStopped = true;
            final Stopwatch rsw = Stopwatch()..start();
            Object? diffs;
            try {
              diffs = await _awaitPumping(
                tester,
                appModel.remoteDictionaryCatalog!.refresh(),
              );
            } catch (e) {
              diffs = 'threw $e';
            }
            _log('5 offline refresh ${rsw.elapsedMilliseconds}ms diffs=$diffs');
            final int remoteCount = appModel.dictRepo.remoteDictionaries.length;
            _check(
              remoteCount >= 7,
              '5 server rows stay while offline',
              remoteCount,
            );
            _log(
              '5 reachability=${reachable()} '
              'failingSince=${appModel.remoteDictionaryHostReachability[hostId]?.failingSince} '
              'cooldown=${appModel.isRemoteDictionaryInFailureCooldown}',
            );
            final Finder page = await _openManager(tester, appModel);
            _printManager(tester, '5', page);
            final List<String> card = _textsIn(
              tester,
              find.byKey(ValueKey<String>('dict-server-source-$hostId')),
            );
            _check(
              card.any(
                (String s) =>
                    s.toLowerCase().contains('unreachable') ||
                    s.toLowerCase().contains('offline') ||
                    s.toLowerCase().contains("can't reach") ||
                    s.toLowerCase().contains('last seen'),
              ),
              '5 source card shows unreachable / last seen',
              card,
            );
            final (String st5, bool fit5) = _statusLine(tester, hostId);
            _check(
              st5.startsWith('Unreachable · ') && fit5,
              '5 offline status uses relative time and is not cut off',
              'text="$st5" fits=$fit5',
            );
            await _shot(tester, '19-offline-strip');

            // 离线时关一条服务器行（焦点 + Enter）。
            final RemoteDictionary? games = _remote(appModel, _kGames);
            final Finder sw = find.byKey(
              ValueKey<String>('dict-row-switch-server:$hostId/$_kGames'),
            );
            final bool f = await _focus(
              tester,
              driver,
              sw,
              'Games switch offline',
            );
            if (f) await driver.activate();
            await _pumpFor(tester, const Duration(seconds: 1));
            final RemoteDictionaryMetaRow? gamesDb = (await _dbRows(appModel))
                .where((RemoteDictionaryMetaRow r) => r.name == _kGames)
                .firstOrNull;
            _check(
              games != null &&
                  gamesDb != null &&
                  gamesDb.hidden != games.hidden,
              '5 toggling a server row offline persists to DB',
              'before=${games?.hidden} db=${gamesDb?.hidden}',
            );
            await _shot(tester, '20-offline-toggled');
            await _closeManager(tester);

            final _Lookup o1 = await _lookup(
              tester,
              appModel,
              '猫',
              '5-offline-1',
            );
            final _Lookup o2 = await _lookup(
              tester,
              appModel,
              '猫',
              '5-offline-2',
            );
            _log(
              '5 latency offline 猫 first=${o1.ms}ms second=${o2.ms}ms '
              'cooldown=${appModel.isRemoteDictionaryInFailureCooldown}',
            );
            _check(
              o1.dicts.isNotEmpty &&
                  o1.dicts.every((String d) => _local(appModel, d) != null),
              '5 offline 猫 returns local dictionaries only',
              o1.dicts,
            );
            _check(
              o1.ms < 1500,
              '5 first offline lookup after the failed refresh is fast (<1.5s)',
              '${o1.ms}ms',
            );

            // 5b. 恢复 → 目录刷新成功 → 下一次查词立刻合并。
            bool up = await _startServer(tester);
            serverStopped = !up;
            _check(up, '5 server restarted');
            final Stopwatch r2 = Stopwatch()..start();
            final Object? diffs2 = await _awaitPumping(
              tester,
              appModel.remoteDictionaryCatalog!.refresh(),
            );
            _log(
              '5 online refresh ${r2.elapsedMilliseconds}ms diffs=$diffs2 '
              'reachable=${reachable()}',
            );
            _check(
              reachable() == true,
              '5 host reachable again after restart + refresh',
            );
            final Finder page2 = await _openManager(tester, appModel);
            _printManager(tester, '5-online', page2);
            await _shot(tester, '21-online-again');
            await _closeManager(tester);
            final Stopwatch sinceRefresh = Stopwatch()..start();
            final _Lookup b1 = await _lookup(
              tester,
              appModel,
              '猫',
              '5-back-immediate',
            );
            final bool mergedImmediately = b1.dicts.any(
              (String d) => _local(appModel, d) == null,
            );
            _log(
              '5 first lookup after successful refresh: ${b1.ms}ms '
              '(${sinceRefresh.elapsedMilliseconds}ms after refresh) merged=$mergedImmediately',
            );
            _check(
              mergedImmediately,
              '5 first lookup right after a successful catalog refresh merges server results again',
              'ms=${b1.ms} cooldown=${appModel.isRemoteDictionaryInFailureCooldown} dicts=${b1.dicts}',
            );

            // 5c. 后台再探测：停服务器、不手动刷新；一次失败查词后卡片自己翻成连不上；
            // 重启服务器后不做任何操作，卡片自己翻回在线。
            await _stopServer(tester);
            serverStopped = true;
            final Stopwatch failSw = Stopwatch()..start();
            final _Lookup f1 = await _lookup(
              tester,
              appModel,
              '猫',
              '5-bg-fail-1',
            );
            final Stopwatch afterFail = Stopwatch()..start();
            _log(
              '5 bg: first failed lookup ${f1.ms}ms dicts=${f1.dicts} '
              'reachable=${reachable()}',
            );
            final Finder page3 = await _openManager(tester, appModel);
            final bool wentDown = await _pumpUntil(
              tester,
              () =>
                  reachable() == false &&
                  _statusLine(tester, hostId).$1.startsWith('Unreachable'),
              timeout: const Duration(seconds: 60),
            );
            final int downMs = afterFail.elapsedMilliseconds;
            _log(
              '5 bg: strip flipped to unreachable=$wentDown after ${downMs}ms '
              '(${failSw.elapsedMilliseconds}ms since lookup start) '
              'status="${_statusLine(tester, hostId).$1}"',
            );
            _check(
              wentDown && downMs <= 50000,
              '5 strip flips to unreachable on its own within ~50s of the first failed lookup',
              '${downMs}ms',
            );
            _printManager(tester, '5-bg-down', page3);
            await _shot(tester, '21b-bg-unreachable');

            up = await _startServer(tester);
            serverStopped = !up;
            final Stopwatch afterUp = Stopwatch()..start();
            final bool cameBack = await _pumpUntil(
              tester,
              () =>
                  reachable() == true &&
                  _statusLine(tester, hostId).$1 == 'Online',
              timeout: const Duration(seconds: 90),
            );
            final int backMs = afterUp.elapsedMilliseconds;
            _log(
              '5 bg: strip flipped back online=$cameBack ${backMs}ms after the '
              'server port opened status="${_statusLine(tester, hostId).$1}"',
            );
            _check(
              up && cameBack && backMs <= 50000,
              '5 strip flips back online on its own within ~50s of the server restart',
              '${backMs}ms',
            );
            _printManager(tester, '5-bg-up', page3);
            await _shot(tester, '21c-bg-online');
            await _closeManager(tester);

            final _Lookup b2 = await _lookup(tester, appModel, '猫', '5-back');
            _check(
              b2.dicts.any((String d) => _local(appModel, d) == null),
              '5 lookup merges server results after the background re-probe',
              '${b2.ms}ms ${b2.dicts}',
            );
          });

          // ═══ 6. 解除配对 ═════════════════════════════════════════════════
          await _scenario('6 unpair', () async {
            final Set<String> hiddenBefore = <String>{
              for (final RemoteDictionary r
                  in appModel.dictRepo.remoteDictionaries)
                if (r.hidden) r.name,
            };
            final int dbBefore = (await _dbRows(appModel)).length;
            _log('6 before unpair: hidden=$hiddenBefore dbRows=$dbBefore');
            await _unpair(appModel, hostId);
            await _pumpUntil(
              tester,
              () => appModel.dictRepo.remoteDictionaries.isEmpty,
              timeout: const Duration(seconds: 10),
            );
            final int dbKept = (await _dbRows(appModel)).length;
            Finder page = await _openManager(tester, appModel);
            _printManager(tester, '6-unpaired-keep', page);
            final List<String> serverRows = _managerRows(tester, page)
                .where(
                  (String r) => r.startsWith('server:') || r.contains('Server'),
                )
                .toList();
            _check(
              serverRows.isEmpty,
              '6 unpair (keep): server rows disappear from the manager',
              serverRows,
            );
            _check(
              dbKept == dbBefore,
              '6 unpair (keep): catalog rows remain in DB',
              'before=$dbBefore after=$dbKept',
            );
            _check(
              !appModel.remoteLookupEnabled,
              '6 unpaired: remote lookup derived off',
            );
            await _shot(tester, '22-unpaired-keep');
            await _closeManager(tester);
            final _Lookup u = await _lookup(
              tester,
              appModel,
              '猫',
              '6-unpaired',
            );
            _check(
              u.dicts.every((String d) => _local(appModel, d) != null),
              '6 unpaired lookup is local-only',
              u.dicts,
            );

            await _pair(tester, appModel);
            await _pumpUntil(
              tester,
              () => appModel.dictRepo.remoteDictionaries.length >= 7,
              timeout: const Duration(seconds: 30),
            );
            final Set<String> hiddenAfter = <String>{
              for (final RemoteDictionary r
                  in appModel.dictRepo.remoteDictionaries)
                if (r.hidden) r.name,
            };
            _check(
              hiddenAfter.length == hiddenBefore.length &&
                  hiddenAfter.containsAll(hiddenBefore),
              '6 re-pair restores the hidden choices',
              'before=$hiddenBefore after=$hiddenAfter',
            );
            page = await _openManager(tester, appModel);
            _printManager(tester, '6-repaired', page);
            await _shot(tester, '23-repaired');
            await _closeManager(tester);

            await _unpair(appModel, hostId);
            await appModel.forgetRemoteDictionaryHost(hostId);
            await _pumpFor(tester, const Duration(seconds: 1));
            final List<RemoteDictionaryMetaRow> left = (await _dbRows(appModel))
                .where((RemoteDictionaryMetaRow r) => r.hostId == hostId)
                .toList();
            _check(
              left.isEmpty,
              '6 unpair (forget): catalog rows for the host are gone',
              left.length,
            );
            page = await _openManager(tester, appModel);
            _printManager(tester, '6-forgotten', page);
            await _shot(tester, '24-unpaired-forget');
            await _closeManager(tester);
          });

          // ═══ 7. 第二台设备并发 ═══════════════════════════════════════════
          await _scenario('7 second device concurrently', () async {
            if (await _pairedUrl(appModel, hostId) == null) {
              await _pair(tester, appModel);
            }
            await _pumpUntil(
              tester,
              () => appModel.dictRepo.remoteDictionaries.length >= 7,
              timeout: const Duration(seconds: 30),
            );
            _log(
              '7 fresh rows: ${_remoteSummary(appModel.dictRepo.remoteDictionaries)}',
            );
            _check(
              _remote(appModel, _kGames)?.hidden == true,
              '7 fresh catalog row follows host default (Games defaultEnabled=false → hidden)',
              _remote(appModel, _kGames)?.hidden,
            );
            final RemoteDictionary? gen = _remote(appModel, _kGeneral);
            if (gen != null) {
              await appModel.setRemoteDictionaryHidden(gen, true);
            }
            final FushiClientUrl url = (await _pairedUrl(appModel, hostId))!;
            final String token =
                url.token ??
                await SyncRepository(appModel.database).getFushiClientToken() ??
                '';
            _log(
              '7 peer token=${token.isEmpty ? '(none)' : '${token.substring(0, 3)}…(${token.length})'} url=${url.url}',
            );
            _log(
              '7 app config: ${_cfg(appModel.dictRepo.filtersForHost(hostId))}',
            );
            final Map<String, Object?> peerBody = <String, Object?>{
              'term': '猫',
              'wildcards': false,
              'maximumTerms': 20,
              'language': 'ja',
              'dictionaries': <String, Object?>{
                'excluded': <String>[_kLocalJa, _kZh],
                'order': <String>[_kGeneral],
              },
            };
            int mismatches = 0;
            for (int round = 0; round < 4; round++) {
              final Future<_Lookup> appF = _lookup(
                tester,
                appModel,
                '猫',
                '7-app-$round',
              );
              final Future<(bool?, List<String>, List<String>)> peerF =
                  _peerLookup(url, token, peerBody);
              final _Lookup app = await appF;
              final (bool?, List<String>, List<String>) peer =
                  await _awaitPumping(tester, peerF);
              _log(
                '7 round $round app=${app.dicts} peer applied=${peer.$1} peer=${peer.$2}',
              );
              final bool appOk =
                  !app.dicts.contains(_kGames) &&
                      !app.dicts.contains(_kGeneral) ||
                  // 本机也装着 General：本机那份照样参与（只关了服务器那份）。
                  (!app.dicts.contains(_kGames) &&
                      _local(appModel, _kGeneral) != null);
              final bool peerOk =
                  peer.$1 == true &&
                  peer.$2.isNotEmpty &&
                  peer.$2.first == _kGeneral &&
                  !peer.$2.contains(_kLocalJa) &&
                  !peer.$2.contains(_kZh) &&
                  peer.$2.contains(_kGames);
              if (!appOk || !peerOk) mismatches++;
              _check(
                appOk,
                '7 round $round app result honours app selection',
                app.dicts,
              );
              _check(
                peerOk,
                '7 round $round peer result honours peer selection',
                peer.$2,
              );
            }
            _log('7 mismatches=$mismatches');
            if (gen != null) {
              final RemoteDictionary? g = _remote(appModel, _kGeneral);
              if (g != null) await appModel.setRemoteDictionaryHidden(g, false);
            }
          });
        } finally {
          _log('──── restore ────');
          try {
            if (serverStopped || !await _serverPortOpen()) {
              await _startServer(tester);
            }
          } catch (e) {
            _log('restore: server restart failed: $e');
          }
          Future<void> safe(String label, Future<void> Function() f) async {
            try {
              await f();
              _log('restore: $label ok');
            } catch (e) {
              _log('restore: $label failed: $e');
            }
          }

          await safe('admin Games defaultEnabled=true', () async {
            final _Http r = await _admin(
              'PUT',
              _dictPath(_kGames),
              json: <String, Object?>{'defaultEnabled': true},
            );
            _log('restore: PUT games ${r.status}');
          });
          await safe('admin KO languageOverride=null (original)', () async {
            final _Http r = await _admin(
              'PUT',
              _dictPath(_kKo),
              json: <String, Object?>{'languageOverride': null},
            );
            _log('restore: PUT ko ${r.status}');
          });
          await safe('admin delete Test Push JA', () async {
            final _Http r = await _admin('DELETE', _dictPath(_kPush));
            _log('restore: DELETE push ${r.status}');
          });
          await safe('bindings cleared', () async {
            final ProfileViewModel vm = _vm(container);
            await vm.loaded;
            await vm.setLanguageBinding('zh', null);
            await vm.setLanguageBinding('zh-Hant', null);
            await vm.setMediaTypeBinding(ProfileMediaKind.video, null);
          });
          await safe('profiles deleted', () async {
            final int? def = defaultProfileId;
            if (def != null && await profileRepo.getActiveProfileId() != def) {
              await _vm(container).switchProfile(def);
            }
            for (final String n in <String>[_kGamesProfile, _kChineseProfile]) {
              final int? id = await _profileId(profileRepo, n);
              if (id != null) await _vm(container).deleteProfile(id);
            }
            _log(
              'restore: profiles now ${(await profileRepo.getAllProfiles()).map((ProfileRow r) => r.name).toList()}',
            );
          });
          await safe('local test dictionaries removed', () async {
            for (final String n in <String>[_kGeneral, _kPush, _kKo]) {
              final Dictionary? d = _local(appModel, n);
              if (d != null) await appModel.deleteDictionary(d);
            }
          });
          try {
            final List<Map<String, Object?>> l = await _adminList();
            _log(
              'restore: server dictionaries now ${l.map((Map<String, Object?> d) => '${d['name']}(default=${d['defaultEnabled']},lang=${d['sourceLanguage']},override=${d['languageOverride']})').toList()}',
            );
          } catch (e) {
            _log('restore: admin list failed: $e');
          }
          await appModel.setExperimentalFocusNavigationEnabled(false);
        }

        _log('════ RESULT ════');
        _log('scenario errors (${_scenarioErrors.length}): $_scenarioErrors');
        _log('failed checks (${_fails.length}):');
        for (final String f in _fails) {
          _log('  FAIL $f');
        }
        expect(_scenarioErrors, isEmpty, reason: '场景执行异常');
        expect(_fails, isEmpty, reason: '产品检查失败（见 [scenario] CHECK FAIL 行）');
      },
    );
  });
}
