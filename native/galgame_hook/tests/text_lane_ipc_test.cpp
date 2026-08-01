// v13 文本分道的**核心不变量**测试：一条线程写疯了也挤不掉别的线程的行。
//
// 这是"放开非胜出文本线程"能成立的唯一前提。v12 之前文本区是一块 256 槽全局 FIFO，
// 放开后逐字重绘型 hook 几秒刷穿全环，配对候选被挤出去 → kExpired → 整段降级
// system_loopback（BUG-1159 的失败链）。分道之后覆盖只发生在道内，这条失败链在结构上
// 不存在——本测试就是钉死这个"结构上"。

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "voice_hook_ipc.h"

namespace {

using hibiki_voice_hook::kTextLaneCount;
using hibiki_voice_hook::kTextLaneSlotCount;
using hibiki_voice_hook::kTextSlotBytes;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::TextLane;
using hibiki_voice_hook::TextLaneWrite;
using hibiki_voice_hook::TextSlot;

int g_failures = 0;

void Check(bool condition, const std::string& what) {
  if (!condition) {
    ++g_failures;
    fprintf(stderr, "FAIL: %s\n", what.c_str());
  }
}

// 一块按真实布局摆好的假共享内存：[SharedHeader][文本区]。不需要音频环，文本区偏移
// 直接跟在 header 后面（injector 真实布局里它跟在音频环之后，偏移由 header 字段给出，
// 读写两侧都只认那个字段，所以这里的简化不影响被测逻辑）。
struct FakeMapping {
  std::vector<uint8_t> bytes;

  FakeMapping() {
    const uint64_t text_bytes = hibiki_voice_hook::TextRegionBytes(
        kTextLaneCount, kTextLaneSlotCount);
    bytes.assign(static_cast<size_t>(sizeof(SharedHeader) + text_bytes), 0);
    SharedHeader* h = header();
    h->magic = hibiki_voice_hook::kSharedMagic;
    h->version = hibiki_voice_hook::kSharedVersion;
    h->text_region_offset = static_cast<uint32_t>(sizeof(SharedHeader));
    h->text_lane_count = kTextLaneCount;
    h->text_lane_slot_count = kTextLaneSlotCount;
  }

  SharedHeader* header() {
    return reinterpret_cast<SharedHeader*>(bytes.data());
  }
};

// 写一行台词（UTF-16），返回全局发布序。
uint64_t WriteLine(SharedHeader* header, uint32_t lane_begin, uint32_t lane_end,
                   uint64_t thread_id, const std::wstring& text) {
  TextLaneWrite write;
  write.thread_id = thread_id;
  write.process_id = 4321;
  write.source_kind = hibiki_voice_hook::kTextSourceLuna;
  write.event_kind = hibiki_voice_hook::kTextEventLine;
  write.is_utf8 = 0;
  write.text = text.empty() ? nullptr : text.c_str();
  write.byte_len =
      static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  return hibiki_voice_hook::WriteTextLaneEvent(header, lane_begin, lane_end,
                                               write);
}

// 读出某条线程当前仍在道内的所有行（与 host 读侧同一套寻址与同一套道内校验）。
std::vector<std::wstring> ReadLane(SharedHeader* header, uint64_t thread_id) {
  std::vector<std::wstring> lines;
  const TextLane* lanes = hibiki_voice_hook::TextLanesOf(header);
  if (lanes == nullptr) return lines;
  for (uint32_t lane = 0; lane < header->text_lane_count; ++lane) {
    if (lanes[lane].thread_id != thread_id) continue;
    const uint64_t written = lanes[lane].write_count;
    const uint64_t first =
        written > header->text_lane_slot_count
            ? written - header->text_lane_slot_count + 1
            : 1;
    for (uint64_t lane_seq = first; lane_seq <= written; ++lane_seq) {
      const auto* slot = reinterpret_cast<const TextSlot*>(
          hibiki_voice_hook::TextLaneSlotAt(header, lane, lane_seq));
      if (slot == nullptr || slot->lane_seq != lane_seq) continue;
      const auto* chars = reinterpret_cast<const wchar_t*>(
          reinterpret_cast<const uint8_t*>(slot) + sizeof(TextSlot));
      lines.emplace_back(chars, slot->byte_len / sizeof(wchar_t));
    }
    break;
  }
  return lines;
}

// 核心不变量：逐字重绘线程刷穿自己那条道之后，另一条线程的行一条都不少。
void TestChattyThreadCannotSqueezeOthers() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  const uint64_t kDialogue = 0x1111;
  const uint64_t kRedraw = 0x2222;

  Check(WriteLine(h, 0, kTextLaneCount, kDialogue, L"配对候选一") != 0,
        "台词线程第一行应写入成功");
  Check(WriteLine(h, 0, kTextLaneCount, kDialogue, L"配对候选二") != 0,
        "台词线程第二行应写入成功");

  // 逐字重绘：远超全区总槽数，旧结构下这足以把上面两行冲得一条不剩。
  for (int i = 0; i < 5000; ++i) {
    WriteLine(h, 0, kTextLaneCount, kRedraw, L"あ");
  }

  const std::vector<std::wstring> dialogue = ReadLane(h, kDialogue);
  Check(dialogue.size() == 2, "台词线程的行必须一条不少（分道的全部意义）");
  if (dialogue.size() == 2) {
    Check(dialogue[0] == L"配对候选一", "第一行内容未被破坏");
    Check(dialogue[1] == L"配对候选二", "第二行内容未被破坏");
  }

  // 刷疯的那条道自己按道深覆盖，不会无限增长。
  const std::vector<std::wstring> redraw = ReadLane(h, kRedraw);
  Check(redraw.size() == kTextLaneSlotCount,
        "逐字重绘线程只保留自己那条道的最近 kTextLaneSlotCount 行");
}

// 道内覆盖：同一条线程写满道深之后，留下的是最近的那批。
void TestLaneKeepsMostRecentLines() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  const uint64_t kThread = 0x3333;
  for (uint32_t i = 0; i < kTextLaneSlotCount * 3; ++i) {
    WriteLine(h, 0, kTextLaneCount, kThread,
              L"line" + std::to_wstring(i));
  }
  const std::vector<std::wstring> lines = ReadLane(h, kThread);
  Check(lines.size() == kTextLaneSlotCount, "道内保留条数 = 道深");
  if (lines.size() == kTextLaneSlotCount) {
    const uint32_t first_kept = kTextLaneSlotCount * 3 - kTextLaneSlotCount;
    Check(lines.front() == L"line" + std::to_wstring(first_kept),
          "保留的是最近一批而不是最早一批");
    Check(lines.back() == L"line" + std::to_wstring(kTextLaneSlotCount * 3 - 1),
          "最后一行是最新写入的那条");
  }
}

// 跨进程 writer 分区：Luna（injector 进程）与游戏内 native adapter 各写各的下标区段，
// 永远不会认领到同一条道——进程内的锁串不住另一个进程，这是 v12 已经踩过的坑。
void TestWriterSegmentsNeverShareALane() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  const uint32_t luna_end = hibiki_voice_hook::kLunaThreadPreviewCount;
  const uint32_t native_begin = hibiki_voice_hook::kNativeThreadPreviewStart;

  // 把 Luna 段占满，再让 native 段写：native 必须写进自己的段，而不是抢到 Luna 段里去。
  for (uint32_t i = 0; i < luna_end; ++i) {
    Check(WriteLine(h, 0, luna_end, 0x8000 + i, L"luna") != 0,
          "Luna 段内每条线程都应认领到道");
  }
  Check(WriteLine(h, 0, luna_end, 0x9999, L"overflow") == 0,
        "Luna 段满了就丢弃本行，绝不越界去踩 native 段");

  Check(WriteLine(h, native_begin, kTextLaneCount, 0x7777, L"native") != 0,
        "native 段仍有空道可用（没被 Luna 段占走）");

  const TextLane* lanes = hibiki_voice_hook::TextLanesOf(h);
  bool native_thread_in_native_segment = false;
  for (uint32_t lane = 0; lane < kTextLaneCount; ++lane) {
    if (lanes[lane].thread_id != 0x7777) continue;
    native_thread_in_native_segment = lane >= native_begin;
  }
  Check(native_thread_in_native_segment,
        "游戏内 writer 的道必须落在 native 段下标区间内");
}

// 全局发布序：跨道仍然单调递增，host 的 pollText 游标语义因此不变。
void TestGlobalSequenceStaysMonotonicAcrossLanes() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  uint64_t previous = 0;
  for (int i = 0; i < 40; ++i) {
    const uint64_t thread_id = 0x100 + (i % 7);
    const uint64_t seq =
        WriteLine(h, 0, kTextLaneCount, thread_id, L"x");
    Check(seq == previous + 1, "全局发布序必须跨道连续递增");
    previous = seq;
  }
  Check(h->text_write_count == previous, "header 上的总数与最后一条发布序一致");
}

}  // namespace

int main() {
  TestChattyThreadCannotSqueezeOthers();
  TestLaneKeepsMostRecentLines();
  TestWriterSegmentsNeverShareALane();
  TestGlobalSequenceStaysMonotonicAcrossLanes();
  if (g_failures != 0) {
    fprintf(stderr, "text lane ipc test failures: %d\n", g_failures);
    return 1;
  }
  printf("text lane ipc test ok\n");
  return 0;
}
