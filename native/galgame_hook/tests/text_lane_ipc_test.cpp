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

using fushi_voice_hook::kTextLaneCount;
using fushi_voice_hook::kTextLaneSlotCount;
using fushi_voice_hook::kTextSlotBytes;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::TextLane;
using fushi_voice_hook::TextLaneWrite;
using fushi_voice_hook::TextSlot;

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
    const uint64_t text_bytes = fushi_voice_hook::TextRegionBytes(
        kTextLaneCount, kTextLaneSlotCount);
    bytes.assign(static_cast<size_t>(sizeof(SharedHeader) + text_bytes), 0);
    SharedHeader* h = header();
    h->magic = fushi_voice_hook::kSharedMagic;
    h->version = fushi_voice_hook::kSharedVersion;
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
  write.source_kind = fushi_voice_hook::kTextSourceLuna;
  write.event_kind = fushi_voice_hook::kTextEventLine;
  write.is_utf8 = 0;
  write.text = text.empty() ? nullptr : text.c_str();
  write.byte_len =
      static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  return fushi_voice_hook::WriteTextLaneEvent(header, lane_begin, lane_end,
                                               write);
}

// 读出某条线程当前仍在道内的所有行（与 host 读侧同一套寻址与同一套道内校验）。
std::vector<std::wstring> ReadLane(SharedHeader* header, uint64_t thread_id) {
  std::vector<std::wstring> lines;
  const TextLane* lanes = fushi_voice_hook::TextLanesOf(header);
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
          fushi_voice_hook::TextLaneSlotAt(header, lane, lane_seq));
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
  const uint32_t luna_end = fushi_voice_hook::kLunaThreadPreviewCount;
  const uint32_t native_begin = fushi_voice_hook::kNativeThreadPreviewStart;

  // 把 Luna 段占满，再让 native 段写：native 必须写进自己的段，而不是抢到 Luna 段里去。
  for (uint32_t i = 0; i < luna_end; ++i) {
    Check(WriteLine(h, 0, luna_end, 0x8000 + i, L"luna") != 0,
          "Luna 段内每条线程都应认领到道");
  }
  // Luna 段满了之后仍然写得进（回收本段内最久没写的道），但**绝不越界**去踩 native 段：
  // 越界就等于两个进程的 writer 抢同一条道，进程内的锁串不住另一个进程。
  Check(WriteLine(h, 0, luna_end, 0x9999, L"overflow") != 0,
        "段内满了应回收本段的道，而不是丢弃");
  {
    const TextLane* all = fushi_voice_hook::TextLanesOf(h);
    bool inside_luna_segment = false;
    for (uint32_t i = 0; i < kTextLaneCount; ++i) {
      if (all[i].thread_id != 0x9999) continue;
      inside_luna_segment = i < luna_end;
    }
    Check(inside_luna_segment, "Luna 段的回收不得越界到 native 段");
  }

  Check(WriteLine(h, native_begin, kTextLaneCount, 0x7777, L"native") != 0,
        "native 段仍有空道可用（没被 Luna 段占走）");

  const TextLane* lanes = fushi_voice_hook::TextLanesOf(h);
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

// 道用尽必须**可观测且可降级**，不能静默丢弃。
//
// 道满的症状（某些线程的台词就是不来）与 v13 要根治的 256 槽挤压完全同形；而放开非胜出
// 线程本身抬高了道满概率。所以：先回收最久没写的**非选定**道（计数），选定线程那条道
// 任何情况下不许被顶掉（它是配对路径的输入），实在无可回收才丢弃（另一个计数）。
void TestLaneExhaustionIsRecycledAndCounted() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  const uint32_t luna_end = fushi_voice_hook::kLunaThreadPreviewCount;
  const uint64_t kSelected = 0x5555;
  h->selected_text_thread_id = kSelected;

  // 选定线程先占一条道，且让它成为**最久没写**的那条（后面所有线程都比它新）。
  Check(WriteLine(h, 0, luna_end, kSelected, L"配対候補") != 0, "选定线程应认领到道");
  // 其余道占满：注意 last_write_ms 用的是 GetTickCount64，同一毫秒内可能相等，
  // 因此判据只看「选定线程那条道没被顶掉」，不依赖具体挑中了哪一条。
  for (uint32_t i = 1; i < luna_end; ++i) {
    Check(WriteLine(h, 0, luna_end, 0x8000 + i, L"other") != 0,
          "空道用完之前每条线程都应认领到道");
  }
  Check(h->text_lane_recycle_count == 0, "还没满就不该有回收");
  Check(h->text_lane_overflow_count == 0, "还没满就不该有丢弃");

  // 再来一条新线程：道已满 → 必须回收一条非选定道，且计数 +1、本行仍然写成功。
  Check(WriteLine(h, 0, luna_end, 0x9001, L"newcomer") != 0,
        "道满时应回收一条非选定道，而不是丢弃本行");
  Check(h->text_lane_recycle_count == 1, "回收必须计数（真机据此分辨道不够用）");
  Check(h->text_lane_overflow_count == 0, "还有可回收的道时不该记丢弃");

  // 选定线程那条道必须还在，且内容没被顶掉——它是配对路径的输入。
  const std::vector<std::wstring> selected_lines = ReadLane(h, kSelected);
  Check(selected_lines.size() == 1 && selected_lines[0] == L"配対候補",
        "选定线程那条道任何情况下不得被回收");

  // 极端：所有道都归选定线程（无可回收）→ 只能丢弃，且必须计数。
  FakeMapping full;
  SharedHeader* fh = full.header();
  fh->selected_text_thread_id = kSelected;
  for (uint32_t i = 0; i < luna_end; ++i) {
    WriteLine(fh, 0, luna_end, kSelected, L"same thread");
  }
  // 同一线程只占一条道，这里再把剩余道用别的线程占满，然后把它们全设成选定线程。
  for (uint32_t i = 1; i < luna_end; ++i) {
    WriteLine(fh, 0, luna_end, 0x7000 + i, L"filler");
  }
  fushi_voice_hook::TextLane* lanes = fushi_voice_hook::TextLanesOf(fh);
  for (uint32_t i = 0; i < luna_end; ++i) lanes[i].thread_id = kSelected;
  Check(WriteLine(fh, 0, luna_end, 0x9002, L"dropped") == 0,
        "无可回收的道时本行只能丢弃");
  Check(fh->text_lane_overflow_count == 1, "丢弃必须计数，绝不静默");
}

}  // namespace

int main() {
  TestChattyThreadCannotSqueezeOthers();
  TestLaneKeepsMostRecentLines();
  TestWriterSegmentsNeverShareALane();
  TestGlobalSequenceStaysMonotonicAcrossLanes();
  TestLaneExhaustionIsRecycledAndCounted();
  if (g_failures != 0) {
    fprintf(stderr, "text lane ipc test failures: %d\n", g_failures);
    return 1;
  }
  printf("text lane ipc test ok\n");
  return 0;
}
