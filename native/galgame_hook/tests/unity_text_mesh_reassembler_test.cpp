#include <cassert>
#include <cstdint>
#include <cwchar>
#include <string>
#include <vector>

#include "text_thread_identity.h"
#include "unity_text_mesh_reassembler.h"
#include "unity_text_profile.h"

int main() {
  using hibiki_voice_hook::UnityTextMeshReassembler;
  using hibiki_voice_hook::UnityTextMeshStateTable;
  using hibiki_voice_hook::UnityTextMeshUpdate;

  UnityTextMeshReassembler<32> line;
  assert(line.ApplySnapshot(L"A", 1, true) ==
         UnityTextMeshUpdate::kPartial);
  // Full cumulative redraw appends only the newly revealed suffix.
  assert(line.ApplySnapshot(L"AB", 2, true) ==
         UnityTextMeshUpdate::kPartial);
  assert(std::wcscmp(line.text(), L"AB") == 0);
  // An empty redraw is not EOF and does not destroy the tail.
  assert(line.ApplySnapshot(L"", 0, true) ==
         UnityTextMeshUpdate::kNoChange);
  assert(std::wcscmp(line.text(), L"AB") == 0);
  assert(line.ApplySnapshot(L"AB\u3000", 3, true) ==
         UnityTextMeshUpdate::kCompleted);
  assert(std::wcscmp(line.completed_text(), L"AB") == 0);
  assert(line.empty());

  // CR/LF/TAB are content, and a non-Sasasa fullwidth space is content.
  line.Reset();
  assert(line.Append(L'\r'));
  assert(line.Append(L'\n'));
  assert(line.Append(L'\t'));
  assert(!line.ShouldTerminate(L'\u3000', false));
  assert(line.Append(L'\u3000'));

  // Overflow commits a bounded prefix and resets, so the following real line
  // remains capturable instead of inheriting a permanently latched truncation.
  UnityTextMeshReassembler<4> bounded;
  assert(bounded.ApplySnapshot(L"ABCDE", 5, true) ==
         UnityTextMeshUpdate::kOverflowCompleted);
  assert(bounded.completed_truncated());
  assert(bounded.empty());
  assert(bounded.ApplySnapshot(L"Z\u3000", 2, true) ==
         UnityTextMeshUpdate::kCompleted);
  assert(std::wcscmp(bounded.completed_text(), L"Z") == 0);

  // Interleaved components and callback threads own independent buckets.
  using Table = UnityTextMeshStateTable<4, 32>;
  Table table;
  std::vector<std::wstring> flushed;
  auto evict = [&flushed](const Table::Bucket& bucket) {
    flushed.emplace_back(bucket.line.text());
  };
  Table::Bucket& a = table.Acquire(0xA, 10, 1, evict);
  Table::Bucket& b = table.Acquire(0xB, 10, 2, evict);
  Table::Bucket& a_other_thread = table.Acquire(0xA, 11, 3, evict);
  a.line.ApplySnapshot(L"A", 1, true);
  b.line.ApplySnapshot(L"B", 1, true);
  a_other_thread.line.ApplySnapshot(L"C", 1, true);
  assert(std::wcscmp(a.line.text(), L"A") == 0);
  assert(std::wcscmp(b.line.text(), L"B") == 0);
  assert(std::wcscmp(a_other_thread.line.text(), L"C") == 0);
  table.FlushAll([&flushed](const Table::Bucket& bucket) {
    flushed.emplace_back(bucket.line.text());
  });
  assert(flushed.size() == 3);

  assert(hibiki_voice_hook::UsesSasasaLegacyTextMeshTerminator(
      L"E:\\games\\Sasasa.exe"));
  assert(!hibiki_voice_hook::UsesSasasaLegacyTextMeshTerminator(
      L"E:\\games\\manosaba.exe"));

  const uint64_t identity =
      hibiki_voice_hook::NativeComponentThreadIdentity(0xA, 10);
  const uint64_t other =
      hibiki_voice_hook::NativeComponentThreadIdentity(0xA, 11);
  assert(identity != other);
  const uint64_t native_id = hibiki_voice_hook::NativeTextThreadIdFrom(
      identity, L"UnityEngine.TextMesh.set_text(glyphs)",
      "Unity TextMesh line");
  assert((native_id & hibiki_voice_hook::kNativeTextThreadNamespaceBit) != 0);
  assert(native_id != hibiki_voice_hook::NormalizeLunaTextThreadId(native_id));
  return 0;
}
