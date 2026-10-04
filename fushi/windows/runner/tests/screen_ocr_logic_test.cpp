// release 也要真断言：NDEBUG 会把 assert 编成空语句，测试就会空跑照样"通过"。
#undef NDEBUG

#include "../screen_ocr_logic.h"
#include "../worker_reply_queue.h"

#include <cassert>
#include <cmath>
#include <string>
#include <vector>

namespace {

bool Near(double a, double b, double eps = 1e-9) {
  return std::fabs(a - b) < eps;
}

}  // namespace

int main() {
  using namespace fushi::screen_ocr;

  // ── 词拼接：CJK 交界不插空格，其余插一个 ──────────────────────────────
  {
    // Windows OCR 把日文按词（常是逐字）拆开：拼回去不能出现「日 本 語」。
    assert(JoinOcrWords({L"日本", L"語", L"の", L"勉強"}) == L"日本語の勉強");
    assert(JoinOcrWords({L"Hello", L"world"}) == L"Hello world");
    // 日英交界保留空格（任一侧是 ASCII 就插）。
    assert(JoinOcrWords({L"これは", L"OCR", L"です"}) == L"これは OCR です");
    // 混写词按交界字符判断，而不是整词。
    assert(JoinOcrWords({L"AI技術", L"の", L"話"}) == L"AI技術の話");
    assert(JoinOcrWords({L"技術AI", L"の"}) == L"技術AI の");
    // 已有空白的一侧不再加；空词跳过。
    assert(JoinOcrWords({L"a ", L"b"}) == L"a b");
    assert(JoinOcrWords({L"", L"x", L"", L"y"}) == L"x y");
    assert(JoinOcrWords({}) == L"");
    // 扩展区汉字（代理对）按非 ASCII。
    assert(JoinOcrWords({L"\U00020BB7", L"野家"}) == L"\U00020BB7野家");
    // 全角标点也是非 ASCII：「。」与下一句直接相连。
    assert(JoinOcrWords({L"です。", L"次"}) == L"です。次");
  }

  // ── 行框 = 词框并集 ───────────────────────────────────────────────────
  {
    const auto u = UnionOfRects({RectD{10, 20, 30, 40}, RectD{25, 15, 60, 35}});
    assert(u && Near(u->left, 10) && Near(u->top, 15) && Near(u->right, 60) &&
           Near(u->bottom, 40));
    // 零面积 / NaN 的词框不参与。
    const auto v = UnionOfRects({RectD{0, 0, 0, 0}, RectD{5, 5, 6, 7},
                                 RectD{NAN, 0, 1, 1}});
    assert(v && Near(v->left, 5) && Near(v->right, 6) && Near(v->bottom, 7));
    assert(!UnionOfRects({}));
    assert(!UnionOfRects({RectD{3, 3, 3, 9}}));
  }

  // ── 识别语言：完全匹配优先，再按主标签 ──────────────────────────────────
  {
    const std::vector<std::wstring> tags = {L"en-US", L"zh-Hans-CN", L"ja-JP",
                                            L"ja"};
    assert(PrimarySubtag(L"zh-Hans-CN") == L"zh");
    assert(PrimarySubtag(L"JA_jp") == L"ja");
    assert(PickRecognizerLanguage(tags, L"ja") == 3);   // 完全匹配优先
    assert(PickRecognizerLanguage(tags, L"JA-jp") == 2);
    assert(PickRecognizerLanguage(tags, L"zh") == 1);
    assert(PickRecognizerLanguage(tags, L"en") == 0);
    assert(PickRecognizerLanguage(tags, L"ko") == -1);  // LANGUAGE_UNAVAILABLE
    assert(PickRecognizerLanguage(tags, L"") == -1);
    assert(PickRecognizerLanguage({}, L"ja") == -1);
    // 只有 ja-JP 也能认 `ja`。
    assert(PickRecognizerLanguage({L"en-US", L"ja-JP"}, L"ja") == 1);
  }

  // ── OCR 最大边长 ─────────────────────────────────────────────────────
  {
    assert(Near(FitScaleForMaxDimension(3840, 2160, 10000), 1.0));
    assert(Near(FitScaleForMaxDimension(20000, 5000, 10000), 0.5));
    assert(Near(FitScaleForMaxDimension(4000, 12500, 10000), 0.8));
    assert(Near(FitScaleForMaxDimension(4000, 4000, 0), 1.0));
    assert(Near(FitScaleForMaxDimension(0, 4000, 10000), 1.0));
  }

  // ── 截哪块显示器：anchor 中心，否则光标 ─────────────────────────────────
  {
    const ProbePoint cursor{-500, 300};
    const ProbePoint a =
        MonitorProbePoint(RectD{1900, 400, 1960, 460}, cursor);
    assert(a.x == 1930 && a.y == 430);
    const ProbePoint b = MonitorProbePoint(std::nullopt, cursor);
    assert(b.x == -500 && b.y == 300);
    const ProbePoint c = MonitorProbePoint(RectD{NAN, 0, 1, 1}, cursor);
    assert(c.x == -500 && c.y == 300);
  }

  // ── 提示条布局与点击归类 ───────────────────────────────────────────────
  {
    // 1920 宽、scale 1、文字 200x20：宽 = 16 + 200 + 10 + 24 + 8 = 258，
    // 高 = max(20, 24) + 20 = 44，水平居中、距顶 24。
    const BannerLayout l = LayoutBanner(1920, 1.0, 200, 20);
    assert(Near(l.banner.left, std::round((1920 - 258) / 2.0)));
    assert(Near(l.banner.Width(), 258));
    assert(Near(l.banner.top, 24) && Near(l.banner.Height(), 44));
    assert(Near(l.text.left, l.banner.left + 16));
    assert(Near(l.close.left, l.text.right + 10));
    assert(Near(l.close.Width(), 24) && Near(l.close.Height(), 24));
    // 关闭钮在提示条内。
    assert(l.close.right <= l.banner.right && l.close.top >= l.banner.top &&
           l.close.bottom <= l.banner.bottom);
    const double cx = (l.close.left + l.close.right) / 2;
    const double cy = (l.close.top + l.close.bottom) / 2;
    assert(ClassifyLeftClick(l, cx, cy) == OverlayClick::kDismiss);
    assert(ClassifyLeftClick(l, l.text.left + 5, cy) == OverlayClick::kIgnore);
    assert(ClassifyLeftClick(l, 10, 500) == OverlayClick::kTap);
    assert(ClassifyLeftClick(l, cx, l.banner.bottom + 1) == OverlayClick::kTap);

    // 200% 缩放：边距与关闭钮按 scale 放大。
    const BannerLayout h = LayoutBanner(3840, 2.0, 400, 40);
    assert(Near(h.close.Width(), 48));
    assert(Near(h.banner.top, 48));
    assert(Near(h.banner.Height(), 48 + 40));

    // 超长文字被限到 MaxBannerTextWidth，提示条不出屏。
    const BannerLayout w = LayoutBanner(800, 1.0, 5000, 20);
    assert(w.banner.left >= 0 && w.banner.right <= 800);
    assert(Near(w.text.Width(), MaxBannerTextWidth(800, 1.0)));
  }

  // ── 工作线程回话队列：完成、取消、关闭后丢弃 ─────────────────────────────
  {
    fushi::WorkerReplyQueue<int> queue([] { return -1; });
    std::vector<int> replies;
    auto first = queue.Enqueue([&](int v) { replies.push_back(v); });
    auto second = queue.Enqueue([&](int v) { replies.push_back(v * 10); });
    assert(first && second && !queue.empty());
    queue.Drain();
    assert(replies.empty());  // 还没完成：不回话
    second->Publish(2);
    second->Publish(99);  // 只认第一次
    queue.Drain();
    assert(replies.size() == 1 && replies[0] == 20);
    // 关闭：未完成的回取消结果；之后才到的结果被丢弃。
    queue.Close();
    assert(replies.size() == 2 && replies[1] == -1 && queue.empty());
    first->Publish(1);
    queue.Drain();
    assert(replies.size() == 2);
    // 关闭后再排队：立即回取消结果、不给工作线程槽位。
    auto late = queue.Enqueue([&](int v) { replies.push_back(v); });
    assert(!late && replies.size() == 3 && replies[2] == -1);
  }

  return 0;
}
