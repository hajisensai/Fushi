import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1271 守卫（源码扫描，不依赖真浏览器）。
///
/// 用户报「这也不是视频，哪来的字幕」：在**普通网页**（非 YouTube/Netflix 流媒体）
/// 上查词后点弹窗「制卡」，扩展弹出 `✗ 没找到当前字幕，稍候再试` 且卡片没建成。
///
/// 根因：批量剪辑重构后 `bridge-shim.js` 的 `mineEntry` **无条件**走视频剪辑队列
/// `window.fushiEnqueue`，而它要求一个视频时间窗（`fushiCurrentCueWindowV()`）。
/// 普通网页没有视频/字幕，取窗返回 null → `fushiEnqueue` 返回 `{reason:'no-cue'}`
/// → 误报「没找到当前字幕」，制卡链路被这条视频专属分支吞掉。
///
/// 根因修复：`mineEntry` 先判「本页能不能拿到可裁的原始媒体」。拿不到就回落到
/// background.js 早已存在的 `type:'mine'`（直接 POST）立即制卡；剪辑队列 +
/// `no-cue` 提示只对必须回放才能取媒体的站点保留。
///
/// **判据演进（同一个行为，换了更准的问法）**：这个门控最初写成站点名枚举
/// `site !== 'youtube' && site !== 'netflix'`，后来发现它把三件互相正交的能力绑死在
/// 一个枚举上——① 有没有可裁的原始流 ② 有没有当前字幕行 ③ 能不能取当前解码帧。于是
/// bilibili.com（②③ 俱全、只缺①）整个落进「普通网页」分支：制卡既没有例句也没有封面
/// （用户报「B 站外挂了字幕，缺截图 + 例句」）。现在门控问的是 `fushiClipSource()` 给出的
/// `mode`，`'queue'` 才入队；本守卫要守的**行为**（普通网页不误报没字幕、照常出卡）逐字
/// 未变，只是判据从「站点名」换成了「能力」。
///
/// 行为层面的真执行断言在 `tools/browser-extension/web-video-mine.test.js`（node，
/// 在受控 vm 里真跑 mineEntry 并检查发出的消息）。本文件只做源码不变式，防的是
/// 「有人把门控删回无条件入队」这类结构性回退。
///
/// 两份扩展镜像（随 app 打包的 `assets/` 与真源 `tools/`）都守。逐字节一致由
/// `test/build/browser_extension_dict_media_mirror_guard_test.dart` 保证。
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  group('TODO-1271 非视频页制卡回落即时制卡（不误报没有字幕）', () {
    mirrors.forEach((String name, String root) {
      test('[$name] mineEntry 按可裁媒体能力门控：拿不到就走即时制卡回落', () {
        final String src = File('$root/bridge-shim.js').readAsStringSync();

        // 1. mineEntry 必须先取制卡上下文，不再无条件入队视频剪辑队列。
        expect(
          src.contains("var ctx = (typeof window.fushiMineContext === 'function')"),
          isTrue,
          reason: '$root bridge-shim.js mineEntry 未取制卡上下文',
        );

        // 2. 门控判的是「必须回放才拿得到媒体」（mode:queue），不是站点名。
        expect(
          src.contains("if (!(ctx && ctx.clip && ctx.clip.mode === 'queue'))"),
          isTrue,
          reason: '$root bridge-shim.js 未按可裁媒体能力分支即时制卡',
        );
        expect(
          src.contains("var msg = { type: 'mine', fields: args[0], "
              'sentence: sentence };'),
          isTrue,
          reason: '$root bridge-shim.js 非队列回落未走 background type:mine',
        );

        // 3. 例句不得只认 Netflix 的字幕 DOM：任何来源的当前字幕行（外挂字幕 /
        //    整集拦截 / textTracks 收割 / DOM 采样）都要能当例句。少了这一级，
        //    B 站挂了外挂字幕制出来的卡就没有句子。
        expect(
          src.contains('var trackText = (ctx && ctx.window) '
              "? (ctx.window.text || '') : '';"),
          isTrue,
          reason: '$root bridge-shim.js 例句未接当前字幕行（只认 Netflix DOM）',
        );
        // 多句合一制卡在最前面多了一级（用户选的上下文合成句），字幕轨这一级仍在。
        expect(
          src.contains('var sentence = ctxSentence || cueText || trackText'),
          isTrue,
          reason: '$root bridge-shim.js 例句优先级里缺少字幕轨这一级',
        );

        // 4. 立即出卡这条路要带上当前解码帧当封面（取不到才不带）。
        expect(
          src.contains('if (frame && frame.base64) '
              'msg.screenshotBase64 = frame.base64;'),
          isTrue,
          reason: '$root bridge-shim.js 立即制卡未带当前解码帧封面',
        );

        // 5. 视频剪辑队列 + no-cue「没找到当前字幕」提示只保留给必须回放的站点——
        //    该 toast 必须落在门控之后（非队列分支已 return，够不到它）。
        //    锚点取只在代码里出现的整串：注释里若含同样的片段，indexOf 会先命中注释，
        //    顺序断言就变成恒真的空转。
        final int gate =
            src.indexOf("if (!(ctx && ctx.clip && ctx.clip.mode === 'queue'))");
        final int enqueue =
            src.indexOf('window.fushiEnqueue(args[0], sentence)');
        final int noCueToast = src.indexOf("res.reason === 'no-cue'");
        expect(gate >= 0 && enqueue > gate, isTrue,
            reason: '$root bridge-shim.js 视频剪辑入队必须在门控之后');
        expect(noCueToast > gate, isTrue,
            reason: '$root bridge-shim.js「没找到当前字幕」提示必须只在队列分支可达');
      });
    });
  });
}
