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
///
/// TODO-1132 追加（V16 主修遗留、无守卫的两处真实缺口）：
/// - #5 offscreen.endClip() 的 recorder.stop() 异常路径也解绑 onstop/ondataavailable 并
///   清 recorder/chunks（原来只 resolve → 孤儿 recorder + 陈旧 chunks 滞留）。
/// - #6 content.hibikiMaybeResumeNetflixBatch 外层 finally 兜底发 nfStopCapture（原来只在
///   正常路径停录；批量抛错时 tabCapture 流不释放 → M7375 + 流泄漏）。
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

        test('#6 批量外层 finally 兜底 nfStopCapture（异常路径也释放 tabCapture 流）', () {
          final String src = content.readAsStringSync();
          // 外层 finally（复位 hibikiNfBatchRunning 处）内必须发 nfStopCapture：
          // hibikiRunNetflixBatch 抛错时也释放 tabCapture 流，避开 M7375 + 流泄漏。
          final int finallyIdx = src.lastIndexOf('} finally {');
          final int resetIdx =
              src.indexOf('hibikiNfBatchRunning = false;', finallyIdx);
          expect(finallyIdx, greaterThanOrEqualTo(0),
              reason: '${content.path} 缺外层 finally');
          expect(resetIdx, greaterThan(finallyIdx));
          expect(
            src.substring(finallyIdx, resetIdx).contains(
                "chrome.runtime.sendMessage({ type: 'nfStopCapture' })"),
            isTrue,
            reason: '${content.path} 外层 finally 未兜底 nfStopCapture',
          );
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

      test('#5 offscreen ${offscreen.path} endClip 异常路径清理 recorder/chunks', () {
        final String src = offscreen.readAsStringSync();
        // recorder.stop() 抛异常时的 catch 块须清理 recorder/chunks（并解绑回调），
        // 否则孤儿 recorder + 陈旧 chunks 滞留在流上。定位到该 catch 块内断言。
        final int stopFailedIdx = src.indexOf("error: 'stop failed'");
        expect(stopFailedIdx, greaterThanOrEqualTo(0),
            reason: '${offscreen.path} 缺 endClip 错误路径');
        final int catchIdx = src.lastIndexOf('} catch (_) {', stopFailedIdx);
        expect(catchIdx, greaterThanOrEqualTo(0));
        final String catchBlock = src.substring(catchIdx, stopFailedIdx);
        expect(catchBlock.contains('recorder = null;'), isTrue,
            reason: '${offscreen.path} endClip 错误路径未清 recorder');
        expect(catchBlock.contains('chunks = [];'), isTrue,
            reason: '${offscreen.path} endClip 错误路径未清 chunks');
        expect(catchBlock.contains('recorder.ondataavailable = null;'), isTrue,
            reason: '${offscreen.path} endClip 错误路径未解绑 ondataavailable');
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

  // TODO-1170 → TODO-1221：网飞制卡提示走「中间下方短暂 toast」；页面右下角常驻队列 chip 已
  // 整体删除（队列 UI 迁到工具栏图标 popup）。守卫收敛为：content.js 绝无页面浮层常驻 chip
  // （hibikiChip/hibikiRenderQueueList 符号不复活），且 toast 仍是中下短暂定位。源码扫描守卫
  // （不依赖真机/真浏览器），两份镜像都守。
  group('TODO-1170/1221 网飞制卡提示：中下短暂 toast、无右下常驻 chip', () {
    for (final File content in <File>[assetsContent, toolsContent]) {
      group('content.js ${content.path}', () {
        test('绝无页面浮层常驻 chip（hibikiChip 已删，队列 UI 迁到 action-popup）', () {
          final String src = content.readAsStringSync();
          // TODO-1221：右下角常驻 chip 及其渲染彻底删除，绝不复活（否则又落右下角常驻控件）。
          expect(src.contains('hibikiChip'), isFalse,
              reason: '${content.path} 复活了页面浮层常驻 chip（hibikiChip）');
          expect(src.contains('hibikiRenderQueueList'), isFalse,
              reason: '${content.path} 复活了页面内队列列表渲染（应在 action-popup.js）');
          expect(src.contains('document.createElement'), isTrue,
              reason: '${content.path} sanity: 应仍有 DOM 创建（toast 等）');
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

  // TODO-1175 → TODO-1217：网飞批量制卡结束后回到批量前位置并恢复原播放态。批量循环逐句
  // seekTo + 暂停会把视频停在最后一句 + 暂停态；进入批量前记录 currentTime/paused，在外层
  // finally（成功或异常都走）里还原。TODO-1217seek 细化：**仅当批量前正在播放**才回位并续播
  // （暂停态制卡不回跳，消除「跳过去又秒挑回来」的跳动），即 seekTo(resumeAt) 与 v.play() 都
  // 门控进 `if (wasPlaying)`。源码扫描守卫（不依赖真机/真浏览器），两份镜像都守。
  group('TODO-1175/1217 网飞批量制卡后按 wasPlaying 回到原播放位置/态', () {
    for (final File content in <File>[assetsContent, toolsContent]) {
      group('content.js ${content.path}', () {
        test('批量前记录 resumeAt/wasPlaying（video 元素取到之后）', () {
          final String src = content.readAsStringSync();
          expect(src.contains('const resumeAt = v.currentTime;'), isTrue,
              reason: '${content.path} 未记录批量前播放位置 resumeAt');
          expect(src.contains('const wasPlaying = !v.paused;'), isTrue,
              reason: '${content.path} 未记录批量前播放态 wasPlaying');
        });

        test('外层 finally 里按 wasPlaying 门控 seek 回 resumeAt + 续播', () {
          final String src = content.readAsStringSync();
          // 用现有 seekTo（走官方 API seek）回到原位。
          expect(src.contains('try { await seekTo(resumeAt); } catch (_) {}'),
              isTrue,
              reason: '${content.path} finally 未 seek 回批量前位置');
          // 原来在播才回位并续播；原本暂停则不回跳、保持暂停（TODO-1217seek）。
          expect(src.contains('try { await v.play(); } catch (_) {}'), isTrue,
              reason: '${content.path} finally 未续播 v.play()');
          // 回位 + 续播都必须门控进 if (wasPlaying)：门在两者之前。
          final int gateIdx = src.indexOf('if (wasPlaying) {');
          final int seekBackIdx =
              src.indexOf('try { await seekTo(resumeAt); } catch (_) {}');
          final int playIdx = src.indexOf(
              'try { await v.play(); } catch (_) {}',
              seekBackIdx >= 0 ? seekBackIdx : 0);
          expect(gateIdx, greaterThanOrEqualTo(0),
              reason: '${content.path} 缺 if (wasPlaying) 门控');
          expect(seekBackIdx, greaterThan(gateIdx),
              reason: '${content.path} seek 回位未门控进 wasPlaying');
          expect(playIdx, greaterThan(seekBackIdx),
              reason: '${content.path} 续播未门控进 wasPlaying（应在 seek 之后）');
          // 还原必须在外层 finally（还原光标那块）里，才能成功/异常都走到。
          final int cursorIdx =
              src.indexOf('document.body.style.cursor = prevCursor;');
          expect(cursorIdx, greaterThanOrEqualTo(0));
          expect(seekBackIdx, greaterThan(cursorIdx),
              reason: '${content.path} 位置还原未与光标还原同处外层 finally');
        });

        test('内容脚本版本标记 bump 到 v46（用户可确认新版）', () {
          final String src = content.readAsStringSync();
          expect(src.contains("'data-hibiki-cs', 'v46'"), isTrue,
              reason: '${content.path} 版本标记未 bump 到 v46');
          expect(src.contains('content script v46 loaded'), isTrue,
              reason: '${content.path} 加载日志版本未 bump 到 v46');
        });
      });
    }
  });

  // TODO-1335 ④：网飞回放录制在 seek 落点**等缓冲就绪再开录**。Netflix seek 完成(seeked)时
  // 数据常还没缓冲到位(readyState=HAVE_CURRENT_DATA=2)，此刻 beginClip 会录进 stall 冻结帧，
  // 而 offscreen 墙钟时长照走 → 录制起点是冻结帧、时长虚长不准。修复：暂停态等
  // readyState>=HAVE_FUTURE_DATA(3) 再 play + beginClip（暂停不推进 currentTime → 保留 200ms
  // 头部提前量）。源码扫描守卫，两份镜像都守。
  group('TODO-1335 网飞录制 seek 后等缓冲就绪再开录', () {
    for (final File content in <File>[assetsContent, toolsContent]) {
      group('content.js ${content.path}', () {
        test('有 hibikiWaitForBuffered 缓冲门（readyState>=HAVE_FUTURE_DATA=3）', () {
          final String src = content.readAsStringSync();
          expect(
              src.contains('function hibikiWaitForBuffered(v, maxMs)'), isTrue,
              reason: '${content.path} 缺 hibikiWaitForBuffered 缓冲就绪门');
          expect(src.contains('v.readyState >= 3'), isTrue,
              reason: '${content.path} 缓冲门未用 HAVE_FUTURE_DATA(3) 阈值');
        });

        test('beginClip 前先暂停 + 等 seek 落定 + 等缓冲就绪（不吃头部提前量）', () {
          final String src = content.readAsStringSync();
          // seek 后暂停态依次等待：v.pause() → hibikiWaitForSeekSettled →
          // hibikiWaitForBuffered → beginClip（暂停不推进 currentTime → 保留 200ms
          // 头部提前量）。TODO-1361（BUG-685）在暂停与缓冲门之间加了 seek 落定门。
          final int pauseIdx = src.indexOf('try { v.pause(); } catch (_) {}');
          final int settledIdx = src
              .indexOf('await hibikiWaitForSeekSettled(v, targetSec, 4000);');
          final int bufIdx =
              src.indexOf('await hibikiWaitForBuffered(v, 3000);');
          final int beginIdx = src.indexOf("type: 'beginClip'");
          expect(pauseIdx, greaterThanOrEqualTo(0),
              reason: '${content.path} seek 后未暂停（保留头部提前量）');
          expect(settledIdx, greaterThan(pauseIdx),
              reason: '${content.path} seek 落定门未排在暂停之后');
          expect(bufIdx, greaterThan(settledIdx),
              reason: '${content.path} 缓冲门未排在 seek 落定门之后');
          expect(beginIdx, greaterThan(bufIdx),
              reason: '${content.path} 缓冲门未排在 beginClip 之前');
        });

        test('旧的固定 sleep(150) 首帧稳定 warmup 已被缓冲门取代', () {
          final String src = content.readAsStringSync();
          expect(src.contains('await sleep(150); // 让首帧稳定'), isFalse,
              reason: '${content.path} 仍残留固定 sleep(150) 首帧稳定 warmup');
        });
      });
    }
  });
}
