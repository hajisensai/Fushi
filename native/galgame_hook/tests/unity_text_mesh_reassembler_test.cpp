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

  assert(fushi_voice_hook::UsesSasasaLegacyTextMeshTerminator(
      L"E:\\games\\Sasasa.exe"));
  assert(fushi_voice_hook::UsesSasasaLegacyTextMeshTerminator(
      L"c:/games/SASASA.EXE"));
  assert(!fushi_voice_hook::UsesSasasaLegacyTextMeshTerminator(
      L"E:\\games\\manosaba.exe"));

  const uint64_t native_id = fushi_voice_hook::NativeTextThreadIdFrom(
      0, L"UnityEngine.TextMesh.set_text(glyphs)",
      "Unity TextMesh line");
  assert((native_id & fushi_voice_hook::kNativeTextThreadNamespaceBit) != 0);
  assert((fushi_voice_hook::NormalizeLunaTextThreadId(native_id) &
          fushi_voice_hook::kNativeTextThreadNamespaceBit) == 0);
  assert(native_id != fushi_voice_hook::NormalizeLunaTextThreadId(native_id));
  return 0;
}
