import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/utils/components/fushi_single_menu_gate.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:material_ui/material_ui.dart';

/// 反馈 U_8sCB0h_f：macOS 漫画阅读器右键菜单不消失、重复叠加。漫画页整页是
/// WKWebView，点 WebView 的鼠标事件到不了菜单的 ModalBarrier，每次右键都 push
/// 一个新菜单路由。
void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  Future<String?> openMenu(
    FushiSingleMenuGate gate,
    BuildContext context,
    String label,
  ) => gate.show<String>(
    context,
    (RouteSettings settings) => showFushiMenu<String>(
      context: context,
      routeSettings: settings,
      position: const RelativeRect.fromLTRB(10, 10, 10, 10),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: label, child: Text(label)),
      ],
    ),
  );

  testWidgets('a second open replaces the first menu instead of stacking', (
    WidgetTester tester,
  ) async {
    final List<bool> states = <bool>[];
    final FushiSingleMenuGate gate = FushiSingleMenuGate(
      routeName: 'test-menu',
      onOpenChanged: states.add,
    );
    final BuildContext context = await pumpHost(tester);

    final Future<String?> first = openMenu(gate, context, 'first');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);

    final Future<String?> second = openMenu(gate, context, 'second');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(await first, isNull);
    expect(gate.isOpen, isTrue);

    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();
    expect(await second, 'second');
    expect(gate.isOpen, isFalse);
    expect(states.last, isFalse);
  });

  testWidgets('dismiss closes the open menu (WebView pointerdown path)', (
    WidgetTester tester,
  ) async {
    final FushiSingleMenuGate gate = FushiSingleMenuGate(
      routeName: 'test-menu',
    );
    final BuildContext context = await pumpHost(tester);

    final Future<String?> menu = openMenu(gate, context, 'only');
    await tester.pumpAndSettle();
    expect(find.text('only'), findsOneWidget);

    gate.dismiss();
    await tester.pumpAndSettle();
    expect(find.text('only'), findsNothing);
    expect(await menu, isNull);
    expect(gate.isOpen, isFalse);
    // 页面本身的路由不能被弹掉。
    expect(find.byType(Scaffold), findsOneWidget);

    // 没有菜单时 dismiss 什么都不做。
    gate.dismiss();
    await tester.pumpAndSettle();
    expect(find.byType(Scaffold), findsOneWidget);
  });

  test(
    'manga WebView reports a mouse press only while the menu is open',
    () async {
      final String document = mangaWindowDocument(
        const <MokuroImage>[
          MokuroImage(
            url: 'page.png',
            size: MokuroSize(1000, 1414),
            blocks: <MokuroBlock>[],
          ),
        ],
        const <String>['page.png'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        zoomPercent: 100,
      );
      const String start = '  // 右键菜单在场时（Dart 置 window.__fushiMangaMenuOpen）';
      // 以监听自己的收尾为界，不借相邻代码当结束标记（相邻代码挪动就切错段）。
      const String end = '},{capture:true,passive:true});';
      final int from = document.indexOf(start);
      expect(from, isNonNegative, reason: '生成文档里找不到菜单关闭监听');
      final int to = document.indexOf(end, from);
      expect(to, isNonNegative);
      final String snippet = document.substring(from, to + end.length);
      final String code =
          '''
const assert=require('node:assert/strict');
const window={};
const listeners=[];
const document={addEventListener(type,fn){ listeners.push([type,fn]); }};
let calls=[];
function _bridge(){ return {callHandler:(n)=>{ calls.push(n); }}; }
$snippet
function down(pointerType){
  listeners.filter((l)=>l[0]==='pointerdown').forEach((l)=>l[1]({pointerType}));
}
down('mouse');
assert.deepEqual(calls,[],'没有菜单时不回报');
window.__fushiMangaMenuOpen=true;
down('touch');
assert.deepEqual(calls,[],'触摸走 Flutter 遮罩，不回报');
down('mouse');
assert.deepEqual(calls,['onMangaDismissMenu']);
assert.equal(window.__fushiMangaMenuOpen,false);
down('mouse');
assert.deepEqual(calls,['onMangaDismissMenu'],'只回报一次');
''';
      final Directory dir = Directory.systemTemp.createTempSync('manga-menu-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync(code);
        final ProcessResult result = await Process.run('node', <String>[
          script.path,
        ], runInShell: Platform.isWindows);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );

  test('manga reader routes its context menu through the gate', () {
    final String source = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    final int fn = source.indexOf(
      'Future<void> _showReaderContextMenu(String payloadJson)',
    );
    expect(fn, isNonNegative, reason: '漫画右键菜单入口不见了（路径过期请更新守卫）');
    final int menu = source.indexOf('showFushiMenu<_MangaContextAction>(', fn);
    final String head = source.substring(fn, menu);
    expect(
      head
          .replaceAll(RegExp(r'\s+'), '')
          .contains('_contextMenuGate.show<_MangaContextAction>('),
      isTrue,
      reason: '漫画右键菜单必须经 FushiSingleMenuGate 打开，否则会叠加',
    );
    expect(
      source.substring(menu, menu + 400).contains('routeSettings: settings'),
      isTrue,
      reason: '菜单路由必须带 gate 给的 RouteSettings，dismiss 才认得出它',
    );
    final int dismiss = source.indexOf("handlerName: 'onMangaDismissMenu'");
    expect(dismiss, isNonNegative, reason: 'WebView pointerdown 回报口不见了');
    expect(
      source
          .substring(dismiss, dismiss + 300)
          .contains('_contextMenuGate.dismiss()'),
      isTrue,
    );
  });
}
