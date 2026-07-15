import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

/// TODO-1366：手机阅读器自绘选区（TODO-1317/BUG-624）遗留缺口守卫 —— 两件事：
///   ① 短选消歧：拖选意图 = 物理指位移过一个小像素阈值（`dragMoveSlopSq`），而不再是
///      「越过一个字框」。短拖（停在同一字框内）也算拖选 → 松手停在选区状态、不再被当成
///      原地长按而立刻查词；真正原地不动（抖动 < 阈值）仍退回单击查词（TODO-971）。
///   ② 起止触摸手柄：拖选出的 app 自绘选区补两个可拖的起止手柄，随书写模式（横排 /
///      竖排 vertical-rl）正确定位，拖手柄经 `collectRangeBetween`（对侧端点为定锚）实时
///      调整选区；手柄绝不触碰 `window.getSelection()`（不复活 TODO-1279 掉的原生双选区）。
///
/// 真机触屏 WebView 才能跑真手势 + 手柄拖动（离屏 pointer:fine 不触发 coarse，且无法真
/// 命中测试字符矩形），故用生成 JS 源码扫描钉死契约。
String _between(String src, String startMarker, String endMarker) {
  final int start = src.indexOf(startMarker);
  final int end = src.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
  expect(end, greaterThan(start), reason: '找不到 $endMarker（在 $startMarker 之后）');
  return src.substring(start, end);
}

void main() {
  final String js = ReaderSelectionScripts.source();

  group('① 短选消歧：像素位移阈值（拖选意图），不再只认越字框', () {
    test('field 块声明 dragStartX/dragStartY + dragMoveSlopSq', () {
      expect(js, contains('dragStartX: 0,'), reason: '缺长按屏幕锚点 X');
      expect(js, contains('dragStartY: 0,'), reason: '缺长按屏幕锚点 Y');
      expect(js, contains('dragMoveSlopSq:'), reason: '缺拖选像素阈值');
    });

    test('beginRangeSelection 记录长按屏幕锚点', () {
      final String body = _between(js, 'beginRangeSelection: function',
          'updateRangeSelection: function');
      expect(body, contains('this.dragStartX = x;'));
      expect(body, contains('this.dragStartY = y;'));
    });

    test('updateRangeSelection 用像素位移过阈值判定 dragMoved（短拖也算拖选）', () {
      final String body = _between(
          js, 'updateRangeSelection: function', 'endRangeSelection: function');
      // 像素距离平方与阈值比较后置 dragMoved=true（短拖停在同一字框内也算）。
      expect(body, contains('this.dragStartX'));
      expect(body, contains('this.dragStartY'));
      expect(body, contains('this.dragMoveSlopSq'));
      expect(body, contains('this.dragMoved = true;'));
    });

    test('endRangeSelection 真拖动仍停在选区状态弹菜单，原地未拖动退回查词', () {
      final String body = _between(
          js, 'endRangeSelection: function', '_selectionVertical: function');
      // 真拖动：抬起手柄 + 弹菜单（确认动作触发查词），不再直接 fireTextSelected。
      expect(body, contains('this.showSelectionHandles();'),
          reason: '真拖动松手必须亮起手柄（停在可调整的选区状态）');
      expect(body, contains('this.fireSelectionMenu(x, y);'),
          reason: '真拖动松手弹选区菜单（确认动作，而非立刻查词）');
      expect(body, isNot(contains('fireTextSelected')),
          reason: '拖选松手不得直接查词（那就是被投诉的「短选立刻查词」）');
      // 原地未拖动（!moved）仍清选区 -> 调用方 selectText 单击查词（TODO-971）。
      expect(body, contains('this.clearSelection();'));
    });
  });

  group('② 起止触摸手柄：状态、书写模式定位、拖动语义、无原生选区', () {
    test('field 块声明 selectionHandles / activeHandle 状态', () {
      expect(js, contains('selectionHandles: null,'));
      expect(js, contains('activeHandle: null,'));
    });

    test('手柄 API 齐全（创建/接线/移动/定位/显隐）', () {
      for (final String api in <String>[
        'selectionEndpoints: function',
        'ensureSelectionHandles: function',
        '_wireHandle: function',
        'moveSelectionHandle: function',
        'positionSelectionHandles: function',
        'showSelectionHandles: function',
        'hideSelectionHandles: function',
      ]) {
        expect(js, contains(api), reason: '缺手柄 API：$api');
      }
    });

    test('两个手柄元素带 data-hoshi-sel-handle 标识（起/止）', () {
      final String body = _between(
          js, 'ensureSelectionHandles: function', '_wireHandle: function');
      expect(body, contains("'hoshi-sel-handle-'"));
      expect(body, contains("'data-hoshi-sel-handle'"));
      expect(body, contains("make('start')"));
      expect(body, contains("make('end')"));
      // 手柄可触（pointer-events:auto）且吃掉浏览器滚动手势（touch-action:none）。
      expect(body, contains('pointer-events:auto'));
      expect(body, contains('touch-action:none'));
    });

    test('手柄触摸 stopPropagation（不误 arm 长按/翻页）+ 松手复现菜单', () {
      final String body = _between(
          js, '_wireHandle: function', 'moveSelectionHandle: function');
      expect(body, contains('stopPropagation'),
          reason: '手柄触摸须阻断冒泡，防止 document 长按/页手势 arm');
      expect(body, contains('preventDefault'));
      expect(body, contains('self.moveSelectionHandle(which'));
      expect(body, contains('self.fireSelectionMenu('),
          reason: '手柄拖动松手后须复现确认菜单');
    });

    test('拖手柄以对侧端点为定锚，经 collectRangeBetween 实时重建选区', () {
      final String body = _between(js, 'moveSelectionHandle: function',
          'positionSelectionHandles: function');
      // end 手柄 -> 起点为定锚；start 手柄 -> 终点为定锚。
      expect(body, contains("which === 'end'"));
      expect(body, contains('eps.startNode'));
      expect(body, contains('eps.endNode'));
      expect(body, contains('this.collectRangeBetween('),
          reason: '手柄调整必须复用同一区间构建器');
      expect(body, contains('this.renderSelectionHighlight();'));
      expect(body, contains('this.positionSelectionHandles();'));
    });

    test('BUG-765：拖手柄 hit-test 时临时熄灭手柄 pointer-events（防命中手柄自身冻结）', () {
      final String body = _between(js, 'moveSelectionHandle: function',
          'positionSelectionHandles: function');
      // 手指压在手柄上，若不让手柄对命中透明，elementFromPoint/caretPositionFromPoint
      // 命中的是最上层手柄 div（非文本节点）→ getCharacterAtPoint 返回 null → 手柄冻结
      // 拖不动。hit-test 前必须置 pointer-events:none，取字后还原。
      expect(body, contains("pointerEvents = 'none'"),
          reason: 'hit-test 前必须把两手柄 pointer-events 置 none');
      // 取字后还原（否则手柄永久不可点）。
      expect(body, contains("|| 'auto'"),
          reason: 'hit-test 后必须还原手柄 pointer-events');
      // 还原发生在拿到 hit 之后（顺序正确）。
      final int noneAt = body.indexOf("pointerEvents = 'none'");
      final int hitAt = body.indexOf('this.getCharacterAtPoint(x, y)');
      final int restoreAt = body.indexOf("|| 'auto'");
      expect(noneAt, greaterThanOrEqualTo(0));
      expect(hitAt, greaterThan(noneAt), reason: '熄灭必须在 hit-test 之前');
      expect(restoreAt, greaterThan(hitAt), reason: '还原必须在 hit-test 之后');
    });

    test('手柄定位按书写模式分支（横排 vs 竖排 vertical-rl）', () {
      final String body = _between(js, 'positionSelectionHandles: function',
          'showSelectionHandles: function');
      expect(body, contains('this._selectionVertical()'), reason: '定位必须读书写模式');
      expect(body, contains('if (vertical)'), reason: '竖排/横排必须各自定位（不是一套硬编码坐标）');
      expect(body, contains('_glyphRect'));
      // _selectionVertical 走 hoshiReader.isVertical()（与 caret 同源）。
      final String vBody = _between(
          js, '_selectionVertical: function', 'selectionEndpoints: function');
      expect(vBody, contains('window.hoshiReader'));
      expect(vBody, contains('isVertical'));
    });

    test('clearSelection 同步隐藏手柄（无选区必无悬空手柄）', () {
      final String body = js.substring(js.indexOf('clearSelection: function'));
      expect(body, contains('this.hideSelectionHandles();'));
    });

    test('手柄段绝不建立/读写原生选区（不复活 TODO-1279 双选区）', () {
      // endRangeSelection..getSelectionRect 之间涵盖全部手柄方法。
      final String region = _between(
          js, 'endRangeSelection: function', 'getSelectionRect: function');
      expect(region, isNot(contains('window.getSelection')),
          reason: '手柄绝不读/建原生选区');
      expect(region, isNot(contains('.addRange(')), reason: '手柄绝不写原生选区');
      expect(region, isNot(contains('removeAllRanges')), reason: '手柄绝不动原生选区');
    });
  });

  group('长按手势 IIFE 对手柄触摸让路', () {
    test('lpsAllowed 排除手柄元素（触手柄不 arm 新长按）', () {
      final String gestureJs =
          ReaderSelectionScripts.longPressDragGestureScript();
      expect(gestureJs, contains('[data-hoshi-sel-handle]'),
          reason: '长按 arm 白名单必须排除起止手柄元素');
    });
  });

  group('BUG-765 续修：getCaretRange caretPositionFromPoint 命中非文本节点不早退', () {
    test('caretPositionFromPoint 仅在文本节点走快路，非文本落几何兜底', () {
      final String body = _between(
          js, 'getCaretRange: function', 'getCharacterAtPoint: function');
      // 命中判据必须校验 TEXT_NODE（旧代码 if(!pos) return 无条件早退，押注
      // caretPositionFromPoint 尊重 pointer-events，真机不成立 → 拖手柄冻结）。
      expect(body, contains('nodeType === Node.TEXT_NODE'),
          reason: 'caretPositionFromPoint 结果必须校验是文本节点才走快路');
      // 非文本节点（遮挡的手柄 div / documentElement）不得早退，必须落到下方
      // elementFromPoint + 最近字符几何兜底（对 pointer-events:none 稳定生效）。
      final int caretIdx = body.indexOf('caretPositionFromPoint');
      final int fallbackIdx = body.indexOf('elementFromPoint');
      expect(caretIdx, greaterThanOrEqualTo(0));
      expect(fallbackIdx, greaterThan(caretIdx),
          reason: 'elementFromPoint 几何兜底必须在 caretPositionFromPoint 之后可达（非早退）');
      // 不得再有「拿到 pos 就无条件 setStart 返回」的旧早退。
      expect(body, isNot(contains('if (!pos) return null;')),
          reason: '旧无条件早退必须移除，改为 TEXT_NODE 校验 + 兜底');
    });
  });

  group('BUG-765 续修：手柄外观（主题色 + 触控盒 + 内层圆钮，去刺眼橙）', () {
    test('手柄用主题变量 var(--hoshi-sel-handle) 上色，不再硬编码刺眼橙 + 发光', () {
      final String body = _between(
          js, 'ensureSelectionHandles: function', '_wireHandle: function');
      expect(body, contains('var(--hoshi-sel-handle'),
          reason: '圆钮颜色须走主题变量（reader CSS 从 linkColor 下发，随主题变）');
      // 内层实心圆钮存在（外层是透明触控盒）。
      expect(body, contains("'data-hoshi-sel-ball'"), reason: '须有内层视觉圆钮元素');
      // 旧刺眼橙 + 双重发光 box-shadow 必须移除。
      expect(body, isNot(contains('rgba(255,138,0,0.98)')),
          reason: '旧刺眼橙背景必须移除');
      expect(body, isNot(contains('0 0 4px rgba(255,138,0,0.9)')),
          reason: '旧橙色发光 box-shadow 必须移除');
    });
  });
}
