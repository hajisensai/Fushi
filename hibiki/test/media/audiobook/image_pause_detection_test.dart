import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-007 回归守卫（源码扫描）：有声书「遇到图片暂停播放几秒」的图片检测必须用
/// **cue 推进锚点间 DOM 判定**，不得退回 `IntersectionObserver` 视口可见性。
///
/// 根因：阅读器是 CSS 多栏 + `overflow:hidden` + `scrollLeft` 离散翻页；reveal 驱动
/// 的有声书播放会把无 cue 的整页插图一帧跳过、从不渲染成「当前页」，IO（视口阈值
/// 0.3）永不达阈值 → `onImageDetected` 永不回调 → 暂停永不发生（功能形同虚设）。
/// 修法把检测挂到 `__hoshiHighlight`：cue 推进到新句子时，用 `compareDocumentPosition`
/// 判定上一句锚点（`__hoshiPrevHighlight`）到当前句之间是否存在 `img/svg`，有则
/// `callHandler('onImageDetected')`——离散翻页跳过整页插图也能确定性抓到。
///
/// 检测是 WebView 内 JS，真行为只能设备验证；此处锁定 JS 检测机制契约不被回退。
void main() {
  final String src = File(
    'lib/src/media/audiobook/audiobook_bridge.dart',
  ).readAsStringSync();

  test('image-pause detection uses cue-advance anchor-span DOM check', () {
    expect(src, contains('window.__hoshiPrevHighlight'),
        reason: 'cue 推进检测须追踪上一句锚点 __hoshiPrevHighlight');
    expect(src, contains('compareDocumentPosition'),
        reason: '须用 compareDocumentPosition 判定锚点间 img/svg（绕开视口可见性）');
    expect(src, contains("querySelectorAll('img, svg')"),
        reason: '须扫描 img/svg 节点');
    expect(src, contains("callHandler('onImageDetected')"),
        reason: '检测到锚点间插图须通知 Dart 暂停');
  });

  test('old IntersectionObserver viewport image detection is removed', () {
    // 断言「实例化」而非单词本身——本文件注释里仍会解释为何弃用 IntersectionObserver。
    expect(src, isNot(contains('new IntersectionObserver(')),
        reason: 'IntersectionObserver 视口检测在离散翻页下永不触发，不得退回');
    expect(src, isNot(contains('__hoshiImageObserver')),
        reason: '旧 IO 图片观察器须移除');
  });
}
