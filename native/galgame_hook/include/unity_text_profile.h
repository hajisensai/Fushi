#ifndef FUSHI_UNITY_TEXT_PROFILE_H_
#define FUSHI_UNITY_TEXT_PROFILE_H_

#include <cwchar>

namespace fushi_voice_hook {

// 旧 Unity TextMesh 逐字渲染器的行终止约定（引擎行为判据，不看 exe 名 / 哈希）。
//
// 真机证据（BUG-1200 / BUG-1247，最悪なる災厄人間に捧ぐ）：老 KEMCO 渲染器把一句
// 对白拆成一串 `TextMesh.set_text` **单字形**调用，每个字形批次之后再单独调用一次、
// 内容恰好是一个 U+3000 的 set_text 作为批次结束符。U+3000 本身不是通用的 Unity
// 行界——其他标题把它当正文里的全角空格保留。
//
// 所以判据是这串调用的**形状**：至少 kMinGlyphsBeforeTerminator 个连续的单字形
// 调用，紧跟一个内容恰好是单独 U+3000 的调用。看到完整签名后锁存，此后按逐字形批次
// 重组、U+3000 终止当前行；没看到签名之前一切调用按整串文本处理，正文里的全角空格
// 原样保留。
//
// 为什么判据是**进程级**而不是按组件分别计数：`TextMesh.set_text` 替换整个组件的
// 文本，一个组件只显示一个字形，所以「一句对白 = 一串单字形调用」的渲染器本来就是
// 一字一个组件（同类的 Mono 逐字形框架实测正是一字一个 GameObject）。按组件计数时，
// 一个组件永远只看到一个字形，签名在 Sasasa 上就再也凑不齐——那是把真阳性一起
// 判没了。组件身份区分不了「逐字对白」和「竖排逐格」，所以不靠它。
//
// 误锁存的代价由下面两条兜住，而不是靠组件身份：
//  * 撤销：锁存后出现**内部**夹着 U+3000 的多字符整串（首尾之外），说明本进程的
//    文本把全角空格当正文——锁存撤销，计数清零；真是逐字渲染器的话，下一批次会
//    重新锁存。
//  * 分流：锁存后只有单字形与单独 U+3000 进逐字形行；多字符整串（UI / 菜单 /
//    名牌）照旧走各自组件的整串线程，不会被拼进同一条 glyph 行。
//
// 判定期（未锁存）内的单字形调用**不作为独立行发布**：它们只进影子缓冲，签名补全时
// 整句一次发布到逐字形行；签名断开时丢弃。否则第一句会以一串单字行出现在各组件线程
// 里，宿主自动选线可能先选中某个组件线程，而锁存后那个线程再也不出字。
//
// 该类只做 O(1) 计数，不分配、不阻塞，可以在 set_text 的 detour 里直接调用。
class UnityLegacyGlyphBatchDetector {
 public:
  static constexpr int kMinGlyphsBeforeTerminator = 2;

  // 一次 set_text 调用应该走哪条路。
  enum class Route {
    // 按整串文本发布到它自己的组件线程（多字符串、空串、无签名的单独 U+3000）。
    // 未锁存时同时意味着影子缓冲里的字形作废。
    kComponentText,
    // 未锁存的单字形：只进影子缓冲，不发布。
    kHoldGlyph,
    // 这一次调用补全了签名：把影子缓冲作为完整一行发布（这次的 U+3000 被消费）。
    kLatchedFlushLine,
    // 已锁存的单字形或单独 U+3000：喂给逐字形行（U+3000 终止当前行）。
    kGlyphLine,
    // 已锁存时的空串：渲染器清空，提交尚未结束的末句。
    kFlushLine,
    // 这一次调用撤销了锁存：先提交逐字形行里已有的半句，再按整串文本发布本次调用。
    kRevokedComponentText,
  };

  // 一个 set_text 负载是不是「单字形」：恰好一个可见字符、且不是 U+3000。
  static bool IsSingleGlyph(const wchar_t* chars, int length) {
    return chars != nullptr && length == 1 && chars[0] >= 0x20 &&
           chars[0] != L'　';
  }

  // 一个 set_text 负载是不是「单独的 U+3000」。
  static bool IsStandaloneFullwidthSpace(const wchar_t* chars, int length) {
    return chars != nullptr && length == 1 && chars[0] == L'　';
  }

  // 多字符整串的首尾之外是否夹着 U+3000（正文全角空格的直接证据）。
  static bool HasInteriorFullwidthSpace(const wchar_t* chars, int length) {
    if (chars == nullptr || length < 3) return false;
    for (int i = 1; i + 1 < length; ++i) {
      if (chars[i] == L'　') return true;
    }
    return false;
  }

  // 观察一次 set_text 调用并给出路由。
  Route Observe(const wchar_t* chars, int length) {
    if (latched_) return ObserveLatched(chars, length);
    if (IsSingleGlyph(chars, length)) {
      if (consecutive_glyphs_ < kMinGlyphsBeforeTerminator) {
        ++consecutive_glyphs_;
      }
      return Route::kHoldGlyph;
    }
    if (IsStandaloneFullwidthSpace(chars, length) &&
        consecutive_glyphs_ >= kMinGlyphsBeforeTerminator) {
      latched_ = true;
      consecutive_glyphs_ = 0;
      return Route::kLatchedFlushLine;
    }
    // 多字符整串、空串、或前面没有字形批次的单独 U+3000：签名断开。
    consecutive_glyphs_ = 0;
    return Route::kComponentText;
  }

  bool latched() const { return latched_; }

  void Reset() {
    consecutive_glyphs_ = 0;
    latched_ = false;
  }

 private:
  Route ObserveLatched(const wchar_t* chars, int length) {
    if (IsSingleGlyph(chars, length) ||
        IsStandaloneFullwidthSpace(chars, length)) {
      return Route::kGlyphLine;
    }
    if (chars == nullptr || length <= 0) return Route::kFlushLine;
    if (HasInteriorFullwidthSpace(chars, length)) {
      Reset();
      return Route::kRevokedComponentText;
    }
    return Route::kComponentText;
  }

  int consecutive_glyphs_ = 0;
  bool latched_ = false;
};

}  // namespace fushi_voice_hook

#endif  // FUSHI_UNITY_TEXT_PROFILE_H_
