import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';

/// TODO-1071 / BUG-490：`renderAudiobookClipTextToPng` 离屏栅格化返 null 根因修复守卫。
///
/// 三层：
/// 1. widget test（真 Overlay + 真 pipeline）驱动渲染函数喂用户触发文本，断言返回非 null
///    且字节非空 —— 此前该函数零覆盖，返 null 才是原始 bug。
/// 2. 源码守卫：断言 `catch (e, st)` 分支记 `ErrorLogService.instance.log(...clipToImageThrew)`，
///    防有人回退到裸 `catch (_) { return null; }` 静默吞异常。
/// 3. 纯函数守卫：18 runes 拗音开头（原始触发文本）→ fontSize>0 且 720×1280。
void main() {
  // 用户触发的原始文本：18 runes，拗音「ょ」开头。
  const String triggerText = 'ょっと面倒だったりする。今は尚更だ。';

  testWidgets(
    'renderAudiobookClipTextToPng returns non-empty PNG for the '
    'user trigger text (BUG-490)',
    (WidgetTester tester) async {
      final GlobalKey<OverlayState> overlayKey = GlobalKey<OverlayState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Overlay(
            key: overlayKey,
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (BuildContext context) => const SizedBox.expand(),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final OverlayState overlay = overlayKey.currentState!;
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: triggerText.runes.length,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.6,
        background: const Color(0xFF101010),
        foreground: const Color(0xFFF0F0F0),
      );

      Uint8List? png;
      // 渲染依赖真实帧调度（scheduleFrame + post-frame），必须在 runAsync 里跑，
      // 并配合 tester.pump 推进离屏 pipeline 完成 paint。
      await tester.runAsync(() async {
        final Future<Uint8List?> future = renderAudiobookClipTextToPng(
          overlay: overlay,
          text: triggerText,
          layout: layout,
        );
        // 推进若干帧让离屏 boundary 完成 layout/paint。
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        png = await future;
      });

      expect(png, isNotNull,
          reason: 'clip text render must not swallow into null (BUG-490)');
      expect(png!.isNotEmpty, isTrue, reason: 'PNG bytes must be non-empty');
      // PNG 魔数守卫：89 50 4E 47。
      expect(png!.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    },
  );

  test(
    'source guard: catch branch logs clipToImageThrew (never a bare '
    'return null) (BUG-490)',
    () {
      final File src = File(
        'lib/src/media/audiobook/audiobook_clip_text_render.dart',
      );
      expect(src.existsSync(), isTrue,
          reason: 'run tests from hibiki/ package root');
      final String code = src.readAsStringSync();
      // 必须捕获异常带 stack 并记日志，禁止裸 catch (_) { return null; }。
      expect(code.contains('catch (e, st)'), isTrue,
          reason: 'exception must be captured with stack, not swallowed');
      expect(code.contains('clipToImageThrew'), isTrue,
          reason: 'toImage/toByteData failures must be logged in-app');
      expect(
        RegExp(r'catch\s*\(\s*_\s*\)\s*\{\s*return null;').hasMatch(code),
        isFalse,
        reason: 'must not regress to a bare swallowing catch',
      );
    },
  );

  test(
    'computeClipTextLayout: 18-rune yoon-initial trigger stays sane '
    '(fontSize>0, 720x1280) (BUG-490)',
    () {
      expect(triggerText.runes.length, 18);
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: triggerText.runes.length,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.6,
        background: const Color(0xFF101010),
        foreground: const Color(0xFFF0F0F0),
      );
      expect(layout.fontSize, greaterThan(0));
      expect(layout.width, 720);
      expect(layout.height, 1280);
    },
  );
}
