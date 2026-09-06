// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 本文件用 Expect() 计数而不是 assert，但守卫要求这条不变式对所有原生测试一致成立。
// 守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// 第三条 exporter 路径的判据测试（BUG-2145）。
//
// 形状门用**真内存**验而不是合成的可读性回调：判据里"候选可读 / 其首字是可读的虚表 /
// 虚表槽落在映像内"三件事里，前两件只有 VirtualQuery 能作证。所以这里造真的静态数组当
// 假虚表与假映像，用生产代码同一个 DefaultReadableSpan 去问。
#include "../hook/adapters/kirikiri_exporter_scan.h"

#include <cstdio>
#include <vector>

namespace {

using fushi_voice_hook::kirikiri_exporter::CollectWritableWords;
using fushi_voice_hook::kirikiri_exporter::DefaultReadableSpan;
using fushi_voice_hook::kirikiri_exporter::IntersectWritableWords;
using fushi_voice_hook::kirikiri_exporter::kMinPlugins;
using fushi_voice_hook::kirikiri_exporter::kVtableProbeEntries;
using fushi_voice_hook::kirikiri_exporter::LooksLikeExporter;

int g_failures = 0;

void Expect(bool condition, const char* what) {
  if (condition) return;
  ++g_failures;
  std::fprintf(stderr, "FAIL: %s\n", what);
}

// 假引擎映像：虚表槽必须指进这里才算像 exporter。
uintptr_t g_engine_image[32];
uintptr_t g_vtable[kVtableProbeEntries + 4];
uintptr_t g_object[2];

uintptr_t ImageBase() { return reinterpret_cast<uintptr_t>(&g_engine_image[0]); }
uint32_t ImageSize() { return static_cast<uint32_t>(sizeof(g_engine_image)); }

void BuildWellFormedCandidate() {
  for (size_t i = 0; i < sizeof(g_vtable) / sizeof(g_vtable[0]); ++i) {
    g_vtable[i] = reinterpret_cast<uintptr_t>(&g_engine_image[i % 32]);
  }
  g_object[0] = reinterpret_cast<uintptr_t>(&g_vtable[0]);
  g_object[1] = 0u;
}

uintptr_t Candidate() { return reinterpret_cast<uintptr_t>(&g_object[0]); }

void TestWellFormedCandidateIsAccepted() {
  BuildWellFormedCandidate();
  Expect(LooksLikeExporter(Candidate(), ImageBase(), ImageSize(),
                           &DefaultReadableSpan),
         "object whose vtable slots all point into the engine image is accepted");
}

// 一个槽出界就否掉：tp_stub 静态里存的插件自有对象虚表指向插件自己，不指向 exe。
void TestOneSlotOutsideImageIsRejected() {
  BuildWellFormedCandidate();
  g_vtable[kVtableProbeEntries - 1] = reinterpret_cast<uintptr_t>(&g_object[0]);
  Expect(!LooksLikeExporter(Candidate(), ImageBase(), ImageSize(),
                            &DefaultReadableSpan),
         "a single vtable slot outside the engine image rejects the candidate");
}

// 探测深度必须真的是 kVtableProbeEntries：只看第一个槽的实现会漏掉这种候选。
void TestProbeDepthIsHonoured() {
  BuildWellFormedCandidate();
  g_vtable[0] = reinterpret_cast<uintptr_t>(&g_engine_image[0]);
  g_vtable[1] = 0x10u;  // 第二个槽出界
  Expect(!LooksLikeExporter(Candidate(), ImageBase(), ImageSize(),
                            &DefaultReadableSpan),
         "probing stops at neither the first nor the last slot only");
}

// 不可读的候选（永不映射的低地址）必须靠真 VirtualQuery 挡住，而不是解引用崩掉。
void TestUnreadableCandidateIsRejected() {
  Expect(!LooksLikeExporter(0x10u, ImageBase(), ImageSize(), &DefaultReadableSpan),
         "unreadable candidate address is rejected without dereferencing it");
}

void TestUnreadableVtableIsRejected() {
  BuildWellFormedCandidate();
  g_object[0] = 0x10u;  // 首字是个永不映射的地址
  Expect(!LooksLikeExporter(Candidate(), ImageBase(), ImageSize(),
                            &DefaultReadableSpan),
         "unreadable vtable pointer is rejected");
}

void TestDegenerateArgumentsAreRejected() {
  BuildWellFormedCandidate();
  Expect(!LooksLikeExporter(0u, ImageBase(), ImageSize(), &DefaultReadableSpan),
         "zero candidate rejected");
  Expect(!LooksLikeExporter(Candidate(), 0u, ImageSize(), &DefaultReadableSpan),
         "zero image base rejected");
  Expect(!LooksLikeExporter(Candidate(), ImageBase(), 0u, &DefaultReadableSpan),
         "zero image size rejected");
  Expect(!LooksLikeExporter(Candidate(), ImageBase(), ImageSize(), nullptr),
         "null readable probe rejected");
}

// 少于 kMinPlugins 个模块时交集不够窄，必须拒绝而不是给一份宽泛的候选表。
void TestTooFewModulesRejected() {
  std::vector<std::vector<uintptr_t>> few;
  for (size_t i = 0; i + 1 < kMinPlugins; ++i) few.push_back({1u, 2u, 3u});
  std::vector<uintptr_t> out;
  Expect(!IntersectWritableWords(few, &out),
         "fewer than kMinPlugins modules is refused");
  Expect(out.empty(), "refused intersection leaves no candidates");
}

void TestIntersectionKeepsOnlyUniversalValues() {
  std::vector<std::vector<uintptr_t>> modules = {
      {1u, 7u, 9u, 42u},
      {2u, 7u, 42u, 99u},
      {7u, 42u, 43u},
      {5u, 7u, 42u},
  };
  std::vector<uintptr_t> out;
  Expect(IntersectWritableWords(modules, &out), "intersection succeeds");
  Expect(out.size() == 2u, "exactly the two universal values survive");
  Expect(out.size() == 2u && out[0] == 7u && out[1] == 42u,
         "the survivors are 7 and 42, sorted");
}

void TestEmptyIntersectionIsRefused() {
  std::vector<std::vector<uintptr_t>> modules = {{1u, 2u}, {3u, 4u}, {5u, 6u}};
  std::vector<uintptr_t> out;
  Expect(!IntersectWritableWords(modules, &out),
         "an empty intersection is a refusal, not an empty success");
}

void TestCollectSkipsZerosAndDeduplicates() {
  uintptr_t raw[6] = {5u, 0u, 5u, 9u, 0u, 5u};
  std::vector<uintptr_t> out;
  CollectWritableWords(reinterpret_cast<const uint8_t*>(raw), sizeof(raw), &out);
  Expect(out.size() == 2u, "zeros dropped and duplicates collapsed");
  Expect(out.size() == 2u && out[0] == 5u && out[1] == 9u, "sorted unique values");
}

void TestCollectHandlesNullAndShortSpans() {
  std::vector<uintptr_t> out;
  out.push_back(1234u);
  CollectWritableWords(nullptr, 16u, &out);
  Expect(out.empty(), "null section clears the output");
  uintptr_t one = 77u;
  CollectWritableWords(reinterpret_cast<const uint8_t*>(&one), 1u, &out);
  Expect(out.empty(), "a span shorter than one word yields nothing");
}

}  // namespace

int main() {
  TestWellFormedCandidateIsAccepted();
  TestOneSlotOutsideImageIsRejected();
  TestProbeDepthIsHonoured();
  TestUnreadableCandidateIsRejected();
  TestUnreadableVtableIsRejected();
  TestDegenerateArgumentsAreRejected();
  TestTooFewModulesRejected();
  TestIntersectionKeepsOnlyUniversalValues();
  TestEmptyIntersectionIsRefused();
  TestCollectSkipsZerosAndDeduplicates();
  TestCollectHandlesNullAndShortSpans();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  std::printf("kirikiri_exporter_scan_test: ok\n");
  return 0;
}
