import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_text_render.dart';

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
        highlight: const Color(0x66FFCC00),
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
    '(fontSize>0, horizontal landscape 1920x1080) (BUG-490 / TODO-1147)',
    () {
      expect(triggerText.runes.length, 18);
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: triggerText.runes.length,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.6,
        background: const Color(0xFF101010),
        foreground: const Color(0xFFF0F0F0),
        highlight: const Color(0x66FFCC00),
      );
      expect(layout.fontSize, greaterThan(0));
      // TODO-1147：横排（vertical:false）默认横屏 1920×1080（用户回访「分辨率
      // 不对」；像素总量与旧 1080×1920 相同，防模糊不回退）。
      expect(layout.width, 1920);
      expect(layout.height, 1080);
    },
  );

  // TODO-1115：多句逐帧高亮渲染守卫。
  testWidgets(
    'renderAudiobookClipFrames highlights the requested sentence per frame '
    '(distinct PNGs, TODO-1115)',
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
        textLength: 4,
        baseFontSize: 40,
        vertical: false,
        lineHeight: 1.6,
        background: const Color(0xFF000000),
        foreground: const Color(0xFFFFFFFF),
        // 不透明高亮色，最大化「哪一句被涂」的像素差异。
        highlight: const Color(0xFFFF0000),
      );
      final List<AudiobookClipTextSegment> segments =
          <AudiobookClipTextSegment>[
        const AudiobookClipTextSegment(text: '第一句です'),
        const AudiobookClipTextSegment(text: '第二句です'),
      ];

      // TODO-1167：renderAudiobookClipFrames 改为逐帧回调（流式），测试自己收集帧字节。
      final List<Uint8List?> frames = <Uint8List?>[];
      await tester.runAsync(() async {
        bool done = false;
        final Future<void> future = renderAudiobookClipFrames(
          overlay: overlay,
          segments: segments,
          layout: layout,
          highlightIndices: <int>[0, 1],
          onFrame: (int highlightIndex, Uint8List? png) async {
            frames.add(png);
            return true; // 收全部帧
          },
        ).whenComplete(() {
          done = true;
        });
        // 两帧串行渲染，各需多帧推进离屏 pipeline；持续泵帧直到整体完成（上限保护）。
        for (int i = 0; i < 200 && !done; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await future;
      });

      expect(frames.length, 2);
      expect(frames[0], isNotNull, reason: 'frame highlighting sentence 0');
      expect(frames[1], isNotNull, reason: 'frame highlighting sentence 1');
      expect(frames[0]!.isNotEmpty, isTrue);
      expect(frames[1]!.isNotEmpty, isTrue);
      // PNG 魔数。
      expect(frames[0]!.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
      expect(frames[1]!.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
      // 高亮句不同 → 两帧字节必然不同（高亮衬底位置随句子移动）。
      expect(frames[0], isNot(equals(frames[1])),
          reason: 'moving the highlight to a different sentence must change '
              'the rendered pixels');
    },
  );

  test(
    'source guard: highlighted line uses layout.highlight, others plain fg '
    '(TODO-1115)',
    () {
      final File src = File(
        'lib/src/media/audiobook/audiobook_clip_text_render.dart',
      );
      final String code = src.readAsStringSync();
      // 高亮句用 highlight 衬底；判据是 highlightIndex 命中当前句。
      expect(code.contains('i == widget.highlightIndex'), isTrue,
          reason: 'the highlighted sentence is chosen by highlightIndex');
      expect(code.contains('color: layout.highlight'), isTrue,
          reason:
              'highlighted line paints the sentenceAudioHighlight highlight backing');
      // 批量渲染入口存在。
      expect(code.contains('renderAudiobookClipFrames'), isTrue);
    },
  );
}
