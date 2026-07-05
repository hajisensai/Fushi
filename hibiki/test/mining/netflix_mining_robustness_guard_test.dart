import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// V16 审查标的：Netflix/YouTube 批量制卡录制健壮性 4 修守卫。源码扫描（不依赖真机/真浏览器），
/// 守住修复不被回退。两份扩展镜像（随 app 打包的 `assets/` 与真源 `tools/`）都守。
///
/// 覆盖：
/// - #1 查词即暂停**仅对 Netflix**（不再对页面任意 <video> 暂停 → UX 副作用）。
/// - #2 Netflix 批量循环 beginClip→endClip 收口放 finally（异常也收口录制器，防状态叠加）。
/// - #3 MediaRecorder 孤儿防御（offscreen beginClip 先停旧 recorder）+ hideStyle/cursor 还原放 finally。
/// - #4 每句时间窗死代码已删（扩展 mineClip 不发段内窗/gifEnd；dart transcodeClipToCapture 去掉
///   windowStartMs/windowEndMs/gifEndMs；payload 去掉 clipGifEndMs）。
void main() {
  // flutter test 的 cwd 是 hibiki 包根。两份镜像分别在 assets/ 与 ../tools/。
  final File assetsContent = File('assets/browser_extension/content.js');
  final File toolsContent = File('../tools/browser-extension/content.js');
  final File assetsOffscreen = File('assets/browser_extension/offscreen.js');
  final File toolsOffscreen = File('../tools/browser-extension/offscreen.js');
  final File assetsBg = File('assets/browser_extension/background.js');
  final File toolsBg = File('../tools/browser-extension/background.js');

  group('V16 Netflix 录制健壮性守卫', () {
    for (final File content in <File>[assetsContent, toolsContent]) {
      group('content.js ${content.path}', () {
        test('文件存在', () {
          expect(content.existsSync(), isTrue,
              reason: 'missing ${content.path}');
        });

        test('#1 查词暂停仅门控 Netflix（不对任意 <video> 暂停）', () {
          final String src = content.readAsStringSync();
          // 暂停必须包在 hibikiSite()==='netflix' 门里。
          expect(
            src.contains("if (hibikiSite() === 'netflix') {\n"
                "    try { const _v = document.querySelector('video'); if (_v && !_v.paused) _v.pause(); } catch (_) {}\n"
                '  }'),
            isTrue,
            reason: '${content.path} 查词暂停未门控到 Netflix',
          );
          // 不得再有顶层（2 空格缩进）未门控的查词暂停。
          expect(
            src.contains(
                "\n  try { const _v = document.querySelector('video'); if (_v && !_v.paused) _v.pause(); } catch (_) {}"),
            isFalse,
            reason: '${content.path} 仍残留未门控的查词暂停（对任意 video 生效）',
          );
        });

        test('#2 beginClip 成功标记 + endClip 收口在 finally', () {
          final String src = content.readAsStringSync();
          expect(src.contains('began = !!(beginResp && beginResp.ok);'), isTrue,
              reason: '${content.path} 未按 beginClip 结果标记 began');
          // finally 里按 began 收口录制器。
          expect(
            src.contains('if (began) {') && src.contains("type: 'endClip'"),
            isTrue,
            reason: '${content.path} 未在 finally 里收口 recorder',
          );
          // 至少两个 finally：per-item 录制器收口 + 外层样式还原。
          expect('} finally {'.allMatches(src).length, greaterThanOrEqualTo(2),
              reason: '${content.path} finally 收口块不足（应 >=2）');
        });

        test('#3 hideStyle/cursor 还原在 finally（不泄漏可见副作用）', () {
          final String src = content.readAsStringSync();
          expect(src.contains('const prevCursor = document.body.style.cursor;'),
              isTrue,
              reason: '${content.path} 未捕获 prevCursor 以还原光标');
          expect(
              src.contains('document.body.style.cursor = prevCursor;'), isTrue,
              reason: '${content.path} 未把光标还原放进 finally');
          expect(src.contains('hideStyle.remove()'), isTrue,
              reason: '${content.path} 缺 hideStyle 还原');
          // 旧的循环外裸还原（cursor 硬写 '' 不在 finally）不得残留。
          expect(src.contains("document.body.style.cursor = '';"), isFalse,
              reason: '${content.path} 仍残留循环外裸还原光标');
        });

        test('#4 扩展 mineClip 不发段内窗/gifEnd 死偏移', () {
          final String src = content.readAsStringSync();
          expect(src.contains('clipGifEndMs'), isFalse,
              reason: '${content.path} 残留 clipGifEndMs 死偏移');
        });
      });
    }

    for (final File offscreen in <File>[assetsOffscreen, toolsOffscreen]) {
      test('#3 offscreen ${offscreen.path} beginClip 防孤儿 recorder', () {
        final String src = offscreen.readAsStringSync();
        // beginClip 新建前先停旧 recorder（解绑 ondataavailable 是 beginClip 独有，stopCapture 只解 onstop）。
        expect(
          src.contains(
              'recorder.onstop = null; recorder.ondataavailable = null; recorder.stop();'),
          isTrue,
          reason: '${offscreen.path} beginClip 未先停旧 recorder（孤儿泄漏）',
        );
      });
    }

    for (final File bg in <File>[assetsBg, toolsBg]) {
      test('#4 background ${bg.path} mineClip 不带 clipGifEndMs', () {
        final String src = bg.readAsStringSync();
        expect(src.contains('clipGifEndMs'), isFalse,
            reason: '${bg.path} mineClip 残留 clipGifEndMs 死偏移');
      });
    }

    test('两份镜像逐字节一致（content.js）', () {
      expect(assetsContent.readAsBytesSync(), toolsContent.readAsBytesSync(),
          reason: 'content.js 两份镜像不一致');
    });
    test('两份镜像逐字节一致（offscreen.js）', () {
      expect(
          assetsOffscreen.readAsBytesSync(), toolsOffscreen.readAsBytesSync(),
          reason: 'offscreen.js 两份镜像不一致');
    });
  });

  group('V16#4 dart 侧时间窗死代码已删', () {
    test('immersion_mine_payload.dart 无 clipGifEndMs', () {
      final String src =
          File('lib/src/sync/immersion_mine_payload.dart').readAsStringSync();
      expect(src.contains('clipGifEndMs'), isFalse,
          reason: 'payload 残留 clipGifEndMs 死字段');
    });
    test(
        'immersion_capture_channel.dart transcodeClipToCapture 无 window/gifEnd 参数',
        () {
      final String src = File('lib/src/mining/immersion_capture_channel.dart')
          .readAsStringSync();
      expect(src.contains('windowStartMs'), isFalse,
          reason: '残留 windowStartMs 死参数');
      expect(src.contains('windowEndMs'), isFalse,
          reason: '残留 windowEndMs 死参数');
      expect(src.contains('gifEndMs'), isFalse, reason: '残留 gifEndMs 死参数');
    });
    test('app_model.dart clipBytes 分支不接线 windowStartMs', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('windowStartMs: payload.clipStartMs'), isFalse,
          reason: 'app_model 仍接线已删的 windowStartMs');
    });
  });

  // TODO-1170：网飞制卡提示不再在右下角常驻小控件，改成「中间下方短暂 toast」。
  // 源码扫描守卫（不依赖真机/真浏览器），两份镜像都守；内容不变，只改位置 + 停留。
  group('TODO-1170 网飞制卡提示：中下短暂 toast、非右下常驻', () {
    for (final File content in <File>[assetsContent, toolsContent]) {
      group('content.js ${content.path}', () {
        test('Netflix 分支隐藏常驻 chip、只在队列增长时弹短暂 toast（内容不变）', () {
          final String src = content.readAsStringSync();
          // Netflix 走短暂提示：隐藏右下角常驻 chip。
          expect(
              src.contains(
                  "if (hibikiChip) hibikiChip.style.display = 'none';"),
              isTrue,
              reason: '${content.path} Netflix 未隐藏右下角常驻 chip');
          // 只在队列**增长**时弹一次（避免加载/删除/跨标签同步刷屏）。
          expect(
              src.contains(
                  "if (total > hibikiLastQueueTotal && typeof window.hibikiToast === 'function')"),
              isTrue,
              reason: '${content.path} Netflix toast 未按队列增长门控');
          // 提示内容保持不变（与旧 chip 文案一致）。
          expect(
              src.contains(
                  "window.hibikiToast('制卡队列 ' + total + ' · 点扩展图标生成本片 ' + here);"),
              isTrue,
              reason: '${content.path} Netflix 提示文案被改动');
        });

        test('Netflix 分支在常驻 chip 创建之前 return（绝不落右下角）', () {
          final String src = content.readAsStringSync();
          final int nfIdx =
              src.indexOf("if (hibikiChip) hibikiChip.style.display = 'none';");
          final int chipIdx =
              src.indexOf('hibikiChip = document.createElement');
          expect(nfIdx, greaterThanOrEqualTo(0),
              reason: '${content.path} 缺 Netflix 短暂 toast 分支');
          expect(chipIdx, greaterThan(nfIdx),
              reason: '${content.path} Netflix 分支须在常驻 chip 创建前 return');
        });

        test('hibikiToast 定位为中间下方、非 sticky 时 5s 自动淡出（短暂）', () {
          final String src = content.readAsStringSync();
          // 中间下方：left:50% + translateX(-50%) + bottom（不是右下角固定）。
          expect(
              src.contains(
                  'position:fixed;left:50%;bottom:64px;transform:translateX(-50%);'),
              isTrue,
              reason: '${content.path} hibikiToast 不是中间下方定位');
          // 非 sticky：5000ms 后自动淡出（短暂、不常驻）。
          expect(
              src.contains(
                  "if (!sticky) hibikiToastTimer = setTimeout(() => { if (t) t.style.opacity = '0'; }, 5000);"),
              isTrue,
              reason: '${content.path} hibikiToast 非 sticky 时未自动淡出');
        });
      });
    }
  });
}
