import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1271 守卫（源码扫描，不依赖真浏览器）。
///
/// 用户报「这也不是视频，哪来的字幕」：在**普通网页**（非 YouTube/Netflix 流媒体）
/// 上查词后点弹窗「制卡」，扩展弹出 `✗ 没找到当前字幕，稍候再试` 且卡片没建成。
///
/// 根因：批量剪辑重构后 `bridge-shim.js` 的 `mineEntry` **无条件**走视频剪辑队列
/// `window.hibikiEnqueue`，而它要求一个视频时间窗（`hibikiCurrentCueWindowV()`）。
/// 普通网页没有视频/字幕，取窗返回 null → `hibikiEnqueue` 返回 `{reason:'no-cue'}`
/// → 误报「没找到当前字幕」，制卡链路被这条视频专属分支吞掉。
///
/// 根因修复：`mineEntry` 先判 `hibikiSite()`。非 youtube/netflix 的站点回落到
/// background.js 早已存在的 `type:'mine'`（纯文本挖词，直接 POST {fields,sentence}）
/// 立即制卡；剪辑队列 + `no-cue` 提示只对流媒体页保留。
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
      test('[$name] mineEntry 按 hibikiSite 门控：非流媒体走即时制卡回落', () {
        final String src = File('$root/bridge-shim.js').readAsStringSync();

        // 1. mineEntry 必须先判站点，不再无条件入队视频剪辑队列。
        expect(
          src.contains("var site = (typeof hibikiSite === 'function') "
              "? hibikiSite() : 'other';"),
          isTrue,
          reason: '$root bridge-shim.js mineEntry 未按 hibikiSite 门控站点',
        );

        // 2. 非 youtube/netflix 站点回落到 background 的纯文本挖词（type:'mine'）。
        expect(
          src.contains("if (site !== 'youtube' && site !== 'netflix')"),
          isTrue,
          reason: '$root bridge-shim.js 未对非流媒体站点分支即时制卡',
        );
        expect(
          src.contains("{ type: 'mine', fields: args[0], sentence: sentence }"),
          isTrue,
          reason: '$root bridge-shim.js 非流媒体回落未走 background type:mine',
        );

        // 3. 视频剪辑队列 + no-cue「没找到当前字幕」提示只保留给流媒体页——
        //    该 toast 必须落在站点门控之后（非流媒体分支已 return，够不到它）。
        final int gate = src.indexOf("if (site !== 'youtube' "
            "&& site !== 'netflix')");
        final int enqueue =
            src.indexOf('window.hibikiEnqueue(args[0], sentence)');
        final int noCueToast = src.indexOf("res.reason === 'no-cue'");
        expect(gate >= 0 && enqueue > gate, isTrue,
            reason: '$root bridge-shim.js 视频剪辑入队必须在非流媒体门控之后');
        expect(noCueToast > gate, isTrue,
            reason: '$root bridge-shim.js「没找到当前字幕」提示必须只在流媒体分支可达');
      });
    });
  });
}
