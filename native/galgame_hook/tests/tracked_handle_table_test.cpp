// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#include "tracked_handle_table.h"

namespace {

int g_failures = 0;

void Check(bool condition, const char* message) {
  if (condition) return;
  std::fprintf(stderr, "FAIL: %s\n", message);
  ++g_failures;
}

HANDLE Handle(uintptr_t value) { return reinterpret_cast<HANDLE>(value); }

struct PathSlot {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG seq = 0;
  wchar_t path[16] = {0};
};

struct IndexSlot {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG seq = 0;
  uint32_t archive_index = 0;
};

bool CopyPath(PathSlot (&slots)[4], HANDLE handle, wchar_t (&out)[16]) {
  return fushi_voice_hook::ReadTrackedHandle(
      slots, handle,
      [&out](const PathSlot& slot) { wcsncpy_s(out, slot.path, _TRUNCATE); });
}

void RememberPath(PathSlot (&slots)[4], HANDLE handle, const wchar_t* path) {
  fushi_voice_hook::RememberTrackedHandle(
      slots, handle,
      [path](PathSlot& slot) { wcsncpy_s(slot.path, path, _TRUNCATE); });
}

}  // namespace

int main() {
  using fushi_voice_hook::ForgetTrackedHandle;
  using fushi_voice_hook::IsTrackedHandle;
  using fushi_voice_hook::RememberTrackedHandle;

  // ── 基本往返：登记 → 读到 → 摘掉 → 读不到 ──
  {
    PathSlot slots[4];
    wchar_t out[16] = {0};
    RememberPath(slots, Handle(0x10), L"voice.ovk");
    Check(CopyPath(slots, Handle(0x10), out) && wcscmp(out, L"voice.ovk") == 0,
          "remembered handle must read back its path");
    Check(IsTrackedHandle(slots, Handle(0x10)), "IsTrackedHandle must see it");
    Check(!IsTrackedHandle(slots, Handle(0x11)),
          "an unknown handle must not match");
    Check(ForgetTrackedHandle(slots, Handle(0x10)),
          "forget must report the removal");
    Check(!CopyPath(slots, Handle(0x10), out),
          "forgotten handle must not read back");
    Check(!ForgetTrackedHandle(slots, Handle(0x10)),
          "forgetting twice must report nothing removed");
  }

  // ── 无效句柄永远不进表 ──
  {
    IndexSlot slots[2];
    Check(!RememberTrackedHandle(slots, INVALID_HANDLE_VALUE,
                                 [](IndexSlot&) {}),
          "INVALID_HANDLE_VALUE must be rejected");
    Check(!RememberTrackedHandle(slots, nullptr, [](IndexSlot&) {}),
          "nullptr must be rejected");
    Check(!IsTrackedHandle(slots, INVALID_HANDLE_VALUE),
          "INVALID_HANDLE_VALUE never matches an empty slot");
  }

  // ── 同一句柄值再次登记 = 原位重写（漏掉 Forget 时的安全网），不占第二个槽位 ──
  {
    PathSlot slots[4];
    wchar_t out[16] = {0};
    RememberPath(slots, Handle(0x20), L"first");
    RememberPath(slots, Handle(0x20), L"second");
    Check(CopyPath(slots, Handle(0x20), out) && wcscmp(out, L"second") == 0,
          "re-remembering the same handle must rewrite in place");
    int occupied = 0;
    for (const PathSlot& slot : slots) {
      if (slot.handle == Handle(0x20)) ++occupied;
    }
    Check(occupied == 1, "same handle must occupy exactly one slot");
    Check((slots[0].seq & 1) == 0 && slots[0].seq > 0,
          "a published slot rests on an even, non-zero seq");
  }

  // ── 关停清表：只清 handle，不碰 seq（奇数窗口不得被「变稳定」）与附带字段 ──
  {
    PathSlot slots[4];
    RememberPath(slots, Handle(0x70), L"a");
    RememberPath(slots, Handle(0x71), L"b");
    const LONG seq_before = slots[0].seq;
    InterlockedIncrement(&slots[1].seq);  // 模拟槽位 1 正处在写窗口
    fushi_voice_hook::ClearTrackedHandles(slots);
    Check(slots[0].handle == INVALID_HANDLE_VALUE &&
              slots[1].handle == INVALID_HANDLE_VALUE &&
              slots[2].handle == INVALID_HANDLE_VALUE &&
              slots[3].handle == INVALID_HANDLE_VALUE,
          "clear must empty every slot");
    Check(slots[0].seq == seq_before, "clear must not touch a stable seq");
    Check((slots[1].seq & 1) == 1, "clear must not flip an in-flight odd seq");
    Check(wcscmp(slots[0].path, L"a") == 0,
          "clear leaves payload alone; it is unreachable without a handle");
    Check(!IsTrackedHandle(slots, Handle(0x70)), "cleared handle no longer reads");
  }

  // ── 表满返回 false，且不覆盖既有条目 ──
  {
    IndexSlot slots[2];
    Check(RememberTrackedHandle(slots, Handle(0x30),
                                [](IndexSlot& s) { s.archive_index = 3; }),
          "first slot");
    Check(RememberTrackedHandle(slots, Handle(0x31),
                                [](IndexSlot& s) { s.archive_index = 4; }),
          "second slot");
    Check(!RememberTrackedHandle(slots, Handle(0x32),
                                 [](IndexSlot& s) { s.archive_index = 5; }),
          "third handle must be refused when the table is full");
    uint32_t index = 0;
    Check(fushi_voice_hook::ReadTrackedHandle(
              slots, Handle(0x31),
              [&index](const IndexSlot& s) { index = s.archive_index; }) &&
              index == 4,
          "existing entries survive a refused insert");
    Check(ForgetTrackedHandle(slots, Handle(0x30)), "free one slot");
    Check(RememberTrackedHandle(slots, Handle(0x32),
                                [](IndexSlot& s) { s.archive_index = 5; }),
          "freed slot must be reusable");
  }

  // ── Forget 清掉所有同值槽位（僵尸条目会匹配将来复用的句柄值）──
  {
    IndexSlot slots[3];
    slots[0].handle = Handle(0x40);
    slots[2].handle = Handle(0x40);
    Check(ForgetTrackedHandle(slots, Handle(0x40)), "forget reports removal");
    Check(slots[0].handle == INVALID_HANDLE_VALUE &&
              slots[2].handle == INVALID_HANDLE_VALUE,
          "every slot holding the handle must be cleared, not just the first");
    Check(slots[1].handle == INVALID_HANDLE_VALUE, "unrelated slot untouched");
  }

  // ── 读者协议：写入中（seq 为奇数）的槽位被跳过；期间被重写的读取不算命中 ──
  {
    PathSlot slots[4];
    wchar_t out[16] = {0};
    RememberPath(slots, Handle(0x50), L"stable");
    InterlockedIncrement(&slots[0].seq);  // 模拟写者正在改
    Check(!CopyPath(slots, Handle(0x50), out),
          "a slot mid-write (odd seq) must be skipped");
    InterlockedIncrement(&slots[0].seq);
    Check(CopyPath(slots, Handle(0x50), out) && wcscmp(out, L"stable") == 0,
          "once the writer finishes the slot reads normally");

    // 读者拷贝期间槽位被重写：seq 变化 → 拒绝本次读取。
    bool accepted = fushi_voice_hook::ReadTrackedHandle(
        slots, Handle(0x50), [&slots](const PathSlot&) {
          InterlockedIncrement(&slots[0].seq);
          InterlockedIncrement(&slots[0].seq);
        });
    Check(!accepted, "a read torn by a concurrent rewrite must be rejected");
  }

  // ── reserved 占位不会被当成任何真实句柄匹配 ──
  {
    IndexSlot slots[2];
    slots[0].handle = fushi_voice_hook::TrackedHandleReserved();
    Check(!IsTrackedHandle(slots, fushi_voice_hook::TrackedHandleReserved()),
          "reserved marker is not a trackable handle value");
    Check(!ForgetTrackedHandle(slots, Handle(0x1)),
          "reserved marker must never be forgotten by a real close");
    Check(RememberTrackedHandle(slots, Handle(0x60), [](IndexSlot&) {}),
          "a reserved slot is skipped and the next free slot is used");
    Check(slots[1].handle == Handle(0x60), "insert landed on the free slot");
  }

  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::printf("tracked_handle_table_test: all checks passed\n");
  return 0;
}
