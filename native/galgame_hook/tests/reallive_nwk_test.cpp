// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "../include/reallive_nwk.h"

// 合成字节，不含任何游戏数据。压缩块由本文件的比特写入器按格式手工编码，期望样本按
// 格式语义逐步手算（不调用被测解码器求期望值）。

namespace nwk = fushi_voice_hook::reallive;

namespace {

void PutLe16(std::vector<uint8_t>* out, uint16_t value) {
  out->push_back(static_cast<uint8_t>(value));
  out->push_back(static_cast<uint8_t>(value >> 8));
}

void PutLe32(std::vector<uint8_t>* out, uint32_t value) {
  for (int i = 0; i < 4; ++i) out->push_back(static_cast<uint8_t>(value >> (8 * i)));
}

void SetLe32(std::vector<uint8_t>* out, size_t at, uint32_t value) {
  for (int i = 0; i < 4; ++i) (*out)[at + i] = static_cast<uint8_t>(value >> (8 * i));
}

class BitWriter {
 public:
  void Put(uint32_t value, uint32_t bits) {
    for (uint32_t i = 0; i < bits; ++i) {
      if ((position_ >> 3) >= bytes_.size()) bytes_.push_back(0);
      if ((value >> i) & 1u) {
        bytes_[position_ >> 3] |= static_cast<uint8_t>(1u << (position_ & 7u));
      }
      ++position_;
    }
  }
  const std::vector<uint8_t>& bytes() const { return bytes_; }

 private:
  std::vector<uint8_t> bytes_;
  size_t position_ = 0;
};

struct Block {
  std::vector<int16_t> initial;
  std::vector<uint8_t> bits;
};

std::vector<uint8_t> BuildCompressedNwa(uint16_t channels, int32_t level,
                                        bool runlength,
                                        const std::vector<Block>& blocks,
                                        uint32_t block_samples,
                                        uint32_t last_block_samples) {
  std::vector<uint8_t> nwa;
  const uint32_t count = static_cast<uint32_t>(blocks.size());
  const uint32_t samples = (count - 1) * block_samples + last_block_samples;
  PutLe16(&nwa, channels);
  PutLe16(&nwa, 16);
  PutLe32(&nwa, 22050);
  PutLe32(&nwa, static_cast<uint32_t>(level));
  PutLe32(&nwa, runlength ? 1u : 0u);
  PutLe32(&nwa, count);
  PutLe32(&nwa, samples * 2u);
  PutLe32(&nwa, 0);  // compressed_bytes，末尾回填
  PutLe32(&nwa, samples);
  PutLe32(&nwa, block_samples);
  PutLe32(&nwa, last_block_samples);
  PutLe32(&nwa, 0);
  const size_t table = nwa.size();
  for (uint32_t i = 0; i < count; ++i) PutLe32(&nwa, 0);
  for (uint32_t i = 0; i < count; ++i) {
    SetLe32(&nwa, table + i * 4u, static_cast<uint32_t>(nwa.size()));
    for (int16_t v : blocks[i].initial) PutLe16(&nwa, static_cast<uint16_t>(v));
    nwa.insert(nwa.end(), blocks[i].bits.begin(), blocks[i].bits.end());
  }
  SetLe32(&nwa, 24, static_cast<uint32_t>(nwa.size()));
  return nwa;
}

std::vector<int16_t> DecodeToSamples(const std::vector<uint8_t>& nwa,
                                     nwk::NwaHeader* header_out = nullptr) {
  nwk::NwaHeader h;
  assert(nwk::ParseNwaHeader(nwa.data(), nwa.size(), &h));
  std::vector<uint8_t> wav(nwk::NwaWavBytes(h));
  assert(nwk::DecodeNwaToWav(nwa.data(), nwa.size(), h, wav.data(), wav.size()));
  assert(std::memcmp(wav.data(), "RIFF", 4) == 0);
  assert(std::memcmp(wav.data() + 8, "WAVEfmt ", 8) == 0);
  assert(std::memcmp(wav.data() + 36, "data", 4) == 0);
  assert(nwk::NwkReadLe32(wav.data() + 40) == h.data_bytes);
  assert(nwk::NwkReadLe16(wav.data() + 22) == h.channels);
  assert(nwk::NwkReadLe32(wav.data() + 24) == h.sample_rate);
  assert(nwk::NwkReadLe16(wav.data() + 34) == 16);
  std::vector<int16_t> samples(h.sample_count);
  std::memcpy(samples.data(), wav.data() + nwk::kWavHeaderBytes, h.data_bytes);
  if (header_out != nullptr) *header_out = h;
  return samples;
}

void TestRawPcm() {
  std::vector<uint8_t> nwa;
  PutLe16(&nwa, 2);
  PutLe16(&nwa, 16);
  PutLe32(&nwa, 44100);
  PutLe32(&nwa, static_cast<uint32_t>(-1));
  PutLe32(&nwa, 0);
  PutLe32(&nwa, 0);
  PutLe32(&nwa, 8);  // 两帧立体声
  PutLe32(&nwa, 0);
  PutLe32(&nwa, 0);
  PutLe32(&nwa, 0);
  PutLe32(&nwa, 0);
  PutLe32(&nwa, 0);
  const int16_t pcm[4] = {1, -2, 300, -32768};
  for (int16_t v : pcm) PutLe16(&nwa, static_cast<uint16_t>(v));
  assert(nwk::LooksLikeNwaHeaderPrefix(nwa.data(), nwa.size()));
  nwk::NwaHeader h;
  const std::vector<int16_t> out = DecodeToSamples(nwa, &h);
  assert(h.complevel == -1 && h.channels == 2 && h.sample_count == 4);
  assert(out.size() == 4 && std::memcmp(out.data(), pcm, sizeof(pcm)) == 0);

  // 声明的 PCM 比实际字节多 → 拒绝。
  nwa.resize(nwa.size() - 2);
  assert(!nwk::ParseNwaHeader(nwa.data(), nwa.size(), &h));
}

void TestCompressedMonoLevel4WithRunlength() {
  // complevel 4：type 1..6 宽 7 位、位移 1+type；type 7 宽 8 位、位移 9。
  BitWriter b0;
  b0.Put(1, 3); b0.Put(3, 7);             // +3<<2   → 1012
  b0.Put(2, 3); b0.Put(0x40 | 5, 7);      // -5<<3   → 972
  b0.Put(0, 3); b0.Put(1, 1); b0.Put(2, 2);  // 游程 2：972 共 3 次
  b0.Put(7, 3); b0.Put(0, 1); b0.Put(0x80 | 1, 8);  // -1<<9 → 460
  b0.Put(7, 3); b0.Put(1, 1);             // 归零 → 0
  b0.Put(6, 3); b0.Put(1, 7);             // +1<<7   → 128
  b0.Put(0, 3); b0.Put(0, 1);             // 游程 0：128 一次
  b0.Put(0, 3); b0.Put(1, 1); b0.Put(3, 2); b0.Put(4, 8);  // 游程 4：128 共 5 次
  BitWriter b1;
  b1.Put(1, 3); b1.Put(1, 7);             // 块 2：-5 + 1<<2 → -1
  const std::vector<Block> blocks = {{{1000}, b0.bytes()}, {{-5}, b1.bytes()}};
  const std::vector<uint8_t> nwa =
      BuildCompressedNwa(1, 4, true, blocks, 14, 2);
  assert(nwk::LooksLikeNwaHeaderPrefix(nwa.data(), nwa.size()));
  const std::vector<int16_t> out = DecodeToSamples(nwa);
  const std::vector<int16_t> expected = {1012, 972, 972, 972, 972, 460, 0, 128,
                                         128, 128, 128, 128, 128, 128, -1, -1};
  // 最后一块只有 2 个样本：第一个是差分后的 -1，第二个是比特流读尽后的
  // type 0（全零填充位）重复当前值。
  assert(out == expected);

  // 截断最后一块的比特流 → 比特流溢出 → 整条拒绝，不输出半截音频。
  std::vector<uint8_t> truncated = nwa;
  truncated.resize(truncated.size() - b1.bytes().size());
  SetLe32(&truncated, 24, static_cast<uint32_t>(truncated.size()));
  nwk::NwaHeader h;
  if (nwk::ParseNwaHeader(truncated.data(), truncated.size(), &h)) {
    std::vector<uint8_t> wav(nwk::NwaWavBytes(h));
    assert(!nwk::DecodeNwaToWav(truncated.data(), truncated.size(), h,
                                wav.data(), wav.size()));
  }
}

void TestCompressedStereoLevel2WithoutRunlength() {
  // complevel 2：type 1..6 宽 3 位、位移 4+type；type 7 宽 6 位、位移 11；
  // 无游程时 type 0 仅重复当前声道值。声道交替 L/R。
  BitWriter b;
  b.Put(1, 3); b.Put(1, 3);            // L += 1<<5  → 132
  b.Put(3, 3); b.Put(4 | 1, 3);        // R -= 1<<7  → -228
  b.Put(0, 3);                         // L 不变     → 132
  b.Put(7, 3); b.Put(0, 1); b.Put(2, 6);  // R += 2<<11 → 3868
  const std::vector<Block> blocks = {{{100, -100}, b.bytes()}};
  const std::vector<uint8_t> nwa =
      BuildCompressedNwa(2, 2, false, blocks, 4, 4);
  const std::vector<int16_t> out = DecodeToSamples(nwa);
  const std::vector<int16_t> expected = {132, -228, 132, 3868};
  assert(out == expected);
}

void TestHeaderRejections() {
  BitWriter b;
  b.Put(0, 3);
  const std::vector<Block> blocks = {{{0}, b.bytes()}};
  const std::vector<uint8_t> good = BuildCompressedNwa(1, 3, false, blocks, 1, 1);
  nwk::NwaHeader h;
  assert(nwk::ParseNwaHeader(good.data(), good.size(), &h));

  std::vector<uint8_t> bad = good;
  bad[0] = 3;  // 3 声道
  assert(!nwk::ParseNwaHeader(bad.data(), bad.size(), &h));
  assert(!nwk::LooksLikeNwaHeaderPrefix(bad.data(), bad.size()));
  bad = good;
  bad[2] = 8;  // 8-bit：符号约定无实测证据，拒绝
  assert(!nwk::ParseNwaHeader(bad.data(), bad.size(), &h));
  bad = good;
  SetLe32(&bad, 8, 6);  // complevel 6
  assert(!nwk::ParseNwaHeader(bad.data(), bad.size(), &h));
  bad = good;
  SetLe32(&bad, 28, 2);  // sample_count 与块数不一致
  assert(!nwk::ParseNwaHeader(bad.data(), bad.size(), &h));
  bad = good;
  SetLe32(&bad, nwk::kNwaHeaderBytes, 4);  // 块偏移压住头
  assert(!nwk::ParseNwaHeader(bad.data(), bad.size(), &h));
  bad = good;
  SetLe32(&bad, 24, static_cast<uint32_t>(bad.size() + 1));  // 压缩长度越界
  assert(!nwk::ParseNwaHeader(bad.data(), bad.size(), &h));
  assert(!nwk::ParseNwaHeader(good.data(), nwk::kNwaHeaderBytes - 1, &h));
}

void TestNwkIndex() {
  // count=2，索引表 4+24=28 字节；两项各 50 字节首尾相接。
  std::vector<uint8_t> index;
  PutLe32(&index, 2);
  PutLe32(&index, 50); PutLe32(&index, 28); PutLe32(&index, 529);
  PutLe32(&index, 50); PutLe32(&index, 78); PutLe32(&index, 550);
  const uint64_t file_bytes = 128;
  nwk::NwkEntry entry;
  assert(nwk::FindNwkEntryAtOffset(index.data(), index.size(), file_bytes, 78, &entry));
  assert(entry.byte_len == 50 && entry.offset == 78 && entry.voice_id == 550);
  // 不是任何成员起点（块读 / 索引读）→ 不命中。
  assert(!nwk::FindNwkEntryAtOffset(index.data(), index.size(), file_bytes, 80, &entry));
  assert(!nwk::FindNwkEntryAtOffset(index.data(), index.size(), file_bytes, 0, &entry));
  // 任一项越出文件 → 整个归档不可信。
  assert(!nwk::FindNwkEntryAtOffset(index.data(), index.size(), 127, 28, &entry));
  // 成员压住索引表 → 拒绝。
  std::vector<uint8_t> overlap = index;
  SetLe32(&overlap, 8, 20);
  assert(!nwk::FindNwkEntryAtOffset(overlap.data(), overlap.size(), file_bytes, 20, &entry));
  // 索引被截断 / count 为 0 / count 超上界。
  assert(!nwk::FindNwkEntryAtOffset(index.data(), index.size() - 1, file_bytes, 28, &entry));
  std::vector<uint8_t> zero = index;
  SetLe32(&zero, 0, 0);
  assert(!nwk::FindNwkEntryAtOffset(zero.data(), zero.size(), file_bytes, 28, &entry));
  std::vector<uint8_t> huge = index;
  SetLe32(&huge, 0, nwk::kMaxNwkEntryCount + 1);
  assert(!nwk::FindNwkEntryAtOffset(huge.data(), huge.size(), file_bytes, 28, &entry));
  // 读索引头的 ReadFile 不得被回调当成 NWA 头投任务。
  assert(!nwk::LooksLikeNwaHeaderPrefix(index.data(), index.size()));
  // 过短的读不判。
  assert(!nwk::LooksLikeNwaHeaderPrefix(index.data(), 15));
}

}  // namespace

int main() {
  TestRawPcm();
  TestCompressedMonoLevel4WithRunlength();
  TestCompressedStereoLevel2WithoutRunlength();
  TestHeaderRejections();
  TestNwkIndex();
  std::puts("reallive_nwk_test: all passed");
  return 0;
}
