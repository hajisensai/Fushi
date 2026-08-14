#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "voice_hook_ipc.h"

// 游戏内查词的真机诊断读取器（x64 独立小工具）。
//
// 用途：injector 起了游戏之后，用它旁路打开共享内存，把「游戏内查词」开关拨到 1，然后按轮
// 打印查词区的真实状态——传感器装没装、几何是从哪条采集面来的、有没有真上报过命中、命中的
// 整行台词与字形矩形是什么。
//
// 为什么需要它：`lookup_enabled` 是 host 运行期开关，平时只有 Fushi 会置 1。要验证注入侧的
// 传感器，不该被迫先跑通整个 app UI——那样一旦不出卡片，「传感器没装」和「host 没投帧」在
// 现象上完全同形，真机上分不开。本工具把注入侧单独拎出来验，责任边界一刀切开。
//
// 只写 `lookup_enabled` 一个字段（host→hook 的开关，契约里本就归 host 写），其余全部只读：
// 不注入、不投帧、不碰位图区。命名文件映射跨 32/64 位可读写，故 x64 工具能验 32 位游戏。
//
// 用法：fushi_voice_lookup_probe <pid> [轮数=60] [间隔ms=500] [--no-enable]
namespace {

using fushi_voice_hook::kSharedMagic;
using fushi_voice_hook::kSharedVersion;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::SharedMemoryName;

struct DiagBit {
  uint32_t mask;
  const char* name;
};

// 与 include/voice_hook_ipc.h 的 kLookupDiag* 一一对应。手拆十六进制是 SOP 明令禁止的，
// 这张表就是符号化解释。
const DiagBit kDiagBits[] = {
    {fushi_voice_hook::kLookupDiagSensorInstalled, "sensor_installed"},
    {fushi_voice_hook::kLookupDiagGeometryObserved, "geometry_observed"},
    {fushi_voice_hook::kLookupDiagHitSubmitted, "hit_submitted"},
    {fushi_voice_hook::kLookupDiagBufferRouteReady, "buffer_route_ready"},
    {fushi_voice_hook::kLookupDiagFallbackPngRoute, "fallback_png_route"},
    {fushi_voice_hook::kLookupDiagFramePresented, "frame_presented"},
    {fushi_voice_hook::kLookupDiagExpressionReady, "expression_ready"},
    {fushi_voice_hook::kLookupDiagFrameRejected, "frame_rejected"},
    {fushi_voice_hook::kLookupDiagClassicTextSource, "classic_patch_installed"},
    {fushi_voice_hook::kLookupDiagClassicGeometry, "classic_geometry_captured"},
    {fushi_voice_hook::kLookupDiagClassicProcessCh, "classic_processch_fired"},
};

void PrintDiag(uint32_t diag) {
  std::printf("  lookup_diag=0x%08X", diag);
  bool any = false;
  for (const DiagBit& bit : kDiagBits) {
    if ((diag & bit.mask) != 0) {
      std::printf("%s%s", any ? "," : " [", bit.name);
      any = true;
    }
  }
  std::printf("%s\n", any ? "]" : " []");
}

// 命中槽里的整行台词是 UTF-8；控制台按 UTF-8 打印，调用方自行设置代码页。
void PrintHit(const fushi_voice_hook::LookupHitSlot* hit) {
  if (hit == nullptr) return;
  const uint32_t bytes =
      hit->line_bytes <= fushi_voice_hook::kLookupLineBytes
          ? hit->line_bytes
          : fushi_voice_hook::kLookupLineBytes;
  std::string line(reinterpret_cast<const char*>(hit->line_utf8), bytes);
  std::printf(
      "  hit seq=%llu char=%u/%u glyph=(%d,%d %dx%d) view=%dx%d flags=%u\n",
      static_cast<unsigned long long>(hit->seq), hit->char_index,
      hit->char_count, hit->glyph_x, hit->glyph_y, hit->glyph_w, hit->glyph_h,
      hit->view_w, hit->view_h, hit->flags);
  std::printf("  line=%s\n", line.c_str());
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr,
                 "usage: fushi_voice_lookup_probe <pid> [rounds] [interval_ms] "
                 "[--no-enable]\n");
    return 2;
  }
  const DWORD pid = static_cast<DWORD>(std::strtoul(argv[1], nullptr, 10));
  int rounds = argc >= 3 ? std::atoi(argv[2]) : 60;
  int interval = argc >= 4 ? std::atoi(argv[3]) : 500;
  bool enable = true;
  for (int i = 2; i < argc; ++i) {
    if (std::strcmp(argv[i], "--no-enable") == 0) enable = false;
  }
  if (rounds <= 0) rounds = 1;
  if (interval < 50) interval = 50;

  const std::wstring shm = SharedMemoryName(pid);
  HANDLE mapping =
      OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, shm.c_str());
  if (mapping == nullptr) {
    std::fprintf(stderr,
                 "OpenFileMapping failed: %lu (injector did not create shared "
                 "memory for pid=%lu?)\n",
                 GetLastError(), pid);
    return 1;
  }
  SharedHeader* header = reinterpret_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0));
  if (header == nullptr) {
    std::fprintf(stderr, "MapViewOfFile failed: %lu\n", GetLastError());
    CloseHandle(mapping);
    return 1;
  }
  if (header->magic != kSharedMagic) {
    std::fprintf(stderr, "bad magic 0x%08X\n", header->magic);
    return 1;
  }
  std::printf("shm=%ls version=%u (tool built against %u)\n", shm.c_str(),
              header->version, kSharedVersion);
  if (!fushi_voice_hook::HasLookupRegion(header)) {
    std::fprintf(stderr,
                 "no lookup region in this session (offset=%u frames=%u "
                 "slots=%u)\n",
                 header->lookup_region_offset, header->lookup_frame_count,
                 header->lookup_input_slot_count);
    return 1;
  }
  if (enable) {
    header->lookup_enabled = 1;
    std::printf("lookup_enabled <- 1\n");
  }

  const fushi_voice_hook::LookupHitSlot* hit =
      fushi_voice_hook::LookupHitOf(header);
  uint64_t last_hit_seq = 0;
  for (int round = 0; round < rounds; ++round) {
    std::printf("[%02d] text_writes=%llu hits=%llu inputs=%llu frames=%llu\n",
                round,
                static_cast<unsigned long long>(header->text_write_count),
                static_cast<unsigned long long>(header->lookup_hit_count),
                static_cast<unsigned long long>(header->lookup_input_count),
                static_cast<unsigned long long>(
                    header->lookup_frame_count_written));
    PrintDiag(header->lookup_diag);
    if (hit != nullptr && hit->seq != last_hit_seq) {
      last_hit_seq = hit->seq;
      PrintHit(hit);
    }
    std::fflush(stdout);
    Sleep(static_cast<DWORD>(interval));
  }
  UnmapViewOfFile(header);
  CloseHandle(mapping);
  return 0;
}
