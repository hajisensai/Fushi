import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

/// BUG-1327 / BUG-1326：「制卡·选择句子上下文」对话框点不动 + 一点就把查词浮层关掉。
///
/// BUG-1327 根因：视频页 / 首页词典页 / texthooker 把整棵查词浮层子树挂在**根 Overlay**
/// （手动 `Overlay.of(context, rootOverlay: true).insert(...)`，为了盖过 media_kit 全屏
/// 路由）。根 Overlay 里手动 insert 的 entry 永远排在 `showDialog` 推的路由**之上**，而
/// 浮层子树里那层整屏 dismiss barrier（`Positioned.fill` + `HitTestBehavior.translucent`）
/// 会把落在对话框上的点击整个吃掉：用户点「确认制卡」既点不到按钮，还被 barrier 判成
/// 「点浮层外面」→ 清整栈。BUG-797 当时只把弹窗 WebView 停到屏外（解决「看得见」），
/// 命中测试这一半漏了。
///
/// 本文件用一个**最小 harness** 复现该层序（不拉起真视频页）：手动往根 Overlay insert
/// 一个带 barrier 的 entry，再 `showDialog` 一个带按钮的对话框，直接观测点击落到谁身上。
/// 第一条测试钉死「barrier 挂着时对话框确实点不动」（若哪天框架层序变了，它会红——
/// 那说明本修复的前提没了）；第二条钉死修复后的行为。
void main() {
  group('shouldShowLookupDismissBarrier 真值表（BUG-1327）', () {
    test('对话框打开时一律不挂 barrier', () {
      expect(
        shouldShowLookupDismissBarrier(
          hasVisiblePopup: true,
          isSearching: false,
          hiddenByDialog: true,
        ),
        isFalse,
      );
      expect(
        shouldShowLookupDismissBarrier(
          hasVisiblePopup: false,
          isSearching: true,
          hiddenByDialog: true,
        ),
        isFalse,
      );
    });

    test('无对话框时保持原语义：有可见层或正在搜索就挂', () {
      expect(
        shouldShowLookupDismissBarrier(
          hasVisiblePopup: true,
          isSearching: false,
          hiddenByDialog: false,
        ),
        isTrue,
      );
      expect(
        shouldShowLookupDismissBarrier(
          hasVisiblePopup: false,
          isSearching: true,
          hiddenByDialog: false,
        ),
        isTrue,
      );
      // 仅剩隐藏热槽（无可见层、没在搜索）：不拦，放行给页面本体。
      expect(
        shouldShowLookupDismissBarrier(
          hasVisiblePopup: false,
          isSearching: false,
          hiddenByDialog: false,
        ),
        isFalse,
      );
    });
  });

  group('根 Overlay barrier 与对话框的层序（BUG-1327）', () {
    /// 搭一个和三个宿主页同构的最小场景：根 Overlay 上手动 insert 一层浮层子树
    /// （只含 dismiss barrier），再弹一个对话框。[barrierEnabled] 模拟修复前后的门控。
    Future<void> pumpHarness(
      WidgetTester tester, {
      required bool barrierEnabled,
      required VoidCallback onBarrierTap,
      required VoidCallback onConfirmTap,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  child: const Text('open'),
                  onPressed: () {
                    // 浮层子树：与宿主页一样手动挂到根 Overlay。
                    Overlay.of(context, rootOverlay: true).insert(
                      OverlayEntry(
                        builder: (_) => Stack(
                          children: <Widget>[
                            if (barrierEnabled)
                              Positioned.fill(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: onBarrierTap,
                                  child: const ColoredBox(
                                      color: Colors.transparent),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                    showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        content: const Text('ctx'),
                        actions: <Widget>[
                          FilledButton(
                            onPressed: onConfirmTap,
                            child: const Text('confirm-mine'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('barrier 挂着时，点「确认制卡」落到 barrier 而不是按钮（复现）',
        (WidgetTester tester) async {
      int barrierTaps = 0;
      int confirmTaps = 0;
      await pumpHarness(
        tester,
        barrierEnabled: true,
        onBarrierTap: () => barrierTaps++,
        onConfirmTap: () => confirmTaps++,
      );
      // 对话框是可见的（BUG-797 已把 WebView 停屏外），但点击进不去。
      expect(find.text('confirm-mine'), findsOneWidget);
      await tester.tap(find.text('confirm-mine'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(confirmTaps, 0, reason: '根 Overlay 的 barrier 排在对话框路由之上，点击被它吃掉');
      expect(barrierTaps, 1, reason: '这一下还会被判成「点浮层外面」→ 宿主清整栈（弹窗被关）');
    });

    testWidgets('对话框期间撤掉 barrier，点「确认制卡」真的点到按钮（修复）',
        (WidgetTester tester) async {
      int barrierTaps = 0;
      int confirmTaps = 0;
      await pumpHarness(
        tester,
        // 修复后 shouldShowLookupDismissBarrier 在 hiddenByDialog 时返回 false。
        barrierEnabled: shouldShowLookupDismissBarrier(
          hasVisiblePopup: true,
          isSearching: false,
          hiddenByDialog: true,
        ),
        onBarrierTap: () => barrierTaps++,
        onConfirmTap: () => confirmTaps++,
      );
      await tester.tap(find.text('confirm-mine'));
      await tester.pumpAndSettle();
      expect(confirmTaps, 1, reason: '对话框按钮必须能被点到');
      expect(barrierTaps, 0, reason: '浮层不该再吃这一下点击，更不该关栈');
    });
  });

  group('三个根 Overlay 宿主页都走同一门控（BUG-1327 守卫）', () {
    String read(String relativePath) {
      final File file = File(relativePath);
      expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
      return file.readAsStringSync();
    }

    test('mixin 暴露 lookupPopupHiddenByDialog（barrier 与 parked visible 同源）', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_page_mixin.dart');
      expect(src.contains('bool get lookupPopupHiddenByDialog'), isTrue,
          reason: '宿主页要拿到「对话框正开着」才能同时撤掉 barrier');
      expect(src.contains('_popupHidingDialogDepth > 0'), isTrue);
    });

    for (final ({String path, String name}) page
        in const <({String path, String name})>[
      (
        path: 'lib/src/pages/implementations/video_hibiki_page.dart',
        name: '视频页'
      ),
      (
        path: 'lib/src/pages/implementations/home_dictionary_page.dart',
        name: '首页词典页'
      ),
      (
        path: 'lib/src/pages/implementations/texthooker_page.dart',
        name: 'texthooker'
      ),
    ]) {
      test('${page.name} barrier 走 shouldShowLookupDismissBarrier', () {
        final String src = read(page.path);
        expect(src.contains('shouldShowLookupDismissBarrier('), isTrue,
            reason: '${page.name}的 dismiss barrier 必须走收口判据，别再手写裸条件');
        expect(
            src.contains('hiddenByDialog: lookupPopupHiddenByDialog'), isTrue,
            reason: '${page.name}漏接对话框门控 → 对话框点不动且一点就关栈（BUG-1327）');
        // 裸条件（不带门控）复发即红。只盯 barrier 本身——正则要求这个 if 紧跟着
        // `Positioned.fill(`，避免误伤同文件里其它「有可见层 || 正在搜索」的判断
        // （如首页词典页下拉刷新的 _clearSearchFromResultPull）。
        expect(
          RegExp(r'if \([^)]*isSearchingUi\)\s*Positioned\.fill\(')
              .hasMatch(src),
          isFalse,
          reason: '${page.name}又出现漏门控的裸 barrier 条件（BUG-1327）',
        );
      });
    }
  });

  group('openSentenceContextModal 参数形态三镜像（BUG-1326 守卫）', () {
    // popup.js 三镜像：app 内 assets + app 内扩展 vendor + 仓库根扩展 vendor。
    const List<String> mirrors = <String>[
      'assets/popup/popup.js',
      'assets/browser_extension/vendor/popup.js',
      '../tools/browser-extension/vendor/popup.js',
    ];

    for (final String path in mirrors) {
      test('$path 传对象而不是 JSON 字符串', () {
        final File file = File(path);
        expect(file.existsSync(), isTrue, reason: 'missing $path');
        final String js = file.readAsStringSync();
        expect(
          RegExp(r"callHandler\(\s*'openSentenceContextModal',\s*JSON\.stringify")
              .hasMatch(js),
          isFalse,
          reason: '$path 又把参数 stringify 了：宿主 handler 只认 Map，'
              'entryIndex 会静默退化成 0 → 确认制卡永远点第一个词条（BUG-1326）',
        );
        expect(
          RegExp(r"callHandler\(\s*'openSentenceContextModal',\s*"
                  r'\{ entryIndex: idx, matched: matched \}\)')
              .hasMatch(js),
          isTrue,
          reason: '$path 的「调整上下文」按钮必须原样传 {entryIndex, matched} 对象',
        );
      });
    }
  });

  group('decodeBridgeMap：JS 桥参数形态（BUG-1326）', () {
    test('对象原样解析（popup.js 现行契约）', () {
      final Map<dynamic, dynamic>? m =
          decodeBridgeMap(<String, Object?>{'entryIndex': 2, 'matched': '見る'});
      expect(m, isNotNull);
      expect((m!['entryIndex'] as num).toInt(), 2);
      expect(m['matched'], '見る');
    });

    test('JSON 字符串也解析（老扩展 vendor 副本仍会 stringify）', () {
      final Map<dynamic, dynamic>? m =
          decodeBridgeMap('{"entryIndex":3,"matched":"読む"}');
      expect(m, isNotNull);
      expect((m!['entryIndex'] as num).toInt(), 3,
          reason: '若只认 Map，entryIndex 会静默退化成 0 → 确认制卡永远点第一个词条');
      expect(m['matched'], '読む');
    });

    test('null / 非法串 / JSON 数组 → null，由调用方走默认值', () {
      expect(decodeBridgeMap(null), isNull);
      expect(decodeBridgeMap(''), isNull);
      expect(decodeBridgeMap('not json'), isNull);
      expect(decodeBridgeMap('[1,2]'), isNull);
      expect(decodeBridgeMap(42), isNull);
    });
  });
}
