import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：浏览器扩展 TODO-1184（图标菜单/队列/删除/开始生成）+ TODO-1185（弹窗字号 zoom /
/// 多列 columns / 嵌套查词）+ TODO-1190（网页源文高亮）源码扫描。不依赖真浏览器，守住实现
/// 不被回退。两份镜像（随 app 打包的 assets/ 与真源 tools/）都守。byte-identical 由
/// browser_extension_installer_test 的漂移守卫另行保证。
void main() {
  // flutter test 的 cwd 是 hibiki 包根。
  final Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  mirrors.forEach((String name, String root) {
    group('extension mirror [$name] $root', () {
      final File manifest = File('$root/manifest.json');
      final File background = File('$root/background.js');
      final File content = File('$root/content.js');
      final File contentCss = File('$root/vendor/content.css');
      final File popupCss = File('$root/vendor/popup.css');
      final File actionHtml = File('$root/vendor/action-popup.html');
      final File actionJs = File('$root/vendor/action-popup.js');

      // TODO-1184：图标菜单（default_popup）+ 队列管理 + 逐项删除 + 开始生成入口迁 popup。
      test('1184 manifest 设 default_popup 指向 action-popup.html', () {
        final String src = manifest.readAsStringSync();
        expect(src.contains('"default_popup"'), isTrue,
            reason: '$root manifest 未设 default_popup');
        expect(src.contains('vendor/action-popup.html'), isTrue,
            reason: '$root default_popup 未指向 vendor/action-popup.html');
      });

      test('1184 action-popup.html/js 存在（新文件）', () {
        expect(actionHtml.existsSync(), isTrue,
            reason: 'missing ${actionHtml.path}');
        expect(actionJs.existsSync(), isTrue,
            reason: 'missing ${actionJs.path}');
      });

      test(
          '1184 action-popup.js 有队列渲染 + 逐项删除 + 开始生成（tabs.query→fushiIconAction）',
          () {
        final String src = actionJs.readAsStringSync();
        expect(src.contains('fushiFilterQueue'), isTrue,
            reason: '$root action-popup.js 缺队列剔除纯函数');
        expect(src.contains('chrome.storage.local'), isTrue,
            reason: '$root action-popup.js 未以 storage 为队列真相源');
        expect(src.contains('chrome.tabs.query'), isTrue,
            reason: '$root action-popup.js 开始生成未 query 当前 tab');
        expect(src.contains("type: 'fushiIconAction'"), isTrue,
            reason: '$root action-popup.js 未发 fushiIconAction 手势消息');
      });

      test('1184 background.js onClicked 已迁走（改 fushiIconAction 消息驱动）', () {
        final String src = background.readAsStringSync();
        // default_popup 设了后 onClicked 永不触发：不得再注册它（否则误导）。
        expect(src.contains('chrome.action.onClicked.addListener'), isFalse,
            reason: '$root background.js 仍注册 onClicked（default_popup 下它永不触发）');
        expect(src.contains("msg.type === 'fushiIconAction'"), isTrue,
            reason: '$root background.js 缺 fushiIconAction 消息分支');
        // fushiIconClick 逻辑本身保留（只换触发口）。
        expect(src.contains('function fushiIconClick'), isTrue,
            reason: '$root background.js 丢了 fushiIconClick 逻辑');
      });

      // TODO-1185：字号 zoom 消费 + 多列 columns 消费 + 嵌套查词。
      test('1185 content.css 消费 --fushi-popup-zoom + --dict-columns', () {
        final String src = contentCss.readAsStringSync();
        expect(src.contains('zoom: var(--fushi-popup-zoom'), isTrue,
            reason: '$root content.css 未消费 --fushi-popup-zoom');
        expect(src.contains('repeat(var(--dict-columns'), isTrue,
            reason: '$root content.css 未消费 --dict-columns 多列布局');
      });

      // TODO-1267 起 vendor/popup.css 改为 app 内弹窗渲染器 assets/popup/popup.css 的字节
      // 镜像（parity，见 browser_extension_popup_parity_guard_test）。多列布局变量
      // --dict-columns 与 app 一致仍在 popup.css；而 CSS `zoom: var(--fushi-popup-zoom)` 是
      // 扩展专属机制（app 弹窗走 WebView 侧缩放、不用 CSS zoom），只在生成的 content.css
      // overlay 出现——由上面「content.css 消费 --fushi-popup-zoom」用例守护，不再要求
      // 死文件 popup.css 携带它（否则与 parity 守卫互斥）。
      test(
          '1185 popup.css 消费 --dict-columns（app 弹窗镜像；zoom 归 content.css overlay）',
          () {
        final String src = popupCss.readAsStringSync();
        expect(src.contains('repeat(var(--dict-columns'), isTrue,
            reason: '$root popup.css 未消费 --dict-columns 多列布局');
      });

      test('1185 content.js 定义 __fushiOnLinkClick（嵌套查词重发 lookup）', () {
        final String src = content.readAsStringSync();
        expect(src.contains('window.__fushiOnLinkClick = function'), isTrue,
            reason: '$root content.js 未定义 __fushiOnLinkClick（点释义里的词无反应）');
        // place() 按 zoom 除算 fixed 定位坐标，避免 CSS zoom 放大偏移。
        expect(
            src.contains('(pos.left / zoom)') &&
                src.contains('(pos.top / zoom)'),
            isTrue,
            reason: '$root content.js place() 未按 --fushi-popup-zoom 补偿定位');
      });

      // TODO-1190：网页源文高亮——强制 DOM 包裹路径（隔离世界的 CSS Custom Highlight 不绘制）。
      test('1190 content.js 强制 DOM 包裹高亮（__hoshiCssHighlightsSupported=false）',
          () {
        final String src = content.readAsStringSync();
        expect(src.contains('window.__hoshiCssHighlightsSupported = false'),
            isTrue,
            reason: '$root content.js 未强制 DOM 包裹高亮路径 → 隔离世界 CSS 高亮不绘制（用户报没高亮）');
        // 高亮调用 + 关窗撤销仍在（与 1150 守卫互补）。
        expect(
            src.contains('window.hoshiSelection.highlightSelection(termLen)'),
            isTrue,
            reason: '$root content.js 丢了 highlightSelection 调用');
      });

      // TODO-1270：制卡队列每行主标签必须优先「词」，避免同一字幕行查多个词后队列显示「句子一模一样」。
      test('1270 action-popup.js 队列标签优先词、句子降为暗色上下文行（不再句子一模一样）', () {
        final String src = actionJs.readAsStringSync();
        // 主标签取词字段(expression/word/term)在前、句子回落在后。
        final int labelIdx = src.indexOf('function fushiQueueItemLabel');
        expect(labelIdx >= 0, isTrue,
            reason: '$root action-popup.js 缺 fushiQueueItemLabel');
        final int labelEnd = src.indexOf('}', labelIdx);
        final String labelBody = src.substring(labelIdx, labelEnd);
        final int wordPos = labelBody.indexOf('q.fields');
        final int sentPos = labelBody.indexOf('q.sentence');
        expect(wordPos >= 0 && (sentPos < 0 || wordPos < sentPos), isTrue,
            reason: '$root fushiQueueItemLabel 未优先词字段（回退到句子优先=队列句子一模一样回归）');
        // 上下文行 helper 存在，且渲染时挂出暗色 .hp-row-sub。
        expect(src.contains('function fushiQueueItemContext'), isTrue,
            reason: '$root action-popup.js 缺 fushiQueueItemContext（句子上下文行）');
        expect(src.contains("'hp-row-sub'"), isTrue,
            reason: '$root action-popup.js 未渲染 hp-row-sub 上下文行');
      });

      test('1270 action-popup.html 定义 .hp-row-sub 暗色上下文样式', () {
        final String src = actionHtml.readAsStringSync();
        expect(src.contains('.hp-row-sub'), isTrue,
            reason: '$root action-popup.html 缺 .hp-row-sub 上下文行样式');
      });

      // TODO-1881：popup 操作流——生成按钮显式状态机（消除「队列空/站点不对点了没反应」的
      // 隐形三态）+ 清空队列（二次确认）+ 队列条目跳回视频页 + 连接状态行点击重检。
      test('1881 action-popup.js 生成按钮状态机 + 清空 + 条目跳转 + 连接重检', () {
        final String src = actionJs.readAsStringSync();
        expect(src.contains('function fushiGenButtonState'), isTrue,
            reason:
                '$root action-popup.js 缺 fushiGenButtonState 状态机（回归成隐形三态按钮）');
        expect(src.contains('function fushiTabSite'), isTrue,
            reason: '$root action-popup.js 缺 fushiTabSite 站点判定');
        expect(src.contains('function fushiQueueItemUrl'), isTrue,
            reason: '$root action-popup.js 缺 fushiQueueItemUrl（队列条目跳回视频页）');
        // 取消逃生口必须保留：batch active 时按钮可点（cancel 态）。
        expect(src.contains("mode: 'cancel'"), isTrue,
            reason: '$root fushiGenButtonState 丢了 cancel 逃生口');
        // 清空队列（二次确认）。
        expect(src.contains("'hp-clear'"), isTrue,
            reason: '$root action-popup.js 缺清空队列按钮');
        expect(src.contains('确认清空'), isTrue,
            reason: '$root action-popup.js 清空队列缺二次确认');
        // 连接状态行点击强制重检（探测抽成 refreshConnection 且行上挂 click）。
        expect(src.contains('function refreshConnection'), isTrue,
            reason: '$root action-popup.js 连接探测未抽成 refreshConnection（行点击无法重检）');
        expect(src.contains("connEl.addEventListener('click'"), isTrue,
            reason: '$root action-popup.js 连接状态行未挂点击重检');
      });

      test('1881 action-popup.html 有 hint 元素与状态样式', () {
        final String src = actionHtml.readAsStringSync();
        expect(src.contains('hp-gen-hint'), isTrue,
            reason: '$root action-popup.html 缺 hp-gen-hint 原因提示元素');
        expect(src.contains('.hp-gen:disabled'), isTrue,
            reason: '$root action-popup.html 缺禁用态样式（按钮不可点无视觉反馈）');
        expect(src.contains('data-mode="cancel"'), isTrue,
            reason: '$root action-popup.html 缺取消态警示样式');
        expect(src.contains('.hp-clear'), isTrue,
            reason: '$root action-popup.html 缺清空按钮样式');
      });
    });
  });
}
