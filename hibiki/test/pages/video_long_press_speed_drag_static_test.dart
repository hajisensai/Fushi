import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 长按倍速可顺滑横向拖动连续调速（TODO-338）的守卫。
///
/// **根因**：长按倍速原本是二段式——[_handleVideoLongPressStart] 设固定加速速
/// （`_asbConfig.longPressSpeed`，如 2x），[_handleVideoLongPressEnd] 松手恢复原速；
/// 手势只绑 `onLongPressStart` / `onLongPressEnd`，**没有 `onLongPressMoveUpdate`**，
/// 故长按后横向拖动期间倍速纹丝不动，只能在松手那一刻看到结果。
///
/// **修法**：加 `onLongPressMoveUpdate` → [_handleVideoLongPressMoveUpdate]，以长按
/// 固定加速速为基准，把相对长按起点的横向位移（右正左负）按
/// [VideoHibikiPage.longPressDragSpeedPerPixel] 线性映射、clamp 到 0.5..4.0、snap 到
/// 0.1x 步进，连续 setSpeed（不持久），松手恢复原速。
///
/// media_kit/libmpv 在测试宿主不可用，无法纯单测真实拖动手势，故守两层：
/// 1. 纯函数 [VideoHibikiPage.longPressDragSpeedFor] 的映射 / clamp / snap 逻辑；
/// 2. 源码守卫：手势绑了 onLongPressMoveUpdate、handler 以基准速连续调速、松手清基准。
///
/// TODO-590 batch12：长按倍速三段 handler ([_handleVideoLongPressStart] /
/// [_handleVideoLongPressMoveUpdate] / [_handleVideoLongPressEnd]) 随 speed 域
/// 抽到 video_hibiki/speed.part.dart，故源码守卫改读合并语料（主壳 + part）；手势
/// 绑定点仍在主壳的 build 体里，`_functionSource` 切片落在 part 里的方法体。
void main() {
  group('longPressDragSpeedFor — 横向位移→倍速映射', () {
    const double base = 2.0; // 长按固定加速速。

    test('零位移 → 维持基准速', () {
      expect(VideoHibikiPage.longPressDragSpeedFor(base, 0), 2.0);
    });

    test('向右拖加速、向左拖减速（200px ≈ 1.0x）', () {
      // 右 200px → 2.0 + 1.0 = 3.0x。
      expect(VideoHibikiPage.longPressDragSpeedFor(base, 200), 3.0);
      // 左 200px → 2.0 - 1.0 = 1.0x。
      expect(VideoHibikiPage.longPressDragSpeedFor(base, -200), 1.0);
    });

    test('snap 到 0.1x 步进（避免每像素抖动）', () {
      // 右 36px → 2.0 + 0.18 = 2.18 → snap 2.2（向上）。
      expect(VideoHibikiPage.longPressDragSpeedFor(base, 36), 2.2);
      // 右 24px → 2.0 + 0.12 = 2.12 → snap 2.1（向下）。
      expect(VideoHibikiPage.longPressDragSpeedFor(base, 24), 2.1);
    });

    test('clamp 到 0.5..4.0（拖过界不溢出）', () {
      expect(VideoHibikiPage.longPressDragSpeedFor(base, 100000),
          VideoHibikiPage.longPressDragMaxSpeed);
      expect(VideoHibikiPage.longPressDragSpeedFor(base, -100000),
          VideoHibikiPage.longPressDragMinSpeed);
    });

    test('上下限常量取值（0.5 / 4.0）', () {
      expect(VideoHibikiPage.longPressDragMinSpeed, 0.5);
      expect(VideoHibikiPage.longPressDragMaxSpeed, 4.0);
    });
  });

  group('源码接线守卫', () {
    final String page = readVideoHibikiSource();

    test('手势绑了 onLongPressMoveUpdate（与 start/end 同处）', () {
      expect(
        page.contains(
          'onLongPressMoveUpdate: _handleVideoLongPressMoveUpdate,',
        ),
        isTrue,
        reason: '没有 onLongPressMoveUpdate 就无法长按后连续拖动调速（TODO-338）',
      );
      // 仍保留长按即固定加速 + 松手恢复的基础行为。
      expect(page.contains('onLongPressStart: _handleVideoLongPressStart,'),
          isTrue);
      expect(
          page.contains('onLongPressEnd: _handleVideoLongPressEnd,'), isTrue);
    });

    test('长按起点记录基准速，move 以基准速连续调速、松手清基准', () {
      // start 记录基准速（= 固定加速速 longPressSpeed）。
      final String start = _functionSource(
        page,
        'void _handleVideoLongPressStart(',
        'void _handleVideoLongPressMoveUpdate(',
      );
      expect(start.contains('_longPressDragBaseSpeed = speed;'), isTrue,
          reason: 'start 必须把固定加速速记为拖动基准');

      // move 以基准速 + 纯函数映射连续调速（不持久）。
      final String move = _functionSource(
        page,
        'void _handleVideoLongPressMoveUpdate(',
        'void _handleVideoLongPressEnd(',
      );
      expect(move.contains('final double? base = _longPressDragBaseSpeed;'),
          isTrue);
      expect(move.contains('if (base == null) return;'), isTrue,
          reason: '非长按手势中（无基准）不响应拖动');
      expect(
        move.contains('VideoHibikiPage.longPressDragSpeedFor('),
        isTrue,
        reason: 'move 必须经纯函数映射横向位移',
      );
      expect(move.contains('localOffsetFromOrigin.dx'), isTrue,
          reason: '用相对长按起点的横向位移驱动调速');
      expect(move.contains('_setSpeed(snapped, persist: false)'), isTrue,
          reason: '拖动调速不持久（松手要恢复原速）');

      // end 恢复原速并清基准。
      final String end = _functionSource(
        page,
        'void _handleVideoLongPressEnd(',
        'Future<void> _adjustSpeed(',
      );
      expect(end.contains('_longPressDragBaseSpeed = null;'), isTrue,
          reason: '松手必须清基准，否则下次手势误判仍在拖动中');
      expect(end.contains('_setSpeed(previous, persist: false)'), isTrue,
          reason: '松手恢复长按前的原速');
    });
  });
}

/// 截取 [source] 中从 [start] 标记到 [end] 标记之间的源码片段（含 [start]、不含 [end]）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
