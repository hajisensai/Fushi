import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/sensor_housing_edge.dart';

/// iPhone 17 Pro 模拟器横屏实测：左右安全区对称，各是灵动岛的深度。
const EdgeInsets _iosLandscapeInsets = EdgeInsets.fromLTRB(61.6, 0, 61.6, 19.9);

/// 去掉 `//` 注释后的 Dart 源码：结构断言不能被注释里的同名字样骗过。
String _code(String path) => File(path)
    .readAsLinesSync()
    .map((String line) => line.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

void main() {
  group('obstructedSafeInsets', () {
    test('灵动岛在左：右侧水平安全区归零，其余原样', () {
      expect(
        obstructedSafeInsets(_iosLandscapeInsets, AxisDirection.left),
        const EdgeInsets.fromLTRB(61.6, 0, 0, 19.9),
      );
    });

    test('灵动岛在右：左侧水平安全区归零', () {
      expect(
        obstructedSafeInsets(_iosLandscapeInsets, AxisDirection.right),
        const EdgeInsets.fromLTRB(0, 0, 61.6, 19.9),
      );
    });

    test('不知道 / 竖屏（上、下）：两侧都保守保留', () {
      for (final AxisDirection? edge in <AxisDirection?>[
        null,
        AxisDirection.up,
        AxisDirection.down,
      ]) {
        expect(
          obstructedSafeInsets(_iosLandscapeInsets, edge),
          _iosLandscapeInsets,
        );
      }
    });
  });

  // BUG-3411：外壳边只有悬浮球宿主在取，视频字幕列表侧栏读不到，iOS 横屏
  // 灵动岛在左时右侧照样空出一条。接线是静默的（缺了照样编译、照样跑），
  // 这里钉住「宿主写共享值、侧栏监听并按它让位」两端。
  test('悬浮球宿主把外壳边写进全应用共享的 sensorHousingEdge', () {
    final String host = _code(
      'lib/src/floating_ball/app_floating_ball_host.dart',
    );
    expect(host, contains('sensorHousingEdge.value = edge;'));
    expect(host, contains('obstructedSafeInsets('));
  });

  test('视频字幕列表侧栏监听外壳边、只给被挡的一侧让位', () {
    final String panel = _code(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    );
    expect(panel, contains('sensorHousingEdge.value,'));
    expect(panel, contains('obstructedSafeInsets('));
    // 横屏左 ↔ 右翻转 180° 时安全区不变、只有外壳边变：页面必须监听它重建。
    final String page = _code(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    expect(
      page,
      contains('sensorHousingEdge.addListener(_onSensorHousingEdgeChanged);'),
    );
    expect(
      page,
      contains(
        'sensorHousingEdge.removeListener(_onSensorHousingEdgeChanged);',
      ),
    );
  });
}
