import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';

// TODO-956 A：右部词条收藏「点了没用」的真因 = 唯一反馈是 popup.css 的 ☆→★ 变色，
// 而该变色依赖 popup.js `nowFav = await callHandler('favoriteEntry')` 的返回值往返；
// 桌面 flutter_inappwebview_windows fork 的 callHandler 返回值 marshalling 与移动端
// 不同，返回值可能不回传 JS → 星标永不变橙 → 用户判定「点了没用」（DB 其实已写）。
//
// 修复 = DB 写成功后**与 callHandler 返回值解耦**直接弹 toast（reader/有声书走
// base_source_page.onFavoriteFromPopup；视频走 dictionary_page_mixin.onFavoriteEntry）。
//
// 受影响的就是桌面（Windows fork）。本测试真执行 [HibikiToast.show] 的桌面 overlay
// 路径——构造带 navigatorKey 的 MaterialApp，调 show 后断言 overlay 真渲染出本地化
// 文案。这正是修复新增的、不依赖任何 WebView 返回值的可见反馈通道。
Future<void> _pumpToastHost(WidgetTester tester) async {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  HibikiToast.navigatorKey = navKey;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocaleRaw('en');

  testWidgets('收藏词条时桌面 toast 真渲染出「已收藏」本地化文案', (WidgetTester tester) async {
    await _pumpToastHost(tester);

    HibikiToast.show(msg: t.word_favorite_added);
    await tester.pump(); // 插入 overlay
    await tester.pump(const Duration(milliseconds: 250)); // 走完淡入

    expect(find.text(t.word_favorite_added), findsOneWidget,
        reason: '收藏成功必须有一条可见 toast，不依赖 callHandler 返回值');
    expect(t.word_favorite_added.trim(), isNotEmpty);

    // 让自动消失计时器跑完，避免 pending-timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('取消收藏时桌面 toast 真渲染出「已取消收藏」本地化文案', (WidgetTester tester) async {
    await _pumpToastHost(tester);

    HibikiToast.show(msg: t.word_favorite_removed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(t.word_favorite_removed), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  test('两条词条收藏 toast key 解析为非空且彼此不同', () {
    expect(t.word_favorite_added.trim(), isNotEmpty);
    expect(t.word_favorite_removed.trim(), isNotEmpty);
    expect(t.word_favorite_added, isNot(equals(t.word_favorite_removed)));
  });

  // 接线守卫（防回归）：两个宿主的收藏切换 handler 必须在 DB 写之后、与返回值解耦地
  // 弹 toast；既不能去掉 toast，也不能把 toast 改成只在 callHandler 返回成功时才弹。
  group('收藏 handler 在写 DB 后解耦弹 toast（防回归）', () {
    test('base_source_page.onFavoriteFromPopup：add/remove 各弹一次词条 toast', () {
      final String src =
          File('lib/src/pages/base_source_page.dart').readAsStringSync();
      final int handlerStart = src.indexOf('Future<bool> onFavoriteFromPopup(');
      expect(handlerStart, greaterThan(0));
      final String body = src.substring(handlerStart);
      expect(body, contains('HibikiToast.show(msg: t.word_favorite_added)'),
          reason: '收藏成功后必须弹「已收藏」toast');
      expect(body, contains('HibikiToast.show(msg: t.word_favorite_removed)'),
          reason: '取消收藏后必须弹「已取消收藏」toast');
      expect(
        body.indexOf('addFavoriteWord(') <
            body.indexOf('HibikiToast.show(msg: t.word_favorite_added)'),
        isTrue,
        reason: 'add 的 toast 必须在 addFavoriteWord 写库之后（解耦于返回值通道）',
      );
    });

    test('dictionary_page_mixin.onFavoriteEntry（视频宿主）：add/remove 各弹一次', () {
      final String src =
          File('lib/src/pages/implementations/dictionary_page_mixin.dart')
              .readAsStringSync();
      final int handlerStart = src.indexOf('Future<bool> onFavoriteEntry(');
      expect(handlerStart, greaterThan(0));
      final String body = src.substring(handlerStart);
      expect(body, contains('HibikiToast.show(msg: t.word_favorite_added)'));
      expect(body, contains('HibikiToast.show(msg: t.word_favorite_removed)'));
      expect(
        body.indexOf('addFavoriteWord(') <
            body.indexOf('HibikiToast.show(msg: t.word_favorite_added)'),
        isTrue,
      );
    });
  });
}
