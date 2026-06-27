import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 反向守卫（TODO-899）：桌面端「画面边缘竖拖调音量/亮度」手势（原 TODO-754）已移除。
///
/// **背景**：TODO-754 曾在桌面给 [layout.part.dart] 的 [GestureDetector] 加一组
/// onVerticalDrag*（左半区调亮度 / 右半区调音量），是桌面专属 Flutter 竖拖手势。
/// 用户反馈这个手势在桌面误触多、不想要 → TODO-899 整体删除（接线 + 三 handler +
/// 状态字段 + 纯函数/常量），不留替代入口（桌面已有音量条 UI + 方向键音量）。
///
/// 移动端竖滑是另一条独立路径：media_kit 内建 volumeGesture / brightnessGesture
/// （见 [_mobileControlsTheme]），与桌面手势零共享，本次不动 → 正向断言其仍启用，
/// 防止误删移动端功能。
///
/// 守卫只能落在源码层：media_kit/libmpv 在测试宿主不可用，无法真实拖动；且这是
/// 「不该再存在的代码」的反向守卫，源码断言比 widget 行为更精确、能防日后被加回来。
void main() {
  group('TODO-899 反向守卫 — 桌面边缘竖拖手势已删除', () {
    final String page = readVideoHibikiSource();

    test('GestureDetector 不再绑 onVerticalDrag*（接线已删）', () {
      expect(
        page.contains('onVerticalDragStart:'),
        isFalse,
        reason: '桌面不应再有竖拖手势入口（TODO-899 已删 TODO-754 接线）',
      );
      expect(page.contains('onVerticalDragUpdate:'), isFalse);
      expect(page.contains('onVerticalDragEnd:'), isFalse);
    });

    test('三个 edge-drag handler 定义已删', () {
      expect(
        page.contains('_handleVideoEdgeDragStart('),
        isFalse,
        reason: 'start handler 应随手势一并删除',
      );
      expect(page.contains('_handleVideoEdgeDragUpdate('), isFalse);
      expect(page.contains('_handleVideoEdgeDragEnd('), isFalse);
    });

    test('edge-drag 状态字段已删', () {
      expect(
        page.contains('_edgeDragIsRightHalf'),
        isFalse,
        reason: '拖动状态字段应随手势一并删除（无残留 unused_field）',
      );
      expect(page.contains('_edgeDragStartValue'), isFalse);
      expect(page.contains('_edgeDragStartDy'), isFalse);
    });

    test('edge-drag 纯函数 / 灵敏度常量已删', () {
      expect(page.contains('edgeDragValueDeltaFor'), isFalse,
          reason: '纯函数无调用方应删除');
      expect(page.contains('edgeDragVerticalSensitivity'), isFalse,
          reason: '灵敏度常量无引用应删除');
    });

    test('保留勿删的共享逻辑仍在（删手势没误伤其它入口）', () {
      // 音量统一入口（方向键 / 音量条 / 移动端回调都走它）。
      expect(page.contains('_applyUserVideoVolume('), isTrue,
          reason: '音量统一入口是共享逻辑，不属本手势私有');
      // 页面级 HUD（移动端 media_kit 竖滑 + 音量条仍在用）。
      expect(page.contains('_showVolumeOsd('), isTrue);
      expect(page.contains('_showBrightnessOsd('), isTrue);
    });
  });

  group('TODO-899 正向守卫 — 移动端 media_kit 竖滑保留', () {
    final String page = readVideoHibikiSource();

    test('移动控制条仍启用 media_kit volumeGesture / brightnessGesture', () {
      // 移动端竖滑是独立路径，与被删的桌面手势零共享，必须保留。
      expect(page.contains('volumeGesture: true'), isTrue,
          reason: '移动端 media_kit 音量竖滑不应被误删');
      expect(page.contains('brightnessGesture:'), isTrue,
          reason: '移动端 media_kit 亮度竖滑不应被误删');
    });
  });
}
