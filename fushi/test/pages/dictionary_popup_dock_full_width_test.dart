import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// BUG-2439：「底部停靠查词弹窗」= 屏幕底部一条**整宽**面板，必须从屏幕最左铺到最右。
///
/// 几何那半（[dockedPopupRect] 的横向 inset 归 0、[resolvePopupRect] 不再把跟随模式的
/// 贴边 padding 转发进横向）锁在 `dictionary_popup_layer_test.dart`。本文件锁**观感**
/// 那半：矩形铺满之后，卡片圆角的四段弧仍会在屏幕左右缘露出背景色，用户看到的还是
/// 「没铺满」。dock 态因此把圆角摊平，跟随模式（四周有留白）保持既有圆角。
DictionaryPopupLayer _layer({required bool bottomDocked}) {
  return DictionaryPopupLayer(
    result: DictionarySearchResult(searchTerm: 'x'),
    webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
    onDismiss: () {},
    onTextSelected: (String _, Rect __) {},
    onLinkClick: (String _, Rect __) {},
    onMineEntry: (Map<String, String> _) async => const MinePopupResult(),
    onDuplicateCheck: (String _, String __) async => false,
    bottomDocked: bottomDocked,
  );
}

Widget _host(Widget layer) {
  return TranslationProvider(
    child: MaterialApp(
      builder: (context, child) => child ?? const SizedBox.shrink(),
      home: Scaffold(
        body: Center(child: SizedBox(width: 360, height: 360, child: layer)),
      ),
    ),
  );
}

BorderRadius? _surfaceRadius(WidgetTester tester) {
  return tester
      .widget<FushiPopupSurface>(find.byType(FushiPopupSurface))
      .borderRadius;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('dock 态：弹窗圆角摊平，surface 真正边到边', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_layer(bottomDocked: true)));
    await tester.pump();

    expect(_surfaceRadius(tester), BorderRadius.zero);
  });

  testWidgets('跟随模式：圆角不动（沿用设计令牌的卡片圆角）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_layer(bottomDocked: false)));
    await tester.pump();

    expect(
      _surfaceRadius(tester),
      isNull,
      reason: 'null = 走令牌默认；写死一个数会让卡片圆角在此处偷偷分叉',
    );
  });

  testWidgets('同一层：dock 与跟随的圆角确实不同（开关真的改变观感）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_layer(bottomDocked: false)));
    await tester.pump();
    final BorderRadius? following = _surfaceRadius(tester);

    await tester.pumpWidget(_host(_layer(bottomDocked: true)));
    await tester.pump();
    final BorderRadius? docked = _surfaceRadius(tester);

    expect(docked, isNot(equals(following)));
  });

  test('FushiPopupSurface 的圆角覆写逐角内缩描边（摊平角不会被减成负数）', () {
    // BUG-2166 的 `_borderInsetChild` 用的是「外圈半径 - 笔宽」。改成可覆写之后，
    // dock 的 0 半径必须仍然是 0，不能变成负半径把 ClipRRect 打爆。
    final String source = File(
      'lib/src/utils/components/fushi_material_components.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('math.max(0, r.x - _borderWidth)'),
      reason: '摊平的角必须夹在 0，否则 dock 面板的 ClipRRect 收到负半径',
    );
  });

  test('两个宿主都把 dock 偏好传进弹窗层（漏传是静默的：只是圆角没摊平）', () {
    for (final String path in <String>[
      'lib/src/pages/base_source_page.dart',
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('bottomDocked:'),
        reason: '$path 必须把 popupBottomDocked 传给 DictionaryPopupLayer',
      );
    }
  });
}
