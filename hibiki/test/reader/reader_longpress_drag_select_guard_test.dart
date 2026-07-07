import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// TODO-1317: 手机「长按没办法选中文本（书籍）」根因守卫。
///
/// 症状根因（只读调查 a741cb57）：TODO-1279 在触屏 `@media (pointer: coarse)` 下
/// `user-select:none` 掐掉了原生文本选区（为消除长按拖选原生蓝选区 + app 查词高亮的
/// 双选区），顺带把用户的长按选中一起禁了 —— 触屏此后根本无路径选中正文。
///
/// 方向 B 根因修复（同时满足 1279 无双选区 + 1317 能选中）：**保留** user-select:none，
/// 改把移动端长按拖选手势绑到 app 自绘选区机器 —— 长按 -> beginRangeSelection 定锚，
/// 拖动 -> updateRangeSelection 扩展 CSS Custom Highlight `hoshi-selection`（绝不碰
/// window.getSelection -> 永不产生原生双选区），松手 -> endRangeSelection ->
/// fireTextSelected -> 复用现成 onTextSelected 查词/制卡管道。原地未拖动退回单击查词。
///
/// 真机长按拖选选中 + 查词/制卡、不出双选区只能真触屏 WebView 验（离屏 pointer:fine
/// 不触发 coarse），故这里用生成的 JS/CSS 源码扫描钉死契约。
void main() {
  group('app 自绘拖选 API（window.hoshiSelection）', () {
    final String js = ReaderSelectionScripts.source();

    test('暴露长按拖选三段式扩展选区 API + 共享 fireTextSelected', () {
      expect(js, contains('beginRangeSelection: function'),
          reason: '缺长按定锚 API');
      expect(js, contains('updateRangeSelection: function'),
          reason: '缺拖动扩展选区 API');
      expect(js, contains('endRangeSelection: function'),
          reason: '缺松手结算/触发 onTextSelected API');
      expect(js, contains('collectRangeBetween: function'),
          reason: '缺跨文本节点区间构建 helper');
      // 单击词路径与拖选路径都经同一 fireTextSelected 发 onTextSelected（选区->查词
      // 契约单一真相源，两路 payload 同构）。
      expect(js, contains('fireTextSelected: function'));
      expect(js, contains('return this.fireTextSelected(x, y);'),
          reason: 'selectFromPosition（tap 路径）必须复用 fireTextSelected');
    });

    test('拖选走 app CSS Custom Highlight，绝不建立原生选区（不破坏 1279 无双选区）', () {
      // 拖选高亮只经 CSS Custom Highlight 门控 + highlightSelection（与 tap 同一
      // 高亮器）；实时逐帧渲染仅在 CSS Highlight 路径（无 DOM 变更）跑。
      expect(js, contains('renderSelectionHighlight: function'));
      final int r = js.indexOf('renderSelectionHighlight: function');
      final int rEnd = js.indexOf('beginRangeSelection: function');
      final String renderBody = js.substring(r, rEnd);
      expect(renderBody, contains('window.__hoshiCssHighlightsSupported'),
          reason: '拖选实时高亮必须门控在 CSS Custom Highlight 路径');
      expect(renderBody, contains('highlightSelection'),
          reason: '拖选复用 tap 的 highlightSelection 高亮器');

      // 拖选 helper 段（collectRangeBetween..endRangeSelection）不得触碰原生选区 API
      // -- 那才会复活 1279 修掉的原生蓝选区、与 app 高亮叠成双选区。
      final int start = js.indexOf('collectRangeBetween: function');
      final int stop = js.indexOf('getSelectionRect: function');
      expect(start, greaterThanOrEqualTo(0));
      expect(stop, greaterThan(start));
      final String dragHelpers = js.substring(start, stop);
      expect(dragHelpers, isNot(contains('window.getSelection')),
          reason: '拖选绝不读/建原生选区（会造双选区）');
      expect(dragHelpers, isNot(contains('.addRange(')), reason: '拖选绝不写原生选区');
      expect(dragHelpers, isNot(contains('removeAllRanges')),
          reason: '拖选绝不动原生选区');
    });
  });

  group('长按拖选手势 IIFE（longPressDragGestureScript）', () {
    final String js = ReaderSelectionScripts.longPressDragGestureScript();

    test('长按定时器 + 移动阈值消歧（长按拖选 vs 滑动翻页/滚动）', () {
      expect(js, contains('setTimeout'));
      expect(js, contains('LPS_DELAY'), reason: '缺长按时限');
      expect(js, contains('LPS_SLOP_SQ'), reason: '缺移动阈值');
      // 未及长按时限先移动过阈值 => 判为滑动/滚动，撤销 arm（放弃拖选，让翻页/滚动）。
      expect(js, contains('> LPS_SLOP_SQ) lpsClearTimer'),
          reason: '缺「移动超阈值->放弃长按」的 swipe 消歧');
    });

    test('拖动扩展 app 选区并阻止原生滚动（非被动 touchmove）', () {
      expect(js, contains('updateRangeSelection'));
      expect(js, contains('preventDefault'), reason: '拖选须阻止原生滚动');
      // 只有非被动监听器才能 preventDefault 阻止连续模式原生滚动。
      expect(js, contains('{passive: false}'),
          reason: 'touchmove/touchend 须非被动才能 preventDefault');
    });

    test('松手触发 onTextSelected；原地未拖动退回单击查词', () {
      expect(js, contains('endRangeSelection'));
      // 原地长按（未拖动）不落多字选区，退回 selectText 单击词查询，保住慢速点词。
      expect(js, contains('selectText'), reason: '缺「长按未拖动->退回单击查词」兜底');
    });

    test('置全局标志与翻页/边界手势消歧', () {
      expect(js, contains('window.__hoshiTextSelectDragActive = true'),
          reason: '缺与 _gestureEnd(翻页)/_bEnd(跨章) 消歧的全局标志');
    });

    test('时限/阈值/单击兜底长度可配置', () {
      final String custom = ReaderSelectionScripts.longPressDragGestureScript(
        delayMs: 321,
        slop: 7,
        maxLength: 250,
      );
      expect(custom, contains('var LPS_DELAY = 321;'));
      expect(custom, contains('var LPS_SLOP_SQ = 49;'));
      expect(custom, contains('var LPS_MAXLEN = 250;'));
    });
  });

  group('翻页/边界手势对拖选让路（消歧守卫）', () {
    test('连续模式边界跨章手势见到拖选标志即让路（不误跨章）', () {
      final String js =
          ReaderPaginationScripts.shellScript(continuousMode: true);
      expect(js, contains('if (window.__hoshiTextSelectDragActive) return;'),
          reason: '_bEnd（跨章）必须在拖选进行时让路');
    });
  });

  group('TODO-1279 无双选区未被破坏', () {
    Future<ReaderSettings> defaultSettings(HibikiDatabase db) async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      return settings;
    }

    test('触屏 user-select:none（pointer: coarse）仍在--拖选走 app 高亮不复活原生选区', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = await defaultSettings(db);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('@media (pointer: coarse)'),
          reason: '1279 触屏门控被删--原生蓝选区会复活成双选区');
      expect(css, contains('user-select: none'));
      expect(css, contains('-webkit-touch-callout: none'));
    });
  });
}
