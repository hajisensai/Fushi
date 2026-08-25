// BUG-1854 源码守卫：galgame 制卡截图只裁**客户区**，标题栏 / 菜单栏 / 边框不进卡片。
//
// WGC `CreateForWindow` 的 item 覆盖整个 DWM 视觉（= DWMWA_EXTENDED_FRAME_BOUNDS），
// 以前 CaptureCore 把整张纹理原样编码，窗口化跑的 galgame 必然把标题栏拍进图里。
// C++ 无法在 Dart 测试里执行，故在源码层锁死结构：
//   ① 裁剪原点必须是「客户区屏幕原点 − 扩展框架原点」（ClientToScreen −
//      DWMWA_EXTENDED_FRAME_BOUNDS），不能用 GetWindowRect（Win10+ 不可见 resize 边框
//      会让它偏出几像素，OBS「Client Area」同款算法）；
//   ② 裁剪在编码前真的生效（指针按行距偏移到子矩形、宽高换成子矩形）；
//   ③ 裁不出来必须回退整窗并写 diagnostics（宁可多一条标题栏，不能丢图）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String capture = File(
    'windows/runner/window_capture.cpp',
  ).readAsStringSync();

  String functionBody(String signature) {
    final int start = capture.indexOf(signature);
    expect(start, isNot(-1), reason: 'missing $signature');
    int i = capture.indexOf('{', start);
    int depth = 0;
    for (; i < capture.length; i++) {
      if (capture[i] == '{') depth++;
      if (capture[i] == '}') {
        depth--;
        if (depth == 0) return capture.substring(start, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  test('① 裁剪原点 = ClientToScreen − DWMWA_EXTENDED_FRAME_BOUNDS', () {
    final String crop = functionBody(
      'bool ComputeClientCropBox(HWND hwnd, UINT width, UINT height, RECT* box)',
    );
    expect(
      crop.contains('GetClientRect(hwnd, &client)'),
      isTrue,
      reason: '客户区尺寸来自 GetClientRect',
    );
    expect(
      crop.contains('DWMWA_EXTENDED_FRAME_BOUNDS'),
      isTrue,
      reason: 'WGC 纹理原点是 DWM 扩展框架原点，不是 GetWindowRect',
    );
    expect(
      crop.contains('ClientToScreen(hwnd, &origin)'),
      isTrue,
      reason: '客户区屏幕原点来自 ClientToScreen',
    );
    expect(crop.contains('origin.x - frame.left'), isTrue);
    expect(crop.contains('origin.y - frame.top'), isTrue);
    expect(
      crop.contains('GetWindowRect'),
      isFalse,
      reason: 'GetWindowRect 含不可见边框，裁剪会偏出几像素',
    );
  });

  test('② 编码前按子矩形偏移指针并换宽高', () {
    final int map = capture.indexOf('D3D11_MAP_READ, 0, &mapped)');
    expect(map, isNot(-1));
    final String tail = capture.substring(map, capture.indexOf('Unmap(', map));
    expect(
      tail.contains(
        'ComputeClientCropBox(hwnd, desc.Width, desc.Height, &crop)',
      ),
      isTrue,
      reason: '裁剪必须落在 Map 之后、编码之前',
    );
    expect(
      tail.contains('crop.top) * mapped.RowPitch'),
      isTrue,
      reason: '指针按行距偏移到子矩形顶行',
    );
    expect(
      tail.contains('crop.left) * 4'),
      isTrue,
      reason: 'BGRA 每像素 4 字节，指针偏移到子矩形左列',
    );
    expect(
      tail.contains(
        'EncodeBgraToPng(pixels, encode_w, encode_h, mapped.RowPitch,',
      ),
      isTrue,
      reason: '编码宽高必须是子矩形，行距保持原纹理行距',
    );
    expect(
      tail.contains(
        'EncodeBgraToPng(static_cast<const uint8_t*>(mapped.pData)',
      ),
      isFalse,
      reason: '不得再整窗直接编码',
    );
  });

  test('③ 裁不出来回退整窗并写 diagnostics', () {
    final String crop = functionBody(
      'bool ComputeClientCropBox(HWND hwnd, UINT width, UINT height, RECT* box)',
    );
    expect(crop.contains('return false;'), isTrue);
    expect(
      capture.contains('"client-area crop unavailable; encoded the whole "'),
      isTrue,
      reason: '回退整窗必须可证（经 diagnostics 回到 Dart 日志）',
    );
    // 裁剪矩形必须与纹理求交，退化成空矩形时拒绝。
    expect(
      crop.contains('if (right <= left || bottom <= top) {'),
      isTrue,
      reason: '空矩形必须判失败，不能编码 0×0',
    );
  });
}
