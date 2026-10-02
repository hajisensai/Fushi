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
// 调用，紧跟一个内容恰好是单独 U+3000 的调用。看到一次完整签名后锁存（本进程的
// 渲染器约定不会中途改变），此后按逐字形批次重组、U+3000 终止当前行；没看到签名之前
// 一切调用按整串文本处理，正文里的全角空格原样保留。
//
// 该类只做 O(1) 计数，不分配、不阻塞，可以在 set_text 的 detour 里直接调用。
class UnityLegacyGlyphBatchDetector {
 public:
  static constexpr int kMinGlyphsBeforeTerminator = 2;

  // 一个 set_text 负载是不是「单字形」：恰好一个可见字符、且不是 U+3000。
  static bool IsSingleGlyph(const wchar_t* chars, int length) {
    return chars != nullptr && length == 1 && chars[0] >= 0x20 &&
           chars[0] != L'　';
  }

  // 一个 set_text 负载是不是「单独的 U+3000」。
  static bool IsStandaloneFullwidthSpace(const wchar_t* chars, int length) {
    return chars != nullptr && length == 1 && chars[0] == L'　';
  }

  // 观察一次 set_text 调用。返回 true 表示**这一次**调用补全了签名并刚刚锁存。
  bool Observe(const wchar_t* chars, int length) {
    if (latched_) return false;
    if (IsSingleGlyph(chars, length)) {
      if (consecutive_glyphs_ < kMinGlyphsBeforeTerminator) {
        ++consecutive_glyphs_;
      }
      return false;
    }
    if (IsStandaloneFullwidthSpace(chars, length) &&
        consecutive_glyphs_ >= kMinGlyphsBeforeTerminator) {
      latched_ = true;
      consecutive_glyphs_ = 0;
      return true;
    }
    // 多字符整串、空串、或前面没有字形批次的单独 U+3000：签名断开。
    consecutive_glyphs_ = 0;
    return false;
  }

  bool latched() const { return latched_; }

  void Reset() {
    consecutive_glyphs_ = 0;
    latched_ = false;
  }

 private:
  int consecutive_glyphs_ = 0;
  bool latched_ = false;
};

}  // namespace fushi_voice_hook

#endif  // FUSHI_UNITY_TEXT_PROFILE_H_
