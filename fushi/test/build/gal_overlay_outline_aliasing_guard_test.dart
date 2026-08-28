// BUG-1889 源码守卫：gal hook 台词浮窗描边的去锯齿修正。
//
// 用户报告：白字黑描边「奇怪地有锯齿感」。描边是 native Direct2D 的「同一
// text_layout_ 多遍偏移叠印」伪描边（floating_lyric_window.cpp），C++ 无法在 Dart
// 测试里执行，故在源码层锁住这次修正赖以成立的两个前提。
//
// 沿轮廓单层真描边（IDWriteFontFace::GetGlyphRunOutline → ID2D1PathGeometry →
// DrawGeometry）是理论正路，但它必须经自定义 IDWriteTextRenderer 落地，而
// overlay_ruby_render_guard_test 明令禁止那条路，理由充分：点字 CharIndexAt、
// 折行、滚动、注音四处几何必须与 text_layout_ 同源，分叉即各走各的。所以本次修正
// **留在多遍偏移这条路内**，只消除它的两个锯齿来源：
//
//   ① 亚像素相位不一致：ScaleForDpi 不取整，r=1.6dip 在 150% DPI 下是 2.4px、
//      d = r*0.7071 = 1.697px，每一遍字形在不同相位上栅格化，灰度 AA 覆盖率各不
//      相同，叠起来是摩尔纹式毛边。取整后各遍与填充遍同相位。
//   ② 半透明叠印的 alpha 非线性：8 遍各带 alpha（默认 0xE0）直接 src-over，轮廓
//      上不同方向被覆盖 1~8 次不等，描边粗细随方向变化。改成图层内**不透明**叠印
//      （叠加只决定形状并集）+ PopLayer 时按用户 alpha 整体合成一次。
//
// 未做的第三条（显式 SetTextAntialiasMode）见 docs/bugs/BUG-1889：它不是根因，
// PREMULTIPLIED 目标下 D2D 本就走 GRAYSCALE，加了反而可能改到其余浮窗的观感。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String window = File(
    'windows/runner/floating_lyric_window.cpp',
  ).readAsStringSync();

  group('① 偏移取整到物理像素', () {
    test('主文本描边半径经 std::round', () {
      expect(
        RegExp(
          r'const float r = std::round\(ScaleForDpi\(static_cast<float>\('
          r'\s*std::clamp\(style_\.outline_width, 0\.0, 8\.0\)\)\)\);',
        ).hasMatch(window),
        isTrue,
        reason: '描边半径不取整 → 各遍落在不同亚像素相位，AA 覆盖率不一致即毛边',
      );
    });

    test('对角与 22.5° 分量同样取整', () {
      expect(
        window.contains('const float d = std::round(r * 0.7071f);'),
        isTrue,
      );
      expect(
        window.contains('const float n = std::round(r * 0.9239f);'),
        isTrue,
      );
      expect(
        window.contains('const float m = std::round(r * 0.3827f);'),
        isTrue,
      );
    });

    test('注音描边半径与对角分量也取整', () {
      expect(
        window.contains('const float rr = std::round(ScaleForDpi('),
        isTrue,
        reason: '注音与正文必须同一套相位处理，否则两处描边观感不一致',
      );
      expect(
        window.contains('const float rd = std::round(rr * 0.7071f);'),
        isTrue,
      );
    });
  });

  group('② 图层内不透明叠印 + 一次性 alpha 合成', () {
    test('描边色在有图层时强制不透明', () {
      expect(
        window.contains(
          'ColorFromArgb(layered ? (style_.outline_color | 0xFF000000)',
        ),
        isTrue,
        reason: '图层内必须用不透明色：叠加只决定形状并集，不再累加 alpha',
      );
    });

    test('用户设定的 alpha 变成图层 opacity，整体合成一次', () {
      expect(
        window.contains(
          'static_cast<float>((style_.outline_color >> 24) & 0xFF) /',
        ),
        isTrue,
        reason:
            'alpha 必须从 outline_color 提取出来交给图层，'
            '否则用户设的半透明描边实际得到的是 1-(1-a)^k，几乎恒为纯色',
      );
      expect(window.contains('outline_alpha'), isTrue);
    });

    test('主文本与注音两处描边环都进图层', () {
      expect(
        'PushLayer('.allMatches(window).length,
        greaterThanOrEqualTo(2),
        reason: '正文与注音各一次；只包其一会让两处描边浓淡不同',
      );
      expect(
        'PopLayer()'.allMatches(window).length,
        greaterThanOrEqualTo(2),
        reason: 'Push / Pop 必须配对，漏 Pop 会污染后续绘制',
      );
    });

    test('CreateLayer 失败时原样降级回旧路径', () {
      expect(
        window.contains(
          'render_target_->CreateLayer(nullptr, outline_layer.GetAddressOf());',
        ),
        isTrue,
      );
      expect(
        'outline_layer != nullptr'.allMatches(window).length,
        greaterThanOrEqualTo(3),
        reason:
            '建层失败必须能不进图层照常画（半透明直绘 = 修前行为），'
            '不能因为拿不到 layer 就不画描边',
      );
    });
  });

  group('③ 修正没有走上被禁的那条路', () {
    test('仍未引入自定义 IDWriteTextRenderer（几何不分叉）', () {
      expect(
        window.contains('IDWriteTextRenderer'),
        isFalse,
        reason:
            '点字 index / 折行 / 滚动 / 注音四处几何必须与 text_layout_ 同源；'
            '这条禁令由 overlay_ruby_render_guard_test 立，本次修正不得绕过它',
      );
    });

    test('描边环仍是同一 text_layout_ 的多遍偏移', () {
      expect(
        RegExp(
          r'for \(const D2D1_POINT_2F& off : ring\)[\s\S]{0,300}?'
          r'text_layout_\.Get\(\), lyric_outline\.Get\(\)',
        ).hasMatch(window),
        isTrue,
      );
    });

    test('描边环补到 16 向（曲线笔画的扇形缺口）', () {
      expect(window.contains('const D2D1_POINT_2F ring[16] = {'), isTrue);
    });
  });
}
