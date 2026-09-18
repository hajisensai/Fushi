import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';

/// 命中判定的薄封装：返回 'next' / 'prev' / null，与注入 JS 的 `_tapZoneTurn`
/// 同一条规则（按声明序先命中者胜）。
String? _turnAt(List<MangaTapZone> zones, double nx, double ny) {
  for (final MangaTapZone z in zones) {
    if (z.contains(nx, ny)) return z.forward ? 'next' : 'prev';
  }
  return null;
}

void main() {
  group('MangaTapZoneLayout 键往返', () {
    test('每个枚举值的 key 都能原样解回', () {
      for (final MangaTapZoneLayout layout in MangaTapZoneLayout.values) {
        expect(MangaTapZoneLayoutKey.fromKey(layout.key), layout);
      }
    });

    test('未知值回落 leftRight（旧版本行为）', () {
      expect(
        MangaTapZoneLayoutKey.fromKey('nonsense'),
        MangaTapZoneLayout.leftRight,
      );
      expect(MangaTapZoneLayoutKey.fromKey(''), MangaTapZoneLayout.leftRight);
    });

    test('落盘的是字符串键而非 enum index', () {
      // 重排枚举不得破坏已落盘偏好：键必须是稳定字面量。
      expect(MangaTapZoneLayout.leftRight.key, 'left_right');
      expect(MangaTapZoneLayout.lShaped.key, 'l_shaped');
      expect(MangaTapZoneLayout.kindle.key, 'kindle');
      expect(MangaTapZoneLayout.topBottom.key, 'top_bottom');
    });
  });

  group('mangaTapZones 几何', () {
    test('leftRight：左退右进，中央不翻页（旧行为原样保留）', () {
      final List<MangaTapZone> z = mangaTapZones(
        MangaTapZoneLayout.leftRight,
        rtl: false,
      );
      expect(_turnAt(z, 0.1, 0.5), 'prev');
      expect(_turnAt(z, 0.9, 0.5), 'next');
      expect(_turnAt(z, 0.5, 0.5), isNull, reason: '中央必须留给查词 / 呼出界面 / 双击缩放');
      expect(_turnAt(z, 0.5, 0.95), isNull, reason: 'leftRight 没有下横条');
    });

    test('lShaped：下横条前进，但两侧竖条优先（声明序先命中者胜）', () {
      final List<MangaTapZone> z = mangaTapZones(
        MangaTapZoneLayout.lShaped,
        rtl: false,
      );
      expect(_turnAt(z, 0.5, 0.95), 'next', reason: '下横条前进');
      expect(_turnAt(z, 0.5, 0.5), isNull, reason: '中央仍不翻页');
      // 左下角同时落在左竖条与下横条里：竖条排在前，必须判后退，否则 L 型的
      // 「左边永远是上一页」在下沿失效。
      expect(_turnAt(z, 0.1, 0.95), 'prev');
      expect(_turnAt(z, 0.9, 0.95), 'next');
    });

    test('kindle：左窄条后退，其余整片（含中央）前进', () {
      final List<MangaTapZone> z = mangaTapZones(
        MangaTapZoneLayout.kindle,
        rtl: false,
      );
      expect(_turnAt(z, 0.1, 0.5), 'prev');
      expect(_turnAt(z, 0.5, 0.5), 'next');
      expect(_turnAt(z, 0.99, 0.01), 'next');
    });

    test('topBottom：上半后退 / 下半前进，与横向位置无关', () {
      final List<MangaTapZone> z = mangaTapZones(
        MangaTapZoneLayout.topBottom,
        rtl: false,
      );
      expect(_turnAt(z, 0.05, 0.2), 'prev');
      expect(_turnAt(z, 0.95, 0.2), 'prev');
      expect(_turnAt(z, 0.05, 0.8), 'next');
      expect(_turnAt(z, 0.95, 0.8), 'next');
    });

    test('整个视口都被判到（无坐标落进表却得不到判定的空洞）', () {
      for (final MangaTapZoneLayout layout in <MangaTapZoneLayout>[
        MangaTapZoneLayout.kindle,
        MangaTapZoneLayout.topBottom,
      ]) {
        final List<MangaTapZone> z = mangaTapZones(layout, rtl: false);
        for (double x = 0.01; x < 1; x += 0.11) {
          for (double y = 0.01; y < 1; y += 0.11) {
            expect(
              _turnAt(z, x, y),
              isNotNull,
              reason: '$layout 在 ($x,$y) 应有判定',
            );
          }
        }
      }
    });
  });

  group('阅读方向镜像', () {
    test('rtl 不动几何；只有 left_right 翻转 forward', () {
      for (final MangaTapZoneLayout layout in MangaTapZoneLayout.values) {
        final List<MangaTapZone> ltr = mangaTapZones(layout, rtl: false);
        final List<MangaTapZone> rtl = mangaTapZones(layout, rtl: true);
        expect(rtl.length, ltr.length);
        final bool mirrored = layout == MangaTapZoneLayout.leftRight;
        for (int i = 0; i < ltr.length; i++) {
          expect(rtl[i].left, ltr[i].left, reason: '$layout[$i] 几何不得镜像');
          expect(rtl[i].top, ltr[i].top);
          expect(rtl[i].width, ltr[i].width);
          expect(rtl[i].height, ltr[i].height);
          expect(
            rtl[i].forward,
            mirrored ? !ltr[i].forward : ltr[i].forward,
            reason: mirrored
                ? '$layout[$i] 是视觉方位语义，RTL 必须翻转 forward'
                : '$layout[$i] 是阅读顺序语义，RTL 不得翻转 forward',
          );
        }
      }
    });

    test('RTL 日漫：Kindle 仍是「左窄条后退、其余整片前进」', () {
      // 整表翻转的旧实现会让默认 RTL 开本下「点中央 = 上一页」，与布局的存在
      // 意义（大片区域 = 前进）相反。
      final List<MangaTapZone> z = mangaTapZones(
        MangaTapZoneLayout.kindle,
        rtl: true,
      );
      expect(_turnAt(z, 0.05, 0.5), 'prev');
      expect(_turnAt(z, 0.5, 0.5), 'next');
      expect(_turnAt(z, 0.95, 0.5), 'next');
    });

    test('RTL 日漫：上下布局仍是「下半前进」，L 型底部横条仍前进', () {
      final List<MangaTapZone> tb = mangaTapZones(
        MangaTapZoneLayout.topBottom,
        rtl: true,
      );
      expect(_turnAt(tb, 0.5, 0.2), 'prev');
      expect(_turnAt(tb, 0.5, 0.8), 'next');
      final List<MangaTapZone> l = mangaTapZones(
        MangaTapZoneLayout.lShaped,
        rtl: true,
      );
      expect(_turnAt(l, 0.5, 0.95), 'next');
      expect(_turnAt(l, 0.95, 0.5), 'next');
      expect(_turnAt(l, 0.05, 0.5), 'prev');
    });

    test('RTL 日漫：左边缘 = 下一页', () {
      final List<MangaTapZone> z = mangaTapZones(
        MangaTapZoneLayout.leftRight,
        rtl: true,
      );
      expect(_turnAt(z, 0.1, 0.5), 'next');
      expect(_turnAt(z, 0.9, 0.5), 'prev');
    });
  });

  group('MangaBackground', () {
    test('每个枚举值的 key 都能原样解回', () {
      for (final MangaBackground bg in MangaBackground.values) {
        expect(MangaBackgroundKey.fromKey(bg.key), bg);
      }
    });

    test('未知值回落 black（旧版本行为 = 黑底）', () {
      expect(MangaBackgroundKey.fromKey('nonsense'), MangaBackground.black);
    });

    test('theme 档没有固定 CSS 值，其余三档有', () {
      expect(
        MangaBackground.theme.fixedCss,
        isNull,
        reason: 'theme 必须由调用方用当时的主题色补上',
      );
      expect(MangaBackground.black.fixedCss, '#000');
      expect(MangaBackground.white.fixedCss, '#fff');
      expect(MangaBackground.gray.fixedCss, isNotNull);
    });
  });
}
