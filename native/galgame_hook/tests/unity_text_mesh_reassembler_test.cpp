// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cwchar>

#include "text_thread_identity.h"
#include "unity_text_mesh_reassembler.h"
#include "unity_text_profile.h"

int main() {
  using fushi_voice_hook::UnityTextMeshReassembler;

  UnityTextMeshReassembler<32> line;
  assert(line.Append(L'前'));
  assert(line.Append(L'\r'));
  assert(line.Append(L'\n'));
  assert(line.Append(L'後'));
  assert(std::wcscmp(line.text(), L"前\r\n後") == 0);

  // A pause has no API and therefore cannot flush or split the accumulator.
  assert(!line.ShouldTerminate(L'\n', true));
  assert(!line.ShouldTerminate(L'\r', true));
  assert(!line.ShouldTerminate(L'\u3000', false));
  assert(line.ShouldTerminate(L'\u3000', true));

  line.Reset();
  assert(line.Append(L'文'));
  assert(line.Append(L'\u3000'));
  assert(line.Append(L'中'));
  assert(std::wcscmp(line.text(), L"文\u3000中") == 0);

  // 逐字形批次 + 单独 U+3000 的引擎行为判据（不看 exe 名）。
  {
    using fushi_voice_hook::UnityLegacyGlyphBatchDetector;
    using Route = UnityLegacyGlyphBatchDetector::Route;
    const wchar_t g1[] = L"今";
    const wchar_t g2[] = L"日";
    const wchar_t g3[] = L"は";
    const wchar_t space[] = L"　";

    // Sasasa 形态：两个单字形调用后跟一个单独 U+3000 → 这一次调用锁存，并把判定期
    // 影子缓冲作为整句发布；判定期的单字形一律只缓冲、不独立发布。
    UnityLegacyGlyphBatchDetector glyphs;
    assert(glyphs.Observe(g1, 1) == Route::kHoldGlyph);
    assert(glyphs.Observe(g2, 1) == Route::kHoldGlyph);
    assert(!glyphs.latched());
    assert(glyphs.Observe(space, 1) == Route::kLatchedFlushLine);
    assert(glyphs.latched());
    // 锁存后：单字形与单独 U+3000 进逐字形行，不再报告「刚锁存」。
    assert(glyphs.Observe(g1, 1) == Route::kGlyphLine);
    assert(glyphs.Observe(space, 1) == Route::kGlyphLine);
    // 锁存后的空串提交末句。
    assert(glyphs.Observe(nullptr, 0) == Route::kFlushLine);
    assert(glyphs.Observe(g1, 0) == Route::kFlushLine);
    // 锁存后的多字符 UI / 菜单整串不拼进逐字形行，也不撤销（没有内部全角空格）。
    const wchar_t menu[] = L"セーブ";
    assert(glyphs.Observe(menu, 3) == Route::kComponentText);
    const wchar_t indent[] = L"　はい";   // 首字缩进不算内部
    assert(glyphs.Observe(indent, 3) == Route::kComponentText);
    const wchar_t tail[] = L"はい　";     // 行尾空格不算内部
    assert(glyphs.Observe(tail, 3) == Route::kComponentText);
    assert(glyphs.latched());
    glyphs.Reset();
    assert(!glyphs.latched());

    // 撤销：锁存后出现内部夹着 U+3000 的多字符整串 → 全角空格在本进程是正文，
    // 锁存撤销、计数清零；真逐字渲染器下一批次重新锁存。
    UnityLegacyGlyphBatchDetector revoked;
    assert(revoked.Observe(g1, 1) == Route::kHoldGlyph);
    assert(revoked.Observe(g2, 1) == Route::kHoldGlyph);
    assert(revoked.Observe(space, 1) == Route::kLatchedFlushLine);
    const wchar_t prose_line[] = L"はい　そうです";
    const int prose_line_len = static_cast<int>(std::wcslen(prose_line));
    assert(revoked.Observe(prose_line, prose_line_len) ==
           Route::kRevokedComponentText);
    assert(!revoked.latched());
    // 撤销后单独 U+3000 不能借撤销前的计数立刻再锁存。
    assert(revoked.Observe(g3, 1) == Route::kHoldGlyph);
    assert(revoked.Observe(space, 1) == Route::kComponentText);
    assert(!revoked.latched());
    assert(revoked.Observe(g1, 1) == Route::kHoldGlyph);
    assert(revoked.Observe(g2, 1) == Route::kHoldGlyph);
    assert(revoked.Observe(space, 1) == Route::kLatchedFlushLine);
    assert(revoked.latched());

    // 竖排逐格（一格一个 TextMesh）的作品：首字缩进的单独 U+3000 前面没有字形批次，
    // 不锁存；只要正文以多字符整串出现过内部全角空格，锁存不会留下来。
    UnityLegacyGlyphBatchDetector vertical;
    assert(vertical.Observe(space, 1) == Route::kComponentText);  // 段首缩进
    assert(vertical.Observe(g1, 1) == Route::kHoldGlyph);
    assert(vertical.Observe(space, 1) == Route::kComponentText);  // 只有 1 个字形
    assert(!vertical.latched());
    // 已知限制（钉住，别当成已解决）：句中 ≥2 格之后的单独 U+3000 与 Sasasa 的批次
    // 结束符在调用形状上无法区分，仍会锁存；之后多字符 UI 不受影响，正文多字符串
    // 带内部全角空格时撤销。
    assert(vertical.Observe(g1, 1) == Route::kHoldGlyph);
    assert(vertical.Observe(g2, 1) == Route::kHoldGlyph);
    assert(vertical.Observe(space, 1) == Route::kLatchedFlushLine);
    assert(vertical.latched());

    // 负向：正常整串文本里的全角空格不是行终止，永不锁存。
    UnityLegacyGlyphBatchDetector prose;
    const wchar_t line[] = L"「おはよう」　と彼女は言った";
    const int line_len = static_cast<int>(std::wcslen(line));
    for (int i = 0; i < 4; ++i) {
      assert(prose.Observe(line, line_len) == Route::kComponentText);
    }
    const wchar_t trailing[] = L"はい　";
    assert(prose.Observe(trailing, 2 + 1) == Route::kComponentText);
    assert(!prose.latched());

    // 负向：字形之间夹了整串文本，批次断开。
    UnityLegacyGlyphBatchDetector broken;
    assert(broken.Observe(g1, 1) == Route::kHoldGlyph);
    assert(broken.Observe(line, line_len) == Route::kComponentText);
    assert(broken.Observe(g2, 1) == Route::kHoldGlyph);
    assert(broken.Observe(space, 1) == Route::kComponentText);
    assert(!broken.latched());

    // 负向：未锁存时空串与 nullptr 不算字形。
    UnityLegacyGlyphBatchDetector empty;
    assert(empty.Observe(nullptr, 0) == Route::kComponentText);
    assert(empty.Observe(g1, 0) == Route::kComponentText);
    assert(!UnityLegacyGlyphBatchDetector::IsSingleGlyph(space, 1));
    assert(UnityLegacyGlyphBatchDetector::IsStandaloneFullwidthSpace(space, 1));
    assert(!UnityLegacyGlyphBatchDetector::IsStandaloneFullwidthSpace(trailing, 3));
    assert(UnityLegacyGlyphBatchDetector::HasInteriorFullwidthSpace(
        prose_line, prose_line_len));
    assert(!UnityLegacyGlyphBatchDetector::HasInteriorFullwidthSpace(trailing, 3));
    assert(!UnityLegacyGlyphBatchDetector::HasInteriorFullwidthSpace(indent, 3));
    assert(!UnityLegacyGlyphBatchDetector::HasInteriorFullwidthSpace(nullptr, 5));
  }

  const uint64_t native_id = fushi_voice_hook::NativeTextThreadIdFrom(
      0, L"UnityEngine.TextMesh.set_text(glyphs)",
      "Unity TextMesh line");
  assert((native_id & fushi_voice_hook::kNativeTextThreadNamespaceBit) != 0);
  assert((fushi_voice_hook::NormalizeLunaTextThreadId(native_id) &
          fushi_voice_hook::kNativeTextThreadNamespaceBit) == 0);
  assert(native_id != fushi_voice_hook::NormalizeLunaTextThreadId(native_id));
  return 0;
}
