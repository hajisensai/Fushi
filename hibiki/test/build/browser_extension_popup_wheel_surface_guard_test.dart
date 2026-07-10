// BUG-686 回归守卫：查词弹窗滚轮「表面感知」——滚动目标与 zoom 读取路径。
//
// 背景：popup.js 由 in-app 弹窗 WebView 与浏览器扩展浮动弹窗共享（TODO-1267 要求
// assets/popup/popup.js 与两份扩展 vendor 镜像逐字节一致），但两个表面的滚动者不同：
//   - in-app：弹窗即整个 WebView 文档，document 自身滚动（window.scrollBy），
//     zoom 由 popup_settings_injection.dart 设在 document.documentElement.style.zoom；
//   - 扩展（Shadow DOM 化后）：滚动者是 shadow host（#hibiki-popup-host，
//     overflow-y:auto + max-height），#entries-container 在 shadow 内被中和为
//     overflow:visible，不可滚；zoom 由 content.js hibikiRender 设在 host.style.zoom。
//
// 历史回归（本守卫锁死）：Shadow DOM 化初版把滚轮目标写成 #entries-container 的
// scrollBy（两个表面都是 no-op：容器都不可滚）、把 zoom 改读容器的 --hibiki-popup-zoom
// 计算变量（in-app 从不下发该变量 → 恒 1）。结果：扩展弹窗与 in-app 弹窗滚轮全部失效，
// 且无任何测试能抓住（镜像字节守卫只保同步、不保行为）。
//
// flutter test cwd 是 hibiki 包根。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const List<String> popupCopies = <String>[
    'assets/popup/popup.js', // in-app 渲染器（真源）
    'assets/browser_extension/vendor/popup.js', // 扩展 bundle 镜像
    '../tools/browser-extension/vendor/popup.js', // 扩展 tools 镜像
  ];

  group('BUG-686 popup wheel-scroll surface guard', () {
    for (final String path in popupCopies) {
      group('[$path]', () {
        final String src = File(path).readAsStringSync();

        test('滚轮滚动目标按表面解析：扩展=shadow host，in-app/宿主页=window', () {
          // 表面解析器存在：只有事件 composedPath 穿过 shadow host 才返回 host。
          expect(src, contains('function __hibikiWheelScroller('),
              reason: 'popup.js 必须有 __hibikiWheelScroller 表面解析器');
          expect(src, contains('p.indexOf(host) !== -1'),
              reason: '__hibikiWheelScroller 必须用 composedPath 判定事件是否来自弹窗内');
          // 滚动分支：host 存在滚 host，否则回落 window（in-app 与宿主页路径）。
          expect(src,
              contains("scroller.scrollBy({ top: step, behavior: 'auto' })"),
              reason: '扩展表面必须滚 shadow host（真正的滚动容器）');
          expect(
              src, contains("window.scrollBy({ top: step, behavior: 'auto' })"),
              reason: 'in-app / 宿主页表面必须保留 window.scrollBy（文档滚动）');
          // 回归形态：对 #entries-container 调 scrollBy（两表面皆 no-op）不得复活。
          expect(src.contains('_hc.scrollBy'), isFalse,
              reason: '禁止把滚轮目标写成 #entries-container.scrollBy（容器不可滚=假滚动）');
        });

        test(
            'zoom 读取按表面解析：扩展=host.style.zoom，in-app=documentElement.style.zoom',
            () {
          expect(src, contains('function popupCurrentZoom(scroller)'),
              reason: 'popupCurrentZoom 必须接受表面滚动者参数');
          expect(src, contains('document.documentElement.style.zoom'),
              reason: 'in-app 必须回落读 documentElement.style.zoom（注入端设它）');
          expect(src, contains('scroller.style && scroller.style.zoom'),
              reason: '扩展表面必须读 shadow host 的 style.zoom（content.js 设它）');
          // 回归形态：读容器 --hibiki-popup-zoom 计算变量（in-app 从不下发 → 恒 1）。
          final RegExp brokenZoomRead = RegExp(
              r"popupCurrentZoom[\s\S]{0,400}?getPropertyValue\('--hibiki-popup-zoom'\)");
          expect(brokenZoomRead.hasMatch(src), isFalse,
              reason: '禁止 popupCurrentZoom 读 --hibiki-popup-zoom 计算变量');
        });
      });
    }

    test('扩展侧 zoom 真值契约：content.js hibikiRender 把 zoom 设在 shadow host 上', () {
      final String js =
          File('assets/browser_extension/content.js').readAsStringSync();
      expect(js, contains('hibikiHost.style.zoom'),
          reason: 'content.js 必须把 --hibiki-popup-zoom 落到 host.style.zoom，'
              '否则 popupCurrentZoom 在扩展表面读不到真值');
    });

    test('in-app 侧 zoom 真值契约：注入端设 documentElement.style.zoom', () {
      final String dart =
          File('lib/src/pages/implementations/popup_settings_injection.dart')
              .readAsStringSync();
      expect(dart, contains('document.documentElement.style.zoom'),
          reason: 'in-app 注入端必须继续把 zoom 设在 documentElement 上（popupCurrentZoom '
              '的 in-app 回落路径依赖它）');
    });
  });
}
