import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1270 guard：Netflix 沉浸制卡的三个用户报障，锁在两份扩展镜像里防回归。
///
/// - Bug A：卡里字幕重复两次。根因 = `extractNetflixCueText` 把 Netflix「外层定位 span >
///   内层样式 span」嵌套里的**每一层** span 的 textContent 都拼进来，父子重复。修复只取叶子
///   span（无后代 span）。
/// - Bug B：制卡录进的 GIF 混入了 Hibiki 自己的「生成中」浮层(#hibiki-toast) + Netflix 顶部
///   返回按钮/举报旗帜。修复把它们一并加进批量隐藏样式。
/// - Bug C：GIF/音频少了一点开头。根因 = seek 到 cueStart-200 后用固定 warmup sleep 播掉这段
///   头部提前量才 beginClip。修复改成一旦确认在播立刻开录。
///
/// flutter test cwd 是 hibiki 包根目录。
void main() {
  const List<String> roots = <String>[
    'assets/browser_extension',
    '../tools/browser-extension',
  ];

  group('TODO-1270 Netflix 制卡三修守卫', () {
    for (final String root in roots) {
      test('[$root] Bug A：extractNetflixCueText 只取叶子 span 去重嵌套', () {
        final String src =
            File('$root/subtitle-adapters.js').readAsStringSync();
        expect(
            src.contains("s.querySelector && s.querySelector('span')"), isTrue,
            reason: '$root subtitle-adapters.js 未按无后代 span 过滤叶子（Bug A 未修）');
        expect(src.contains('const leaves = Array.from(spans).filter('), isTrue,
            reason: '$root subtitle-adapters.js 缺 leaves 叶子过滤');
      });

      test('[$root] Bug B：批量隐藏样式含 #hibiki-toast + Netflix 返回/举报', () {
        final String src = File('$root/content.js').readAsStringSync();
        expect(
            src.contains('#hibiki-toast{visibility:hidden!important}'), isTrue,
            reason: '$root content.js hideStyle 未隐藏 Hibiki 自己的生成中浮层（Bug B）');
        expect(src.contains('.watch-video--back-container'), isTrue,
            reason: '$root content.js hideStyle 未隐藏 Netflix 返回按钮（Bug B）');
        expect(src.contains('.watch-video--flag-container'), isTrue,
            reason: '$root content.js hideStyle 未隐藏 Netflix 举报旗帜容器（Bug B）');
      });

      test('[$root] Bug C：确认在播即刻 beginClip，不用固定 warmup 吃掉头部提前量', () {
        final String src = File('$root/content.js').readAsStringSync();
        expect(
            src.contains(
                'for (let i = 0; i < 8 && v.paused; i++) { try { await v.play(); } catch (_) {} await sleep(60); }'),
            isTrue,
            reason: '$root content.js 缺确认在播即刻开录轮询（Bug C）');
        final int playIdx = src.indexOf('try { await v.play(); } catch (_) {}\n'
            '        for (let i = 0; i < 8');
        final int beginIdx = src.indexOf("type: 'beginClip'");
        expect(playIdx >= 0 && beginIdx > playIdx, isTrue,
            reason: '$root content.js beginClip 顺序异常');
        expect(src.substring(playIdx, beginIdx).contains('await sleep(200)'),
            isFalse,
            reason: '$root content.js beginClip 前仍残留固定 200ms warmup（Bug C 未修）');
        expect(src.contains('startV: Math.max(0, w.startV - 200)'), isTrue,
            reason: '$root content.js 丢了入队 -200ms 头部提前量');
      });
    }
  });
}
