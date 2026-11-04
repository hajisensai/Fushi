// BUG-4013 guard: in windowed mode (32-bit processes) a blobs.bin view longer
// than one window step is read into a heap buffer, and that buffer is capped at
// blob_file::kMaxHeapViewBytes.
//
// Why: the length of every such view is read from disk (glossary / meanings
// u32 sizes, offset-table counts) and view() only clamps it to the end of the
// file. A corrupt size therefore asked for "the rest of blobs.bin" on the heap
// -- hundreds of MB to GB inside ~3 GB of address space -- and std::bad_alloc
// crossed the FFI entry points (no try/catch) and aborted the app.
// read_offset_list already rejects tables that run past EOF; this covers the
// lengths that fit in the file but are still absurd.
//
// The test lowers the ceiling with set_blob_heap_view_cap_for_test so a few-MB
// fixture crosses it.
//
// Usage: blob_heap_view_cap_test   (no args) -> exit 0 PASS, non-zero FAIL.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "memory/memory.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

constexpr size_t kStep = memory::blob_file::kWindowStepBytes;

// [u32 count][u64 x count][byte pattern...], 4 window steps long. The pattern
// lets a successful read be checked byte for byte.
std::string write_fixture(uint32_t table_count) {
  std::vector<uint8_t> bytes(4 * kStep);
  for (size_t i = 0; i < bytes.size(); i++) {
    bytes[i] = static_cast<uint8_t>(i * 31 + 7);
  }
  std::memcpy(bytes.data(), &table_count, sizeof(uint32_t));
  const std::string path = fushi_test::temp_dir() + "/fushi_blob_heap_view_cap.bin";
  FILE* fp = std::fopen(path.c_str(), "wb");
  if (!fp) return {};
  std::fwrite(bytes.data(), 1, bytes.size(), fp);
  std::fclose(fp);
  return path;
}

bool pattern_ok(const memory::blob_span& s, uint64_t at) {
  for (size_t i = sizeof(uint32_t); i < s.size; i += 4093) {
    if (s.data[i] != static_cast<uint8_t>((at + i) * 31 + 7)) return false;
  }
  return true;
}

}  // namespace

int main() {
  // Table of 2.5 steps worth of u64s: fits in the file, over a 2-step cap.
  const uint32_t table_count = static_cast<uint32_t>((5 * kStep / 2) / sizeof(uint64_t));
  const std::string path = write_fixture(table_count);
  if (path.empty()) {
    fail("could not write fixture");
    return 1;
  }
  const size_t cap = 2 * kStep;
  memory::set_blob_heap_view_cap_for_test(cap);

  memory::set_blob_mode_for_test(memory::blob_mode::windowed);
  {
    const auto blobs = memory::open_blob_file(path);
    if (!blobs || !blobs->windowed()) {
      fail("windowed blob file not opened");
    } else {
      const memory::blob_span under = blobs->view(0, cap - 1);
      if (!under || under.size != cap - 1 || !pattern_ok(under, 0)) {
        fail("heap view under the cap was not read exactly");
      }
      const memory::blob_span at_cap = blobs->view(0, cap);
      if (!at_cap || at_cap.size != cap) {
        fail("heap view exactly at the cap was refused");
      }
      if (blobs->view(0, cap + 1)) {
        fail("heap view over the cap was allocated");
      }
      if (blobs->view(kStep / 2, 3 * kStep)) {
        fail("heap view over the cap at an unaligned offset was allocated");
      }
      // A window-sized view is not a heap read and is unaffected.
      if (!blobs->view(3 * kStep, kStep)) {
        fail("window-sized view was refused");
      }
      // The offset table fits in the file but its bytes exceed the cap: no span.
      const memory::offset_list list = memory::read_offset_list(*blobs, 0);
      if (list.span) {
        fail("offset table over the heap cap produced a span (" + std::to_string(list.span.size) + " bytes)");
      }
    }
  }

  // Whole-file mode maps the file; views are pointer arithmetic, no heap.
  memory::set_blob_mode_for_test(memory::blob_mode::whole);
  {
    const auto blobs = memory::open_blob_file(path);
    if (!blobs || blobs->windowed()) {
      fail("whole blob file not opened");
    } else {
      const memory::blob_span big = blobs->view(0, 3 * kStep);
      if (!big || big.size != 3 * kStep || !pattern_ok(big, 0)) {
        fail("whole-file view over the heap cap changed");
      }
      const memory::offset_list list = memory::read_offset_list(*blobs, 0);
      if (!list.span || list.count != table_count) {
        fail("whole-file offset table should still be served");
      }
    }
  }

  memory::set_blob_heap_view_cap_for_test(0);
  memory::set_blob_mode_for_test(memory::blob_mode::automatic);
  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
