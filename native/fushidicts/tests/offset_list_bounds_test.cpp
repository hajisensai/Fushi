// BUG-4013 guard: a blobs.bin offset table whose u32 count claims more u64s
// than the file still holds is rejected, not read.
//
// Why: in a 32-bit process blob_file serves views longer than one window step
// from a heap buffer sized by the request. The table length comes straight
// from the on-disk count, and view() only clamps it to the end of the file, so
// a corrupt count turned into "allocate the rest of blobs.bin" -- hundreds of
// MB to GB inside ~3 GB of address space. std::bad_alloc then crossed the FFI
// entry points (no try/catch) and aborted the app. A table that runs past the
// end of the file is corrupt either way, so read_offset_list treats it like an
// unreadable header: empty span, no allocation.
//
// Usage: offset_list_bounds_test   (no args) -> exit 0 PASS, non-zero FAIL.

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

void put_u32(std::vector<uint8_t>& out, uint32_t v) {
  uint8_t b[4];
  std::memcpy(b, &v, 4);
  out.insert(out.end(), b, b + 4);
}

void put_u64(std::vector<uint8_t>& out, uint64_t v) {
  uint8_t b[8];
  std::memcpy(b, &v, 8);
  out.insert(out.end(), b, b + 8);
}

std::string write_file(const std::string& name, const std::vector<uint8_t>& bytes) {
  const std::string path = fushi_test::temp_dir() + "/fushi_offset_list_" + name + ".bin";
  FILE* fp = std::fopen(path.c_str(), "wb");
  if (!fp) return {};
  std::fwrite(bytes.data(), 1, bytes.size(), fp);
  std::fclose(fp);
  return path;
}

struct fixture {
  std::string path;
  uint64_t good_at = 0;
  uint64_t bad_at = 0;
};

// Layout: [intact table: count=3, 3 u64s] [bad table: count=claimed, 2 u64s]
// [zero padding]. The padding makes the bad table's clamped tail longer than
// one window step, so the windowed path would take the heap read.
fixture build(const std::string& name, uint32_t claimed, size_t padding) {
  std::vector<uint8_t> bytes;
  fixture f;
  f.good_at = bytes.size();
  put_u32(bytes, 3);
  put_u64(bytes, 11);
  put_u64(bytes, 22);
  put_u64(bytes, 33);
  f.bad_at = bytes.size();
  put_u32(bytes, claimed);
  put_u64(bytes, 44);
  put_u64(bytes, 55);
  bytes.resize(bytes.size() + padding, 0);
  f.path = write_file(name, bytes);
  return f;
}

void check_mode(memory::blob_mode mode, const std::string& label) {
  memory::set_blob_mode_for_test(mode);
  const size_t padding = 3 * memory::blob_file::kWindowStepBytes;
  // Bytes after the bad header: 2 u64s + padding. One u64 more than fits.
  const uint32_t just_over = static_cast<uint32_t>((2 * sizeof(uint64_t) + padding) / sizeof(uint64_t) + 1);
  const struct {
    const char* name;
    uint32_t claimed;
  } cases[] = {{"huge", 0xFFFFFFFFu}, {"just_over", just_over}};
  for (const auto& c : cases) {
    const std::string tag = label + "_" + c.name;
    const fixture f = build(tag, c.claimed, padding);
    if (f.path.empty()) {
      fail(tag + ": could not write fixture");
      continue;
    }
    const auto blobs = memory::open_blob_file(f.path);
    if (!blobs) {
      fail(tag + ": open_blob_file failed");
      continue;
    }
    if ((mode == memory::blob_mode::windowed) != blobs->windowed()) {
      fail(tag + ": blob mode not applied");
    }

    const memory::offset_list good = memory::read_offset_list(*blobs, f.good_at);
    if (!good.span || good.count != 3 || good.span.size != 3 * sizeof(uint64_t)) {
      fail(tag + ": intact table not read exactly");
    } else {
      uint64_t second = 0;
      std::memcpy(&second, good.span.data + sizeof(uint64_t), sizeof(uint64_t));
      if (second != 22) fail(tag + ": intact table content wrong");
    }

    const memory::offset_list bad = memory::read_offset_list(*blobs, f.bad_at);
    if (bad.span) {
      fail(tag + ": table running past EOF was read (" + std::to_string(bad.span.size) + " bytes)");
    }

    // Header past EOF / straddling EOF.
    if (memory::read_offset_list(*blobs, blobs->size()).span ||
        memory::read_offset_list(*blobs, blobs->size() - 2).span) {
      fail(tag + ": unreadable header produced a span");
    }
  }
}

}  // namespace

int main() {
  check_mode(memory::blob_mode::whole, "whole");
  check_mode(memory::blob_mode::windowed, "windowed");
  memory::set_blob_mode_for_test(memory::blob_mode::automatic);
  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
