#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

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

// ── 合成帧：把「呈现器能不能真的把位图显示出来」单独验穿 ─────────────────────────
//
// 为什么需要它：注入侧的呈现路径（引擎自己的图层 / 通用分层窗口）在真机上只有一种触发
// 方式——host 收到 hit 后投一帧。于是没有命中源的引擎（Ren'Py / Siglus / CMVS …）根本
// 没法验证呈现这一半，而「卡片不出现」与「host 压根没投帧」在现象上完全同形。
// 本模式扮演 host 投一帧**图案已知**的位图：显示出来就说明呈现器这半是通的，与引擎侧的
// 命中源无关。
//
// 写序严格照抄生产 host（voice_hook_reader.cpp 的 WriteLookupFrame）：
//   ready=0 → 像素 → 元数据 → seq → ready=1 → 推进 lookup_frame_count_written。
// 槽下标同样照契约取「**帧发布序** % lookup_frame_count」，元数据与像素块共用一个下标。
bool PresentTestFrame(SharedHeader* header, int32_t anchor_x, int32_t anchor_y,
                      uint32_t width, uint32_t height) {
  const uint32_t frame_count = header->lookup_frame_count;
  if (frame_count == 0) return false;
  const uint32_t pitch = width * 4u;
  const uint64_t bytes = static_cast<uint64_t>(pitch) * height;
  if (bytes > header->lookup_bitmap_bytes) {
    std::fprintf(stderr, "test frame %ux%u exceeds bitmap budget %u\n", width,
                 height, header->lookup_bitmap_bytes);
    return false;
  }

  const uint64_t publish_seq =
      static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64*>(
              &header->lookup_frame_count_written),
          0, 0)) +
      1u;
  const uint32_t index = static_cast<uint32_t>(publish_seq % frame_count);
  fushi_voice_hook::LookupFrame* frame =
      fushi_voice_hook::LookupFrameAt(header, index);
  uint8_t* dst = fushi_voice_hook::LookupBitmapAt(header, index);
  if (frame == nullptr || dst == nullptr) return false;

  // 图案刻意做成一眼可辨且不可能被别的东西碰巧画出来：品红不透明边框 + 半透明青色
  // 填充 + 一条对角线。alpha 非预乘（契约规定），呈现器负责预乘。
  std::vector<uint8_t> pixels(static_cast<size_t>(bytes));
  for (uint32_t y = 0; y < height; ++y) {
    uint8_t* row = pixels.data() + static_cast<size_t>(y) * pitch;
    for (uint32_t x = 0; x < width; ++x) {
      const bool border = x < 4 || y < 4 || x + 4 >= width || y + 4 >= height;
      const bool diagonal = (x * height) / (width == 0 ? 1 : width) == y;
      uint8_t b = 200, g = 180, r = 0, a = 190;  // 半透明青
      if (diagonal) { b = 0; g = 255; r = 255; a = 255; }
      if (border) { b = 255; g = 0; r = 255; a = 255; }  // 品红边框
      row[x * 4 + 0] = b;
      row[x * 4 + 1] = g;
      row[x * 4 + 2] = r;
      row[x * 4 + 3] = a;
    }
  }

  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 0);
  memcpy(dst, pixels.data(), static_cast<size_t>(bytes));
  frame->width = width;
  frame->height = height;
  frame->pitch = pitch;
  frame->anchor_x = anchor_x;
  frame->anchor_y = anchor_y;
  frame->highlight_start = 0;
  frame->highlight_len = 0;
  frame->byte_len = static_cast<uint32_t>(bytes);
  // hit_seq=0：通用呈现器不做命中围栏；引擎适配器那条会用 ShouldApplyLookupFrame 判
  // `hit_seq == 当前 submit 序`，尚无命中时也正好是 0，两条路径都接受这一帧。
  frame->hit_seq = 0;
  frame->flags = 0;
  frame->reserved = 0;
  frame->reserved2 = 0;
  if (!fushi_voice_hook::IsLookupFrameSane(header, frame)) {
    std::fprintf(stderr, "staged test frame failed IsLookupFrameSane\n");
    return false;
  }
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&frame->seq),
                        static_cast<LONG64>(publish_seq));
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 1);
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64*>(&header->lookup_frame_count_written),
      static_cast<LONG64>(publish_seq));
  std::printf(
      "test frame published: seq=%llu slot=%u %ux%u pitch=%u anchor=(%d,%d)\n",
      static_cast<unsigned long long>(publish_seq), index, width, height, pitch,
      anchor_x, anchor_y);
  return true;
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
  bool test_frame = false;
  for (int i = 2; i < argc; ++i) {
    if (std::strcmp(argv[i], "--no-enable") == 0) enable = false;
    if (std::strcmp(argv[i], "--present-test-frame") == 0) test_frame = true;
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

  if (test_frame) {
    // 先投一帧再进轮询循环：轮询里能看着 lookup_diag 的 frame_presented 位亮起来。
    PresentTestFrame(header, 40, 40, 480, 200);
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
