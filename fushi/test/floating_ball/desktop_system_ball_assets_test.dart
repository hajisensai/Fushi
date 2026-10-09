import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/desktop_system_ball_assets.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 桌面应用外球的按钮图标由 Dart 画成 PNG 交给原生窗口（原生不加载图标字体），
/// 球面是同一张资源图。这里钉住「画得出、尺寸对、确实画上了东西、颜色是给的」。
void main() {
  testWidgets('按钮图标画成 66×66 透明底 PNG，字形用给定颜色', (WidgetTester tester) async {
    const Color color = Color(0xFF123456);
    final Uint8List? png = await tester.runAsync<Uint8List?>(
      () => renderFloatingBallIconPng(Icons.search, color),
    );
    expect(png, isNotNull);
    // PNG 签名。
    expect(png!.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    final ui.Image image = (await tester.runAsync(() async {
      final ui.Codec codec = await ui.instantiateImageCodec(png);
      return (await codec.getNextFrame()).image;
    }))!;
    expect(image.width, kDesktopSystemBallIconPx);
    expect(image.height, kDesktopSystemBallIconPx);
    final ByteData rgba = (await tester.runAsync<ByteData?>(
      () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
    ))!;
    int opaque = 0;
    int transparent = 0;
    bool colorMatches = true;
    for (int i = 0; i < rgba.lengthInBytes; i += 4) {
      final int a = rgba.getUint8(i + 3);
      if (a == 0) {
        transparent++;
      } else if (a == 255) {
        opaque++;
        if (rgba.getUint8(i) != 0x12 ||
            rgba.getUint8(i + 1) != 0x34 ||
            rgba.getUint8(i + 2) != 0x56) {
          colorMatches = false;
        }
      }
    }
    image.dispose();
    expect(opaque, greaterThan(50), reason: '字形确实画上了');
    expect(transparent, greaterThan(opaque), reason: '背景透明');
    expect(colorMatches, isTrue, reason: '实心像素就是给的颜色');
  });

  testWidgets('每颗原生按钮都有图标 PNG（含打开 / 关闭）', (WidgetTester tester) async {
    final Map<String, Uint8List> pngs = (await tester.runAsync(
      () => renderFloatingBallIconPngs(
        floatingBallNativeIconData(),
        Colors.black,
      ),
    ))!;
    expect(pngs.keys.toSet(), floatingBallNativeIconData().keys.toSet());
    expect(pngs.keys, containsAll(<String>['open_app', 'close', 'lookup']));
  });

  test('一颗图标画不出来：只少这一颗并记日志，其余照常；画出 null 的静默跳过', () async {
    final int before = ErrorLogService.instance.entries.length;
    final Uint8List png = Uint8List.fromList(<int>[1, 2, 3]);
    final List<IconData> drawn = <IconData>[];
    final Map<String, Uint8List> pngs = await renderFloatingBallIconPngs(
      <String, IconData>{
        'lookup': Icons.search,
        'clipboard': Icons.content_paste_search,
        'open_app': Icons.open_in_new,
        'close': Icons.close,
      },
      Colors.black,
      render: (IconData icon, Color color) async {
        drawn.add(icon);
        if (icon == Icons.content_paste_search) throw StateError('boom');
        if (icon == Icons.open_in_new) return null;
        return png;
      },
    );
    expect(drawn, hasLength(4), reason: '失败的那颗之后的图标照样画');
    expect(pngs, <String, Uint8List>{'lookup': png, 'close': png});
    final List<ErrorLogEntry> added = ErrorLogService.instance.entries
        .skip(before)
        .toList();
    expect(added.map((ErrorLogEntry e) => e.source), <String>[
      'floating_ball.icon_png.clipboard',
    ]);
  });

  test('球面资源缺失：返回 null 并记日志（原生退化成纯色球）', () async {
    final int before = ErrorLogService.instance.entries.length;
    final Uint8List? bytes = await loadFloatingBallImage(_ThrowingBundle());
    expect(bytes, isNull);
    final List<ErrorLogEntry> added = ErrorLogService.instance.entries
        .skip(before)
        .toList();
    expect(added.map((ErrorLogEntry e) => e.source), <String>[
      'floating_ball.ball_image',
    ]);
  });

  test('球面：不是「资源缺失」的异常不吞（只收窄到 AssetBundle 的 FlutterError）', () {
    expect(
      loadFloatingBallImage(_ThrowingBundle(error: StateError('boom'))),
      throwsStateError,
    );
  });
}

/// load 必抛的资源包：默认抛 AssetBundle 找不到资源时的 FlutterError。
class _ThrowingBundle extends CachingAssetBundle {
  _ThrowingBundle({this.error});

  final Error? error;

  @override
  Future<ByteData> load(String key) async =>
      throw error ?? FlutterError('Unable to load asset: "$key".');
}
