// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

#include "voice_hook_session.h"
#include "../injector/unity_voice_bundles.h"

using fushi_voice_hook::AdvanceUnityEventCursorIfCommitted;

// injector 侧：Unity 资源语音该到哪几个 voice bundle 里抽（多个 Addressables 语音组）。
void TestVoiceBundleCandidates() {
  using fushi_voice_injector::IsUnityVoiceBundleFileName;
  using fushi_voice_injector::OrderUnityVoiceBundleCandidates;
  assert(IsUnityVoiceBundleFileName(L"voice(action)_assets_all_af.bundle"));
  assert(IsUnityVoiceBundleFileName(L"C:\\x\\VOICE_Main.BUNDLE"));
  assert(!IsUnityVoiceBundleFileName(L"se_assets_all_8c.bundle"));
  assert(!IsUnityVoiceBundleFileName(L"voice.assets"));
  assert(!IsUnityVoiceBundleFileName(L"C:\\voice\\bgm.bundle"));  // dir only

  const std::wstring dir = L"\\\\?\\D:\\g\\aa\\StandaloneWindows64";
  const std::wstring opened = dir + L"\\voice(action)_a.bundle";
  const std::vector<std::wstring> siblings = {
      L"bgm_assets_all_9.bundle", L"voice(scenario)_d.bundle",
      L"voice(action)_a.bundle", L"se_assets_all_8.bundle",
      L"voice(gimmick)_d.bundle"};
  // Hook-reported bundle first, then the other voice bundles in name order;
  // BGM / SE bundles are never candidates.
  std::vector<std::wstring> c =
      OrderUnityVoiceBundleCandidates(opened, siblings, L"");
  assert(c.size() == 3);
  assert(c[0] == opened);
  assert(c[1] == dir + L"\\voice(gimmick)_d.bundle");
  assert(c[2] == dir + L"\\voice(scenario)_d.bundle");
  // The bundle the last clip came from goes first.
  c = OrderUnityVoiceBundleCandidates(opened, siblings,
                                      dir + L"\\voice(scenario)_d.bundle");
  assert(c.size() == 3 && c[0] == dir + L"\\voice(scenario)_d.bundle" &&
         c[1] == opened);
  // A remembered bundle from another directory is ignored.
  c = OrderUnityVoiceBundleCandidates(opened, siblings,
                                      L"E:\\other\\voice(x).bundle");
  assert(c.size() == 3 && c[0] == opened);
  // Not a voice bundle: no candidates (the caller keeps the reported path).
  assert(OrderUnityVoiceBundleCandidates(dir + L"\\se_assets_all_8.bundle",
                                         siblings, L"")
             .empty());
  // Bounded.
  std::vector<std::wstring> many;
  for (int i = 0; i < 20; ++i) {
    many.push_back(L"voice" + std::to_wstring(100 + i) + L".bundle");
  }
  assert(OrderUnityVoiceBundleCandidates(opened, many, L"").size() ==
         fushi_voice_injector::kMaxUnityVoiceBundleCandidates);

  fushi_voice_injector::UnityVoiceNegativeCache cache;
  assert(!cache.Contains(dir, L"se_003"));
  cache.Add(dir, L"se_003");
  assert(cache.Contains(dir, L"se_003"));
  assert(!cache.Contains(dir, L"sce_0001"));
  assert(!cache.Contains(L"E:\\other", L"se_003"));
}

int main() {
  TestVoiceBundleCandidates();
  uint64_t next_event = 6;

  // 生产者已预留 write_count、但槽 seq 仍为 0：消费者必须保留游标。
  assert(!AdvanceUnityEventCursorIfCommitted(7, 0, &next_event));
  assert(next_event == 6);

  // 同一槽提交后再消费，恰好前进一步。
  assert(AdvanceUnityEventCursorIfCommitted(7, 7, &next_event));
  assert(next_event == 7);

  // 错槽与空指针都不能伪造消费进度。
  assert(!AdvanceUnityEventCursorIfCommitted(8, 9, &next_event));
  assert(next_event == 7);
  assert(!AdvanceUnityEventCursorIfCommitted(8, 8, nullptr));
  return 0;
}
