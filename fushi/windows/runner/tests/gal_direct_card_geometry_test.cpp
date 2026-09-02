#include "../gal_direct_card_geometry.h"

#include <cassert>
#include <cmath>

namespace {

bool NearlyEqual(double a, double b) { return std::fabs(a - b) < 1e-9; }

}  // namespace

int main() {
  using fushi::gal_direct_card_geometry::CanvasToClientScale;
  using fushi::gal_direct_card_geometry::ClampDirectCardOrigin;
  using fushi::gal_direct_card_geometry::LetterboxOffset;

  // 1:1 —— 直连路径原本唯一支持的情形。scale 必须恰为 1、信箱边恰为 0，否则本次改动
  // 就改变了既有行为。
  assert(NearlyEqual(CanvasToClientScale(1280, 720, 1280, 720), 1.0));
  assert(NearlyEqual(LetterboxOffset(1280, 1280, 1.0), 0.0));
  assert(NearlyEqual(LetterboxOffset(720, 720, 1.0), 0.0));

  // 放大（9-nine 实测形态：画布 1280x720 被放大进 1902x1069 客户区）。取两轴较小者。
  {
    const double scale = CanvasToClientScale(1902, 1069, 1280, 720);
    assert(NearlyEqual(scale, 1069.0 / 720.0));
    assert(scale > 1.0);
    // 高度是较紧的一轴，所以纵向无信箱边、横向有。
    assert(NearlyEqual(LetterboxOffset(1069, 720, scale), 0.0));
    assert(LetterboxOffset(1902, 1280, scale) > 0.0);
  }

  // 缩小（窗口被拉到比画布还小）。
  {
    const double scale = CanvasToClientScale(640, 360, 1280, 720);
    assert(NearlyEqual(scale, 0.5));
  }

  // 宽高比不一致时按较小轴等比缩放并居中，两侧留信箱边。
  {
    const double scale = CanvasToClientScale(1920, 1080, 1280, 800);
    assert(NearlyEqual(scale, 1080.0 / 800.0));
    assert(LetterboxOffset(1920, 1280, scale) > 0.0);
    assert(NearlyEqual(LetterboxOffset(1080, 800, scale), 0.0));
  }

  // 退化输入必须返回 0，让调用方拒绝直连而不是当作 1:1 继续。
  assert(NearlyEqual(CanvasToClientScale(1280, 720, 0, 720), 0.0));
  assert(NearlyEqual(CanvasToClientScale(1280, 720, 1280, 0), 0.0));
  assert(NearlyEqual(CanvasToClientScale(0, 720, 1280, 720), 0.0));
  assert(NearlyEqual(CanvasToClientScale(1280, 0, 1280, 720), 0.0));

  // 原点夹取：区间内原样返回（含四舍五入）。
  assert(ClampDirectCardOrigin(100.0, 300, 1000) == 100);
  assert(ClampDirectCardOrigin(100.4, 300, 1000) == 100);
  assert(ClampDirectCardOrigin(100.6, 300, 1000) == 101);

  // 越过右/下边时贴边，保证卡片整体留在游戏画面内。
  assert(ClampDirectCardOrigin(900.0, 300, 1000) == 700);
  assert(ClampDirectCardOrigin(1e9, 300, 1000) == 700);

  // 负原点夹到 0。
  assert(ClampDirectCardOrigin(-50.0, 300, 1000) == 0);

  // 卡片比客户区还大时以 0 兜底，绝不给出负坐标。
  assert(ClampDirectCardOrigin(10.0, 1200, 1000) == 0);
  assert(ClampDirectCardOrigin(-10.0, 1200, 1000) == 0);

  using fushi::gal_direct_card_geometry::GlyphAnchoredCardOrigin;

  // 水平居中于字形。
  {
    const auto o = GlyphAnchoredCardOrigin(500.0, 800.0, 40.0, 40.0, 200, 100);
    assert(NearlyEqual(o.left, 500.0 + 20.0 - 100.0));
  }

  // 上方放得下就贴正上方：卡片底边紧贴字形顶边。
  {
    const auto o = GlyphAnchoredCardOrigin(500.0, 800.0, 40.0, 40.0, 200, 100);
    assert(NearlyEqual(o.top, 700.0));
    assert(NearlyEqual(o.top + 100.0, 800.0));
  }

  // 上方放不下（会出负坐标）才翻到字形下方。
  {
    const auto o = GlyphAnchoredCardOrigin(500.0, 60.0, 40.0, 40.0, 200, 100);
    assert(NearlyEqual(o.top, 100.0));
  }

  // 恰好贴边（above == 0）仍算放得下，不该翻到下方。
  {
    const auto o = GlyphAnchoredCardOrigin(500.0, 100.0, 40.0, 40.0, 200, 100);
    assert(NearlyEqual(o.top, 0.0));
  }

  // 这正是 9-nine 全屏实测的形态：画布 1280x720 放大 3 倍，字形在画布 y=600。
  // 沿用旧的 anchor*scale 会把卡片放到 y=402，离字形约 1000px；以字形为基准则贴在
  // 字形正上方。
  {
    const double scale = 3.0;
    const double glyph_top = 600.0 * scale;   // 1800
    const double glyph_left = 454.0 * scale;
    const auto o =
        GlyphAnchoredCardOrigin(glyph_left, glyph_top, 24.0 * scale,
                                24.0 * scale, 563, 432);
    assert(NearlyEqual(o.top, 1800.0 - 432.0));
    assert(o.top > 1300.0);  // 绝不再落回画面上三分之一
  }

  return 0;
}
