import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2170 守卫：Netflix 批量自动制卡**切集后**必须先把片头年龄分级 overlay 播过去再开录。
///
/// 复诉根因：批量状态机到达目标集后只 `fushiWaitForPlayer` + `sleep(800)` 就 `nfEnsureCapture`
/// 并逐句录制，而 Netflix 每集开播时会在左上角显示数秒年龄分级 overlay（"RATED 13+ / 暴力,
/// 自杀"）。tabCapture 录的是**合成后的标签页画面**，落在这一窗内的 clip 把提示烧进了卡片图。
///
/// 常驻 CSS 隐藏（TODO-1391）不能当保证：它受用户开关 `netflixHideNextEpisode` 门控（用户为
/// 留住 Netflix 的「下一集」按钮把它关掉，分级 overlay 会一起放出来），选择器也随 Netflix 的
/// 哈希类名漂移。故录制侧另加一道**与选择器无关**的时间门。
///
/// 行为层（等待判据、上界、放弃名单）由 node 测试
/// `tools/browser-extension/netflix-intro-overlay-gate.test.js` 在 vm 里真跑 content.js 钉住；
/// 但 node 测试不在 CI 的真单测门内，所以这里再用源码扫描守住**接线**——接线错了行为测试
/// 照样全绿（helper 存在、只是没人调用）。
///
/// flutter test 的 cwd 是 hibiki 包根。两份扩展镜像（随 app 打包的 assets/ 与真源 tools/）都守。
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  mirrors.forEach((String name, String root) {
    group('[$name] BUG-2170 片头分级提示窗门', () {
      final File file = File('$root/content.js');

      test('提示窗常量存在且是正数秒', () {
        final String src = file.readAsStringSync();
        final RegExpMatch? m =
            RegExp(r'const kNfIntroOverlaySec = (\d+);').firstMatch(src);
        expect(m, isNotNull,
            reason: '$root content.js 必须定义提示窗长度常量 kNfIntroOverlaySec');
        expect(int.parse(m!.group(1)!), greaterThan(0),
            reason: '$root content.js 提示窗长度必须为正（0 = 这道门等于不存在）');
      });

      test('切集到位后、开 tabCapture 之前先播过提示窗', () {
        final String src = file.readAsStringSync();
        const String gate =
            'if (fromLoad) await fushiWaitPastNetflixIntroOverlay(';
        final int gateAt = src.indexOf(gate);
        expect(gateAt, greaterThan(-1),
            reason: '$root content.js 状态机必须在真实页面加载（切集）后等过提示窗；'
                '只挂 fromLoad 是因为就地续跑时页面早已开播多时、提示不在');
        final int captureAt = src.indexOf("type: 'nfEnsureCapture'");
        expect(captureAt, greaterThan(-1),
            reason: '$root content.js 找不到 nfEnsureCapture（接线已变，守卫需重写）');
        expect(gateAt, lessThan(captureAt),
            reason: '$root content.js 必须**先**播过提示窗再开录制器；'
                '顺序反了等于录制器仍在提示窗内开着，提示照样进卡片');
      });

      test('等待是有界的，推不动时放行而不是卡死整批', () {
        final String src = file.readAsStringSync();
        expect(
            src.contains('function fushiWaitPastNetflixIntroOverlay(v, maxMs)'),
            isTrue,
            reason: '$root content.js 等待函数必须带 maxMs 上界参数');
        expect(
            src.contains(
                'if (Date.now() >= deadline) { resolve(false); return; }'),
            isTrue,
            reason: '$root content.js 等待必须有 deadline 逃生口'
                '（DRM/弱网推不动时返回 false 让批量继续，绝不无限等）');
      });

      test('判据是播放推进量而不是绝对位置（续播集不能直接放行）', () {
        final String src = file.readAsStringSync();
        expect(src.contains('const base = v.currentTime;'), isTrue,
            reason: '$root content.js 必须记录开始等待时的位置作基线');
        expect(
            src.contains(
                'if (v.currentTime - base >= kNfIntroOverlaySec) { resolve(true); return; }'),
            isTrue,
            reason: '$root content.js 必须按「相对基线的推进量」判定；'
                '改成绝对位置会让中途续播的集直接放行（提示照录）');
      });

      test('片头窗内的队列项被放弃：不录、按失败计、且不出队', () {
        final String src = file.readAsStringSync();
        expect(
            src.contains('fushiSplitNetflixIntroOverlayItems(items)'), isTrue,
            reason: '$root content.js 批量必须先把片头窗内的句分出来');
        expect(src.contains('for (const q of recordable) {'), isTrue,
            reason: '$root content.js 录制循环必须只跑 recordable');
        // 4 空格缩进 = Netflix 批量的 try 块内那层（YouTube 批量另有一处 2 空格缩进的
        // `for (const q of items)`，与本 bug 无关，不能一起误伤）。
        expect(src.contains('\n    for (const q of items) {'), isFalse,
            reason: '$root content.js Netflix 批量不能再对全量 items 录制'
                '（否则分出来的 skipped 白分了）');
        expect(src.contains('let done = 0, fail = introSkipped,'), isTrue,
            reason: '$root content.js 放弃的句必须计入失败总账'
                '（BUG-675 的教训：跳过必须可见可清点）');
        expect(src.contains('fushiRemoveQueued(okIds)'), isTrue,
            reason: '$root content.js 出队仍只认成功的 id');
        expect(src.contains('fushiRemoveQueued(introSplit'), isFalse,
            reason: '$root content.js 放弃 ≠ 丢弃：被跳过的卡必须留在队列里');
        expect(src.contains('fushiRemoveQueued(skipped'), isFalse,
            reason: '$root content.js 放弃 ≠ 丢弃：被跳过的卡必须留在队列里');
        expect(src.contains('fushiToastNetflixIntroSkipped('), isTrue,
            reason: '$root content.js 必须把「放弃了几张」告诉用户');
      });

      test('录制作用域无条件藏分级 overlay（不受用户开关门控）', () {
        final String src = file.readAsStringSync();
        // 录制期 hideStyle 用 visibility/opacity（本文件既定策略：display:none 会把节点摘出
        // 布局，取词/制卡一起废）。常驻隐藏那份用 display:none，故这条断言只会命中录制那份。
        expect(
            src.contains(
                '.watch-video [class*="maturity-rating"]{opacity:0!important;visibility:hidden!important}'),
            isTrue,
            reason: '$root content.js 录制期 hideStyle 必须无条件藏分级 overlay——'
                '常驻隐藏受 netflixHideNextEpisode 开关门控，用户关掉后提示会照录进卡片');
      });
    });
  });
}
