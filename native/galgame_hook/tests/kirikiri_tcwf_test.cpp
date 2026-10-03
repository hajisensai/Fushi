// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "kirikiri_tcwf.h"

namespace tcwf = fushi_voice_hook::tcwf;

namespace {

void Put16(std::vector<uint8_t>* v, int32_t x) {
  v->push_back(static_cast<uint8_t>(x));
  v->push_back(static_cast<uint8_t>(x >> 8));
}

void Put32(std::vector<uint8_t>* v, int32_t x) {
  for (int i = 0; i < 4; ++i) v->push_back(static_cast<uint8_t>(x >> (8 * i)));
}

std::vector<uint8_t> Header(uint8_t channels, int32_t blocks,
                            int32_t bytes_per_block, int32_t samples) {
  std::vector<uint8_t> v = {'T', 'C', 'W', 'F', '0', 0x1a, channels, 0};
  Put32(&v, 22050);
  Put32(&v, blocks);
  Put32(&v, bytes_per_block);
  Put32(&v, samples);
  return v;
}

struct Peak {
  uint16_t pos;
  int16_t revise;
};

// 4 样本一块：块头 32 字节 + 2 个码字节。
void Block(std::vector<uint8_t>* v, int16_t s0, int16_t s1, uint8_t bpred,
           uint8_t c2, uint8_t c3, Peak peak = {0, 0}) {
  Put16(v, s0);
  Put16(v, s1);
  Put16(v, 16);  // idelta
  v->push_back(bpred);
  v->push_back(0);  // ima_stepindex
  Put16(v, peak.pos);
  Put16(v, peak.revise);
  for (int i = 1; i < 6; ++i) {
    Put16(v, 0);
    Put16(v, 0);
  }
  v->push_back(c2);
  v->push_back(c3);
}

std::vector<int16_t> Decode(const std::vector<uint8_t>& file,
                            tcwf::Header* h) {
  assert(tcwf::ParseHeader(file.data(), file.size(), h));
  std::vector<uint8_t> wav(tcwf::WavBytes(*h));
  assert(tcwf::DecodeToWav(file.data(), file.size(), *h, wav.data(),
                           wav.size()));
  assert(std::memcmp(wav.data(), "RIFF", 4) == 0);
  assert(std::memcmp(wav.data() + 8, "WAVE", 4) == 0);
  std::vector<int16_t> pcm((wav.size() - tcwf::kWavHeaderBytes) / 2);
  std::memcpy(pcm.data(), wav.data() + tcwf::kWavHeaderBytes, pcm.size() * 2);
  return pcm;
}

}  // namespace

int main() {
  // 单声道一块，手算期望值：
  //   MS 层（bpred=0：predict = 上一个样本）：k=2 码 1 → 1×16+200=216；k=3 码 0 → 216。
  //   IMA 层：k=2 码 0 → diff=7>>3=0；k=3 码 4 → diff=0+7=7，误差累积到 7 → 223。
  //   峰值：pos=1 减 50 → 150（MS 层预测用的仍是修正前的 200）。
  {
    std::vector<uint8_t> f = Header(1, 1, 34, 4);
    Block(&f, 100, 200, 0, 0x01, 0x40, {1, 50});
    tcwf::Header h;
    const std::vector<int16_t> pcm = Decode(f, &h);
    assert(h.channels == 1 && h.frequency == 22050 && h.blocks == 1);
    assert(pcm.size() == 4);
    assert(pcm[0] == 100 && pcm[1] == 150 && pcm[2] == 216 && pcm[3] == 223);
  }
  // 预测系数真的被用上：bpred=1（2×prev - prevprev）→ k=2 = 2×200-100 = 300，k=3 = 400。
  {
    std::vector<uint8_t> f = Header(1, 1, 34, 4);
    Block(&f, 100, 200, 1, 0x00, 0x00);
    tcwf::Header h;
    const std::vector<int16_t> pcm = Decode(f, &h);
    assert(pcm[2] == 300 && pcm[3] == 400);
  }
  // 立体声：每组两块，依次落到声道 0、1，输出交错。
  {
    std::vector<uint8_t> f = Header(2, 1, 34, 4);
    Block(&f, 10, 20, 0, 0x00, 0x00);
    Block(&f, -10, -20, 0, 0x00, 0x00);
    tcwf::Header h;
    const std::vector<int16_t> pcm = Decode(f, &h);
    assert(pcm.size() == 8);
    assert(pcm[0] == 10 && pcm[1] == -10 && pcm[2] == 20 && pcm[3] == -20);
    assert(pcm[6] == 20 && pcm[7] == -20);
  }
  // 头里声称 3 组、实际只有 1 组：按实际字节截断，不越界读。
  {
    std::vector<uint8_t> f = Header(1, 3, 34, 4);
    Block(&f, 1, 2, 0, 0x00, 0x00);
    f.push_back(0);  // 不足一块的残余
    tcwf::Header h;
    assert(tcwf::ParseHeader(f.data(), f.size(), &h));
    assert(h.blocks == 1);
  }
  // 拒绝：魔数不对（Ogg / RIFF 不是 TCWF）、声道越界、码流装不下样本、一块都没有。
  {
    std::vector<uint8_t> f = Header(1, 1, 34, 4);
    Block(&f, 1, 2, 0, 0x00, 0x00);
    tcwf::Header h;
    std::vector<uint8_t> bad = f;
    bad[4] = '1';
    assert(!tcwf::LooksLikeTcwf(bad.data(), bad.size()));
    assert(!tcwf::ParseHeader(bad.data(), bad.size(), &h));
    bad = f;
    bad[6] = 3;
    assert(!tcwf::ParseHeader(bad.data(), bad.size(), &h));
    std::vector<uint8_t> tight = Header(1, 1, 33, 4);  // 32 + 1 < 32 + 2
    assert(!tcwf::ParseHeader(tight.data(), tight.size(), &h));
    std::vector<uint8_t> empty = Header(1, 1, 34, 4);
    assert(!tcwf::ParseHeader(empty.data(), empty.size(), &h));
  }
  // 失步（bpred ≥ 7）与峰值位置越界：整条拒绝，不输出半截音频。
  {
    tcwf::Header h;
    std::vector<uint8_t> f = Header(1, 1, 34, 4);
    Block(&f, 1, 2, 7, 0x00, 0x00);
    assert(tcwf::ParseHeader(f.data(), f.size(), &h));
    std::vector<uint8_t> wav(tcwf::WavBytes(h));
    assert(!tcwf::DecodeToWav(f.data(), f.size(), h, wav.data(), wav.size()));
    std::vector<uint8_t> g = Header(1, 1, 34, 4);
    Block(&g, 1, 2, 0, 0x00, 0x00, {4, 9});
    assert(tcwf::ParseHeader(g.data(), g.size(), &h));
    assert(!tcwf::DecodeToWav(g.data(), g.size(), h, wav.data(), wav.size()));
    // 输出区不够大也拒绝。
    assert(!tcwf::DecodeToWav(g.data(), g.size(), h, wav.data(), wav.size() - 1));
  }
  return 0;
}
