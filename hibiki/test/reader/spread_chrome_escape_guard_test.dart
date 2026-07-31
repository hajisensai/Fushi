import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show buildSpreadPageHtml;
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-1280 守卫：从书架打开书后自动切进「双页漫画」（spread）展开，就再也唤不出
/// 底栏、退不出这本书。
///
/// 根因有两层，各自独立致命：
/// ① spread 页是 [buildSpreadPageHtml] 生成的**独立文档**（继歌词 BUG-756、VN
///    BUG-1195 之后的第四种），没有正文 hoshiReader 的 onTap/onTapEmpty。它此前
///    唯一的手势是「点图片 → 弹图片查看器」，于是底栏一收起就再没有任何唤出通道，
///    用户看不到返回按钮 → 退不出书 → 回不到书架。
/// ② 点图片的 Dart 处理器是全阅读器唯一没有 reclaim 阅读焦点的手势入口，OS 焦点
///    留在 WebView，ESC 全局退出也失效（BUG-136 同族）。两张整页图铺满视口时点击
///    几乎必然命中图片，于是两条退出通道同时死掉。
///
/// 修法：spread 文档补「图片以外的点击」专桥交给 Dart 判唤出/收起（镜像歌词），
/// 点图片路径补 reclaim；并把 `spreadMode` 默认从 auto 改成 off——不再让没主动选过
/// 的用户被自动切进这套手势契约不同的文档（选项本身完整保留）。
void main() {
  const String kEmptyTapBridge = 'onSpreadTapEmpty';

  group('spread 文档有唤出底栏的通道 (BUG-1280)', () {
    const String leftUrl = 'hoshi.local/OEBPS/img/left.png';
    const String rightUrl = 'hoshi.local/OEBPS/img/right.png';
    final String html =
        buildSpreadPageHtml(leftUrl: leftUrl, rightUrl: rightUrl);

    test('图片以外的点击有专桥回传 Dart', () {
      expect(html, contains("callHandler('$kEmptyTapBridge')"),
          reason: 'spread 页没有这条桥就没有任何唤出底栏的手势 → 退不出书');
      expect(html, contains("document.addEventListener('click'"),
          reason: '专桥必须挂在文档级，才能收到 letterbox 留白 / 页缝上的点击');
    });

    test('点在图片上仍走图片查看器，不误报成空白点', () {
      // 图片的 click 会冒泡到文档级监听；没有这条短路，点图片会同时弹查看器和
      // 翻转底栏。撤回短路 → 转红。
      final int bridgeIdx = html.indexOf("callHandler('$kEmptyTapBridge')");
      final int guardIdx = html.indexOf("tagName === 'IMG'");
      expect(guardIdx, greaterThan(0), reason: '缺少 IMG 短路');
      expect(guardIdx, lessThan(bridgeIdx),
          reason: 'IMG 短路必须在回传之前，否则点图片会被当成空白点');
      expect(html, contains("callHandler('onImageTap'"),
          reason: '点图片查看原图是既有行为，不得被本次修复吃掉');
    });

    test('空白桥与 spreadReady 就绪门控互不干扰 (TODO-1229 不回退)', () {
      expect(html, contains("callHandler('spreadReady')"));
      expect(html, contains('function signalReady'));
      expect("callHandler('spreadReady')".allMatches(html).length, 1);
    });
  });

  group('Dart 侧接线 (BUG-1280)', () {
    final String source = readReaderPageSource();

    test('注册了 $kEmptyTapBridge 处理器，且无条件翻转底栏 + 夺回焦点', () {
      final int idx = source.indexOf("handlerName: '$kEmptyTapBridge'");
      expect(idx, greaterThan(0), reason: 'JS 发了桥而 Dart 不接 = 桥是死的');
      // 切到下一个 handler 注册为止，只看本处理器函数体。
      final int end = source.indexOf('addJavaScriptHandler', idx + 1);
      expect(end, greaterThan(idx));
      final String body = source.substring(idx, end);

      expect(body, contains('_handleFloatingChromeReveal()'),
          reason: '悬浮态必须走唤出/收起状态机');
      expect(body, contains('_toggleChrome()'), reason: '挤压态必须能翻转底栏');
      expect(body, contains('FocusReclaimCause.gesture'),
          reason: '不夺回 Flutter 焦点则 ESC 退出仍然失效（BUG-136）');
      expect(body.contains('tapEmptyToHideChrome'), isFalse,
          reason: 'spread 没有别的唤出途径，绝不能被「点空白隐藏控制栏」开关关死');
    });

    test('点图片路径夺回阅读焦点，ESC 仍能退出', () {
      final int idx = source.indexOf("handlerName: 'onImageTap'");
      expect(idx, greaterThan(0));
      final int end = source.indexOf('addJavaScriptHandler', idx + 1);
      expect(end, greaterThan(idx));
      final String body = source.substring(idx, end);

      expect(body, contains('FocusReclaimCause.gesture'),
          reason: '点图片把 OS 焦点交给 WebView，不 reclaim 则看完图后 ESC 退不出书');
      expect(body, contains('_openImageViewer('),
          reason: '查看原图是既有行为，reclaim 不得取代它');
    });
  });

  group('spreadMode 默认不再自动进双页 (BUG-1280)', () {
    late HibikiDatabase db;

    setUp(() {
      db = HibikiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('没设置过的用户默认 off', () {
      expect(ReaderSettings(db).spreadMode, 'off');
    });

    test('显式设过的值照旧生效（选项没被删掉）', () async {
      final ReaderSettings settings = ReaderSettings(db);
      for (final String mode in <String>['auto', 'on', 'off']) {
        await settings.setSpreadMode(mode);
        expect(settings.spreadMode, mode);
      }
    });
  });
}
