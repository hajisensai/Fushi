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
    const wchar_t g1[] = L"今";
    const wchar_t g2[] = L"日";
    const wchar_t space[] = L"　";

    // 正向：两个单字形调用后跟一个单独 U+3000 → 这一次调用锁存。
    UnityLegacyGlyphBatchDetector glyphs;
    assert(!glyphs.Observe(g1, 1));
    assert(!glyphs.Observe(g2, 1));
    assert(!glyphs.latched());
    assert(glyphs.Observe(space, 1));
    assert(glyphs.latched());
    // 锁存后不再报告「刚锁存」。
    assert(!glyphs.Observe(g1, 1));
    assert(!glyphs.Observe(space, 1));
    assert(glyphs.latched());
    glyphs.Reset();
    assert(!glyphs.latched());

    // 负向：正常整串文本里的全角空格不是行终止，永不锁存。
    UnityLegacyGlyphBatchDetector prose;
    const wchar_t line[] = L"「おはよう」　と彼女は言った";
    const int line_len = static_cast<int>(std::wcslen(line));
    for (int i = 0; i < 4; ++i) assert(!prose.Observe(line, line_len));
    const wchar_t trailing[] = L"はい　";
    assert(!prose.Observe(trailing, 2 + 1));
    assert(!prose.latched());

    // 负向：没有前置字形批次的单独 U+3000（例如空白 UI 标签）不锁存。
    UnityLegacyGlyphBatchDetector lone;
    assert(!lone.Observe(space, 1));
    assert(!lone.Observe(g1, 1));
    assert(!lone.Observe(space, 1));  // 只有 1 个字形，不够批次
    assert(!lone.latched());

    // 负向：字形之间夹了整串文本，批次断开。
    UnityLegacyGlyphBatchDetector broken;
    assert(!broken.Observe(g1, 1));
    assert(!broken.Observe(line, line_len));
    assert(!broken.Observe(g2, 1));
    assert(!broken.Observe(space, 1));
    assert(!broken.latched());

    // 负向：空串与 nullptr 不算字形。
    UnityLegacyGlyphBatchDetector empty;
    assert(!empty.Observe(nullptr, 0));
    assert(!empty.Observe(g1, 0));
    assert(!UnityLegacyGlyphBatchDetector::IsSingleGlyph(space, 1));
    assert(UnityLegacyGlyphBatchDetector::IsStandaloneFullwidthSpace(space, 1));
    assert(!UnityLegacyGlyphBatchDetector::IsStandaloneFullwidthSpace(trailing, 3));
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
