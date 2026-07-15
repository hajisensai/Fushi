import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（BUG-819）：桌面全局查词浮窗顶部控制条（拖拽 grip + 置顶图钉 📌 + 关闭 ×）
/// 由 `assets/popup/global_lookup_host.js` 在 WebView 注入 `#global-lookup-panel-bar`。其
/// **浅色窗口变体**曾取值过淡（栏底 0.10 / 芯片 0.16 / 图标 0.75 / pin-off 0.45），在浅色壁纸
/// 或浅色卡片上整条控制栏糊没、图钉/关闭看不清。修复上调浅色变体对比。
///
/// 此守卫锁死浅色变体的可见度下限，防重构把它调回过淡；并确认深色变体（BUG-768）未被误伤。
/// 该 JS 是注入字符串、无法用 flutter test 直接驱动，故源码扫描。
void main() {
  final File js = File('assets/popup/global_lookup_host.js');

  late final String src;

  setUpAll(() {
    expect(js.existsSync(), isTrue,
        reason: 'global_lookup_host.js 应存在: ${js.path}');
    src = js.readAsStringSync();
  });

  group('BUG-819 桌面查词浮窗控制条浅色变体对比', () {
    test('浅色栏底/芯片/图标已用提升后的值', () {
      expect(
          src.contains(
              'background:rgba(120,120,128,0.18);border-radius:10px 10px 0 0;}'),
          isTrue,
          reason: '浅色栏底须 >=0.18 才在浅色上有存在感');
      expect(
          src.contains(
              'background:rgba(120,120,128,0.30);color:rgba(60,60,67,0.92);}'),
          isTrue,
          reason: '浅色按钮芯片/图标须提升到 0.30/0.92 才看得清图钉/关闭');
      expect(src.contains('panel-pin-off{opacity:0.62;}'), isTrue,
          reason: '未置顶图钉不得再砍到 0.45 那么淡');
    });

    test('旧的过淡浅色值不得复现（防回归）', () {
      expect(src.contains('background:rgba(120,120,128,0.10);border-radius'),
          isFalse,
          reason: '旧浅色栏底 0.10 太淡，不得复现');
      expect(
          src.contains(
              'background:rgba(120,120,128,0.16);color:rgba(60,60,67,0.75);}'),
          isFalse,
          reason: '旧浅色芯片/图标 0.16/0.75 太淡，不得复现');
      expect(src.contains('panel-pin-off{opacity:0.45;}'), isFalse,
          reason: '旧 pin-off 0.45 太淡，不得复现');
    });

    test('深色变体（BUG-768）未被误伤', () {
      expect(src.contains('rgba(235,235,245,0.14)'), isTrue,
          reason: '深色变体按钮芯片须保留（BUG-768）');
    });
  });
}
