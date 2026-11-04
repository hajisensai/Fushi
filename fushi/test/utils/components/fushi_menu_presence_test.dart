import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_menu_presence.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/webview/webview_menu_dismiss_bridge.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 U_8sCB0h_f：macOS 上盖在 WebView 上的右键菜单点 WebView 关不掉、每次右键再
/// 叠一层。过去只有漫画阅读器用页面私有的「单菜单句柄」补；现在由 showFushiMenu
/// 自己登记在场（FushiMenuPresence），所有 WebView 宿主经 WebViewMenuDismissBridge
/// 同一条路关菜单。
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

  Future<String?> openMenu(BuildContext context, String label) =>
      showFushiMenu<String>(
        context: context,
        position: const RelativeRect.fromLTRB(10, 10, 10, 10),
        items: <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: label, child: Text(label)),
        ],
      );

  final FushiMenuPresence presence = FushiMenuPresence.instance;

  testWidgets('showFushiMenu：后开的菜单顶替在场的菜单，不叠加', (WidgetTester tester) async {
    final List<bool> states = <bool>[];
    void record() => states.add(presence.isOpen.value);
    presence.isOpen.addListener(record);
    addTearDown(() => presence.isOpen.removeListener(record));
    final BuildContext context = await pumpHost(tester);

    final Future<String?> first = openMenu(context, 'first');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(presence.isOpen.value, isTrue);

    // 平台视图吞掉了点击：旧菜单的遮罩没收到，又来一次右键。
    final Future<String?> second = openMenu(context, 'second');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(await first, isNull);
    expect(presence.debugOpenCount, 1);

    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();
    expect(await second, 'second');
    expect(presence.isOpen.value, isFalse);
    expect(states.last, isFalse);
  });

  testWidgets('dismissAll 关掉在场菜单（WebView pointerdown 回报路径），不动页面路由', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    final Future<String?> menu = openMenu(context, 'only');
    await tester.pumpAndSettle();
    expect(find.text('only'), findsOneWidget);

    presence.dismissAll();
    await tester.pumpAndSettle();
    expect(find.text('only'), findsNothing);
    expect(await menu, isNull);
    expect(presence.isOpen.value, isFalse);
    expect(find.byType(Scaffold), findsOneWidget);

    // 没有菜单时什么都不做。
    presence.dismissAll();
    await tester.pumpAndSettle();
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('菜单上方又推了别的路由：dismissAll 只移除菜单，不弹上面的路由', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    final Future<String?> menu = openMenu(context, 'under');
    await tester.pumpAndSettle();
    final NavigatorState navigator = Navigator.of(context);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => const Scaffold(body: Text('above')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    presence.dismissAll();
    await tester.pumpAndSettle();
    expect(await menu, isNull);
    expect(find.text('above'), findsOneWidget);
    expect(presence.isOpen.value, isFalse);
  });

  test('WebView 页内监听：菜单在场时鼠标按下只回报一次，触摸不回报', () async {
    final String code =
        '''
const assert=require('node:assert/strict');
const window={};
const listeners=[];
const document={addEventListener(type,fn){ listeners.push([type,fn]); }};
const calls=[];
window.flutter_inappwebview={callHandler:(n)=>{ calls.push(n); }};
${WebViewMenuDismissBridge.script}
${WebViewMenuDismissBridge.script}
function down(pointerType){
  listeners.filter((l)=>l[0]==='pointerdown').forEach((l)=>l[1]({pointerType}));
}
assert.equal(listeners.length,1,'重复注入只装一次监听');
down('mouse');
assert.deepEqual(calls,[],'没有菜单时不回报');
window.${WebViewMenuDismissBridge.openFlag}=true;
down('touch');
assert.deepEqual(calls,[],'触摸走 Flutter 遮罩，不回报');
down('mouse');
assert.deepEqual(calls,['${WebViewMenuDismissBridge.handlerName}']);
assert.equal(window.${WebViewMenuDismissBridge.openFlag},false);
down('pen');
assert.deepEqual(calls,['${WebViewMenuDismissBridge.handlerName}'],'只回报一次');
''';
    final Directory dir = Directory.systemTemp.createTempSync('menu-dismiss-');
    try {
      final File script = File('${dir.path}/verify.js')
        ..writeAsStringSync(code);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('在自己上方弹 showFushiMenu 的 WebView 宿主都接了 WebViewMenuDismissBridge', () {
    // 正向发现：一个 Dart 库（含 part 文件）里既构造 InAppWebView 又调 showFushiMenu，
    // 就是「菜单盖在 WebView 上」的宿主。
    String norm(String path) => File(path).absolute.uri.normalizePath().path;
    final Map<String, String> libraries = <String, String>{};
    final RegExp partOf = RegExp(r"^part of '([^']+)';", multiLine: true);
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = entity.readAsStringSync();
      final RegExpMatch? owner = partOf.firstMatch(source);
      final String lib = owner == null
          ? norm(entity.path)
          : norm('${entity.parent.path}/${owner.group(1)}');
      libraries[lib] = <String>[?libraries[lib], source].join('\n');
    }
    final RegExp webView = RegExp(r'(?<![A-Za-z_])InAppWebView\(');
    final List<String> hosts = <String>[];
    final List<String> missing = <String>[];
    libraries.forEach((String lib, String source) {
      if (!webView.hasMatch(source) || !source.contains('showFushiMenu<')) {
        return;
      }
      hosts.add(lib);
      final int webViews = webView.allMatches(source).length;
      final int scripts = 'WebViewMenuDismissBridge.userScript'
          .allMatches(source)
          .length;
      final bool attached = RegExp(
        r'[Mm]enuDismiss\.attach\(',
      ).hasMatch(source);
      if (scripts < webViews || !attached) {
        missing.add(
          '$lib（WebView $webViews 处，注入脚本 $scripts 处，attach: $attached）',
        );
      }
    });
    expect(
      hosts.length,
      greaterThanOrEqualTo(4),
      reason: '已知漫画 / 正文阅读器 / 内置浏览器 / 查词弹窗 4 个宿主，发现规则失效了',
    );
    expect(missing, isEmpty, reason: missing.join('\n'));
  });
}
