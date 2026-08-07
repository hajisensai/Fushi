import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1150 守卫：浏览器扩展查词「弹窗钉在被查词旁 + 高亮词」（yomitan 式）源码扫描。
/// 不依赖真机/真浏览器，守住实现不被回退到「贴鼠标坐标、无高亮」。两份扩展镜像
/// （随 app 打包的 assets/ 与真源 tools/）都守，且必须逐字节一致。
///
/// 覆盖：
/// - 取词复用 window.fushiSelection.getCharacterAtPoint + selectFromPosition（不再用
///   已删的 fushiCaretFromPoint / expandWordWindow）。
/// - 弹窗锚点=被查词的视口 bbox（highlightSelection 返回 rect → wordRect.x/y），
///   不再贴鼠标坐标（旧签名 fushiRender(popupJson, x, y, theme) 已消失）。
/// - 高亮匹配长度用服务端 result.bestLength（缺失回落 term.length）。
/// - 关窗清理调用 fushiSelection.clearSelection() 撤高亮。
void main() {
  // flutter test 的 cwd 是 hibiki 包根。两份镜像分别在 assets/ 与 ../tools/。
  final File assetsContent = File('assets/browser_extension/content.js');
  final File toolsContent = File('../tools/browser-extension/content.js');

  group('TODO-1150 扩展查词贴词定位+高亮守卫', () {
    for (final File content in <File>[assetsContent, toolsContent]) {
      group('content.js ${content.path}', () {
        test('文件存在', () {
          expect(content.existsSync(), isTrue,
              reason: 'missing ${content.path}');
        });

        test('取词复用 fushiSelection（getCharacterAtPoint + selectFromPosition）',
            () {
          final String src = content.readAsStringSync();
          expect(src.contains('window.fushiSelection.getCharacterAtPoint('),
              isTrue,
              reason:
                  '${content.path} 未用 fushiSelection.getCharacterAtPoint 取词');
          expect(
              src.contains('window.fushiSelection.selectFromPosition('), isTrue,
              reason:
                  '${content.path} 未用 fushiSelection.selectFromPosition 扩词');
          // 旧取词路径已删（否则说明回退）。
          expect(src.contains('fushiCaretFromPoint'), isFalse,
              reason: '${content.path} 残留已删的 fushiCaretFromPoint');
          expect(src.contains('expandWordWindow('), isFalse,
              reason:
                  '${content.path} 仍调用 expandWordWindow（应改走 fushiSelection）');
        });

        test('弹窗钉在被查词旁（高亮 rect 锚点，非鼠标坐标）', () {
          final String src = content.readAsStringSync();
          expect(
              src.contains('window.fushiSelection.highlightSelection(termLen)'),
              isTrue,
              reason:
                  '${content.path} fushiRender 未调用 highlightSelection 取词 bbox+高亮');
          expect(
              src.contains('wordRect ? wordRect.x') &&
                  src.contains('wordRect ? wordRect.y'),
              isTrue,
              reason: '${content.path} 未按 highlightSelection 返回的词 bbox 锚定弹窗');
          // 旧的「贴鼠标坐标」渲染签名/实现已消失。
          expect(
              src.contains('fushiRender(resp.data.popupJson, px, py'), isFalse,
              reason: '${content.path} 仍按鼠标 px/py 渲染弹窗');
          expect(src.contains('function fushiRender(popupJson, x, y, theme)'),
              isFalse,
              reason: '${content.path} 仍是旧的鼠标坐标 fushiRender 签名');
        });

        test('高亮长度用服务端 result.bestLength（回落 term.length）', () {
          final String src = content.readAsStringSync();
          expect(src.contains('resp.data.result.bestLength'), isTrue,
              reason: '${content.path} 未用 result.bestLength 决定高亮词长');
          expect(src.contains('best > 0 ? best : term.length'), isTrue,
              reason: '${content.path} 缺 bestLength 缺失时回落 term.length');
        });

        test('关窗清理撤高亮（clearSelection）', () {
          final String src = content.readAsStringSync();
          expect(src.contains('window.fushiSelection.clearSelection()'), isTrue,
              reason: '${content.path} 关窗未调用 clearSelection 撤高亮');
          // clearSelection 必须落在 fushiRemoveContainer（统一关窗点）里。
          final int removeIdx = src.indexOf('function fushiRemoveContainer()');
          expect(removeIdx, greaterThanOrEqualTo(0),
              reason: '${content.path} 缺 fushiRemoveContainer');
          final String removeBody =
              src.substring(removeIdx, (removeIdx + 800).clamp(0, src.length));
          expect(removeBody.contains('clearSelection()'), isTrue,
              reason:
                  '${content.path} clearSelection 不在 fushiRemoveContainer 关窗点');
        });

        test('TODO-1272 被查词高亮走扩展自绘覆盖层（不改宿主页 DOM，保持到关窗）', () {
          // 根因：旧实现走 selection.js DOM 包裹路径（<span class="hoshi-dict-highlight"> 直接裹
          // 宿主页文本节点），动态站点框架 diff / MutationObserver 会在下一帧把它 revert 掉 →
          // 高亮闪一下就没（用户报「非常容易消失」）。改画扩展自有的顶层 fixed 覆盖层。
          final String src = content.readAsStringSync();
          // 覆盖层的画/撤/取 rects 三个函数必须存在。
          expect(src.contains('function fushiDrawHighlightOverlay('), isTrue,
              reason: '${content.path} 缺覆盖层高亮绘制 fushiDrawHighlightOverlay');
          expect(src.contains('function fushiClearHighlightOverlay('), isTrue,
              reason: '${content.path} 缺覆盖层高亮清除 fushiClearHighlightOverlay');
          expect(src.contains('function fushiSelectionRects('), isTrue,
              reason:
                  '${content.path} 缺只读取 rects（不改 DOM）的 fushiSelectionRects');
          // 覆盖层是扩展自有的穿透点击顶层元素（宿主页事件碰不到它）。
          expect(src.contains("layer.id = 'fushi-highlight-overlay'"), isTrue,
              reason: '${content.path} 覆盖层缺稳定 id fushi-highlight-overlay');
          expect(src.contains('pointer-events:none'), isTrue,
              reason: '${content.path} 覆盖层未穿透点击');
          // 取 rects 只读 selection.ranges + Range.getClientRects，不做 DOM 包裹。
          final int rectsIdx = src.indexOf('function fushiSelectionRects(');
          final String rectsBody =
              src.substring(rectsIdx, (rectsIdx + 900).clamp(0, src.length));
          expect(
              rectsBody.contains('window.fushiSelection.selection') &&
                  rectsBody.contains('.ranges') &&
                  rectsBody.contains('getClientRects()'),
              isTrue,
              reason:
                  '${content.path} fushiSelectionRects 未从 selection.ranges 只读取 client rects');
          // fushiRender 主路径改画覆盖层（不再靠 DOM 包裹高亮做主高亮）。
          expect(src.contains('fushiDrawHighlightOverlay(hl.rects)'), isTrue,
              reason: '${content.path} fushiRender 未改画覆盖层高亮');
          // 关窗即撤覆盖层高亮（高亮跟随弹窗生命周期）。
          final int removeIdx2 =
              src.indexOf('function fushiRemoveContainer()');
          final String removeBody2 = src.substring(
              removeIdx2, (removeIdx2 + 800).clamp(0, src.length));
          expect(removeBody2.contains('fushiClearHighlightOverlay()'), isTrue,
              reason: '${content.path} 关窗未撤覆盖层高亮（会残留在宿主页上）');
        });

        test('Shift 悬停查词接线未断（mousemove→shiftKey→发 lookup）', () {
          // TODO-1132 回归守卫：用户复诉「浏览器按 Shift 没反应」。5657c55d1 把发查词逻辑
          // 从 mousemove 抽成 fushiSendLookup、1219 P1-P3 又在前后加脚本——守住这条主查词
          // 接线不被重构悄悄拆断。行为层实证见 tools/browser-extension/shift-hover.test.js。
          final String src = content.readAsStringSync();
          // 修饰键必须是 Shift，且 mousemove 顶层注册（不能被塞进只在某站点调用的函数里）。
          expect(src.contains("const FUSHI_MOD = 'shiftKey'"), isTrue,
              reason: '${content.path} 查词修饰键不再是 Shift');
          expect(
              RegExp(r"^document\.addEventListener\('mousemove'",
                      multiLine: true)
                  .hasMatch(src),
              isTrue,
              reason: '${content.path} mousemove 监听器不在顶层，Shift 悬停可能永不触发');
          // mousemove 分支必须以 Shift 为门（松开即复位）。
          expect(src.contains('if (!e[FUSHI_MOD])'), isTrue,
              reason: '${content.path} mousemove 未以 Shift 为门');
          // 取词后必须真的发出 lookup 查词消息（接线终点）。
          expect(
              src.contains(
                  "chrome.runtime.sendMessage({ type: 'lookup', term }"),
              isTrue,
              reason: '${content.path} 未向 background 发 lookup 查词消息');
          // mousemove 命中后调用 fushiSendLookup（1132 抽取后的分发点）。
          expect(
              src.contains('fushiSendLookup(term, fushiAnchorRect)'), isTrue,
              reason: '${content.path} mousemove 未调用 fushiSendLookup 发查词');
        });

        test('未破坏 v35 Netflix 取词兜底 / 全屏挂载', () {
          final String src = content.readAsStringSync();
          expect(src.contains('fushiSubtitleCaretAtPoint('), isTrue,
              reason: '${content.path} 丢了 Netflix 字幕逐字兜底取词');
          expect(src.contains('document.fullscreenElement'), isTrue,
              reason: '${content.path} 丢了全屏 fullscreenElement 挂载');
        });

        test('TODO-1279 查词清掉浏览器原生蓝色选区（只留覆盖层，纯悬停清、拖拽复制不清）', () {
          // 根因：Shift 悬停取词时浏览器把原生文本选区从既有 caret 扩到指针，与自绘覆盖层叠出
          // 一条多余蓝色原生选区。修复：纯悬停(e.buttons===0)清 window.getSelection()，拖拽划选
          // (buttons!==0)保留复制能力。行为层实证见 tools/browser-extension/native-selection-clear.test.js。
          final String src = content.readAsStringSync();
          expect(src.contains('function fushiClearNativeSelection('), isTrue,
              reason:
                  '${content.path} 缺清原生选区 helper fushiClearNativeSelection');
          expect(src.contains('removeAllRanges()'), isTrue,
              reason: '${content.path} 未 removeAllRanges 清浏览器原生选区');
          // 纯悬停(buttons===0)才清；拖拽划选(buttons!==0)不清，保住手动复制。
          expect(src.contains('e.buttons === 0'), isTrue,
              reason: '${content.path} 未按 e.buttons 门控（会误伤用户手动拖拽划选复制）');
          // 清原生选区必须真接进 mousemove Shift 悬停查词路径。
          final int mmIdx =
              src.indexOf("document.addEventListener('mousemove'");
          expect(mmIdx, greaterThanOrEqualTo(0),
              reason: '${content.path} 缺 mousemove 监听器');
          final String mmBody =
              src.substring(mmIdx, (mmIdx + 900).clamp(0, src.length));
          expect(mmBody.contains('fushiClearNativeSelection()'), isTrue,
              reason: '${content.path} mousemove Shift 悬停未清原生选区');
        });
      });
    }

    test('两份镜像逐字节一致（content.js）', () {
      expect(assetsContent.readAsBytesSync(), toolsContent.readAsBytesSync(),
          reason: 'content.js 两份镜像不一致');
    });
  });
}
