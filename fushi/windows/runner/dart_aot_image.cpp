#include "dart_aot_image.h"

#include <windows.h>

#include <atomic>

namespace fushi
{
  namespace
  {
    DartAotImageInfo g_cached;
    std::atomic<bool> g_cached_valid{false};

    bool IsReadable(DWORD protect)
    {
      if (protect & (PAGE_NOACCESS | PAGE_GUARD)) return false;
      return (protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY)) != 0;
    }

    // Total size of the allocation starting at [base] (all its regions).
    uint64_t AllocationSize(const uint8_t* base)
    {
      uint64_t total = 0;
      const uint8_t* p = base;
      MEMORY_BASIC_INFORMATION mbi;
      while (VirtualQuery(p, &mbi, sizeof(mbi)) == sizeof(mbi) &&
             mbi.AllocationBase == base) {
        total += mbi.RegionSize;
        p = static_cast<const uint8_t*>(mbi.BaseAddress) + mbi.RegionSize;
      }
      return total;
    }
  }  // namespace

  bool FindDartAotImage(DartAotImageInfo* out)
  {
    if (out == nullptr) return false;
    if (g_cached_valid.load(std::memory_order_acquire)) {
      *out = g_cached;
      return true;
    }
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    const uint8_t* p =
      static_cast<const uint8_t*>(si.lpMinimumApplicationAddress);
    const uint8_t* end =
      static_cast<const uint8_t*>(si.lpMaximumApplicationAddress);
    MEMORY_BASIC_INFORMATION mbi;
    while (p < end && VirtualQuery(p, &mbi, sizeof(mbi)) == sizeof(mbi)) {
      const uint8_t* region = static_cast<const uint8_t*>(mbi.BaseAddress);
      const uint8_t* next = region + mbi.RegionSize;
      // Dart's loader maps app.so into private memory; images LoadLibrary'd
      // (MEM_IMAGE) are PE files and never match the ELF magic anyway.
      if (mbi.State == MEM_COMMIT && mbi.Type == MEM_PRIVATE &&
          mbi.AllocationBase == mbi.BaseAddress && IsReadable(mbi.Protect) &&
          mbi.RegionSize >= 64 && region[0] == 0x7f && region[1] == 'E' &&
          region[2] == 'L' && region[3] == 'F') {
        DartAotImageInfo info;
        if (DescribeLoadedElf(region, mbi.RegionSize, &info) &&
            IsLoadedImageAllocation(AllocationSize(region), info.span)) {
          info.base = reinterpret_cast<uint64_t>(region);
          g_cached = info;
          g_cached_valid.store(true, std::memory_order_release);
          *out = info;
          return true;
        }
      }
      if (next <= p) break;
      p = next;
    }
    return false;
  }
}
