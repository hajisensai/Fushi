// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include "layer_origin_pixels.h"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

using fushi_voice_hook::LayerOriginPixelSolve;
using fushi_voice_hook::SolveLayerOriginFromBgra;

// 客户区 960x540，设计分辨率 1920x1080 ⇒ sx = sy = 0.5。
constexpr int32_t kW = 960;
constexpr int32_t kH = 540;
constexpr uint32_t kDesignW = 1920;
constexpr uint32_t kDesignH = 1080;

// 注入侧发布的本行层空间包围盒：宽 800、高 40 ⇒ 预测墨迹 400x20 客户区像素。
constexpr int32_t kLayerLeft = 200;
constexpr int32_t kLayerTop = 400;
constexpr int32_t kLayerRight = 1000;
constexpr int32_t kLayerBottom = 440;

struct Canvas {
  std::vector<uint8_t> bgra;

  explicit Canvas(uint8_t fill = 20) {
    bgra.assign(static_cast<size_t>(kW) * kH * 4u, fill);
    for (size_t i = 3; i < bgra.size(); i += 4) bgra[i] = 255;  // alpha
  }

  void Fill(int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint8_t v) {
    for (int32_t y = y0; y <= y1; ++y) {
      for (int32_t x = x0; x <= x1; ++x) {
        const size_t i = (static_cast<size_t>(y) * kW + x) * 4u;
        bgra[i + 0] = v;
        bgra[i + 1] = v;
        bgra[i + 2] = v;
      }
    }
  }

  // 画一行「字」：从 |x0| 起，|glyphs| 个 |glyph_w| 宽的亮块，块间留 |gap| 空。
  // 返回这一行墨迹的右端（含）。
  int32_t DrawLine(int32_t x0, int32_t y0, int32_t y1, int32_t glyphs,
                   int32_t glyph_w, int32_t gap) {
    int32_t x = x0;
    int32_t right = x0;
    for (int32_t i = 0; i < glyphs; ++i) {
      Fill(x, y0, x + glyph_w - 1, y1, 255);
      right = x + glyph_w - 1;
      x += glyph_w + gap;
    }
    return right;
  }
};

LayerOriginPixelSolve Solve(const Canvas& c, uint32_t glyph_count) {
  return SolveLayerOriginFromBgra(c.bgra.data(), kW, kH, kLayerLeft, kLayerTop,
                                  kLayerRight, kLayerBottom, kDesignW, kDesignH,
                                  glyph_count);
}

// 单条命中：origin 必须数值正确，且用的是**中点**而不是左上角。
void TestSingleBandSolvesMidpoint() {
  Canvas c;
  // 16 个 20px 块 + 15 个 5px 间隙 = 395；再让最后一块补到 400 宽。
  // 墨迹 x ∈ [150, 549]（宽 400 = 预测宽），y ∈ [300, 319]（高 20 = 预测高）。
  const int32_t right = c.DrawLine(150, 300, 319, 16, 20, 5);
  c.Fill(right + 1, 300, 549, 319, 255);

  const LayerOriginPixelSolve out = Solve(c, 16);
  assert(out.ok && "单条同宽墨迹带必须解得出来");
  assert(out.candidate_count == 1);
  assert(out.measured_left == 150 && out.measured_right == 549);
  assert(out.measured_top == 300 && out.measured_bottom == 319);
  // 实测中点 (350, 310) / 0.5 = (700, 620)；层中点 (600, 420)。
  assert(out.origin_x == 100 && "origin_x = 700 - 600");
  assert(out.origin_y == 200 && "origin_y = 620 - 420");
}

// 多条同宽：**绝不允许静默挑一条**。NVL 堆叠正文（历史行淡出留屏）里多行同宽是常态，
// 挑错一次就会被「一个客户区尺寸只解一次」锁死整局。
void TestAmbiguousBandsAreRejectedWithoutGlyphCount() {
  Canvas c;
  int32_t right = c.DrawLine(150, 300, 319, 16, 20, 5);
  c.Fill(right + 1, 300, 549, 319, 255);
  // 第二条：同样 400 宽，但字形数不同（8 个 45px 块）。
  right = c.DrawLine(150, 200, 219, 8, 45, 5);
  c.Fill(right + 1, 200, 549, 219, 255);

  const LayerOriginPixelSolve out = Solve(c, 0);  // 拿不到 glyph_count
  assert(!out.ok && "多解必须拒绝，不得 fail-open");
  assert(out.candidate_count == 2);
  assert(std::string(out.reason) == "ambiguous_ink_bands");
}

// 有 glyph_count 时可以消歧，但只在**唯一最接近**时才算解出来。
void TestGlyphCountDisambiguatesAmbiguousBands() {
  Canvas c;
  int32_t right = c.DrawLine(150, 300, 319, 16, 20, 5);
  c.Fill(right + 1, 300, 549, 319, 255);
  right = c.DrawLine(150, 200, 219, 8, 45, 5);
  c.Fill(right + 1, 200, 549, 219, 255);

  const LayerOriginPixelSolve pick16 = Solve(c, 16);
  assert(pick16.ok && pick16.candidate_count == 2);
  assert(pick16.measured_top == 300 && "16 字形那条是 y=300..319");

  const LayerOriginPixelSolve pick8 = Solve(c, 8);
  assert(pick8.ok && pick8.measured_top == 200 && "8 字形那条是 y=200..219");
}

// 两条同宽**且字形数一样**：glyph_count 也消不掉歧义 ⇒ 仍然必须拒绝。
void TestEquallyPlausibleBandsStayRejected() {
  Canvas c;
  int32_t right = c.DrawLine(150, 300, 319, 16, 20, 5);
  c.Fill(right + 1, 300, 549, 319, 255);
  right = c.DrawLine(150, 200, 219, 16, 20, 5);
  c.Fill(right + 1, 200, 549, 219, 255);

  const LayerOriginPixelSolve out = Solve(c, 16);
  assert(!out.ok && "并列不是消歧");
  assert(std::string(out.reason) == "ambiguous_ink_bands");
}

// 宽度对不上：那不是这一行。
void TestWidthMismatchIsRejected() {
  Canvas c;
  c.Fill(150, 300, 349, 319, 255);  // 只有 200 宽，预测 400
  const LayerOriginPixelSolve out = Solve(c, 8);
  assert(!out.ok);
  assert(std::string(out.reason) == "no_band_matched_predicted_width");
}

// 全黑：一个墨迹像素都没有。
void TestAllBlackIsRejected() {
  Canvas c(0);
  const LayerOriginPixelSolve out = Solve(c, 16);
  assert(!out.ok);
  assert(std::string(out.reason) == "no_ink_band");
}

// 全白：整屏都过阈值 ⇒ 唯一那条带高度是整个客户区，被行高判据挡掉。
// 这条防的是「明亮场景把背景整片吃进来」——没有它，origin 会被解成背景中点。
void TestAllWhiteIsRejected() {
  Canvas c(255);
  const LayerOriginPixelSolve out = Solve(c, 16);
  assert(!out.ok);
  assert(std::string(out.reason) == "no_ink_band");
}

// 非法输入一律 fail-closed，绝不返回一个「看起来像数字」的 origin。
void TestInvalidInputsFailClosed() {
  Canvas c;
  LayerOriginPixelSolve out = SolveLayerOriginFromBgra(
      nullptr, kW, kH, kLayerLeft, kLayerTop, kLayerRight, kLayerBottom,
      kDesignW, kDesignH, 16);
  assert(!out.ok && std::string(out.reason) == "invalid_pixels");

  out = SolveLayerOriginFromBgra(c.bgra.data(), kW, kH, kLayerLeft, kLayerTop,
                                 kLayerLeft, kLayerBottom, kDesignW, kDesignH,
                                 16);
  assert(!out.ok && std::string(out.reason) == "invalid_layer_bounds");

  out = SolveLayerOriginFromBgra(c.bgra.data(), kW, kH, kLayerLeft, kLayerTop,
                                 kLayerRight, kLayerBottom, 0, kDesignH, 16);
  assert(!out.ok && std::string(out.reason) == "invalid_layer_bounds");

  // 行太小：缩放后不足 8x6 像素，量不出来就别装作量得出来。
  out = SolveLayerOriginFromBgra(c.bgra.data(), kW, kH, 0, 0, 4, 4, kDesignW,
                                 kDesignH, 16);
  assert(!out.ok && std::string(out.reason) == "predicted_line_too_small");
}

}  // namespace

int main() {
  TestSingleBandSolvesMidpoint();
  TestAmbiguousBandsAreRejectedWithoutGlyphCount();
  TestGlyphCountDisambiguatesAmbiguousBands();
  TestEquallyPlausibleBandsStayRejected();
  TestWidthMismatchIsRejected();
  TestAllBlackIsRejected();
  TestAllWhiteIsRejected();
  TestInvalidInputsFailClosed();
  return 0;
}
