import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（BUG-818）：独立查词浮窗（`lib/popup_main.dart` 宿主 `PopupDictionaryPage`）
/// 跑在**完全透明的浮动窗**里（圆角+阴影靠内部卡片画），窗内唯一背景是 `_buildCard` 的
/// `FushiPopupSurface`。其色 `appModel.overrideDictionaryColor ?? tokens.surfaces.page`
/// 会灌入阅读器主题背景色（`_syncDictionaryTheme`），某些预设/自定义主题背景**带 alpha**；
/// 在透明浮窗上半透明卡片直接透出**桌面壁纸**，浅色壁纸下文字/边界看不清。
///
/// 修复把该卡片色强制补满 alpha（`.withValues(alpha: 1.0)`，现收在 `_cardColor`）。
/// 浮窗卡片是透明窗上唯一背景层，理应恒不透明——app 内背后是不透明阅读页不受影响，no-op。
/// 此守卫锁死不变式，防重构去掉 alpha 补齐又让透明主题色透出宿主壁纸（无法用 flutter test 直接驱动独立浮窗宿主窗，故源码扫描）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/popup_dictionary_page.dart',
  );

  late final String flat;

  setUpAll(() {
    expect(
      page.existsSync(),
      isTrue,
      reason: 'popup_dictionary_page.dart 应存在: ${page.path}',
    );
    // 去空白后匹配，抗 dart format 换行。
    flat = page.readAsStringSync().replaceAll(RegExp(r'\s+'), '');
  });

  group('BUG-818 查词浮窗卡片背景恒不透明', () {
    // 卡片色抽成 `_cardColor`（BUG-3660：基础层空结果盖板与卡片共用同一个不透明色），
    // 所以分两步钉：`_cardColor` 对主题色补满 alpha，且 `_buildCard` 的卡片用它。
    test('_cardColor 对主题色补满 alpha=1.0', () {
      expect(
        RegExp(
          r'Color_cardColor\(FushiDesignTokenstokens\)=>'
          r'\(appModel\.overrideDictionaryColor\?\?tokens\.surfaces\.page\)'
          r'\.withValues\(alpha:1\.0,?\);',
        ).hasMatch(flat),
        isTrue,
        reason:
            '浮窗卡片是透明窗上唯一背景层，须强制不透明，'
            '否则带 alpha 的阅读器主题色会透出桌面壁纸（BUG-818）',
      );
    });

    test('_buildCard 的 FushiPopupSurface color 取 _cardColor', () {
      expect(
        flat.contains('FushiPopupSurface(color:_cardColor(tokens),'),
        isTrue,
        reason: '卡片底色必须走补满 alpha 的 _cardColor（BUG-818）',
      );
    });

    test('未包裹的半透明形状不得复现（防回归）', () {
      expect(
        flat.contains(
          'color:appModel.overrideDictionaryColor??tokens.surfaces.page,',
        ),
        isFalse,
        reason: '旧的直接用主题色（可能带 alpha）的形状不得复现——那会让浮窗透出壁纸',
      );
    });
  });
}
