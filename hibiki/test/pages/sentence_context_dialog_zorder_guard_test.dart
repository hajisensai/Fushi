import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-790 守卫：「制卡·选择句子上下文」原生对话框（[SentenceContextDialog]，BUG-766）
/// 打开期间，必须把查词弹窗 WebView 停靠屏外，否则**原生平台视图**（桌面 WebView2 /
/// Android platform view，总画在 Flutter overlay 之上）盖住 `showAppDialog` 弹的对话框
/// （用户报「层级不对」）。airspace 无头测试照不到，故用源码扫描钉死两车道接线：
///   ① 有状态位 `_sentenceContextDialogOpen`；② 对话框打开/关闭 setState 翻真/假；
///   ③ `parkedPopupLayer` 的 `visible` 与该状态位相与（对话框期间强制停靠屏外）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: 'missing $rel');
    return f.readAsStringSync();
  }

  void assertZOrderWiring(String src, String visibleExpr, String label) {
    expect(src.contains('_sentenceContextDialogOpen'), isTrue,
        reason: '$label 缺对话框打开状态位');
    // 对话框打开置真、关闭（finally）置假。
    expect(src.contains('_sentenceContextDialogOpen = true'), isTrue,
        reason: '$label 打开对话框必须置真（停靠弹窗）');
    expect(src.contains('_sentenceContextDialogOpen = false'), isTrue,
        reason: '$label 关闭对话框必须置假（复原弹窗）');
    // parkedPopupLayer 的 visible 与状态位相与 → 对话框期间弹窗停靠屏外。
    expect(src.contains(visibleExpr), isTrue,
        reason:
            '$label 的 parkedPopupLayer visible 必须与 !_sentenceContextDialogOpen 相与');
    // 置真/置假必须经 setState（触发重建让弹窗真的移动）。
    expect(src.contains('setState(() => _sentenceContextDialogOpen = true)'),
        isTrue,
        reason: '$label 置真须走 setState');
  }

  test('reader 车道 (base_source_page) 对话框期间停靠弹窗', () {
    final String src = read('lib/src/pages/base_source_page.dart');
    assertZOrderWiring(
      src,
      'visible: item.visible && !_sentenceContextDialogOpen',
      'base_source_page',
    );
  });

  test('video/首页车道 (dictionary_page_mixin) 对话框期间停靠弹窗', () {
    final String src =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    assertZOrderWiring(
      src,
      'visible: entry.visible && !_sentenceContextDialogOpen',
      'dictionary_page_mixin',
    );
  });
}
