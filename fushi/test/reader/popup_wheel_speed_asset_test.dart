import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1026 回归守卫：查词弹窗滚轮速度可配置。
///
/// 根因：popup.js 的滚轮步长过去完全由硬编码常量决定（粗鼠标 notch 0.24 / 触控板 1.0），
/// 用户觉得慢也无法调节。修复引入一个 app 偏好 `popup_wheel_speed`（倍率，默认 1.0），
/// 一处存储驱动全部弹窗表面：
///   - in-app 三种弹窗：popup_settings_injection 注入 window.__fushiPopupWheelSpeed；
///   - 浏览器扩展弹窗：查词响应 theme 通道下发 --fushi-wheel-speed，由 content.js
///     读成同名全局（content.js 与 popup.js 同隔离世界共享 window）。
/// popup.js 三份镜像把 factor 乘以该倍率。任一环断掉滑杆就变成哑设置，故逐环锁死。
///
/// flutter test cwd 是 hibiki 包根。
void main() {
  const List<String> popupCopies = <String>[
    'assets/popup/popup.js', // in-app 渲染器（真源）
    'assets/browser_extension/vendor/popup.js', // 扩展 bundle 镜像
    '../tools/browser-extension/vendor/popup.js', // 扩展 tools 镜像
  ];

  const List<String> contentCopies = <String>[
    'assets/browser_extension/content.js',
    '../tools/browser-extension/content.js',
  ];

  group('popup.js 三份镜像都按可配置倍率缩放滚轮步长 (BUG-1026)', () {
    for (final String path in popupCopies) {
      test('[$path] wheel factor 乘以 __fushiPopupWheelSpeed', () {
        final String src = File(path).readAsStringSync();

        expect(src, contains('window.__fushiPopupWheelSpeed'),
            reason: 'popup.js 必须读注入的滚轮速度倍率，否则设置项是哑的');
        // 设备分类（粗鼠标 / 触控板）必须保留，倍率只在其外层相乘。
        expect(src, contains('? POPUP_WHEEL_PIXEL_FACTOR'),
            reason: 'BUG-870 的粗鼠标/触控板设备分类不得被倍率改造抹掉');
        expect(src, contains(': POPUP_WHEEL_TRACKPAD_FACTOR'));
        expect(src, contains('* wheelSpeed'),
            reason: '倍率必须真的乘进 factor，而不是读了就丢');
        expect(src, contains('deltaPx * factor'),
            reason: '每帧步长仍由 factor 决定（BUG-260/870 既有链路不变）');
        // 缺省/非法值必须回落 1.0：旧 app + 新扩展、或注入尚未到达时，行为与改前一致。
        expect(
            src, contains("typeof window.__fushiPopupWheelSpeed === 'number'"),
            reason: '必须做类型/有限性校验，非法值不得把滚动放飞或归零');
      });
    }
  });

  group('滚轮速度真值下发链路 (BUG-1026)', () {
    test('in-app 注入端设 window.__fushiPopupWheelSpeed', () {
      final String dart =
          File('lib/src/pages/implementations/popup_settings_injection.dart')
              .readAsStringSync();
      expect(dart, contains('window.__fushiPopupWheelSpeed'),
          reason: 'in-app 三种弹窗都经此 head 注入滚轮速度');
      expect(dart, contains('appModel.popupWheelSpeed'),
          reason: '注入值必须来自偏好真值，而不是写死常量');
    });

    test('扩展 theme 通道下发 --fushi-wheel-speed', () {
      final String dart =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(dart, contains("'--fushi-wheel-speed'"),
          reason: '扩展弹窗只能经查词响应 theme 拿到 app 设置');
      expect(dart, contains('popupWheelSpeed'), reason: 'theme 下发值必须来自同一个偏好真值');
    });

    for (final String path in contentCopies) {
      test('[$path] content.js 把 theme 值落成同名全局', () {
        final String src = File(path).readAsStringSync();
        expect(src, contains("theme['--fushi-wheel-speed']"),
            reason: 'content.js 必须读 theme 下发的滚轮速度');
        expect(src, contains('window.__fushiPopupWheelSpeed'),
            reason: '必须落到 popup.js 读取的同名全局，否则扩展弹窗调速无效');
      });
    }

    test('偏好读写带 clamp，越界值不得放飞滚动', () {
      final String dart =
          File('lib/src/models/preferences_repository.dart').readAsStringSync();
      expect(dart, contains("'popup_wheel_speed'"));
      expect(dart, contains('clamp(0.5, 5.0)'),
          reason: '损坏/越界的存值不得作为倍率直达 popup.js');
    });

    test('设置页暴露滚轮速度滑杆', () {
      final String dart = File('lib/src/settings/settings_schema_lookup.dart')
          .readAsStringSync();
      expect(dart, contains('lookup.popup_wheel_speed'),
          reason: '设置项必须在查词分类可见可搜，否则用户改不了');
      expect(dart, contains('setPopupWheelSpeed'));
    });
  });
}
