// release 也要真断言（同 window_activation_policy_test.cpp 的写法说明）。
#undef NDEBUG

// BUG-5568: the Dart AOT image locator that lets hang / crash dumps be
// symbolized. Runs the pure ELF parsing against hand-built images.

#include "../dart_aot_image.h"
#include "../hang_watchdog.h"

#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

void Put16(std::vector<uint8_t>& b, size_t off, uint16_t v) {
  std::memcpy(b.data() + off, &v, 2);
}
void Put32(std::vector<uint8_t>& b, size_t off, uint32_t v) {
  std::memcpy(b.data() + off, &v, 4);
}
void Put64(std::vector<uint8_t>& b, size_t off, uint64_t v) {
  std::memcpy(b.data() + off, &v, 8);
}

// Same shape as gen_snapshot's app.so: ELF header, PT_LOAD segments, a PT_NOTE
// at 0x200 holding the GNU build-id (16 bytes).
std::vector<uint8_t> MakeImage(uint64_t last_load_end, bool with_build_id) {
  std::vector<uint8_t> b(0x1000, 0);
  std::memcpy(b.data(), "\x7f" "ELF", 4);
  b[4] = 2;  // ELFCLASS64
  b[5] = 1;  // little-endian
  Put16(b, 0x12, 62);  // EM_X86_64
  Put64(b, 0x20, 0x40);  // e_phoff
  Put16(b, 0x36, 56);  // e_phentsize
  Put16(b, 0x38, 3);  // e_phnum
  // PT_LOAD #1: [0, 0x800)
  size_t ph = 0x40;
  Put32(b, ph, 1);
  Put64(b, ph + 0x10, 0);
  Put64(b, ph + 0x20, 0x800);
  Put64(b, ph + 0x28, 0x800);
  // PT_NOTE at 0x200
  ph += 56;
  Put32(b, ph, 4);
  Put64(b, ph + 0x10, 0x200);
  Put64(b, ph + 0x20, with_build_id ? 0x20 : 0);
  Put64(b, ph + 0x28, with_build_id ? 0x20 : 0);
  // PT_LOAD #2: text, ends at last_load_end
  ph += 56;
  Put32(b, ph, 1);
  Put64(b, ph + 0x10, 0x2000);
  Put64(b, ph + 0x20, last_load_end - 0x2000);
  Put64(b, ph + 0x28, last_load_end - 0x2000);
  if (with_build_id) {
    Put32(b, 0x200, 4);   // namesz
    Put32(b, 0x204, 16);  // descsz
    Put32(b, 0x208, 3);   // NT_GNU_BUILD_ID
    std::memcpy(b.data() + 0x20c, "GNU", 4);
    const uint8_t id[16] = {0x68, 0x22, 0xc6, 0x10, 0x2a, 0x7a, 0x2c, 0x3d,
                            0x77, 0xfc, 0x29, 0x7b, 0x8b, 0xf7, 0x34, 0xd1};
    std::memcpy(b.data() + 0x210, id, 16);
  }
  return b;
}

}  // namespace

int main() {
  using fushi::DartAotImageInfo;
  using fushi::DescribeLoadedElf;
  using fushi::FormatDartAotImageLine;
  using fushi::IsLoadedImageAllocation;
  using fushi::IsWatchdogLoopStarved;
  bool passed = true;

  {
    const std::vector<uint8_t> image = MakeImage(0x758c068, true);
    DartAotImageInfo info;
    passed &= Expect(DescribeLoadedElf(image.data(), image.size(), &info),
                     "a gen_snapshot-shaped image parses");
    passed &= Expect(info.span == 0x758c068,
                     "span is the end of the last PT_LOAD segment");
    passed &= Expect(std::string(info.build_id) ==
                         "6822c6102a7a2c3d77fc297b8bf734d1",
                     "build-id is the GNU note, lower-case hex");
    info.base = 0x21eec9a0000ull;
    char line[160];
    passed &= Expect(FormatDartAotImageLine(info, line, sizeof(line)) > 0 &&
                         std::string(line) ==
                             "dart_aot base=0x21eec9a0000 span=0x758c068 "
                             "build_id=6822c6102a7a2c3d77fc297b8bf734d1",
                     "the line the dump stream and the log carry");
    char tiny[8];
    passed &= Expect(FormatDartAotImageLine(info, tiny, sizeof(tiny)) == 0,
                     "a too-small buffer formats nothing");
  }
  {
    const std::vector<uint8_t> image = MakeImage(0x5000, false);
    DartAotImageInfo info;
    passed &= Expect(DescribeLoadedElf(image.data(), image.size(), &info) &&
                         info.build_id[0] == '\0',
                     "an image without a build-id note still parses");
    char line[160];
    FormatDartAotImageLine(info, line, sizeof(line));
    passed &= Expect(std::string(line).find("build_id=none") !=
                         std::string::npos,
                     "a missing build-id is spelled out");
  }
  {
    std::vector<uint8_t> image = MakeImage(0x5000, true);
    DartAotImageInfo info;
    passed &= Expect(!DescribeLoadedElf(image.data(), 0x60, &info),
                     "program headers past the readable bytes are rejected");
    // Build-id note beyond the readable window: the image parses (headers are
    // readable) but the id is not invented from unreadable memory.
    passed &= Expect(DescribeLoadedElf(image.data(), 0x180, &info) &&
                         info.build_id[0] == '\0',
                     "a note past the readable window yields no build-id");
    image[1] = 'X';
    passed &= Expect(!DescribeLoadedElf(image.data(), image.size(), &info),
                     "non-ELF memory is not an image");
    image = MakeImage(0x5000, true);
    Put16(image, 0x12, 183);  // EM_AARCH64
    passed &= Expect(!DescribeLoadedElf(image.data(), image.size(), &info),
                     "only x86-64 images match this runner");
    passed &= Expect(!DescribeLoadedElf(nullptr, 4096, &info),
                     "null image is rejected");
  }

  // Dart's loader also leaves a one-page copy of the ELF header behind; only
  // the allocation that covers the whole span is the loaded image.
  passed &= Expect(!IsLoadedImageAllocation(0x1000, 0x758c068),
                   "the one-page header copy is not the image");
  passed &= Expect(IsLoadedImageAllocation(0x758d000, 0x758c068),
                   "the allocation covering every segment is the image");
  passed &= Expect(!IsLoadedImageAllocation(0x1000, 0),
                   "an empty span never matches");

  passed &= Expect(!IsWatchdogLoopStarved(100), "a normal 100 ms tick");
  passed &= Expect(!IsWatchdogLoopStarved(1999), "just under the threshold");
  passed &= Expect(IsWatchdogLoopStarved(2000),
                   "two seconds without a loop is starvation");

  return passed ? 0 : 1;
}
