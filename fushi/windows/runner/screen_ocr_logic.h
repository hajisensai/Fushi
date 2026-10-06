#ifndef RUNNER_SCREEN_OCR_LOGIC_H_
#define RUNNER_SCREEN_OCR_LOGIC_H_

// 桌面应用外悬浮球「截屏识字」与 Windows 系统 OCR 的纯逻辑（无 Win32 / WinRT 调用），
// 契约：docs/specs/2026-09-30-desktop-system-floating-ball.md「截屏识字」。
// 抽成头文件是为了随每次 runner 构建跑一遍（tests/screen_ocr_logic_test.cpp）：
// 词拼接规则错了 Dart 拿到的行文本就和截图对不上（查的后缀错位），识别语言挑错了
// 就是「明明装了日语却报没装」，提示条 / 关闭钮的命中错了就是点关闭却查了词。

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace fushi {
namespace screen_ocr {

struct RectD {
  double left = 0;
  double top = 0;
  double right = 0;
  double bottom = 0;

  double Width() const { return right - left; }
  double Height() const { return bottom - top; }
  bool HasArea() const { return right > left && bottom > top; }
  bool Contains(double x, double y) const {
    return x >= left && x < right && y >= top && y < bottom;
  }
};

// ── OCR 结果整形 ───────────────────────────────────────────────────────────

// Windows OCR 把日文 / 中文按词（常常是逐字）拆成 OcrWord，OcrLine.Text 在每个词之间
// 插空格（「日 本 語」）。行文本自己拼：交界两侧都是非 ASCII（CJK）时直接相连，否则
// 插一个空格（英文单词、日英混排的边界保留空格）。按交界字符而不是整词判断，
// 「AI技術」「技術AI」这种混写词也拼得对。UTF-16 代理对的两个单元都 >= 0x80，
// 按非 ASCII 处理（扩展区汉字正是 CJK）。
inline bool IsAsciiUnit(wchar_t unit) { return unit < 0x80; }

inline bool IsSpaceUnit(wchar_t unit) {
  return unit == L' ' || unit == L'\t' || unit == L'\r' || unit == L'\n' ||
         unit == 0x3000;  // 全角空格
}

inline bool NeedsSpaceBetween(const std::wstring& previous,
                              const std::wstring& next) {
  if (previous.empty() || next.empty()) {
    return false;
  }
  const wchar_t tail = previous.back();
  const wchar_t head = next.front();
  if (IsSpaceUnit(tail) || IsSpaceUnit(head)) {
    return false;
  }
  return IsAsciiUnit(tail) || IsAsciiUnit(head);
}

inline std::wstring JoinOcrWords(const std::vector<std::wstring>& words) {
  std::wstring joined;
  for (const std::wstring& word : words) {
    if (word.empty()) {
      continue;
    }
    if (NeedsSpaceBetween(joined, word)) {
      joined.push_back(L' ');
    }
    joined += word;
  }
  return joined;
}

// 行框 = 该行所有（有面积的）词框的并集；一个有效词框都没有时返回 nullopt。
inline std::optional<RectD> UnionOfRects(const std::vector<RectD>& rects) {
  std::optional<RectD> out;
  for (const RectD& r : rects) {
    if (!std::isfinite(r.left) || !std::isfinite(r.top) ||
        !std::isfinite(r.right) || !std::isfinite(r.bottom) || !r.HasArea()) {
      continue;
    }
    if (!out) {
      out = r;
      continue;
    }
    out->left = std::min(out->left, r.left);
    out->top = std::min(out->top, r.top);
    out->right = std::max(out->right, r.right);
    out->bottom = std::max(out->bottom, r.bottom);
  }
  return out;
}

// ── 识别语言 ───────────────────────────────────────────────────────────────

inline wchar_t AsciiLower(wchar_t c) {
  return (c >= L'A' && c <= L'Z') ? static_cast<wchar_t>(c - L'A' + L'a') : c;
}

inline std::wstring AsciiLowerString(const std::wstring& value) {
  std::wstring out = value;
  for (wchar_t& c : out) c = AsciiLower(c);
  return out;
}

// BCP-47 主标签（「ja-JP」→「ja」、「zh-Hans-CN」→「zh」），小写。
inline std::wstring PrimarySubtag(const std::wstring& tag) {
  const size_t dash = tag.find_first_of(L"-_");
  return AsciiLowerString(dash == std::wstring::npos ? tag
                                                     : tag.substr(0, dash));
}

// Dart 送来的是主标签（`ja`），本机识别器的标签带地区（`ja-JP`、`zh-Hans-CN`）。
// 先找完全相同的标签（忽略大小写），再找主标签相同的第一个；都没有回 -1
// （= LANGUAGE_UNAVAILABLE：本机没装这门语言的 OCR 组件）。
inline int PickRecognizerLanguage(const std::vector<std::wstring>& available,
                                  const std::wstring& requested) {
  const std::wstring wanted = AsciiLowerString(requested);
  if (wanted.empty()) {
    return -1;
  }
  for (size_t i = 0; i < available.size(); ++i) {
    if (AsciiLowerString(available[i]) == wanted) {
      return static_cast<int>(i);
    }
  }
  const std::wstring wanted_primary = PrimarySubtag(wanted);
  for (size_t i = 0; i < available.size(); ++i) {
    if (PrimarySubtag(available[i]) == wanted_primary) {
      return static_cast<int>(i);
    }
  }
  return -1;
}

// Windows OCR 有最大边长（OcrEngine.MaxImageDimension，实测 10000）。超出时整图等比
// 缩到上限内识别，坐标再按同一比例放回原图像素。返回缩放比（<= 1）。
inline double FitScaleForMaxDimension(unsigned width, unsigned height,
                                      unsigned max_dimension) {
  if (width == 0 || height == 0 || max_dimension == 0) {
    return 1.0;
  }
  const unsigned longest = std::max(width, height);
  if (longest <= max_dimension) {
    return 1.0;
  }
  return static_cast<double>(max_dimension) / static_cast<double>(longest);
}

// ── 冻结层 ─────────────────────────────────────────────────────────────────

// 截哪块显示器：anchor（球的屏幕矩形）中心所在的那块；没有 anchor 取光标位置。
struct ProbePoint {
  long x = 0;
  long y = 0;
};

inline ProbePoint MonitorProbePoint(const std::optional<RectD>& anchor,
                                    ProbePoint cursor) {
  if (!anchor || !std::isfinite(anchor->left) || !std::isfinite(anchor->top) ||
      !std::isfinite(anchor->right) || !std::isfinite(anchor->bottom)) {
    return cursor;
  }
  return ProbePoint{
      static_cast<long>(std::lround((anchor->left + anchor->right) / 2)),
      static_cast<long>(std::lround((anchor->top + anchor->bottom) / 2))};
}

// 冻结层上的绘制常量（DIP；乘显示器 scale 得物理像素）。
constexpr double kDimAlpha = 0.18;          // 截图上压一层 18% 黑
constexpr double kLineStrokeDip = 1.5;      // 行框描边
constexpr double kLineFillAlpha = 0.12;     // 行框填充（primary）
constexpr double kLineOutsetDip = 2.0;      // 行框比字框外扩一点，描边不压字
constexpr double kBannerTopDip = 24.0;      // 提示条距显示器顶
constexpr double kBannerSideMarginDip = 24.0;
constexpr double kBannerPadHDip = 16.0;
constexpr double kBannerPadVDip = 10.0;
constexpr double kBannerGapDip = 10.0;      // 文字与关闭钮之间
constexpr double kCloseSizeDip = 24.0;      // 关闭钮（圆）直径
constexpr double kBannerFontDip = 14.0;

struct BannerLayout {
  RectD banner;  // 圆角提示条整体（物理 px，冻结层客户区坐标 = 截图像素）
  RectD text;    // 文字框
  RectD close;   // 关闭钮命中区（圆的外接方框）
};

// |text_w| / |text_h| 是 DirectWrite 量出的文字尺寸（物理 px，已按
// MaxBannerTextWidth 限过宽）。提示条水平居中，关闭钮在文字右侧。
inline double MaxBannerTextWidth(double screen_width, double scale) {
  const double reserved =
      2 * kBannerSideMarginDip + 2 * kBannerPadHDip + kBannerGapDip +
      kCloseSizeDip;
  return std::max(1.0, screen_width - reserved * scale);
}

inline BannerLayout LayoutBanner(double screen_width, double scale,
                                 double text_w, double text_h) {
  const double s = scale > 0 ? scale : 1.0;
  text_w = std::clamp(text_w, 0.0, MaxBannerTextWidth(screen_width, s));
  const double close = kCloseSizeDip * s;
  const double content_h = std::max(text_h, close);
  const double width = kBannerPadHDip * s + text_w + kBannerGapDip * s +
                       close + kBannerPadHDip * s * 0.5;
  const double height = content_h + 2 * kBannerPadVDip * s;
  BannerLayout out;
  out.banner.left = std::round((screen_width - width) / 2);
  out.banner.top = std::round(kBannerTopDip * s);
  out.banner.right = out.banner.left + std::round(width);
  out.banner.bottom = out.banner.top + std::round(height);
  out.text.left = out.banner.left + kBannerPadHDip * s;
  out.text.top = out.banner.top + (height - text_h) / 2;
  out.text.right = out.text.left + text_w;
  out.text.bottom = out.text.top + text_h;
  out.close.left = out.text.right + kBannerGapDip * s;
  out.close.top = out.banner.top + (height - close) / 2;
  out.close.right = out.close.left + close;
  out.close.bottom = out.close.top + close;
  return out;
}

enum class OverlayClick {
  kTap,      // 交给 Dart 命中测试（screenOcrTap）
  kDismiss,  // 关闭钮：原生关层（screenOcrDismissed）
  kIgnore,   // 点在提示条本身（非关闭钮）：什么都不做
};

// 左键按在冻结层客户区 (x, y)（物理 px）上的含义。提示条盖住的那一小块截图不当作
// 点字——用户点提示条是想看清 / 点关闭，不是查被它挡住的字。
inline OverlayClick ClassifyLeftClick(const BannerLayout& layout, double x,
                                      double y) {
  if (layout.close.Contains(x, y)) {
    return OverlayClick::kDismiss;
  }
  if (layout.banner.Contains(x, y)) {
    return OverlayClick::kIgnore;
  }
  return OverlayClick::kTap;
}

}  // namespace screen_ocr
}  // namespace fushi

#endif  // RUNNER_SCREEN_OCR_LOGIC_H_
