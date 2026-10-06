import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/misc/logo_accent_tint.dart';
import 'package:image/image.dart' as img;
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

/// logo 原图里的代表色（`assets/meta/icon.png` 实测直方图）。
const int _background = 0xFFE6E2F6; // 薰衣草底
const int _periwinkle = 0xFFC4C6E0; // 耳尖 / 腮红 / 鳍
const int _ink = 0xFF3F3242; // 深紫墨线
const int _white = 0xFFFFFFFF; // 身体
const int _mouth = 0xFFE8A07C; // 桃色嘴巴

double _hueDistance(double a, double b) {
  final double d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

ColorScheme _presetScheme(String key, Brightness brightness) =>
    ThemeNotifier.buildPresetColorScheme(
      ThemeNotifier.themePresets[key]!,
      brightness,
    );

Uint8List _decodeAssetRgba(String path, {int width = 128}) {
  final img.Image decoded = img.decodePng(File(path).readAsBytesSync())!;
  final img.Image small = img.copyResize(decoded, width: width);
  return small
      .convert(format: img.Format.uint8, numChannels: 4)
      .getBytes(order: img.ChannelOrder.rgba);
}

void main() {
  group('基线紫 = 原图', () {
    for (final Brightness brightness in Brightness.values) {
      test('基线紫预设（$brightness）的 primary 推出恒等变换', () {
        final ColorScheme cs = _presetScheme('m3-baseline', brightness);
        final LogoAccentTint tint = LogoAccentTint.fromAccent(
          cs.primary.toARGB32(),
        );
        expect(tint.isIdentity, isTrue, reason: '$tint');
      });
    }

    test('Material 默认亮色 ThemeData（primary = 基线紫种子）同样是恒等变换', () {
      expect(
        LogoAccentTint.fromAccent(
          ThemeData().colorScheme.primary.toARGB32(),
        ).isIdentity,
        isTrue,
      );
    });

    test('恒等变换下整张 logo 逐字节不变', () {
      final Uint8List rgba = _decodeAssetRgba('assets/meta/icon.png');
      expect(tintLogoRgba(rgba, LogoAccentTint.identity), rgba);
    });
  });

  group('换强调色后色相跟随', () {
    const List<String> presets = <String>[
      'm3-indigo',
      'm3-blue',
      'm3-teal',
      'm3-green',
      'm3-yellow',
      'm3-orange',
      'm3-red',
      'm3-pink',
    ];
    for (final String key in presets) {
      for (final Brightness brightness in Brightness.values) {
        test('$key（$brightness）：logo 配色族转到 primary 色相、明度不变', () {
          final ColorScheme cs = _presetScheme(key, brightness);
          final Hct primary = Hct.fromInt(cs.primary.toARGB32());
          final LogoAccentTint tint = LogoAccentTint.fromAccent(
            cs.primary.toARGB32(),
          );
          // 原图里耳尖色比基线紫偏 -21°：换色后保持同一相对关系。
          final Hct basePeri = Hct.fromInt(_periwinkle);
          final double baseOffset =
              basePeri.hue -
              Hct.fromInt(kLogoReferenceAccentArgb).hue; // ≈ -21°
          for (final int source in <int>[_background, _periwinkle, _ink]) {
            final Hct before = Hct.fromInt(source);
            final Hct after = Hct.fromInt(tintLogoArgb(source, tint));
            expect(
              _hueDistance(after.hue, before.hue + tint.hueShift),
              lessThan(4),
              reason: '${source.toRadixString(16)} → $tint',
            );
            expect((after.tone - before.tone).abs(), lessThan(1.0));
            expect(
              (after.chroma - before.chroma).abs(),
              lessThan(2.5),
              reason: '彩色强调色下保留原有彩度层次',
            );
          }
          final Hct peri = Hct.fromInt(tintLogoArgb(_periwinkle, tint));
          expect(
            _hueDistance(peri.hue, primary.hue + baseOffset),
            lessThan(4),
            reason: '耳尖色相 ${peri.hue} vs primary ${primary.hue}',
          );
        });
      }
    }
  });

  group('中性色与非配色族不动', () {
    final LogoAccentTint red = LogoAccentTint.fromAccent(
      _presetScheme('m3-red', Brightness.light).primary.toARGB32(),
    );

    test('白身体、灰阶、桃色嘴巴原样保留', () {
      for (final int c in <int>[
        _white,
        0xFFFEFEFE,
        0xFF808080,
        0xFF000000,
        _mouth,
      ]) {
        expect(tintLogoArgb(c, red), c, reason: c.toRadixString(16));
      }
    });

    test('透明度原样保留', () {
      expect(tintLogoArgb(0x80C4C6E0, red) >>> 24, 0x80);
      expect(tintLogoArgb(0x00C4C6E0, red) >>> 24, 0x00);
    });

    test('整张 logo：alpha 通道与白色像素逐字节不变，配色族像素被换色', () {
      final Uint8List rgba = _decodeAssetRgba('assets/meta/icon.png');
      final Uint8List out = tintLogoRgba(rgba, red);
      int changed = 0;
      for (int i = 0; i < rgba.length; i += 4) {
        expect(out[i + 3], rgba[i + 3]);
        final bool white =
            rgba[i] == 255 && rgba[i + 1] == 255 && rgba[i + 2] == 255;
        if (white) {
          expect(out[i] + out[i + 1] + out[i + 2], 765);
        }
        if (out[i] != rgba[i] ||
            out[i + 1] != rgba[i + 1] ||
            out[i + 2] != rgba[i + 2]) {
          changed++;
        }
      }
      // 薰衣草底占了大半张：换色必须真的发生。
      expect(changed, greaterThan(rgba.length ~/ 4 ~/ 3));
    });
  });

  group('低彩度强调色褪色', () {
    test('中性灰预设：logo 彩度按比例降低', () {
      final ColorScheme cs = _presetScheme('m3-neutral', Brightness.light);
      final LogoAccentTint tint = LogoAccentTint.fromAccent(
        cs.primary.toARGB32(),
      );
      expect(tint.chromaScale, lessThan(1));
      final Hct after = Hct.fromInt(tintLogoArgb(_periwinkle, tint));
      expect(after.chroma, lessThan(Hct.fromInt(_periwinkle).chroma));
    });

    test('无彩度强调色（纯灰）：logo 变灰阶，色相不转', () {
      final LogoAccentTint tint = LogoAccentTint.fromAccent(0xFF777777);
      expect(tint.chromaScale, 0);
      expect(tint.hueShift, 0);
      final int gray = tintLogoArgb(_periwinkle, tint);
      final List<int> rgb = <int>[
        (gray >> 16) & 0xFF,
        (gray >> 8) & 0xFF,
        gray & 0xFF,
      ];
      expect(
        rgb.reduce((int a, int b) => a > b ? a : b) -
            rgb.reduce((int a, int b) => a < b ? a : b),
        lessThanOrEqualTo(2),
        reason: '灰阶：RGB 三通道几乎相等',
      );
      expect(
        (Hct.fromInt(tintLogoArgb(_periwinkle, tint)).tone -
                Hct.fromInt(_periwinkle).tone)
            .abs(),
        lessThan(1),
      );
    });
  });

  test('参数量化：色相取整度、彩度缩放取 0.05 步长，同一主题得到同一个缓存 key', () {
    final LogoAccentTint a = LogoAccentTint.fromAccent(
      _presetScheme('m3-teal', Brightness.light).primary.toARGB32(),
    );
    final LogoAccentTint b = LogoAccentTint.fromAccent(
      _presetScheme('m3-teal', Brightness.light).primary.toARGB32(),
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.hueShift, a.hueShift.roundToDouble());
    expect((a.chromaScale * 20) % 1, 0);
  });
}
