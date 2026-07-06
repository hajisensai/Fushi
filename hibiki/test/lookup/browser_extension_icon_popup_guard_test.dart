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
          '1184 action-popup.js 有队列渲染 + 逐项删除 + 开始生成（tabs.query→hibikiIconAction）',
          () {
        final String src = actionJs.readAsStringSync();
        expect(src.contains('hibikiFilterQueue'), isTrue,
            reason: '$root action-popup.js 缺队列剔除纯函数');
        expect(src.contains('chrome.storage.local'), isTrue,
            reason: '$root action-popup.js 未以 storage 为队列真相源');
        expect(src.contains('chrome.tabs.query'), isTrue,
            reason: '$root action-popup.js 开始生成未 query 当前 tab');
        expect(src.contains("type: 'hibikiIconAction'"), isTrue,
            reason: '$root action-popup.js 未发 hibikiIconAction 手势消息');
      });

      test('1184 background.js onClicked 已迁走（改 hibikiIconAction 消息驱动）', () {
        final String src = background.readAsStringSync();
        // default_popup 设了后 onClicked 永不触发：不得再注册它（否则误导）。
        expect(src.contains('chrome.action.onClicked.addListener'), isFalse,
            reason: '$root background.js 仍注册 onClicked（default_popup 下它永不触发）');
        expect(src.contains("msg.type === 'hibikiIconAction'"), isTrue,
            reason: '$root background.js 缺 hibikiIconAction 消息分支');
        // hibikiIconClick 逻辑本身保留（只换触发口）。
        expect(src.contains('function hibikiIconClick'), isTrue,
            reason: '$root background.js 丢了 hibikiIconClick 逻辑');
      });

      // TODO-1185：字号 zoom 消费 + 多列 columns 消费 + 嵌套查词。
      test('1185 content.css 消费 --hibiki-popup-zoom + --dict-columns', () {
        final String src = contentCss.readAsStringSync();
        expect(src.contains('zoom: var(--hibiki-popup-zoom'), isTrue,
            reason: '$root content.css 未消费 --hibiki-popup-zoom');
        expect(src.contains('repeat(var(--dict-columns'), isTrue,
            reason: '$root content.css 未消费 --dict-columns 多列布局');
      });

      test('1185 popup.css 消费 --hibiki-popup-zoom + --dict-columns（镜像一致）', () {
        final String src = popupCss.readAsStringSync();
        expect(src.contains('zoom: var(--hibiki-popup-zoom'), isTrue,
            reason: '$root popup.css 未消费 --hibiki-popup-zoom');
        expect(src.contains('repeat(var(--dict-columns'), isTrue,
            reason: '$root popup.css 未消费 --dict-columns 多列布局');
      });

      test('1185 content.js 定义 __hibikiOnLinkClick（嵌套查词重发 lookup）', () {
        final String src = content.readAsStringSync();
        expect(src.contains('window.__hibikiOnLinkClick = function'), isTrue,
            reason: '$root content.js 未定义 __hibikiOnLinkClick（点释义里的词无反应）');
        // place() 按 zoom 除算 fixed 定位坐标，避免 CSS zoom 放大偏移。
        expect(src.contains('(left / zoom)') && src.contains('(top / zoom)'),
            isTrue,
            reason: '$root content.js place() 未按 --hibiki-popup-zoom 补偿定位');
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
    });
  });
}
