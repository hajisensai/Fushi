// BUG-2415 回归守卫：查词弹窗「瞬时滚动」（lookup.popup_instant_scroll）的**触摸**半边。
//
// 原始 bug：BUG-2284 只把 window.__fushiPopupInstantScroll 接进了 wheel 监听，可墨水屏
// 设备（Android e-ink 阅读器）上没有滚轮——用户是用手指上下滑弹窗的。那条路径此前
// 100% 走 WebView 原生滚动：逐帧连续位移 + 松手惯性 fling，正是设置文案（"Jump the
// lookup popup by fixed distances without animated scrolling for e-ink screens."）
// 承诺要消掉的东西。于是在唯一真正的墨水屏输入方式上，这个开关等于没接线。
//
// 单测里没有真 WebView，滚动本身无法直接断言（与 popup_instant_scroll_guard_test 同
// 处境），所以本守卫钉死的是「开关 → 触摸行为」这条线上每一段**载荷位**的存在性：
// 任何一段被摘掉，触摸路径都会静默退回原生惯性滚动，而 UI 上看不出任何差别。
//
// flutter test cwd 是 fushi 包根。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const List<String> popupCopies = <String>[
    'assets/popup/popup.js', // in-app 渲染器（真源）
    'assets/browser_extension/vendor/popup.js', // 扩展 bundle 镜像
    '../tools/browser-extension/vendor/popup.js', // 扩展 tools 镜像
  ];

  group('BUG-2415 popup touch instant-scroll guard', () {
    for (final String path in popupCopies) {
      late String src;

      setUp(() => src = File(path).readAsStringSync());

      test('[$path] 触摸路径真的消费 __fushiPopupInstantScroll', () {
        // 触摸接管的入口必须读这个偏好——否则开关对手指无效（原始 bug）。
        final int startAt = src.indexOf('function __fushiPopupEinkTouchStart(');
        expect(
          startAt,
          greaterThanOrEqualTo(0),
          reason: '触摸接管必须有独立入口 __fushiPopupEinkTouchStart',
        );
        final int moveAt = src.indexOf('function __fushiPopupEinkTouchMove(');
        expect(moveAt, greaterThan(startAt));
        final String startBody = src.substring(startAt, moveAt);
        expect(
          startBody,
          contains('window.__fushiPopupInstantScroll'),
          reason: 'touchstart 必须按偏好决定是否接管，否则开关对触摸无效',
        );
      });

      test('[$path] touchmove 是 passive:false 且真的 preventDefault', () {
        // 这两条是「掐掉原生惯性」的全部载荷：passive 默认为 true 时
        // preventDefault 静默失效，惯性照旧，bug 完全复发且无任何报错。
        expect(
          src,
          contains(
            "document.addEventListener('touchmove', __fushiPopupEinkTouchMove, "
            '{ passive: false });',
          ),
          reason: 'touchmove 必须非 passive，否则 preventDefault 无效、惯性照旧',
        );
        final int moveAt = src.indexOf('function __fushiPopupEinkTouchMove(');
        final int tailAt = src.indexOf(
          "if (typeof chrome !== 'undefined'",
          moveAt,
        );
        expect(tailAt, greaterThan(moveAt));
        final String moveBody = src.substring(moveAt, tailAt);
        expect(
          moveBody,
          contains('e.preventDefault();'),
          reason: '不 preventDefault 就掐不掉原生滚动与松手惯性',
        );
      });

      test('[$path] 跳跃是固定步长，不按手指位移比例缩放', () {
        // 设置文案承诺的是「按固定距离瞬时跳动」。步长必须来自视口比例，而不是
        // travel 的函数——后者就退化回连续滚动了（只是换了个实现）。
        expect(src, contains('POPUP_EINK_TOUCH_VIEWPORT_FRACTION'));
        expect(src, contains('POPUP_EINK_TOUCH_MIN_STEP'));
        expect(src, contains('function popupEinkTouchStep('));
        final int moveAt = src.indexOf('function __fushiPopupEinkTouchMove(');
        final int tailAt = src.indexOf(
          "if (typeof chrome !== 'undefined'",
          moveAt,
        );
        final String moveBody = src.substring(moveAt, tailAt);
        expect(
          moveBody.contains('travel *'),
          isFalse,
          reason: '步长不得按手指位移比例缩放——那就不是「固定距离跳动」了',
        );
        expect(
          moveBody,
          contains('popupEinkTouchStep('),
          reason: '每帧的步长必须实时解析（视口会随 zoom/旋转变）',
        );
      });

      test('[$path] 锚点按步长推进 = 量化的 1:1 跟手', () {
        // 跳完一步后锚点必须跟着走一步，手指要再滑满一步才触发下一跳。少了这行，
        // travel 永远 >= step，一次 touchmove 就会把内容一路跳到底。
        final int moveAt = src.indexOf('function __fushiPopupEinkTouchMove(');
        final int tailAt = src.indexOf(
          "if (typeof chrome !== 'undefined'",
          moveAt,
        );
        final String moveBody = src.substring(moveAt, tailAt);
        expect(
          moveBody,
          contains('_popupEinkTouchAnchorY -= dir * step;'),
          reason: '锚点不推进 → 一次 touchmove 跳到底',
        );
        expect(
          moveBody,
          contains('POPUP_EINK_TOUCH_MAX_STEPS_PER_MOVE'),
          reason: '补步循环必须有防御性上限，杜绝异常视口下的死循环',
        );
      });

      test('[$path] 三条整轮豁免都在 touchstart 判', () {
        // 接管必须在 touchstart 一次定死：Chromium 只在某帧 touchmove 未被
        // preventDefault 时才启动原生滚动，一旦启动后续帧 cancelable 就变 false。
        // 留「判轴死区」不拦截，Android ~8dp touch slop 恰好落在死区里 → 原生滚动
        // 抢先起步，变成原生与瞬跳同时位移。所以豁免只能在 touchstart 判。
        final int startAt = src.indexOf('function __fushiPopupEinkTouchStart(');
        final int moveAt = src.indexOf('function __fushiPopupEinkTouchMove(');
        final String startBody = src.substring(startAt, moveAt);

        expect(
          startBody,
          contains('e.touches.length !== 1'),
          reason: '多指（缩放/系统手势）必须整轮不接管',
        );
        expect(
          startBody,
          contains('sel.isCollapsed'),
          reason: '已有选区时不接管——选区手柄拖动也是 touchmove，拦了就拖不动手柄',
        );
        expect(
          startBody,
          contains('__fushiPopupEinkTouchHasHorizontalScroll('),
          reason: '手指落在真正横向溢出的祖先上时必须整轮交还，否则横滚被一起掐掉',
        );
        expect(
          startBody,
          contains('__fushiEventInsidePopup(e)'),
          reason: '扩展镜像与宿主页共用 document，必须只消费弹窗内的事件',
        );
      });

      test('[$path] 横向溢出判据看实际溢出，不是只看 CSS 声明', () {
        // popup.css 里 .expression-scroll 常驻 overflow-x:auto，但短词头根本没溢出。
        // 只看声明会让绝大多数条目都命中豁免，开关等于又没接线。
        final int fnAt = src.indexOf(
          'function __fushiPopupEinkTouchHasHorizontalScroll(',
        );
        expect(fnAt, greaterThanOrEqualTo(0));
        final int endAt = src.indexOf(
          'function __fushiPopupEinkTouchStart(',
          fnAt,
        );
        final String body = src.substring(fnAt, endAt);
        expect(
          body,
          contains('el.scrollWidth > el.clientWidth'),
          reason: '必须以实际溢出为判据',
        );
        expect(
          body,
          allOf(contains("'auto'"), contains("'scroll'")),
          reason: '还要确认该祖先真的可横滚（overflowX auto/scroll）',
        );
      });

      test('[$path] 扩展镜像刻意不挂 document 级触摸监听', () {
        // 扩展里 popup.js 与宿主页共用 document，非 passive 的 touchmove 会掐掉宿主页
        // 整页的合成器快速滚动路径（wheel 那条为此专门只挂 shadow host，BUG-1078）。
        // 三镜像逐字节一致，差别只能在运行期分支上。
        final int tailAt = src.indexOf(
          "if (typeof chrome !== 'undefined' && !!(chrome.runtime && "
          'chrome.runtime.id)) {',
          src.indexOf('function __fushiPopupEinkTouchMove('),
        );
        expect(
          tailAt,
          greaterThanOrEqualTo(0),
          reason: '触摸监听的挂载必须按 in-app / 扩展分支',
        );
        final String tail = src.substring(tailAt);
        final int elseAt = tail.indexOf('} else {');
        expect(elseAt, greaterThan(0));
        expect(
          tail.substring(0, elseAt).contains('addEventListener'),
          isFalse,
          reason: '扩展分支不得挂任何 document 级触摸监听',
        );
      });
    }

    test('三镜像的触摸块逐字节一致（TODO-1267 parity 的子集自检）', () {
      final List<String> blocks = popupCopies.map((String path) {
        final String src = File(path).readAsStringSync();
        final int from = src.indexOf('/* BUG-2415:');
        expect(from, greaterThanOrEqualTo(0), reason: '$path 缺少 BUG-2415 触摸块');
        final int to = src.indexOf(
          'let _popupMouseDownPos = null;',
          from,
        );
        expect(to, greaterThan(from));
        return src.substring(from, to);
      }).toList();
      expect(blocks[1], blocks[0]);
      expect(blocks[2], blocks[0]);
    });

    test('偏好本身仍经既有通道下发（触摸半边不新增下发通道）', () {
      // 触摸路径读的是 BUG-2284 已经铺好的同一个全局。这条钉死「没有另起炉灶」，
      // 否则两个半边会各读各的、设置只对其中一半生效。
      final String injection = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
      expect(
        injection,
        contains(
          r'window.__fushiPopupInstantScroll = ${appModel.popupInstantScroll};',
        ),
      );
      for (final String path in popupCopies) {
        final String src = File(path).readAsStringSync();
        final int startAt = src.indexOf('function __fushiPopupEinkTouchStart(');
        final int moveAt = src.indexOf('function __fushiPopupEinkTouchMove(');
        expect(
          src.substring(startAt, moveAt),
          isNot(contains('__fushiPopupInstantTouchScroll')),
          reason: '$path 触摸半边不得另起一个偏好全局',
        );
      }
    });
  });
}
