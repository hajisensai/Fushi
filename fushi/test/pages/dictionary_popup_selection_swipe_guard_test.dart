import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/reader/popup_swipe_close_script.dart';

import '../widgets/widget_test_helpers.dart';

/// BUG-4925：Android 查词弹窗里长按选字后拖选区柄调整范围，那一划横向位移过阈值，
/// 抬手就被正文横滑检测器当成滑动关闭，弹窗直接关掉。
///
/// 修复后的契约（本文件逐条钉住）：
///   ① 这一划期间 WebView 选区变成新的非空选区（[PopupSelectionChangedNotification]
///      从 WebView 子树冒泡上来）→ 抬手不关；
///   ② 划之前就留着的旧选区不挡滑关，作废标记不漏到下一划；
///   ③ 选区上报脚本只在「新的非空选区」时上报，折叠不报——JS 经 node 真跑；
///   ④ 下拉关闭脚本同一判据：这一拉改动了选区就不上报；
///   ⑤ 应用内弹窗注入上报脚本，并把 `popupSelectionChanged` 转成通知冒泡。
void main() {
  const Key bodyAnchorKey = Key('bug4925-body-anchor');
  final ReaderFushiSource source = ReaderFushiSource.instance;

  Widget popup({required VoidCallback onDismiss}) {
    return buildTestApp(
      Center(
        child: SizedBox(
          width: 320,
          height: 360,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            enableSwipeToClose: source.enableSwipeToClose,
            enableTouchSwipeToClose: source.enableTouchSwipeToClose,
            onClose: () {},
            headerWidget: const SizedBox(
              height: 44,
              width: double.infinity,
              child: Center(child: Text('HEADER')),
            ),
            overlayWidget: const Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(key: bodyAnchorKey, height: 120, width: 200),
            ),
            onDismiss: onDismiss,
            onTextSelected:
                (String text, Rect rect, List<Object?> _, String __) {},
            onLinkClick: (String query, Rect rect) {},
            onMineEntry: (Map<String, String> fields) async =>
                const MinePopupResult(),
            onDuplicateCheck: (String expression, String reading) async =>
                false,
          ),
        ),
      ),
    );
  }

  /// 模拟 WebView 收到 `popupSelectionChanged` 后在自身 context 上冒泡的通知：
  /// 从正文子树（WebView 所在位置）派发。
  void reportSelectionChanged(WidgetTester tester) {
    const PopupSelectionChangedNotification().dispatch(
      tester.element(find.byKey(bodyAnchorKey)),
    );
  }

  /// 正文单指横拖 240px；[midway] 在拖到一半时执行（模拟这一划里选区变化）。
  Future<void> swipeBody(WidgetTester tester, {void Function()? midway}) async {
    final Offset start = tester.getCenter(find.byKey(bodyAnchorKey));
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.touch,
    );
    const int steps = 12;
    for (int i = 0; i < steps; i++) {
      await gesture.moveBy(const Offset(20, 0));
      if (i == steps ~/ 2) midway?.call();
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  group('正文横滑检测器 × WebView 选区', () {
    setUp(() => source.deletePreference(key: 'enable_swipe_to_close'));

    testWidgets('对照：选区没变的正文横拖照常关', (WidgetTester tester) async {
      int dismissed = 0;
      await tester.pumpWidget(popup(onDismiss: () => dismissed++));
      await swipeBody(tester);
      expect(dismissed, 1);
    });

    testWidgets('这一划里选区变了（拖选区柄）→ 不关', (WidgetTester tester) async {
      int dismissed = 0;
      await tester.pumpWidget(popup(onDismiss: () => dismissed++));
      await swipeBody(tester, midway: () => reportSelectionChanged(tester));
      expect(dismissed, 0);
    });

    testWidgets('划之前留下的旧选区不挡滑关，作废标记不漏到下一划', (WidgetTester tester) async {
      int dismissed = 0;
      await tester.pumpWidget(popup(onDismiss: () => dismissed++));
      // 两划之间（没有按下的指针）的选区变化：不影响下一划。
      reportSelectionChanged(tester);
      await swipeBody(tester);
      expect(dismissed, 1);

      // 被作废的一划之后，下一划恢复正常。
      await swipeBody(tester, midway: () => reportSelectionChanged(tester));
      expect(dismissed, 1);
      await swipeBody(tester);
      expect(dismissed, 2);
    });
  });

  group('wiring', () {
    String read(String path) => File(path).readAsStringSync();

    test('应用内弹窗注入选区上报脚本并把它转成通知冒泡', () {
      final String src = read(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      );
      expect(
        src,
        contains('_selectionChangeReportJs = kPopupSelectionChangeReportJs'),
      );
      expect(
        src,
        contains('evaluateJavascript(source: _selectionChangeReportJs)'),
      );
      final int handler = src.indexOf("handlerName: 'popupSelectionChanged'");
      expect(handler, isNonNegative);
      expect(
        src.substring(handler, handler + 600),
        contains('const PopupSelectionChangedNotification().dispatch(context)'),
      );
    });
  });

  test('选区上报 / 下拉关闭脚本的选区判据经 node 真跑', () async {
    final String? node = _resolveNode();
    if (node == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final Directory dir = await Directory.systemTemp.createTemp(
      'fushi_selection_swipe_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final File harness = File('${dir.path}/harness.js')
      ..writeAsStringSync(_harness());
    final ProcessResult result = await Process.run(node, <String>[
      harness.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final Map<String, Object?> out =
        (jsonDecode((result.stdout as String).trim()) as Map)
            .cast<String, Object?>();
    final List<Object?> selected = <Object?>[
      <Object?>['popupSelectionChanged'],
    ];
    expect(out['newSelection'], selected);
    expect(out['sameSelectionAgain'], isEmpty);
    expect(out['extended'], selected);
    expect(out['collapsed'], isEmpty);
    expect(out['reselectAfterCollapse'], selected);
    expect(out['installOnce'], selected);

    final List<Object?> pulled = <Object?>[
      <Object?>['topPullReleased', 'touch'],
    ];
    expect(out['pullPlain'], pulled);
    expect(out['pullWhileSelecting'], isEmpty);
    expect(out['pullStaleSelection'], pulled);
    expect(out['mousePullWhileSelecting'], isEmpty);
    expect(out['mousePullPlain'], <Object?>[
      <Object?>['topPullReleased', 'mouse'],
    ]);
  });
}

String _harness() =>
    '''
const winListeners = {};
const docListeners = {};
let selection = '';
const calls = [];
global.document = {
  addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
  documentElement: { scrollTop: 0 },
  body: { scrollTop: 0 },
};
global.window = {
  scrollY: 0,
  addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); },
  getSelection() { return { isCollapsed: selection === '', toString() { return selection; } }; },
  flutter_inappwebview: { callHandler(...args) { calls.push(args); } },
};
const installReport = () => { (new Function(${jsonEncode(kPopupSelectionChangeReportJs)}))(); };
const installPull = () => { (new Function(${jsonEncode(kPopupTopPullReleaseJs)}))(); };
installReport();
installPull();
function selChange(text) {
  selection = text;
  for (const fn of docListeners['selectionchange'] || []) fn({});
}
function fireWin(type, e) { for (const fn of winListeners[type] || []) fn(e); }
const t = (x, y) => ({ clientX: x, clientY: y });
function touchPull(midway) {
  fireWin('touchstart', { touches: [t(100, 10)] });
  fireWin('touchmove', { touches: [t(100, 40)] });
  if (midway) midway();
  fireWin('touchmove', { touches: [t(100, 120)] });
  fireWin('touchend', { touches: [] });
}
function mousePull(midway) {
  fireWin('pointerdown', { pointerType: 'mouse', button: 0, clientY: 10 });
  if (midway) midway();
  fireWin('pointermove', { pointerType: 'mouse', clientY: 120 });
  fireWin('pointerup', { pointerType: 'mouse' });
}
const out = {};
function run(name, fn) {
  calls.length = 0;
  fn();
  out[name] = calls.slice();
}
run('newSelection', () => selChange('word'));
run('sameSelectionAgain', () => selChange('word'));
run('extended', () => selChange('word more'));
run('collapsed', () => selChange(''));
run('reselectAfterCollapse', () => selChange('word more'));
run('installOnce', () => { installReport(); selChange('other'); });
// Top-pull: clear the selection without counting report calls.
selChange('');
run('pullPlain', () => touchPull());
run('pullWhileSelecting', () => touchPull(() => { selection = 'grab'; }));
run('pullStaleSelection', () => touchPull());
run('mousePullWhileSelecting', () => { selection = ''; mousePull(() => { selection = 'drag'; }); });
run('mousePullPlain', () => { selection = ''; mousePull(); });
process.stdout.write(JSON.stringify(out));
''';

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  for (final String dir in (Platform.environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
