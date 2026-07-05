import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-553 源码守卫：字幕盒的 tap 命中必须**按字符矩形门控竞技场**，不得回退到无条件
/// 收下所有 tap 的整片 GestureDetector。
///
/// 根因：字幕 overlay（[Positioned.fill]）盖在 media_kit `AdaptiveVideoControls` 之上；
/// 旧实现用整片 translucent GestureDetector 包字幕盒，任何落在盒内的 tap 都无条件加入
/// 手势竞技场、赢下裁决，连字符间空白的 tap 也 reject 掉 media_kit 的 show-controls
/// onTap。移动端无 hover 兜底 → 有字幕在屏时点画面唤不出控制条。
///
/// 修复：把 tap 识别器换成 [_SubtitleCharTapRecognizer]（`isPointerAllowed` 仅在按下点
/// 命中字符时才收指针、进竞技场），并保留整片 translucent 命中语义（media_kit 仍在命中
/// 路径 / hover 透传不回归，BUG-198）。真实竞技场时序 headless 跑不了，故锁源码结构。
void main() {
  final File src = File('lib/src/media/video/video_subtitle_overlay.dart');

  late String code;
  setUpAll(() {
    expect(src.existsSync(), isTrue,
        reason: 'video_subtitle_overlay.dart 必须存在');
    code = src.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('存在按字符门控的 tap 识别器（isPointerAllowed 门控竞技场）', () {
    expect(
      code.contains(
          'class _SubtitleCharTapRecognizer extends TapGestureRecognizer'),
      isTrue,
      reason: 'BUG-553：字幕 tap 必须走按字符门控的 _SubtitleCharTapRecognizer',
    );
    expect(
      RegExp(r'bool isPointerAllowed\(PointerDownEvent event\)').hasMatch(code),
      isTrue,
      reason: '须以 isPointerAllowed 承载「按下点命中字符才进竞技场」的门控',
    );
    // 门控判据：未命中字符即拒收指针（返回 false）。
    expect(
      RegExp(r'if \(!hitTestChar\(event\.position\)\) return false;')
          .hasMatch(code),
      isTrue,
      reason: '门控必须在未命中字符时拒收指针（让 media_kit 竞技场胜出）',
    );
  });

  test('字符点击经 RawGestureDetector + 门控识别器承载，不再无条件收下全部 tap', () {
    // 锚定 onCharTap 的手势块（从 `if (widget.onCharTap != null)` 到其后紧邻的
    // `if (blurred)` 块之前）。
    final int start = code.indexOf('if (widget.onCharTap != null) {');
    expect(start, greaterThanOrEqualTo(0), reason: '未找到 onCharTap 的手势块');
    final int end = code.indexOf('if (blurred) {', start);
    expect(end, greaterThan(start));
    final String block = code.substring(start, end);

    expect(block.contains('RawGestureDetector'), isTrue,
        reason: 'BUG-553：字符点击须经 RawGestureDetector + 门控识别器承载');
    expect(block.contains('_SubtitleCharTapRecognizer'), isTrue,
        reason: '字符点击的手势识别器必须是 _SubtitleCharTapRecognizer');
    // 仍是 translucent：hover 透传 / media_kit 在命中路径不回归（BUG-198）。
    expect(block.contains('HitTestBehavior.translucent'), isTrue,
        reason: 'BUG-553 修复不得改变 translucent 命中语义（否则 BUG-198 hover 回归）');
    // 不得再用普通 GestureDetector 无条件收 tap（旧根因结构）。
    expect(block.contains('box = GestureDetector('), isFalse,
        reason: 'BUG-553：字符点击不得再用无条件收 tap 的整片 GestureDetector');
  });
}
