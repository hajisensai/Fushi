import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（BUG-1001，承接 BUG-819 审计）：桌面全局查词浮窗顶部控制条
/// （拖拽 grip + 置顶图钉 📌 + 防截屏盾 + 关闭 ×）由 `assets/popup/global_lookup_host.js`
/// 在 WebView 注入 `#global-lookup-panel-bar`。其**浅色窗口变体**曾整体过淡（栏底 0.10 /
/// 芯片 0.16+图标 0.75 / pin-off 0.45），在浅色壁纸或浅色卡片上整条控制栏糊没。
///
/// 栏底/芯片/hover 已由早前提交提亮（栏底 0.18+轮廓、芯片 0.24/深灰 0.95、hover 0.36/1）；
/// 本轮补齐最后一处过淡：`.panel-pin-off` 与其复用同淡度的 `.panel-block-off`
/// 由 `opacity:0.45` 提升到 `0.62`（二者须保持一致，见 JS 注释）。
///
/// 该 JS 是注入字符串、无法用 flutter test 直接驱动，故源码扫描。
void main() {
  final File js = File('assets/popup/global_lookup_host.js');

  late final String src;

  setUpAll(() {
    expect(js.existsSync(), isTrue,
        reason: 'global_lookup_host.js 应存在: ${js.path}');
    src = js.readAsStringSync();
  });

  group('BUG-1001 桌面查词浮窗控制条浅色变体对比', () {
    test('未置顶图钉/防截屏关闭态已提亮到 0.62 且保持一致', () {
      expect(src.contains('panel-pin-off{opacity:0.62;}'), isTrue,
          reason: '未置顶图钉不得再砍到 0.45 那么淡');
      expect(src.contains('panel-block-off{opacity:0.62;}'), isTrue,
          reason: '防截屏关闭态须与 pin-off 一致（同为 0.62）');
    });

    test('旧的过淡 dimmed 值不得复现（防回归）', () {
      expect(src.contains('panel-pin-off{opacity:0.45;}'), isFalse,
          reason: '旧 pin-off 0.45 太淡，不得复现');
      expect(src.contains('panel-block-off{opacity:0.45;}'), isFalse,
          reason: '旧 block-off 0.45 太淡，不得复现');
    });

    test('浅色栏底/芯片对比不得回退到旧过淡值', () {
      // 栏底旧过淡值 0.10（现已 0.18 + border-bottom 轮廓）。
      expect(src.contains('background:rgba(120,120,128,0.10);border-radius'),
          isFalse,
          reason: '旧浅色栏底 0.10 太淡，不得复现');
      // 按钮芯片旧过淡组合 0.16 芯片 + 0.75 图标（现已 0.24 芯片 + 深灰 0.95）。
      expect(
          src.contains(
              'background:rgba(120,120,128,0.16);color:rgba(60,60,67,0.75);}'),
          isFalse,
          reason: '旧浅色芯片/图标 0.16/0.75 太淡，不得复现');
      expect(
          src.contains(
              'background:rgba(120,120,128,0.24);color:rgba(30,30,35,0.95);}'),
          isTrue,
          reason: '浅色按钮芯片/图标须保持已提亮的 0.24/深灰 0.95');
    });

    test('深色变体（BUG-768）未被误伤', () {
      expect(src.contains('rgba(235,235,245,0.14)'), isTrue,
          reason: '深色变体按钮芯片须保留（BUG-768）');
    });
  });
}
