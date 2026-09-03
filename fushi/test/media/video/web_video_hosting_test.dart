import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';

void main() {
  test('偏好值解析：只有 windowed 才进窗口宿主档，缺省/未知/旧值一律 builtin', () {
    expect(webVideoHostingFromPref('windowed'), WebVideoHosting.windowed);
    expect(webVideoHostingFromPref('builtin'), WebVideoHosting.builtin);
    expect(webVideoHostingFromPref(null), WebVideoHosting.builtin);
    expect(webVideoHostingFromPref('4k'), WebVideoHosting.builtin);
    expect(webVideoHostingFromPref(1), WebVideoHosting.builtin);
  });

  test('窗口宿主哨兵与 fork C++ 头文件里的字面量一致（两侧各写一份，守卫比对）', () {
    final File header = File(
      '../packages/flutter_inappwebview_windows/windows/webview_environment/webview_environment.h',
    );
    expect(header.existsSync(), isTrue, reason: header.path);
    final String src = header.readAsStringSync();
    expect(
      src,
      contains(
        'kWindowedHostingSentinel = "$kWebVideoWindowedHostingSentinel"',
      ),
      reason: 'Dart 侧改了哨兵字面量必须同步 WebViewEnvironment::kWindowedHostingSentinel',
    );
    // 哨兵形如 Chromium 开关（`--x-y`）：WebView2 会把它原样交给浏览器进程，未知开关被忽略；
    // 别改成会被 Chromium 认出的名字。
    expect(kWebVideoWindowedHostingSentinel, startsWith('--fushi-'));
  });

  test('parseWebVideoLookupPayload：完整载荷 → 请求；缺句子/下标/矩形 → null', () {
    final WebVideoLookupRequest? r = parseWebVideoLookupPayload(
      <String, Object?>{
        'type': 'lookup',
        'kind': 'click',
        'sentence': '沙漠蝗来了',
        'index': 2,
        'cueStart': 12000,
        'cueEnd': 14000,
        'rect': <String, Object?>{'x': 160.0, 'y': 700, 'w': 20, 'h': 36},
        'screenX': 50,
        'screenY': 60.5,
        'dpr': 1.5,
      },
    );
    expect(r, isNotNull);
    expect(r!.sentence, '沙漠蝗来了');
    expect(r.graphemeIndex, 2);
    expect(r.cueStartMs, 12000);
    expect(r.cueEndMs, 14000);
    expect(r.clientRect, const Rect.fromLTWH(160, 700, 20, 36));
    expect(r.screenX, 50);
    expect(r.screenY, 60.5);
    expect(r.isHover, isFalse);
    expect(
      parseWebVideoLookupPayload(<String, Object?>{
        'kind': 'hover',
        'sentence': 'x',
        'index': 0,
        'rect': <String, Object?>{'x': 0, 'y': 0, 'w': 1, 'h': 1},
      })!.isHover,
      isTrue,
    );
    expect(
      parseWebVideoLookupPayload(<String, Object?>{
        'sentence': '',
        'index': 0,
        'rect': <String, Object?>{'x': 0, 'y': 0, 'w': 1, 'h': 1},
      }),
      isNull,
    );
    expect(
      parseWebVideoLookupPayload(<String, Object?>{
        'sentence': 'a',
        'index': 'x',
        'rect': <String, Object?>{'x': 0, 'y': 0, 'w': 1, 'h': 1},
      }),
      isNull,
    );
    expect(
      parseWebVideoLookupPayload(<String, Object?>{
        'sentence': 'a',
        'index': 0,
        'rect': <String, Object?>{'x': 0, 'y': 0},
      }),
      isNull,
    );
    expect(parseWebVideoLookupPayload('nope'), isNull);
  });

  test('锚点屏幕矩形 = 视口矩形 + 视口屏幕位置；零尺寸回 null（回落光标定位）', () {
    const WebVideoLookupRequest r = WebVideoLookupRequest(
      kind: 'click',
      sentence: 's',
      graphemeIndex: 0,
      cueStartMs: 0,
      cueEndMs: 1,
      clientRect: Rect.fromLTWH(160, 700, 20, 36),
      screenX: 50,
      screenY: 60,
    );
    expect(
      webVideoLookupAnchorScreenRect(r),
      const Rect.fromLTWH(210, 760, 20, 36),
    );
    const WebVideoLookupRequest empty = WebVideoLookupRequest(
      kind: 'click',
      sentence: 's',
      graphemeIndex: 0,
      cueStartMs: 0,
      cueEndMs: 1,
      clientRect: Rect.zero,
      screenX: 50,
      screenY: 60,
    );
    expect(webVideoLookupAnchorScreenRect(empty), isNull);
  });
}
