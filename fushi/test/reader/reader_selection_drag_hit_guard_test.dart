// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——那里删掉
// 模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
//
// 写法纪律：所有断言都在 test() 体内（含 indexOf/substring 这类取值）——`expect()` 只许在
// 测试体内调用，放在 main() 顶层（收集期）会整文件报错、连累整个分片。
// 几何行为（回放拖动坐标）由 reader_selection_drag_hit_behavior_test.dart（Node 真跑生产 JS）
// 守；这里只钉源码契约：API 存在、优先级顺序、不碰原生选区、单词/字符两种粒度。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// 移动端 EPUB 文本选择「坐标 -> 文本位置」解析层守卫。
///
/// 症状（用户报）：长按进入选择、拖选/拖手柄时，手指落在**字缝、行尾、行首、行距、段间空白**
/// 上（没有字符矩形盖住手指），手柄停止移动，松手再拖也过不去。
///
/// 根因：拖动路径只认 `getSelectableCharacterAtPoint`（要求手指压在字符矩形上，精确或 ±6px），
/// 落空后 `updateRangeSelection` 把端点钉回锚点（选区塌回锚点字）、`moveSelectionHandle`
/// 直接 return（手柄冻结）。修法不是把 ±6px 调大，而是补一层真正的坐标解析：
///   ① 原生 caret API（`caretPositionFromPoint` / `caretRangeFromPoint`）——Chrome WebView 与
///      WKWebView 都实现「最近 caret」clamp 语义；
///   ② 拿不到 / 被手柄遮挡 / 结果不可见时的几何兜底：在命中元素所在文本块里按「交叉轴最近
///      -> 行内轴最近」逐字符扫描（与布局引擎 `getOffsetForHorizontal` 同一判据）；
///   ③ 端点规范化 + 单词/字符粒度吸附 + BUG-1797 可见性收口。
void main() {
  test('解析层 API 齐全（端点解析入口 / 原生 caret / 几何兜底 / 规范化）', () {
    final String js = ReaderSelectionScripts.source();
    for (final String api in <String>[
      'charRangeAt: function',
      'charAxisBounds: function',
      'compareTextPosition: function',
      'spaceDelimitedWordBounds: function',
      'normalizeEndpoint: function',
      'caretHasVisibleNeighbour: function',
      'nativeCaretAtPoint: function',
      'geometricCaretAtPoint: function',
      'caretPositionAtPoint: function',
      'resolveSelectionEndpoint: function',
      'selectionEndpointAtPoint: function',
      'selectionAnchorAtHit: function',
    ]) {
      expect(js, contains(api), reason: '缺解析层 API：$api');
    }
  });

  test('三级优先级：原生 caret 快路在前，几何兜底在后（都不是早退）', () {
    final String js = ReaderSelectionScripts.source();
    final int native = js.indexOf('nativeCaretAtPoint: function');
    final int geometric = js.indexOf('geometricCaretAtPoint: function');
    final int driver = js.indexOf('caretPositionAtPoint: function');
    final int resolve = js.indexOf('resolveSelectionEndpoint: function');
    expect(native, greaterThan(0));
    expect(geometric, greaterThan(native));
    expect(driver, greaterThan(geometric));
    expect(resolve, greaterThan(driver));
    // 驱动函数必须是「先 native、失败再 geometric」。
    final String driverBody = js.substring(driver, resolve);
    expect(driverBody, contains('nativeCaretAtPoint'));
    expect(
      driverBody.indexOf('geometricCaretAtPoint'),
      greaterThan(driverBody.indexOf('nativeCaretAtPoint')),
      reason: '原生快路失败后必须可达几何兜底',
    );
  });

  test('原生 caret 路径：两条 WebView 方言 + 只认文本节点 + 可见性收口', () {
    final String js = ReaderSelectionScripts.source();
    final String body = js.substring(
      js.indexOf('nativeCaretAtPoint: function'),
      js.indexOf('geometricCaretAtPoint: function'),
    );
    expect(
      body,
      contains('document.caretPositionFromPoint'),
      reason: 'Chromium / Android WebView 的 caretPositionFromPoint',
    );
    expect(
      body,
      contains('document.caretRangeFromPoint'),
      reason: 'WKWebView / 老 Blink 的 caretRangeFromPoint',
    );
    // BUG-765：手柄 div / documentElement 的命中不可信，只认文本节点结果。
    expect(body, contains('Node.TEXT_NODE'));
    // BUG-1797：分页页边距带里被 clip 掉的相邻页字符不得成为端点。
    expect(body, contains('caretHasVisibleNeighbour'));
    expect(body, contains('isFurigana'), reason: '振假名不能被 caret 快路命中');
  });

  test('几何兜底按「交叉轴 -> 行内轴」定行/定 caret（与布局引擎同判据）', () {
    final String js = ReaderSelectionScripts.source();
    final String body = js.substring(
      js.indexOf('geometricCaretAtPoint: function'),
      js.indexOf('caretPositionAtPoint: function'),
    );
    // 交叉轴（横排 y / 竖排 x）先定行 —— 否则拖到行尾右侧时端点会跳到下一行。
    expect(body, contains('crossDist'), reason: '缺交叉轴距离');
    expect(body, contains('inlineDist'), reason: '缺行内轴距离');
    expect(
      body,
      contains('crossCoord < bounds.crossLo'),
      reason: '交叉轴距离必须按行盒上下沿算',
    );
    // 行内轴按字符矩形中点取前沿/后沿（Layout.getOffsetForHorizontal）——行尾右侧空白
    // clamp 到行尾、行首左侧空白 clamp 到行首。
    expect(body, contains('afterGlyph'), reason: '缺「点越过字符中线取后沿」的前沿/后沿规则');
    // 有界：根是命中元素所在的块（不落整个 body），且有字符数上限。
    expect(
      body,
      contains('this._hitElementUnderPoint('),
      reason: '命中元素必须经「跳过手柄」的取元素层（手柄不能被当成文本块）',
    );
    expect(body, contains('closest('));
    expect(body, contains('scanned <'), reason: '逐字符扫描必须有上界（防超大块卡住拖动帧）');
    // 可见性收口：不可见字符不参与竞争（BUG-1797）。
    expect(body, contains('charRangeVisible'));
    // 取元素层本身：优先 elementsFromPoint（拿元素栈才跳得掉手柄），老 WebView 退回
    // elementFromPoint，并且必须真的认识手柄标记——否则手指压在手柄上时几何兜底会把
    // 手柄（一个 div）当成文本块，扫不到任何字符、端点解析恒失败。
    final String hitBody = js.substring(
      js.indexOf('_hitElementUnderPoint: function'),
      js.indexOf('geometricCaretAtPoint: function'),
    );
    expect(hitBody, contains('elementsFromPoint'));
    expect(hitBody, contains('elementFromPoint'));
    expect(
      hitBody,
      contains("'[data-fushi-sel-handle]'"),
      reason: '手柄标记必须被识别并跳过',
    );
  });

  test('端点规范化：跳过的纯空白 / 振假名节点必须挪到正文节点', () {
    final String js = ReaderSelectionScripts.source();
    final String body = js.substring(
      js.indexOf('normalizeEndpoint: function'),
      js.indexOf('caretHasVisibleNeighbour: function'),
    );
    // Filtered endpoints do not obey the range walker's contract. Directional
    // failure alone is not proof that no body text exists (e.g. a leading indent).
    expect(body, contains('createWalker'));
    expect(body, contains('isFurigana'));
    expect(
      body,
      contains(r'/^[\s　]*$/'),
      reason: '纯空白文本节点判据必须与 createWalker 的 REJECT 判据一致',
    );
    expect(body, contains('walker.nextNode()'), reason: '正向顺延到下一个正文节点');
    expect(body, contains('previousNode()'), reason: '反向回退到上一个正文节点');
  });

  test('端点解析：严格命中优先（零回归）+ 落空才走坐标解析 + 端点必须可见', () {
    final String js = ReaderSelectionScripts.source();
    final String body = js.substring(
      js.indexOf('resolveSelectionEndpoint: function'),
      js.indexOf('selectionAnchorAtHit: function'),
    );
    expect(body, contains('if (strictHit)'), reason: '手指压在字符矩形上时必须沿用严格命中结果');
    expect(body, contains('this.caretPositionAtPoint('));
    // caret 是字符之间的位置：正向取 caret 前一个字符、反向取 caret 所在字符。
    expect(body, contains('this.charBefore(caret.node, caret.offset)'));
    expect(body, contains('this.charAt(caret.node, caret.offset)'));
    // BUG-1797：端点字符必须可见，否则页边距带里的相邻页字符会被选中。
    expect(body, contains('charRangeVisible'), reason: '端点可见性收口（BUG-1797）');
    expect(body, contains('return null'), reason: '解析失败要交给调用方保持旧端点');
  });

  group('单词选择模式（Android 手柄拖动语义）', () {
    test('空格分词词的边界用与扫描模型同一套真值', () {
      final String js = ReaderSelectionScripts.source();
      final String body = js.substring(
        js.indexOf('spaceDelimitedWordBounds: function'),
        js.indexOf('normalizeEndpoint: function'),
      );
      // BUG-2056 的字母集/词内撇号判据 —— 不另造一套「什么算单词」的定义。
      expect(body, contains('isSpaceDelimitedLetter'));
      expect(body, contains('isIntraWordApostrophe'));
    });

    test('端点不做词边界吸附：拖动逐字跟随手指（拉丁文也能选词内任意字符）', () {
      final String js = ReaderSelectionScripts.source();
      // 用户反馈：拉丁文本只能按整词进退、选不到词内任意字符，与浏览器/平台实现不一致。
      // 词边界吸附整条已移除 —— 端点解析只把坐标换算成端点字符，不再按空格分词放宽。
      expect(
        js,
        isNot(contains('snapEndpointToWord')),
        reason: '端点不得吸附词边界（拖动必须逐字精确）',
      );
      expect(
        js,
        isNot(contains('wordSelectMode')),
        reason: '「单词选择模式」开关随之移除：CJK 与拉丁都走同一条逐字路径',
      );
      final String endpointBody = js.substring(
        js.indexOf('resolveSelectionEndpoint: function'),
        js.indexOf('selectionAnchorAtHit: function'),
      );
      expect(
        endpointBody,
        isNot(contains('spaceDelimitedWordBounds')),
        reason: '端点解析不得再碰空格分词边界',
      );
      // 长按仍然选中整词：那是**锚点**的语义（selectionAnchorAtHit），与拖动端点无关。
      expect(
        js.substring(
          js.indexOf('selectionAnchorAtHit: function'),
          js.indexOf('getSentenceContext: function'),
        ),
        contains('spaceDelimitedWordBounds'),
        reason: '锚点仍按词定区间，长按选中整词的语义不变',
      );
    });

    test('拖动端点始终跟随手指；长按原地不动才保留锚点区间', () {
      final String js = ReaderSelectionScripts.source();
      final int begin = js.indexOf('beginRangeSelection: function');
      final int update = js.indexOf('updateRangeSelection: function');
      final int end = js.indexOf('endRangeSelection: function');
      expect(begin, greaterThan(0));
      expect(update, greaterThan(begin));
      expect(end, greaterThan(update));
      // 长按：直接画锚点区间，不经过端点解析（手指还压在这次长按的锚点上，解析会把刚
      // 定下的词截成手指所在的那一个字）。
      final String beginBody = js.substring(begin, update);
      expect(beginBody, contains('this.collectRangeBetween('));
      expect(
        beginBody,
        isNot(contains('this.updateRangeSelection(')),
        reason: '长按必须直接画锚点区间，不能走端点解析',
      );
      // 拖动：端点**始终**解析 —— 没有「落在锚点区间内就维持锚点」的粘滞分支（那会让
      // 拉丁词永远只按整词进退、选不到词内的任意字符）。
      final String updateBody = js.substring(update, end);
      expect(updateBody, contains('this.selectionEndpointAtPoint('));
      expect(updateBody, contains('if (!endpoint) return null;'));
      expect(updateBody, contains('anchor.moved = true'));
      expect(updateBody, contains('if (!anchor.moved) return'));
      expect(
        updateBody,
        isNot(contains('anchor.endNode, anchor.endOffset) > 0')),
        reason: '不得保留锚点区间粘滞判定',
      );
      // Only an actual drag resolves the last release coordinate; a hold keeps the word.
      final String endBody = js.substring(
        end,
        js.indexOf('_selectionVertical: function'),
      );
      expect(
        endBody,
        contains(
          'if (this.dragAnchor && this.dragAnchor.moved) this.updateRangeSelection(x, y);',
        ),
      );
      expect(
        endBody.indexOf('this.updateRangeSelection('),
        lessThan(endBody.indexOf('this.dragAnchor = null')),
      );
      // 会话状态复位。
      expect(
        js.substring(js.indexOf('clearSelection: function')),
        contains('this.dragAnchor = null'),
      );
    });

    test(
      'clear/detach invalidates the long-press session before end can show a menu',
      () {
        final String js = ReaderSelectionScripts.source();
        final String end = js.substring(
          js.indexOf('endRangeSelection: function'),
          js.indexOf('_selectionVertical: function'),
        );
        expect(end, contains('if (!this.dragAnchor) return false;'));
        expect(end, contains('if (!this.liveDragAnchor())'));
        expect(
          end.indexOf('if (!this.dragAnchor) return false;'),
          lessThan(end.indexOf('this.updateRangeSelection(')),
        );
        expect(
          end.indexOf('if (!this.liveDragAnchor())'),
          lessThan(end.indexOf('this.fireSelectionMenu(')),
        );
        final String points = js.substring(
          js.indexOf('liveSelectionPoint: function'),
          js.indexOf('_glyphRect: function'),
        );
        expect(points, contains('node.isConnected'));
        expect(points, contains('document.body.contains(node)'));
        expect(points, contains('segment.end - 1'));
      },
    );

    test(
      'begin reacquires a hit only after old wrappers normalize the DOM',
      () {
        final String js = ReaderSelectionScripts.source();
        final String begin = js.substring(
          js.indexOf('beginRangeSelection: function'),
          js.indexOf('notifySelectionDragStarted: function'),
        );
        expect(
          begin,
          contains('var hadWrappers = this.highlightWrappers.length > 0;'),
        );
        expect(
          begin,
          contains(
            'if (hadWrappers) hit = this.getSelectableCharacterAtPoint(x, y);',
          ),
        );
        expect(
          begin.indexOf('if (hadWrappers) hit ='),
          greaterThan(begin.indexOf('this.clearSelection();')),
        );
      },
    );

    test('长按锚点是区间（词首..词末 / 单字），反向拖动不丢词尾', () {
      final String js = ReaderSelectionScripts.source();
      final String body = js.substring(
        js.indexOf('selectionAnchorAtHit: function'),
        js.indexOf('getSentenceContext: function'),
      );
      expect(body, contains('spaceDelimitedWordBounds'));
      expect(body, contains('offset: bounds.start'));
      expect(body, contains('endOffset: bounds.end - 1'));
      // 非空格分词脚本（CJK / 标点 / 空白）：单字锚点，首尾同一位置。
      expect(
        body,
        contains(
          'offset: hit.offset, endNode: hit.node, endOffset: hit.offset',
        ),
      );
    });
  });

  group('未破坏既有约束', () {
    test('解析层绝不触碰原生选区（不复活 TODO-1279 双选区）', () {
      final String js = ReaderSelectionScripts.source();
      // 解析层所在区间：插在几何命中层与句子解析之间。
      final String layer = js.substring(
        js.indexOf('charRangeAt: function'),
        js.indexOf('getSentenceContext: function'),
      );
      expect(
        layer,
        isNot(contains('window.getSelection')),
        reason: '解析层不读原生选区',
      );
      expect(layer, isNot(contains('.addRange(')), reason: '解析层不写原生选区');
      expect(layer, isNot(contains('removeAllRanges')), reason: '解析层不动原生选区');
    });

    test('查词命中分层未被改动（查词仍剔除词边界）', () {
      final String js = ReaderSelectionScripts.source();
      final String body = js.substring(
        js.indexOf('getCharacterAtPoint: function'),
        js.indexOf('getSelectableCharacterAtPoint: function'),
      );
      expect(body, contains('isScanBoundary'));
      expect(body, contains('this.getSelectableCharacterAtPoint(x, y)'));
    });

    test('桌面鼠标与单击查词路径不经解析层（只被拖动入口调用）', () {
      final String js = ReaderSelectionScripts.source();
      // Both drag entries share a single hit/resolve window. Tap lookup stays separate.
      expect('resolveSelectionEndpoint: function'.allMatches(js).length, 1);
      expect('this.resolveSelectionEndpoint('.allMatches(js).length, 1);
      expect('this.selectionEndpointAtPoint('.allMatches(js).length, 2);
      final int tapStart = js.indexOf('selectText: function');
      final int tapEnd = js.indexOf('selectFromPosition: function');
      expect(tapStart, greaterThan(0));
      expect(tapEnd, greaterThan(tapStart));
      final String tap = js.substring(tapStart, tapEnd);
      expect(
        tap,
        isNot(contains('resolveSelectionEndpoint')),
        reason: '单击查词路径不得经解析层（桌面/移动点词行为零变化）',
      );
      expect(tap, isNot(contains('wordSelectMode')));
      // 词吸附整条已移除（见上一组）：全文件不应再有这两个符号，防止有人把词选择模式
      // 加回来又把拉丁文的逐字选择堵掉。
      expect(js, isNot(contains('wordSelectMode')));
      expect(js, isNot(contains('snapEndpointToWord')));
    });

    test('both drag entries use one transparent endpoint window', () {
      final String js = ReaderSelectionScripts.source();
      final String body = js.substring(
        js.indexOf('selectionEndpointAtPoint: function'),
        js.indexOf('selectionAnchorAtHit: function'),
      );
      final int transparent = body.indexOf("pointerEvents = 'none'");
      final int hit = body.indexOf('this.getSelectableCharacterAtPoint(');
      final int resolve = body.indexOf('this.resolveSelectionEndpoint(');
      final int restore = body.indexOf('pointerEvents = savedStartPe;');
      expect(transparent, greaterThanOrEqualTo(0));
      expect(hit, greaterThan(transparent));
      expect(resolve, greaterThan(hit));
      expect(restore, greaterThan(resolve));
      expect(body, contains('finally'));
      expect(body, isNot(contains("|| 'auto'")));
      expect(body, isNot(contains('style.display')));
    });

    test(
      'normalization failure is terminal and a normalized endpoint stays visible',
      () {
        final String js = ReaderSelectionScripts.source();
        final String body = js.substring(
          js.indexOf('resolveSelectionEndpoint: function'),
          js.indexOf('selectionEndpointAtPoint: function'),
        );
        expect(
          body,
          contains('this.normalizeEndpoint(node, offset, forward);'),
        );
        expect(body, contains('if (!endpoint) return null;'));
        expect(
          body,
          contains('this.charRangeAt(endpoint.node, endpoint.offset)'),
        );
        expect(body, contains('this.charRangeVisible(normalizedRange,'));
        expect(body, isNot(contains('forward) ||')));
      },
    );
  });
}
