// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_overlayability_test.cpp 同一写法；无 assert 的文件也照写，免得
// 日后新增断言时又要重走一遍这个坑。
#undef NDEBUG

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

  // 1:1 —— 直连路径原本唯一支持的情形。scale 必须恰为 1、信箱边恰为 0。
  // 注意这是**映射函数**的恒等性质，不等于「1:1 下落点不变」：文件末尾的组合用例
  // 明确记录了 1:1 下贴附策略确实变了（水平中心对齐、垂直优先上方）。
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


  // ── 组合结果：1:1 下的落点**不是**旧行为的逐像素复现 ──────────────────────
  //
  // 两个 helper 各自的恒等性证明不了整条路径的行为：真正决定卡片贴在哪的是
  // 「GlyphAnchoredCardOrigin 之后再 ClampDirectCardOrigin」这个组合，而字形有效时
  // 它无条件接管定位。这里把 1:1 的组合结果钉死，作为策略变更的书面记录。
  {
    // 1:1：客户区 == 画布 == 1280x720，所以 scale==1、信箱边为 0。
    const double scale = CanvasToClientScale(1280, 720, 1280, 720);
    assert(NearlyEqual(scale, 1.0));
    const double content_left = LetterboxOffset(1280, 1280, scale);
    const double content_top = LetterboxOffset(720, 720, scale);
    assert(NearlyEqual(content_left, 0.0));
    assert(NearlyEqual(content_top, 0.0));

    // 真机形态的一行台词：24px 字形，563x432 的卡片。
    const double glyph_left = 600.0;
    const double glyph_top = 500.0;
    const double glyph_w = 24.0;
    const double glyph_h = 24.0;
    const int card_w = 563;
    const int card_h = 432;

    const auto placed = GlyphAnchoredCardOrigin(
        content_left + glyph_left, content_top + glyph_top, glyph_w, glyph_h,
        card_w, card_h);
    const int x = ClampDirectCardOrigin(placed.left, card_w, 1280);
    const int y = ClampDirectCardOrigin(placed.top, card_h, 720);

    // 水平：**中心**对齐字形中心 —— 600 + 12 - 281.5 = 330.5 -> 331（四舍五入）。
    // 旧行为是左边缘对齐字形左边（= 600）。差 269px，与 563 宽卡片的半宽同量级。
    assert(x == 331);
    assert(x != 600);

    // 垂直：优先**上方**且**零间隙** —— 500 - 432 = 68。
    // 旧行为优先下方（500 + 24 + popupPadding 4 = 528）并按 screenBorderPadding 6
    // 夹取；这里既不在下方，也没有那 4px 间隙。
    assert(y == 68);
    assert(y != 528);
    // 零间隙的判据：卡片底边正好压在字形顶边上。
    assert(y + card_h == static_cast<int>(glyph_top));
  }

  // ── BUG-2921：嵌套子卡出现时根卡必须原地不动 ────────────────────────────
  //
  // 用户视频（CLANNAD，客户区约 2000x1500）：根卡 800x900 贴在台词字形正上方，
  // 在根卡里点词，子卡级联到被点词上方，union 向上长出。
  {
    using fushi::gal_direct_card_geometry::PlaceDirectUnionAroundRoot;
    const int client_w = 2000;
    const int client_h = 1500;
    const double glyph_left = 700.0;
    const double glyph_top = 1250.0;
    const double glyph_w = 40.0;
    const double glyph_h = 40.0;
    const int root_w = 800;
    const int root_h = 900;

    // 首次上屏：union == 根卡，根卡在 window-local (0,0)。
    const auto first = PlaceDirectUnionAroundRoot(
        glyph_left, glyph_top, glyph_w, glyph_h, root_w, root_h, 0, 0, 0, 0,
        root_w, root_h, client_w, client_h);
    assert(first.root_y == 350);  // 1250 - 900，底边贴字形
    assert(first.root_x == 320);  // 720 - 400，水平居中于字形
    assert(first.union_x == first.root_x && first.union_y == first.root_y);

    // 子卡在上方长出 300、在左侧长出 150：union 原点 window-local (-150,-300)，
    // 尺寸 950x1200。根卡位置必须与首次上屏逐像素相同。
    const auto nested = PlaceDirectUnionAroundRoot(
        glyph_left, glyph_top, glyph_w, glyph_h, root_w, root_h, 0, 0, -150,
        -300, 950, 1200, client_w, client_h);
    assert(nested.root_x == first.root_x && nested.root_y == first.root_y);
    assert(nested.union_x + 150 == first.root_x);
    assert(nested.union_y + 300 == first.root_y);
    assert(nested.union_y == 50);  // 子卡整块留在客户区内，标题栏不被裁

    // 旧实现拿 union 尺寸贴字形：子卡再高一点（union 1300，原点 -400 → 顶边仍在
    // 客户区 -50 处被夹到 0）时 1250 - 1300 < 0，整个 union 翻到字形下方再夹回
    // 1500 - 1300 = 200，根卡从 350 跳到 600——视频里根卡先跳位的形态。
    const auto old_way = GlyphAnchoredCardOrigin(glyph_left, glyph_top, glyph_w,
                                                 glyph_h, 950, 1300);
    assert(ClampDirectCardOrigin(old_way.top, 1300, client_h) + 400 !=
           first.root_y);

    // 根卡本身不在 window-local 原点时，用它自己的偏移抵消。
    const auto offset_root = PlaceDirectUnionAroundRoot(
        glyph_left, glyph_top, glyph_w, glyph_h, root_w, root_h, 30, 20, 30,
        20, root_w, root_h, client_w, client_h);
    assert(offset_root.union_x == first.root_x);
    assert(offset_root.union_y == first.root_y);

    // 根卡因尾批词典长高（900 → 1000）：底边仍贴字形，不会盖住台词。
    const auto grown = PlaceDirectUnionAroundRoot(
        glyph_left, glyph_top, glyph_w, glyph_h, root_w, 1000, 0, 0, 0, 0,
        root_w, 1000, client_w, client_h);
    assert(grown.root_y + 1000 == static_cast<int>(glyph_top));

    // 字形贴近左边：根卡先被夹进客户区，嵌套后仍用同一个被夹过的根卡位置。
    const auto edge_first = PlaceDirectUnionAroundRoot(
        100.0, glyph_top, glyph_w, glyph_h, root_w, root_h, 0, 0, 0, 0, root_w,
        root_h, client_w, client_h);
    assert(edge_first.root_x == 0);
    const auto edge_nested = PlaceDirectUnionAroundRoot(
        100.0, glyph_top, glyph_w, glyph_h, root_w, root_h, 0, 0, 0, -300,
        root_w, 1200, client_w, client_h);
    assert(edge_nested.root_x == 0 && edge_nested.union_x == 0);
    assert(edge_nested.union_y + 300 == edge_first.root_y);
  }

  return 0;
}
