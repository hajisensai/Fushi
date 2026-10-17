// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// TODO-1366：手机阅读器自绘选区（TODO-1317/BUG-624）遗留缺口守卫 —— 两件事：
///   ① 长按即选：达到长按阈值时立刻建立并绘制锚点单字选区；无需再额外拖动。继续拖动
///      仍按命中的字符位置扩展区间，松手统一停在选区状态并弹菜单。
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

  group('① 长按即选：无需额外拖动', () {
    test('beginRangeSelection 建锚后直接绘制锚点区间（不走端点解析）', () {
      final String body = _between(
        js,
        'beginRangeSelection: function',
        'updateRangeSelection: function',
      );
      expect(body, contains('this.dragAnchor ='));
      // 锚点是**区间**：空格分词词里长按 -> 整词锚点（原地长按即选中整词），其它脚本 -> 单字。
      expect(
        body,
        contains('this.selectionAnchorAtHit(hit)'),
        reason: '锚点区间必须由 selectionAnchorAtHit 解析（词/字两种粒度）',
      );
      expect(
        body,
        contains('endNode: anchor.endNode'),
        reason: '锚点必须记下区间末端，反向拖动才不会丢词尾',
      );
      // 长按阈值触发时立刻出现选区反馈 —— 但必须**直接** collectRangeBetween 画锚点区间，
      // 不能走 updateRangeSelection（端点解析会把端点收到手指所在的字上，把刚定下的整词
      // 截成半截：手指此刻还压在锚点上）。拖动扩展由 touchmove 的 updateRangeSelection 负责。
      expect(
        body,
        contains('this.collectRangeBetween('),
        reason: '长按阈值触发时就应出现选区反馈',
      );
      expect(
        body,
        isNot(contains('this.updateRangeSelection(')),
        reason: '长按不得走端点解析（否则整词被截断）',
      );
    });

    test('updateRangeSelection 继续按当前命中字/坐标扩展选区', () {
      final String body = _between(
        js,
        'updateRangeSelection: function',
        'endRangeSelection: function',
      );
      // BUG-长按选择不灵敏：扩选走**选择**命中（不剔除标点/空白），不是查词命中——
      // 拖过句号时查词命中返回 null 会让选区停住。
      expect(body, contains('if (!endpoint) return null;'));
      expect(
        body,
        contains('this.selectionEndpointAtPoint(x, y'),
        reason:
            '本次修复：严格命中落空（字缝/行距/行尾/行首）时必须回退到「坐标 -> 文本位置」'
            '解析，否则端点被钉回锚点、选区当场塌回锚点字（用户报的手柄卡住）',
      );
      expect(body, contains('this.collectRangeBetween('));
      expect(body, contains('this.renderSelectionHighlight();'));
      // 锚点是区间：正向取 anchor.node/offset、反向取 anchor.endNode/endOffset。
      expect(body, contains('anchor.endNode'));
      expect(body, contains('anchor.endOffset'));
    });

    test('endRangeSelection 对原地与拖动长按都停在选区状态弹菜单', () {
      final String body = _between(
        js,
        'endRangeSelection: function',
        '_selectionVertical: function',
      );
      expect(
        body,
        contains('this.showSelectionHandles();'),
        reason: '长按松手必须亮起手柄（停在可调整的选区状态）',
      );
      expect(
        body,
        contains('this.fireSelectionMenu(x, y);'),
        reason: '长按松手弹选区菜单（确认动作，而非立刻查词）',
      );
      expect(body, isNot(contains('fireTextSelected')), reason: '长按松手不得直接查词');
      expect(body, isNot(contains('if (!moved')), reason: '原地长按不应再被隐藏的位移门槛拒绝');
    });
  });

  group('live handle lifecycle and host geometry contract', () {
    test('begin and every update position handles before release', () {
      final String begin = _between(
        js,
        'beginRangeSelection: function',
        'notifySelectionDragStarted: function',
      );
      final String update = _between(
        js,
        'updateRangeSelection: function',
        'endRangeSelection: function',
      );
      expect(begin, contains('this.showSelectionHandles();'));
      expect(begin, contains('this.notifySelectionDragStarted();'));
      expect(update, contains('this.positionSelectionHandles();'));
      expect(
        update.indexOf('this.positionSelectionHandles();'),
        greaterThan(update.indexOf('this.renderSelectionHighlight();')),
      );
      expect(update, isNot(contains('requestAnimationFrame')));
      expect(update, isNot(contains('setTimeout')));
    });

    test('grip start notifies host without clearing its live selection', () {
      final String wire = _between(
        js,
        '_wireHandle: function',
        'moveSelectionHandle: function',
      );
      final String start = wire.substring(
        0,
        wire.indexOf("el.addEventListener('touchmove'"),
      );
      expect(start, contains('self.notifySelectionDragStarted();'));
      expect(start, contains('self.selectionHandles[which] !== el'));
      expect(start, isNot(contains('clearSelection()')));
      final String notify = _between(
        js,
        'notifySelectionDragStarted: function',
        'liveDragAnchor: function',
      );
      expect(notify, contains("callHandler('onSelectionDragStarted')"));
    });

    test(
      'top-layer grips keep the same visible touch targets while moving',
      () {
        final String create = _between(
          js,
          'ensureSelectionHandles: function',
          '_wireHandle: function',
        );
        expect(create, contains("typeof el.showPopover === 'function'"));
        expect(create, contains("el.setAttribute('popover', 'manual')"));
        expect(create, contains('inset:auto;margin:0;'));
        final String position = _between(
          js,
          'positionSelectionHandles: function',
          'selectionHandlesRect: function',
        );
        expect(position, contains("!el.matches(':popover-open')"));
        expect(position, contains("if (el.style.display !== 'block')"));
        expect(position, isNot(contains("display = 'none'")));
        expect(position, isNot(contains('hidePopover')));
      },
    );

    test(
      'menu adds both touch bounds without changing the lookup glyph rect',
      () {
        final String menu = _between(
          js,
          'fireSelectionMenu: function',
          'collectRangeBetween: function',
        );
        expect(
          menu,
          contains('payload.handlesRect = this.selectionHandlesRect();'),
        );
        final String bounds = _between(
          js,
          'selectionHandlesRect: function',
          'showSelectionHandles: function',
        );
        expect(bounds, contains('handles.start : handles.end'));
        expect(bounds, contains('el.getBoundingClientRect()'));
        expect(bounds, contains('width: bounds.right - bounds.x'));
        expect(bounds, contains('height: bounds.bottom - bounds.y'));
        final String glyph = _between(
          js,
          'getSelectionRect: function',
          'highlightSelection: function',
        );
        expect(glyph, isNot(contains('selectionHandles')));
        expect(glyph, contains('first.start + 1'));
      },
    );
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
        'selectionHandlesRect: function',
        'hideSelectionHandles: function',
      ]) {
        expect(js, contains(api), reason: '缺手柄 API：$api');
      }
    });

    test('两个手柄元素带 data-fushi-sel-handle 标识（起/止）', () {
      final String body = _between(
        js,
        'ensureSelectionHandles: function',
        '_wireHandle: function',
      );
      expect(body, contains("'fushi-sel-handle-'"));
      expect(body, contains("'data-fushi-sel-handle'"));
      expect(body, contains("make('start')"));
      expect(body, contains("make('end')"));
      // 手柄可触（pointer-events:auto）且吃掉浏览器滚动手势（touch-action:none）。
      expect(body, contains('pointer-events:auto'));
      expect(body, contains('touch-action:none'));
    });

    test('手柄触摸 stopPropagation（不误 arm 长按/翻页）+ 松手复现菜单', () {
      final String body = _between(
        js,
        '_wireHandle: function',
        'moveSelectionHandle: function',
      );
      expect(
        body,
        contains('stopPropagation'),
        reason: '手柄触摸须阻断冒泡，防止 document 长按/页手势 arm',
      );
      expect(body, contains('preventDefault'));
      expect(body, contains('self.moveSelectionHandle(which'));
      expect(
        body,
        contains('self.fireSelectionMenu('),
        reason: '手柄拖动松手后须复现确认菜单',
      );
    });

    test('拖手柄以对侧端点为定锚，经 collectRangeBetween 实时重建选区', () {
      final String body = _between(
        js,
        'moveSelectionHandle: function',
        'positionSelectionHandles: function',
      );
      // end 手柄 -> 起点为定锚；start 手柄 -> 终点为定锚。
      expect(body, contains("which === 'end'"));
      expect(body, contains('eps.startNode'));
      expect(body, contains('eps.endNode'));
      expect(
        body,
        contains('this.collectRangeBetween('),
        reason: '手柄调整必须复用同一区间构建器',
      );
      expect(body, contains('this.renderSelectionHighlight();'));
      expect(body, contains('this.positionSelectionHandles();'));
      // 本次修复：严格命中落空时必须走「坐标 -> 文本位置」解析，不得直接 return 冻结手柄。
      expect(
        body,
        contains(
          'this.selectionEndpointAtPoint(x, y, anchorNode, anchorOffset)',
        ),
        reason: '拖手柄到字缝/行尾空白时必须仍然解析出端点（否则手柄视觉冻结）',
      );
      expect(
        body,
        contains('if (!endpoint) return;'),
        reason: '只有解析失败才允许保持旧端点（不收缩、不塌陷）',
      );
      final int resolveAt = body.indexOf('this.selectionEndpointAtPoint(');
      final int nullGuardAt = body.indexOf('if (!endpoint) return;');
      expect(resolveAt, greaterThanOrEqualTo(0));
      expect(nullGuardAt, greaterThan(resolveAt), reason: '空值守卫必须在解析之后');
    });

    test('hit window restores exact pointer events after hit AND resolve', () {
      final String body = _between(
        js,
        'selectionEndpointAtPoint: function',
        'selectionAnchorAtHit: function',
      );
      final int noneAt = body.indexOf("pointerEvents = 'none'");
      final int hitAt = body.indexOf('this.getSelectableCharacterAtPoint(');
      final int resolveAt = body.indexOf('this.resolveSelectionEndpoint(');
      final int finallyAt = body.indexOf('finally');
      final int restoreAt = body.indexOf('pointerEvents = savedStartPe;');
      expect(noneAt, greaterThanOrEqualTo(0));
      expect(hitAt, greaterThan(noneAt));
      expect(resolveAt, greaterThan(hitAt));
      expect(finallyAt, greaterThan(resolveAt));
      expect(restoreAt, greaterThan(finallyAt));
      expect(body, contains('pointerEvents = savedEndPe;'));
      expect(body, isNot(contains("|| 'auto'")));
    });

    test(
      'viewport clear protects active drags and notifies host after local cleanup',
      () {
        final String viewport = _between(
          js,
          'clearSelectionOnViewportChange: function',
          'clearSelection: function',
        );
        expect(
          viewport,
          contains('if (this.dragAnchor || this.activeHandle) return;'),
        );
        expect(
          viewport.indexOf('this.clearSelection();'),
          greaterThan(viewport.indexOf('return;')),
        );
        final String clear = js.substring(
          js.indexOf('clearSelection: function'),
        );
        final int notify = clear.indexOf("callHandler('onSelectionCleared')");
        expect(notify, greaterThan(clear.indexOf('this.selection = null;')));
        expect(notify, greaterThan(clear.indexOf('this.dragAnchor = null;')));
        expect(
          notify,
          greaterThan(clear.indexOf('this.hideSelectionHandles();')),
        );
        expect(
          clear,
          contains(
            "typeof window.flutter_inappwebview.callHandler === 'function'",
          ),
        );
        expect(clear, isNot(contains('if (!this.selection) return')));
      },
    );

    test('rollback preserves endpoint anchors and only fits viewport edges', () {
      final String body = _between(js, 'positionSelectionHandles: function', 'selectionHandlesRect: function');
      expect(body, contains('var GAP = 8;'));
      expect(body, contains('sy = sRect.top - GAP;'));
      expect(body, contains('ey = eRect.bottom + GAP;'));
      expect(body, contains('sx = sRect.left;'));
      expect(body, contains('ex = eRect.right;'));
      expect(body, contains('edgeClamped && Math.abs(sx - ex) < SIZE'));
      expect(body, contains('return Math.max(half, Math.min(extent - half, value));'));
      expect(body, contains('this.visibleContentBox()'));
      expect(body, isNot(contains('selectedRects')));
      expect(body, isNot(contains('bestStart')));
      expect(body, isNot(contains('this.selection =')));
    });
  });
}
