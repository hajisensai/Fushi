import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1150 守卫：浏览器扩展查词「弹窗钉在被查词旁 + 高亮词」（yomitan 式）源码扫描。
/// 不依赖真机/真浏览器，守住实现不被回退到「贴鼠标坐标、无高亮」。两份扩展镜像
/// （随 app 打包的 assets/ 与真源 tools/）都守，且必须逐字节一致。
///
/// 覆盖：
/// - 取词复用 window.hoshiSelection.getCharacterAtPoint + selectFromPosition（不再用
///   已删的 hibikiCaretFromPoint / expandWordWindow）。
/// - 弹窗锚点=被查词的视口 bbox（highlightSelection 返回 rect → wordRect.x/y），
///   不再贴鼠标坐标（旧签名 hibikiRender(popupJson, x, y, theme) 已消失）。
/// - 高亮匹配长度用服务端 result.bestLength（缺失回落 term.length）。
/// - 关窗清理调用 hoshiSelection.clearSelection() 撤高亮。
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

        test('取词复用 hoshiSelection（getCharacterAtPoint + selectFromPosition）',
            () {
          final String src = content.readAsStringSync();
          expect(src.contains('window.hoshiSelection.getCharacterAtPoint('),
              isTrue,
              reason:
                  '${content.path} 未用 hoshiSelection.getCharacterAtPoint 取词');
          expect(
              src.contains('window.hoshiSelection.selectFromPosition('), isTrue,
              reason:
                  '${content.path} 未用 hoshiSelection.selectFromPosition 扩词');
          // 旧取词路径已删（否则说明回退）。
          expect(src.contains('hibikiCaretFromPoint'), isFalse,
              reason: '${content.path} 残留已删的 hibikiCaretFromPoint');
          expect(src.contains('expandWordWindow('), isFalse,
              reason:
                  '${content.path} 仍调用 expandWordWindow（应改走 hoshiSelection）');
        });

        test('弹窗钉在被查词旁（高亮 rect 锚点，非鼠标坐标）', () {
          final String src = content.readAsStringSync();
          expect(
              src.contains('window.hoshiSelection.highlightSelection(termLen)'),
              isTrue,
              reason:
                  '${content.path} hibikiRender 未调用 highlightSelection 取词 bbox+高亮');
          expect(
              src.contains('wordRect ? wordRect.x') &&
                  src.contains('wordRect ? wordRect.y'),
              isTrue,
              reason: '${content.path} 未按 highlightSelection 返回的词 bbox 锚定弹窗');
          // 旧的「贴鼠标坐标」渲染签名/实现已消失。
          expect(
              src.contains('hibikiRender(resp.data.popupJson, px, py'), isFalse,
              reason: '${content.path} 仍按鼠标 px/py 渲染弹窗');
          expect(src.contains('function hibikiRender(popupJson, x, y, theme)'),
              isFalse,
              reason: '${content.path} 仍是旧的鼠标坐标 hibikiRender 签名');
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
          expect(src.contains('window.hoshiSelection.clearSelection()'), isTrue,
              reason: '${content.path} 关窗未调用 clearSelection 撤高亮');
          // clearSelection 必须落在 hibikiRemoveContainer（统一关窗点）里。
          final int removeIdx = src.indexOf('function hibikiRemoveContainer()');
          expect(removeIdx, greaterThanOrEqualTo(0),
              reason: '${content.path} 缺 hibikiRemoveContainer');
          final String removeBody =
              src.substring(removeIdx, (removeIdx + 400).clamp(0, src.length));
          expect(removeBody.contains('clearSelection()'), isTrue,
              reason:
                  '${content.path} clearSelection 不在 hibikiRemoveContainer 关窗点');
        });

        test('Shift 悬停查词接线未断（mousemove→shiftKey→发 lookup）', () {
          // TODO-1132 回归守卫：用户复诉「浏览器按 Shift 没反应」。5657c55d1 把发查词逻辑
          // 从 mousemove 抽成 hibikiSendLookup、1219 P1-P3 又在前后加脚本——守住这条主查词
          // 接线不被重构悄悄拆断。行为层实证见 tools/browser-extension/shift-hover.test.js。
          final String src = content.readAsStringSync();
          // 修饰键必须是 Shift，且 mousemove 顶层注册（不能被塞进只在某站点调用的函数里）。
          expect(src.contains("const HIBIKI_MOD = 'shiftKey'"), isTrue,
              reason: '${content.path} 查词修饰键不再是 Shift');
          expect(
              RegExp(r"^document\.addEventListener\('mousemove'",
                      multiLine: true)
                  .hasMatch(src),
              isTrue,
              reason: '${content.path} mousemove 监听器不在顶层，Shift 悬停可能永不触发');
          // mousemove 分支必须以 Shift 为门（松开即复位）。
          expect(src.contains('if (!e[HIBIKI_MOD])'), isTrue,
              reason: '${content.path} mousemove 未以 Shift 为门');
          // 取词后必须真的发出 lookup 查词消息（接线终点）。
          expect(
              src.contains(
                  "chrome.runtime.sendMessage({ type: 'lookup', term }"),
              isTrue,
              reason: '${content.path} 未向 background 发 lookup 查词消息');
          // mousemove 命中后调用 hibikiSendLookup（1132 抽取后的分发点）。
          expect(
              src.contains('hibikiSendLookup(term, hibikiAnchorRect)'), isTrue,
              reason: '${content.path} mousemove 未调用 hibikiSendLookup 发查词');
        });

        test('未破坏 v35 Netflix 取词兜底 / 全屏挂载', () {
          final String src = content.readAsStringSync();
          expect(src.contains('hibikiSubtitleCaretAtPoint('), isTrue,
              reason: '${content.path} 丢了 Netflix 字幕逐字兜底取词');
          expect(src.contains('document.fullscreenElement'), isTrue,
              reason: '${content.path} 丢了全屏 fullscreenElement 挂载');
        });
      });
    }

    test('两份镜像逐字节一致（content.js）', () {
      expect(assetsContent.readAsBytesSync(), toolsContent.readAsBytesSync(),
          reason: 'content.js 两份镜像不一致');
    });
  });
}
