import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2260 守卫：Netflix 年龄分级/内容提示 overlay（左上角 "RATED 13+ / 暴力, 自杀"）的
/// DOM 已改为
///   div.watch-video--advisories-container > div.advisory-container > div.advisory >
///   [data-uia="advisory-content"] > h4.advisory-header
/// （2026-09-08 登录态 WebView2 探针实测）。仓库里原有的三组选择器
/// （`.watch-video--evidence-overlay-container` / `*maturity*`）一个都不再命中，于是扩展的
/// 常驻隐藏、录制期隐藏和内置播放器的 chrome 隐藏对它全部**静默**失效。
///
/// 第二根因在内置播放器：队列换集走 `loadUrl` 整页重载，上一份文档里的 chrome 隐藏 `<style>`
/// 随之消失，而 Dart 只在队列开跑前挂过一次——之后每张卡都带控制条。
///
/// 本守卫钉四处：扩展两镜像的常驻清单 + 录制作用域、内置播放器 glue 的 document-start 常驻隐藏
/// + chrome 清单、Dart 页 onLoadStop / 换集就绪后的重挂。
/// flutter test cwd is the fushi package root.
void main() {
  const String advisorySelector = '.watch-video--advisories-container';
  const String advisoryHashSelector = '[class*="watch-video--advisories"]';

  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  mirrors.forEach((String name, String root) {
    group('[$name] 扩展 content.js', () {
      final String src = File('$root/content.js').readAsStringSync();

      test('常驻隐藏清单含 advisories 容器（含哈希类名兜底）', () {
        final int listStart =
            src.indexOf('function fushiNetflixNextEpisodeSelectors()');
        expect(listStart, greaterThanOrEqualTo(0));
        final int listEnd = src.indexOf('];', listStart);
        final String list = src.substring(listStart, listEnd);
        expect(list.contains("'$advisorySelector'"), isTrue,
            reason: '$root content.js 常驻清单必须含 $advisorySelector');
        expect(list.contains("'$advisoryHashSelector'"), isTrue,
            reason: '$root content.js 常驻清单必须含哈希类名兜底 $advisoryHashSelector');
      });

      test('录制作用域 hideStyle 无条件藏 advisories 容器', () {
        final int start = src.indexOf('hideStyle.textContent =');
        expect(start, greaterThanOrEqualTo(0));
        final int end =
            src.indexOf('document.head.appendChild(hideStyle)', start);
        expect(end, greaterThan(start));
        final String block = src.substring(start, end);
        expect(block.contains(advisorySelector), isTrue,
            reason: '$root content.js 录制期 hideStyle 必须含 $advisorySelector——'
                '常驻隐藏受 netflixHideNextEpisode 开关门控，关掉后提示会照录进卡片');
        expect(block.contains(advisoryHashSelector), isTrue,
            reason: '$root content.js 录制期 hideStyle 必须含哈希类名兜底');
      });
    });
  });

  group('内置网页播放器 glue', () {
    final String glue =
        File('assets/web_video/web_video_glue.js').readAsStringSync();

    test('document-start 常驻隐藏 advisories 容器（display:none，每份文档重新注入）', () {
      final int start = glue.indexOf('NETFLIX_ADVISORY_SELECTORS =');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'glue 必须集中定义 NETFLIX_ADVISORY_SELECTORS');
      final int end = glue.indexOf(';', start);
      final String selectors = glue.substring(start, end);
      expect(selectors.contains(advisorySelector), isTrue);
      expect(selectors.contains(advisoryHashSelector), isTrue);
      expect(glue.contains('fushi-web-video-hide-advisory'), isTrue,
          reason: '常驻隐藏 style 必须有稳定 id（幂等注入）');
      final int styleAt = glue.indexOf('fushi-web-video-hide-advisory');
      final String block = glue.substring(
          styleAt, glue.indexOf('appendChild(advisoryStyle)', styleAt));
      expect(block.contains('display:none !important'), isTrue,
          reason: '常驻隐藏要用 display:none——分级提示不参与取词，摘出布局最干净');
    });

    test('制卡期 chrome 清单复用同一组 advisories 选择器', () {
      final int start = glue.indexOf('HIDE_CHROME_CSS =');
      expect(start, greaterThanOrEqualTo(0));
      final int end = glue.indexOf("'{visibility:hidden !important}';", start);
      expect(end, greaterThan(start));
      expect(glue.substring(start, end).contains('NETFLIX_ADVISORY_SELECTORS'),
          isTrue,
          reason: 'HIDE_CHROME_CSS 必须拼入 NETFLIX_ADVISORY_SELECTORS，别再各抄一份');
    });
  });

  group('内置网页播放器 Dart 页', () {
    final String page = File(
      'lib/src/pages/implementations/web_video_fushi_page.dart',
    ).readAsStringSync();

    test('onLoadStop 按 _mineRunning 重挂 chrome 隐藏（整页换集不丢）', () {
      final int start = page.indexOf('onLoadStop:');
      expect(start, greaterThanOrEqualTo(0));
      final int end = page.indexOf('onRenderProcessGone:', start);
      expect(end, greaterThan(start));
      expect(
          page
              .substring(start, end)
              .contains('_setPlayerChromeHidden(_mineRunning)'),
          isTrue,
          reason: '换集 loadUrl 后上一份文档的 <style> 已没了，隐藏态归 Dart 所有，新文档必须重挂');
    });

    test('换集就绪后开录前再挂一次（画面就绪可能早于 onLoadStop）', () {
      final int start = page.indexOf('Future<bool> _navigateForMining(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = page.indexOf('Future<void> _runMineQueue()', start);
      expect(end, greaterThan(start));
      expect(
          page.substring(start, end).contains('_setPlayerChromeHidden(true)'),
          isTrue);
    });
  });
}
